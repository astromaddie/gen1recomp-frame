#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -eq 1 ]]; then
    image=gen1recomp-frame-builder:latest
    output="$1"
elif [[ "$#" -eq 2 ]]; then
    image="$1"
    output="$2"
else
    echo 'usage: build-runtime.sh [IMAGE] OUTPUT_DIR' >&2
    exit 2
fi
kit_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
image_platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
log="$output/runtime-export.log"
if docker run --rm --platform linux/arm64 \
  -v "$kit_dir:/kit:ro" -v "$output:/out" "$image" \
  bash /kit/tools/export-runtime.sh /out/runtime >"$log" 2>&1; then
    python3 - "$image" "$image_id" "$image_platform" > "$output/runtime-image.json" <<'PYMETA'
import json, sys
print(json.dumps({'image': sys.argv[1], 'image_id': sys.argv[2], 'platform': sys.argv[3]}, indent=2))
PYMETA
    tail -n 8 "$log"
    printf 'Runtime image metadata: %s/runtime-image.json\n' "$output"
    printf 'Full runtime export log: %s\n' "$log"
else
    result=$?
    tail -n 80 "$log" >&2
    printf 'Full failed runtime export log: %s\n' "$log" >&2
    exit "$result"
fi
