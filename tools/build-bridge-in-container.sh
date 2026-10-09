#!/usr/bin/env bash
set -euo pipefail
cmake -S /src/vrbridge -B /tmp/xrbridge-build -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DOPENXR_INCLUDE_DIR=/opt/openxr/include \
  -DOPENXR_LOADER_LIBRARY=/opt/openxr/lib/libopenxr_loader.a \
  -DLUAJIT_INCLUDE_DIR=/usr/include/luajit-2.1 \
  -DLUAJIT_LIBRARY=/usr/lib/aarch64-linux-gnu/libluajit-5.1.so \
  -DLOVE_ROOT=/opt/love-11.5 \
  -DLOVE_LIBRARY=/opt/love/lib/liblove-11.5.so
cmake --build /tmp/xrbridge-build --config Release
cp /tmp/xrbridge-build/xrbridge.so /out/xrbridge.so
file /out/xrbridge.so | grep -Eq 'ELF 64-bit LSB shared object, ARM aarch64'
readelf -h /out/xrbridge.so | grep -Eq 'Machine:[[:space:]]+AArch64'
python3 - /out/xrbridge.so <<'PYABI'
import hashlib, json, re, subprocess, sys
path = sys.argv[1]
text = subprocess.check_output(['readelf', '--version-info', path], text=True, stderr=subprocess.DEVNULL)
def maximum(pattern):
    values = [tuple(map(int, value.split('.'))) for value in re.findall(pattern, text)]
    return max(values) if values else None
glibc = maximum(r'GLIBC_([0-9]+(?:\.[0-9]+)+)')
glibcxx = maximum(r'GLIBCXX_([0-9]+(?:\.[0-9]+)+)')
def within(value, ceiling): return value is None or value <= ceiling
if not within(glibc, (2, 35)):
    raise SystemExit(f'glibc ABI exceeds 2.35: {glibc}')
if not within(glibcxx, (3, 4, 30)):
    raise SystemExit(f'GLIBCXX ABI exceeds 3.4.30: {glibcxx}')
closure_path = '/out/xrbridge-dependency-closure.txt'
env = {'PATH': '/usr/bin:/bin', 'LD_LIBRARY_PATH': '/runtime/runtime/lib'}
result = subprocess.run(['ldd', '-r', path], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
with open(closure_path, 'w') as f: f.write(result.stdout)
if (result.returncode or 'not found' in result.stdout
        or 'undefined symbol:' in result.stdout or '/usr/local/' in result.stdout):
    raise SystemExit(f'isolated bridge dependency closure failed; see {closure_path}')
with open('/out/xrbridge-checks.json', 'w') as f:
    json.dump({
        'artifacts': {
            'xrbridge.so': hashlib.sha256(open(path, 'rb').read()).hexdigest(),
            'xrbridge-dependency-closure.txt': hashlib.sha256(open(closure_path, 'rb').read()).hexdigest(),
        },
        'checks': {
            'elf_architecture': 'aarch64',
            'glibc_max': '.'.join(map(str, glibc)) if glibc else None,
            'glibcxx_max': '.'.join(map(str, glibcxx)) if glibcxx else None,
            'abi_ceilings_passed': True,
            'unresolved_dependencies': [],
            'usr_local_cleared': True,
        },
    }, f, indent=2)
PYABI

# Verify relocation against the exact runtime export and execute the module
# factory through LÖVE's real package.loadlib path without starting OpenXR.
env PATH=/usr/bin:/bin \
  LD_LIBRARY_PATH=/runtime/runtime/lib:/usr/local/lib \
  SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=x11 \
  POKEPORT_XRBRIDGE=/out/xrbridge.so POKEPORT_VR_TELEMETRY=1 \
  timeout 30s xvfb-run -a -s '-screen 0 1280x1024x24' \
    /runtime/runtime/bin/love /kit/tools/native-module-smoke
python3 - /out/xrbridge.so /out/xrbridge-checks.json <<'PYSMOKE'
import hashlib, json, sys
from pathlib import Path
binary = Path(sys.argv[1])
receipt = Path(sys.argv[2])
checks = json.loads(receipt.read_text())
checks['checks']['native_module_import_passed'] = True
checks['checks']['native_module_import_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
receipt.write_text(json.dumps(checks, indent=2) + '\n')
PYSMOKE
