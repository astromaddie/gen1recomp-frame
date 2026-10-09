#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: export-runtime.sh OUTPUT_DIR}"
mkdir -p "$destination/bin" "$destination/lib" "$destination/licenses"
libdir="$destination/lib"
cp /opt/love/bin/love "$destination/bin/love"
cp -L /opt/love/lib/liblove-11.5.so "$destination/lib/liblove-11.5.so"

# Copy every non-platform dependency in the transitive ELF closure. SteamOS owns
# its glibc, libstdc++, graphics stack, and loader; these are intentionally external.
python3 - "$destination" <<'PY'
import os, re, shutil, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
libdir = root / 'lib'
platform = {
    'ld-linux-aarch64.so.1', 'libc.so.6', 'libm.so.6', 'libpthread.so.0',
    'libdl.so.2', 'librt.so.1', 'libresolv.so.2', 'libutil.so.1',
    'libgcc_s.so.1', 'libstdc++.so.6', 'libGL.so.1', 'libGLX.so.0',
    'libGLdispatch.so.0', 'libEGL.so.1', 'libOpenGL.so.0', 'libgbm.so.1',
    'libdrm.so.2', 'libudev.so.1', 'libX11.so.6', 'libXext.so.6',
    'libXrandr.so.2', 'libXcursor.so.1', 'libXi.so.6', 'libXinerama.so.1',
    'libXss.so.1', 'libxcb.so.1', 'libwayland-client.so.0', 'libwayland-egl.so.1',
    'libasound.so.2', 'libpulse.so.0', 'libdbus-1.so.3', 'libxkbcommon.so.0',
}
queue = [root / 'bin/love', libdir / 'liblove-11.5.so']
seen = set()
while queue:
    elf = queue.pop()
    real = elf.resolve()
    if real in seen: continue
    seen.add(real)
    result = subprocess.run(['ldd', str(real)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode and 'not a dynamic executable' not in result.stdout:
        raise SystemExit(f'ldd failed for {real}:\n{result.stdout}')
    for line in result.stdout.splitlines():
        if 'not found' in line:
            raise SystemExit(f'unresolved dependency for {real}: {line}')
        match = re.search(r'\s(\S+)\s+=>\s+(\S+)', line)
        if not match:
            continue
        soname, path = match.groups()
        if path == 'not': raise SystemExit(f'unresolved dependency: {line}')
        if soname in platform:
            continue
        source = Path(path)
        target = libdir / soname
        if not target.exists():
            shutil.copy2(source.resolve(), target)
        queue.append(target)
    # Direct interpreter entries are platform-owned, but malformed/missing results
    # are caught by ldd above.

# Refuse OpenGL/driver material in the shipped payload, including indirect copies.
for path in libdir.iterdir():
    if re.search(r'(?:^|lib)(?:GL|EGL|OpenGL|gbm|drm|nvidia|vulkan)', path.name, re.I):
        raise SystemExit(f'platform graphics library must not ship: {path.name}')
PY

cp /opt/love-11.5/license.txt "$destination/licenses/LOVE.txt"
for package_name in libluajit-5.1-2 libmodplug1 libvorbis0a libogg0 libfreetype6 libpng16-16 zlib1g libbrotli1; do
    src="/usr/share/doc/$package_name/copyright"
    test -s "$src"
    cp "$src" "$destination/licenses/$package_name.copyright"
done
cp /opt/runtime-licenses/*.txt "$destination/licenses/"

# Verify isolated resolution: package libraries first, no /usr/local, and fail on gaps.
closure="$destination/dependency-closure.txt"
: > "$closure"
for elf in "$destination/bin/love" "$destination"/lib/*.so*; do
    test -L "$elf" && continue
    file "$elf" | grep -q 'ARM aarch64' || { echo "wrong ELF architecture: $elf" >&2; exit 1; }
    printf '\n### %s\n' "${elf#"$destination"/}" >> "$closure"
    env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH="$libdir" ldd "$elf" >> "$closure" 2>&1 || { cat "$closure" >&2; exit 1; }
done
! grep -q 'not found' "$closure" || { cat "$closure" >&2; exit 1; }

# Verify required symbol-version ceilings without requiring every ELF to use C++.
for elf in "$destination/bin/love" "$destination"/lib/*.so*; do
    test -L "$elf" && continue
    python3 - "$elf" <<'PYABI'
import re, subprocess, sys
path = sys.argv[1]
text = subprocess.check_output(['readelf', '--version-info', path], text=True, stderr=subprocess.DEVNULL)
def maximum(pattern):
    versions = [tuple(map(int, m.split('.'))) for m in re.findall(pattern, text)]
    return max(versions) if versions else None
for symbol, pattern, limit in (
    ('GLIBCXX', r'GLIBCXX_([0-9]+(?:\.[0-9]+)+)', (3, 4, 30)),
    ('glibc', r'GLIBC_([0-9]+(?:\.[0-9]+)+)', (2, 35)),
):
    found = maximum(pattern)
    if found and found > limit:
        raise SystemExit(f'{symbol} ABI ceiling exceeded in {path}: {found} > {limit}')
PYABI
done
printf 'Runtime export passed: AArch64 ELF, %s bundled libraries, dependency closure complete; glibc <= 2.35 and GLIBCXX <= 3.4.30.\n' "$(find "$destination/lib" -maxdepth 1 -type f -name '*.so*' | wc -l | tr -d ' ')"
printf 'Full isolated dependency closure: %s/dependency-closure.txt\n' "$destination"
