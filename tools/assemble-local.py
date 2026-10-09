#!/usr/bin/env python3
"""Assemble a private local game tree from pinned player-fetched sources."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ENGINE_REVISION = '1d2c421ff47f487d836589d38c6209b031bbce91'
VOXEL_REVISION = '38d8238785716b82af2d29fb9291d01d316e16f7'
FORBIDDEN_SUFFIXES = {'.gb', '.gbc', '.gba', '.sav', '.srm', '.dll', '.exe', '.so', '.dylib'}


def git(path, *arguments):
    return subprocess.check_output(['git', '-C', str(path), *arguments], text=True).strip()


def copy_tracked(source, destination, revision, engine=False):
    if git(source, 'rev-parse', 'HEAD') != revision:
        raise SystemExit(f'{source}: expected revision {revision}')
    if git(source, 'status', '--porcelain'):
        raise SystemExit(f'{source}: source checkout must be clean')
    copied = 0
    for name in git(source, 'ls-tree', '-r', '--name-only', 'HEAD').splitlines():
        relative = Path(name)
        if engine and not (name in {
                               'main.lua', 'conf.lua', 'LICENSE.MD',
                               'tools/rom_manifest.json',
                               'tools/rom_manifest_blue.json',
                               'tools/rom_manifest_yellow.json',
                           } or name.startswith(('src/', 'data/', 'assets/', 'tools/save-editor/'))):
            continue
        if not engine and not (name in {'main.lua', 'manifest.json', 'mod.card', 'README.md', 'LICENSE-POLYMATIC-LABS.md'} or
                               name.startswith(('lib/', 'assets/', 'data/'))):
            continue
        if relative.suffix.lower() in FORBIDDEN_SUFFIXES or '/generated/' in '/' + name or name.startswith('assets/vr/'):
            continue
        original = source / relative
        if original.is_symlink() or not original.is_file():
            raise SystemExit(f'Unexpected source file: {original}')
        output = destination / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, output)
        copied += 1
    return copied


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engine', required=True, type=Path)
    parser.add_argument('--voxel', required=True, type=Path)
    parser.add_argument('--kit', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        raise SystemExit(f'Refusing to replace existing assembly: {output}')
    kit = args.kit.resolve()
    game = output / 'game'
    game.mkdir(parents=True)
    counts = {'engine': copy_tracked(args.engine.resolve(), game, ENGINE_REVISION, True),
              'voxel': copy_tracked(args.voxel.resolve(), game / 'mods' / 'DRAMATIC_SHAPE', VOXEL_REVISION)}
    subprocess.run(['patch', '-p1', '--batch', '--forward', '-i', str(kit / 'integration' / 'main.lua.patch')], cwd=game, check=True)
    for overlay in (kit / 'integration' / 'src').rglob('*'):
        if overlay.is_file():
            target = game / 'src' / overlay.relative_to(kit / 'integration' / 'src')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(overlay, target)
    files = {}
    for path in sorted(game.rglob('*')):
        if path.is_file():
            files[str(path.relative_to(output))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / 'LOCAL-SOURCE-METADATA.json').write_text(json.dumps({
        'engine_revision': ENGINE_REVISION, 'voxel_revision': VOXEL_REVISION,
        'file_counts': counts, 'sha256': files,
        'distribution': 'Private local assembly; complete voxel mod is not licensed for redistribution.'
    }, indent=2) + '\n')
    print(f'Assembled {len(files)} pinned source files into {output}')


if __name__ == '__main__':
    main()
