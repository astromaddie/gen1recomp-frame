#!/usr/bin/env bash
set -euo pipefail
kit_dir="$(cd "$(dirname "$0")/.." && pwd)"
data_dir="${GEN1_FRAME_DATA_DIR:-$HOME/.local/share/Gen1RecompFrame}"
export XDG_DATA_HOME="$data_dir"
export LD_LIBRARY_PATH="$kit_dir/runtime/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LUA_CPATH="$kit_dir/?.so;;"
export POKEPORT_XRBRIDGE="$kit_dir/xrbridge.so"
export SDL_VIDEODRIVER=x11
export POKEPORT_DEV=1
export POKEPORT_VR="${POKEPORT_VR:-1}"
export POKEPORT_VR_REQUIRED="${POKEPORT_VR_REQUIRED:-1}"
if [[ -f /opt/steamvr/steamxr_linuxarm64.json && -z "${XR_RUNTIME_JSON:-}" ]]; then
    export XR_RUNTIME_JSON=/opt/steamvr/steamxr_linuxarm64.json
fi

mode=game
if [[ "${1:-}" == --probe ]]; then
    mode=probe
    shift
elif [[ "${1:-}" == --flat ]]; then
    mode=flat
    shift
    export POKEPORT_VR=0
    export POKEPORT_VR_REQUIRED=0
fi
if [[ "$mode" != probe && ! -f "$kit_dir/game/main.lua" ]]; then
    printf '%s\n' 'Private local game assembly missing. Run tools/assemble-local.py before launching.' >&2
    exit 2
fi
if [[ "$mode" == probe ]]; then
    app="$kit_dir/probe"
else
    app="$kit_dir/game"
fi
mkdir -p "$data_dir/logs"
log="$data_dir/logs/${mode}-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
printf 'Gen1Recomp Frame %s startup log: %s\n' "$mode" "$log" >&2
cd "$app"
exec "$kit_dir/runtime/bin/love" "$app" "$@" >>"$log" 2>&1
