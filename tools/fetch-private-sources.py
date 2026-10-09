#!/usr/bin/env python3
"""Fetch exact upstream source revisions for a private local assembly."""
import argparse
from pathlib import Path
import subprocess

REPOSITORIES = {
    'gen1recomp': ('https://github.com/polymathiclabs/gen1recomp.git', '1d2c421ff47f487d836589d38c6209b031bbce91'),
    'DramaticShapeVoxelMod': ('https://github.com/polymathiclabs/DramaticShapeVoxelMod.git', '38d8238785716b82af2d29fb9291d01d316e16f7'),
}

parser = argparse.ArgumentParser()
parser.add_argument('destination', type=Path)
args = parser.parse_args()
args.destination.mkdir(parents=True, exist_ok=True)
for name, (url, revision) in REPOSITORIES.items():
    path = args.destination / name
    if path.exists():
        raise SystemExit(f'Refusing to modify existing checkout: {path}')
    subprocess.run(['git', 'init', str(path)], check=True)
    subprocess.run(['git', '-C', str(path), 'remote', 'add', 'origin', url], check=True)
    subprocess.run(['git', '-C', str(path), 'fetch', '--depth=1', 'origin', revision], check=True)
    subprocess.run(['git', '-C', str(path), 'checkout', '--detach', revision], check=True)
    actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != revision:
        raise SystemExit(f'{name}: unexpected source revision')
    print(f'{name}: {actual}')
