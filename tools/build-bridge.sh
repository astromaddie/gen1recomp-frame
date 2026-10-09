#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 3 ]]; then
  image=gen1recomp-frame-builder:latest
  source_arg="$1"
  runtime_arg="$2"
  output_arg="$3"
elif [[ "$#" -eq 4 ]]; then
  image="$1"
  source_arg="$2"
  runtime_arg="$3"
  output_arg="$4"
else
  echo 'usage: build-bridge.sh [IMAGE] SOURCE_ROOT RUNTIME_ROOT OUTPUT_SO' >&2
  exit 2
fi
source_root="$(cd "$source_arg" && pwd)"
runtime_root="$(cd "$runtime_arg" && pwd)"
output="$output_arg"
output="$(python3 - "$output" <<'PYRESOLVE'
from pathlib import Path
import sys
print(Path(sys.argv[1]).resolve())
PYRESOLVE
)"
output_name="$(basename "$output")"
[[ "$output_name" == xrbridge.so ]] || { echo 'Output filename must be xrbridge.so' >&2; exit 2; }
[[ -f "$source_root/vrbridge/CMakeLists.txt" && -f "$source_root/vrbridge/xrbridge.cpp" && -f "$source_root/vrbridge/Telemetry.h" && -f "$source_root/vrbridge/VisibilitySelection.h" && -f "$source_root/vrbridge/VisibilitySelection.cpp" ]] || {
  echo "Native bridge sources are missing under $source_root/vrbridge" >&2; exit 2;
}
[[ -s "$runtime_root/runtime/lib/liblove-11.5.so" ]] || {
  echo "Matching runtime export missing under $runtime_root/runtime" >&2; exit 2;
}
[[ "$output" != "$source_root" && "$output" != "$source_root"/* ]] || {
  echo 'Bridge output must remain outside the source tree' >&2; exit 2;
}
output_dir="$(dirname "$output")"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
output="$output_dir/xrbridge.so"
report="$output_dir/xrbridge.build.json"
deps="$output_dir/xrbridge-dependency-closure.txt"
checks="$output_dir/xrbridge-checks.json"
log="$output_dir/xrbridge-build-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
for artifact in "$output" "$report" "$deps" "$checks"; do
  [[ ! -e "$artifact" ]] || { echo "Refusing to overwrite $artifact" >&2; exit 2; }
done
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
image_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
[[ "$image_platform" == linux/arm64 ]] || { echo "Builder image must be linux/arm64 (got $image_platform)" >&2; exit 2; }
kit_root="$(cd "$(dirname "$0")/.." && pwd)"
read_source_identity() {
  python3 - "$source_root" <<'PYSOURCE'
import hashlib, json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
def git(*args):
    result = subprocess.run(['git', '-C', str(root), *args], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout.strip() if result.returncode == 0 else None
files = {}
for rel in ('vrbridge/CMakeLists.txt', 'vrbridge/xrbridge.cpp', 'vrbridge/Telemetry.h', 'vrbridge/VisibilitySelection.h', 'vrbridge/VisibilitySelection.cpp'):
    files[rel] = hashlib.sha256((root / rel).read_bytes()).hexdigest()
status = git('status', '--porcelain=v1', '--untracked-files=all')
print(json.dumps({'head': git('rev-parse', 'HEAD'),
                  'status_porcelain': status.splitlines() if status else [],
                  'files': files}, sort_keys=True))
PYSOURCE
}
source_before="$(read_source_identity)"
if docker run --rm --platform linux/arm64 \
  -v "$kit_root:/kit:ro" -v "$source_root:/src:ro" \
  -v "$runtime_root:/runtime:ro" -v "$output_dir:/out" "$image" \
  bash /kit/tools/build-bridge-in-container.sh >"$log" 2>&1; then
  source_after="$(read_source_identity)"
  if [[ "$source_before" != "$source_after" ]]; then
    echo 'Native bridge source changed during build; refusing build receipt.' >&2
    rm -f "$output" "$deps" "$checks"
    exit 1
  fi
  python3 - "$image_id" "$image_platform" "$output_dir" "$source_before" <<'PYMETA'
import json, sys
from pathlib import Path
image_id, platform, directory = sys.argv[1:4]
root = Path(directory)
source = json.loads(sys.argv[4])
checks = json.loads((root / 'xrbridge-checks.json').read_text())
report = {
    'format': 'xrbridge-build-v1',
    'runtime_image_id': image_id,
    'runtime_platform': platform,
    'source': source,
    'artifacts': checks['artifacts'],
    'checks': checks['checks'],
}
(root / 'xrbridge.build.json').write_text(json.dumps(report, indent=2) + '\n')
(root / 'xrbridge-checks.json').unlink()
PYMETA
  tail -n 8 "$log"
  printf 'Bridge build metadata: %s/xrbridge.build.json\n' "$output_dir"
else
  result=$?
  tail -n 80 "$log" >&2
  printf 'Full failed bridge build log: %s\n' "$log" >&2
  rm -f "$output" "$deps" "$checks"
  exit "$result"
fi
