#!/usr/bin/env python3
"""Fetch the pinned native runtime build inputs and verify their SHA-256."""
import argparse
import hashlib
from pathlib import Path
import urllib.request

SOURCES = {
    'SDL2-2.30.11.tar.gz': 'https://www.libsdl.org/release/SDL2-2.30.11.tar.gz',
    'love-11.5-linux-src.tar.gz': 'https://github.com/love2d/love/releases/download/11.5/love-11.5-linux-src.tar.gz',
    'openxr-1.1.63.tar.gz': 'https://github.com/KhronosGroup/OpenXR-SDK/archive/refs/tags/release-1.1.63.tar.gz',
    'openal-soft-1.23.1.tar.gz': 'https://github.com/kcat/openal-soft/archive/refs/tags/1.23.1.tar.gz',
    'libtheora-1.1.1.tar.bz2': 'https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.bz2',
    'mpg123-1.32.10.tar.bz2': 'https://www.mpg123.de/download/mpg123-1.32.10.tar.bz2',
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    parser.add_argument('--checksums', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'sources' / 'SHA256SUMS')
    args = parser.parse_args()
    expected = {}
    for line in args.checksums.read_text().splitlines():
        digest, name = line.split()
        expected[name] = digest
    if set(expected) != set(SOURCES):
        raise SystemExit('Source/checksum inventory differs')
    args.destination.mkdir(parents=True, exist_ok=True)
    for name, url in SOURCES.items():
        path = args.destination / name
        if not path.exists():
            temporary = path.with_name(path.name + '.partial')
            with urllib.request.urlopen(url, timeout=120) as source, temporary.open('wb') as target:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
            temporary.replace(path)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected[name]:
            raise SystemExit(f'{path}: checksum mismatch; delete this download before retrying')
        print(f'{name}: {digest}')
    (args.destination / 'SHA256SUMS').write_text(args.checksums.read_text())

if __name__ == '__main__':
    main()
