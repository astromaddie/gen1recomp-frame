#!/usr/bin/env python3
"""Build a deterministic, allowlisted native Steam Frame kit (never includes game/ROM data)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def git(source, *args, check=True):
    p = subprocess.run(['git', '-C', str(source), *args], text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        raise SystemExit(p.stderr.strip() or f'git {args[0]} failed')
    return p.stdout.strip() if p.returncode == 0 else None


PACKAGE_OUTPUT_ROOT = None

def copy_file(src, dst, inventory):
    if not src.is_file() or src.is_symlink():
        raise SystemExit(f'Allowlisted file missing or not regular: {src}')
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    inventory[dst.relative_to(PACKAGE_OUTPUT_ROOT).as_posix()] = sha256(dst)


def copy_tree(src, dst, inventory, allow):
    if not src.is_dir() or src.is_symlink():
        raise SystemExit(f'Allowlisted directory missing or not a directory: {src}')
    for path in sorted(src.rglob('*')):
        if path.is_symlink():
            raise SystemExit(f'Symlink rejected from package: {path}')
        if path.is_file():
            rel = path.relative_to(src).as_posix()
            if not allow(rel):
                raise SystemExit(f'File outside package allowlist: {path}')
            copy_file(path, dst / rel, inventory)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--source', type=Path, required=True, help='native kit source checkout')
    ap.add_argument('--runtime', type=Path, required=True, help='output containing runtime/')
    ap.add_argument('--xrbridge', type=Path, required=True, help='built ARM64 xrbridge.so')
    ap.add_argument('--output', type=Path, required=True, help='new package directory outside source')
    ap.add_argument('--allow-dirty', action='store_true', help='record exact source status in package metadata')
    args = ap.parse_args()
    source, runtime_root, bridge, output = (p.resolve() for p in (args.source, args.runtime, args.xrbridge, args.output))
    if output.exists():
        raise SystemExit(f'Refusing to overwrite existing output: {output}')
    if output == source or source in output.parents or output in source.parents:
        raise SystemExit('Package output must be a separate sibling tree, not nested with source')
    status = git(source, 'status', '--porcelain=v1', '--untracked-files=all')
    head = git(source, 'rev-parse', 'HEAD', check=False)
    if status and not args.allow_dirty:
        raise SystemExit('Source checkout is dirty; review it and pass --allow-dirty to record exact state')

    # Deliberate release allowlist. The private game assembly and all arbitrary
    # source-tree content are excluded by construction.
    output.mkdir(parents=True)
    global PACKAGE_OUTPUT_ROOT
    PACKAGE_OUTPUT_ROOT = output
    inventory = {}
    for rel in ('integration/main.lua.patch', 'integration/dramaless.patch', 'LICENSE-MIT-ENGINE'):
        copy_file(source / rel, output / rel, inventory)
    copy_tree(source / 'integration/src', output / 'integration/src', inventory,
              lambda rel: rel.endswith('.lua'))
    copy_tree(source / 'integration/probe', output / 'probe', inventory,
              lambda rel: rel.endswith('.lua'))
    for rel in ('vrbridge/CMakeLists.txt', 'vrbridge/xrbridge.cpp',
                'vrbridge/Telemetry.h', 'vrbridge/README.md'):
        copy_file(source / rel, output / rel, inventory)

    kit_root = Path(__file__).resolve().parents[1]
    for rel in ('README.md', 'LICENSES.md', 'TOOLS.md', 'VR_ARCHITECTURE.md'):
        copy_file(kit_root / rel, output / rel, inventory)
    copy_file(kit_root / 'sources' / 'SHA256SUMS', output / 'sources' / 'SHA256SUMS', inventory)
    copy_tree(kit_root / 'tools', output / 'tools', inventory,
              lambda rel: rel in {
                  'build-runtime.sh', 'export-runtime.sh', 'fetch-runtime-sources.py',
                  'fetch-private-sources.py', 'assemble-local.py', 'LAUNCH-STEAM-FRAME.sh',
                  'package.py', 'Dockerfile', 'build-bridge.sh', 'build-bridge-in-container.sh', 'verify-package.py'
              })
    copy_file(runtime_root / 'runtime-image.json', output / 'RUNTIME-IMAGE.json', inventory)
    bridge_report_path = bridge.with_name('xrbridge.build.json')
    bridge_deps_path = bridge.with_name('xrbridge-dependency-closure.txt')
    bridge_report = json.loads(bridge_report_path.read_text())
    source_hashes = bridge_report.get('source', {}).get('files', {})
    for rel in ('vrbridge/CMakeLists.txt', 'vrbridge/xrbridge.cpp',
                'vrbridge/Telemetry.h'):
        if source_hashes.get(rel) != sha256(source / rel):
            raise SystemExit(f'bridge source changed since build: {rel}')
    if bridge_report.get('artifacts', {}).get('xrbridge.so') != sha256(bridge):
        raise SystemExit('xrbridge build report does not match the supplied binary')
    if bridge_report.get('artifacts', {}).get('xrbridge-dependency-closure.txt') != sha256(bridge_deps_path):
        raise SystemExit('xrbridge dependency closure does not match its build report')
    checks = bridge_report.get('checks', {})
    if checks.get('elf_architecture') != 'aarch64' or checks.get('unresolved_dependencies') or checks.get('abi_ceilings_passed') is not True:
        raise SystemExit('xrbridge build report does not confirm clean ARM64 dependency and ABI checks')
    if bridge_report.get('runtime_image_id') != json.loads((runtime_root / 'runtime-image.json').read_text()).get('image_id'):
        raise SystemExit('xrbridge and LOVE runtime were not built from the same image')
    copy_file(bridge, output / 'xrbridge.so', inventory)
    copy_file(bridge_report_path, output / 'XRBRIDGE-BUILD.json', inventory)
    copy_file(bridge_deps_path, output / 'XRBRIDGE-DEPS.txt', inventory)
    bridge_header = bridge.read_bytes()[:20]
    if len(bridge_header) < 20 or bridge_header[:4] != b'\x7fELF' or bridge_header[4] != 2 or bridge_header[5] != 1 or int.from_bytes(bridge_header[18:20], 'little') != 183:
        raise SystemExit('xrbridge must be a little-endian ELF64 AArch64 binary')
    copy_tree(runtime_root / 'runtime', output / 'runtime', inventory,
              lambda rel: rel.startswith(('bin/', 'lib/', 'licenses/')) or rel == 'dependency-closure.txt')

    expected_runtime_licenses = {
        'LOVE.txt', 'libluajit-5.1-2.copyright', 'libmodplug1.copyright',
        'libvorbis0a.copyright', 'libogg0.copyright', 'libfreetype6.copyright',
        'libpng16-16.copyright', 'zlib1g.copyright', 'libbrotli1.copyright',
        'SDL2.txt', 'OpenXR.txt',
        'OpenAL.txt', 'Theora.txt', 'mpg123.txt'
    }
    runtime_licenses = {p.name for p in (output / 'runtime/licenses').iterdir() if p.is_file()}
    missing = expected_runtime_licenses - runtime_licenses
    if missing:
        raise SystemExit('Runtime license inventory incomplete: ' + ', '.join(sorted(missing)))
    if (output / 'game').exists():
        raise SystemExit('Game assembly is prohibited in the distributable package')
    forbidden = {'.gb', '.gbc', '.gba', '.sav', '.srm', '.state', '.zip'}
    for path in output.rglob('*'):
        if path.is_file() and path.suffix.lower() in forbidden:
            raise SystemExit(f'Forbidden user/game data in package: {path}')

    licenses = [p for p in sorted(output.rglob('*')) if p.is_file() and
                (p.name.lower().startswith('license') or p.name.lower().endswith('.copyright') or
                 '/licenses/' in p.as_posix())]
    license_inventory = {str(p.relative_to(output)): sha256(p) for p in licenses}
    metadata = {
        'format': 'gen1recomp-steam-frame-kit-v1',
        'source': {'head': head, 'dirty': bool(status), 'status_porcelain': status.splitlines() if status else []},
        'architecture': 'aarch64',
        'bridge_build': bridge_report,
        'runtime': 'LÖVE 11.5 with bundled non-platform dependency closure',
        'runtime_build': json.loads((output / 'RUNTIME-IMAGE.json').read_text()),
        'files': inventory,
        'license_inventory': license_inventory,
        'excluded': ['assembled game tree', 'ROMs', 'generated caches', 'save files'],
    }
    (output / 'PACKAGE-METADATA.json').write_text(json.dumps(metadata, indent=2) + '\n')
    with (output / 'SHA256SUMS').open('w') as f:
        for path in sorted(p for p in output.rglob('*') if p.is_file() and p.relative_to(output).as_posix() != 'SHA256SUMS'):
            f.write(f'{sha256(path)}  {path.relative_to(output).as_posix()}\n')
    subprocess.run([sys.executable, str(kit_root / 'tools' / 'verify-package.py'), str(output)], check=True)
    print(f'Packaged {len(inventory)} allowlisted files into {output}')
    print(f'Source: {head or "no commit"}; dirty={bool(status)}; licenses={len(license_inventory)}')


if __name__ == '__main__':
    main()
