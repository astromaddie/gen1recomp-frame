#!/usr/bin/env python3
"""Verify package hashes, runtime license inventory, and forbidden payload classes."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
metadata = json.loads((root / 'PACKAGE-METADATA.json').read_text())
expected = {}
for line in (root / 'SHA256SUMS').read_text().splitlines():
    digest, rel = line.split(None, 1)
    rel = rel.strip()
    path = root / rel
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f'missing or non-regular package file: {rel}')
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f'hash mismatch: {rel}')
    expected[rel] = digest
actual_files = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
if actual_files != set(expected) | {'SHA256SUMS'}:
    raise SystemExit(f'package file set differs from SHA256SUMS: {sorted(actual_files ^ (set(expected) | {"SHA256SUMS"}))}')
for rel in actual_files:
    p = Path(rel)
    if p.suffix.lower() in {'.gb', '.gbc', '.gba', '.sav', '.srm', '.state', '.zip'}:
        raise SystemExit(f'forbidden game/user data: {rel}')
    if rel == 'game' or rel.startswith('game/'):
        raise SystemExit('private game assembly must not ship')
bridge_build = json.loads((root / 'XRBRIDGE-BUILD.json').read_text())
if bridge_build.get('artifacts', {}).get('xrbridge.so') != hashlib.sha256((root / 'xrbridge.so').read_bytes()).hexdigest():
    raise SystemExit('native bridge binary hash differs from its build receipt')
if bridge_build.get('artifacts', {}).get('xrbridge-dependency-closure.txt') != hashlib.sha256((root / 'XRBRIDGE-DEPS.txt').read_bytes()).hexdigest():
    raise SystemExit('native bridge dependency closure hash differs from its build receipt')
if bridge_build.get('runtime_image_id') != metadata.get('runtime_build', {}).get('image_id'):
    raise SystemExit('native bridge and runtime image identities differ')
if bridge_build.get('checks', {}).get('abi_ceilings_passed') is not True:
    raise SystemExit('native bridge ABI ceilings were not verified')
for rel in ('vrbridge/CMakeLists.txt', 'vrbridge/xrbridge.cpp',
            'vrbridge/Telemetry.h'):
    if bridge_build.get('source', {}).get('files', {}).get(rel) != hashlib.sha256((root / rel).read_bytes()).hexdigest():
        raise SystemExit(f'packaged bridge source differs from the built source: {rel}')
license_files = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in root.rglob('*') if p.is_file() and
                 (p.name.lower().startswith('license') or p.name.lower().endswith('.copyright') or '/licenses/' in p.as_posix())}
if license_files != metadata.get('license_inventory'):
    raise SystemExit('license inventory differs from package metadata')
tool_files = {
    'build-runtime.sh', 'export-runtime.sh', 'fetch-runtime-sources.py',
    'fetch-private-sources.py', 'assemble-local.py', 'LAUNCH-STEAM-FRAME.sh',
    'package.py', 'Dockerfile', 'build-bridge.sh', 'build-bridge-in-container.sh', 'verify-package.py'
}
license_files_expected = {
    'LOVE.txt', 'libluajit-5.1-2.copyright', 'libmodplug1.copyright',
    'libvorbis0a.copyright', 'libogg0.copyright', 'libfreetype6.copyright',
    'libpng16-16.copyright', 'zlib1g.copyright', 'libbrotli1.copyright',
    'SDL2.txt', 'OpenXR.txt', 'OpenAL.txt', 'Theora.txt', 'mpg123.txt'
}
def allowlisted(rel):
    if rel in {'README.md', 'LICENSES.md', 'LICENSE-MIT-ENGINE', 'TOOLS.md', 'VR_ARCHITECTURE.md',
               'RUNTIME-IMAGE.json', 'PACKAGE-METADATA.json', 'SHA256SUMS',
               'XRBRIDGE-BUILD.json', 'XRBRIDGE-DEPS.txt', 'xrbridge.so',
               'vrbridge/CMakeLists.txt', 'vrbridge/xrbridge.cpp',
               'vrbridge/Telemetry.h', 'vrbridge/README.md', 'integration/main.lua.patch', 'sources/SHA256SUMS',
               'runtime/bin/love', 'runtime/dependency-closure.txt'}:
        return True
    if rel.startswith('tools/'):
        return rel.removeprefix('tools/') in tool_files
    if rel.startswith(('integration/src/', 'probe/')):
        return rel.endswith('.lua')
    if rel.startswith('docs/'):
        return rel.endswith('.md')
    if rel.startswith('runtime/lib/'):
        return '.so' in Path(rel).name
    if rel.startswith('runtime/licenses/'):
        return Path(rel).name in license_files_expected
    return False
if any(not allowlisted(rel) for rel in actual_files):
    raise SystemExit('package contains files outside the release allowlist')
if set(metadata.get('files', {})) != actual_files - {'PACKAGE-METADATA.json', 'SHA256SUMS'}:
    raise SystemExit('metadata file inventory differs from package contents')
for rel, digest in metadata['files'].items():
    if hashlib.sha256((root / rel).read_bytes()).hexdigest() != digest:
        raise SystemExit(f'metadata file hash mismatch: {rel}')
print(f'Verified {len(expected)} checksums and {len(license_files)} license notices: {root}')
