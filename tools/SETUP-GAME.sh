#!/usr/bin/env bash
set -euo pipefail
kit_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -e "$kit_dir/game" || -L "$kit_dir/game" ]]; then
    echo 'The game folder already exists. Keeping your installation as it is.' >&2
    exit 2
fi
for tool in python3 git patch; do
    command -v "$tool" >/dev/null || { echo "Install $tool before running setup." >&2; exit 2; }
done
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/gen1-frame-setup.XXXXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
echo 'Downloading the pinned public engine and voxel renderer. No ROM is downloaded.'
python3 "$kit_dir/tools/fetch-private-sources.py" "$work_dir/sources"
python3 "$kit_dir/tools/assemble-local.py" \
    --engine "$work_dir/sources/gen1recomp" \
    --voxel "$work_dir/sources/DRAMALESS_SHAPE" \
    --kit "$kit_dir" --output "$work_dir/assembly"
mv -- "$work_dir/assembly/game" "$kit_dir/game"
cp -- "$work_dir/assembly/LOCAL-SOURCE-METADATA.json" "$kit_dir/GAME-SOURCE-METADATA.json"
echo 'Setup complete. Launch tools/LAUNCH-STEAM-FRAME.sh from Steam and import your own ROM.'
