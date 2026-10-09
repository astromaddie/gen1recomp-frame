# Steam Frame port architecture and acceptance

Target: native AArch64 ELF, SteamOS VR, SteamLinuxRuntime_4-arm64, OpenXR primary
stereo with the active SteamVR runtime. Engine and voxel revisions are pinned in
`tools/fetch-private-sources.py`. User data remains outside the install directory.

LÖVE owns the X11/GLX context. `xrbridge.so` binds that context to OpenXR and uses
the pinned static loader, sRGB eye swapchains and a projection layer. Linux eye
submission copies the LÖVE Canvas on the GPU; steady-state Linux rendering has
no synchronous CPU image readback. The Canvas interface uses the exact packaged
LÖVE 11.5 ABI and validates the canonical Canvas userdata type.

The game simulates once before drawing both eyes. The existing voxel mod derives
each eye camera from the same frame's predicted pose/FOV. `xrWaitFrame` supplies
pacing; successive predicted display timestamps supply simulation dt, with the
runtime period used on first frame, resume, or invalid/nonmonotonic timestamps.
Unreasonable deltas fall back to that period. Window VSync and FrameCap sleeps
are bypassed while the XR clock is active. Focus/render loss freezes simulation,
audio and input while XR events and empty frames continue.

The existing launcher starts OpenXR before constructing its UI. Its mono Canvas
is sent to both projection eyes, and native actions reuse its gamepad callbacks.
The Frame controller extension is enabled and suggested only when advertised.
Menu/short View/long View implement Start/Select/recentre. A/B and left stick/
D-pad provide normal game input. No OS keyboard injection is used.

| Gate | Evidence | State |
| --- | --- | --- |
| Native source and ABI | ARM64 bridge/runtime builds; Lua integration tests; ELF/closure/ABI receipts | Host passed |
| GPU Canvas copy | Actual pinned LÖVE/Xvfb pixel/state/type tests | Host passed |
| Flat game and real save | Red Pallet Town; copied Yellow Continue at Pewter City (22,19), voxel render | Host passed |
| OpenXR colour probe | SteamVR/OpenXR + Zink GL 4.3, sRGB 1728 x 1728 eyes, 1,588 logged submissions, exact copied pixels; wearer confirmed clear patterns | Device and wearer passed |
| Actual game on Frame | Copied Yellow save at Pewter City (22,19): native flat render; focused VR run with 300 submissions and no bridge error | Short run passed; settled stereo-eye capture pending |
| Physical input and camera modes | A/B, stick, Menu, View/recentre, launcher selection and voxel Options | Pending wearer |
| Presentation/comfort | 0/90/180 yaw, lean, readable menus, view scale, eye alignment | Pending wearer |
| Audio, sustained performance, sleep/resume | Gameplay session and power-button sleep/recovery | Pending device/wearer |

The ROM-free color probe submits whenever OpenXR says `shouldRender`; an
explicit dry-run flag skips submission. Optional probe diagnostics capture the
source Canvases and each copied swapchain eye once, with native dumps capped at
8,388,608 pixels per eye. The probe exits automatically.
Probe/test settings must be removed from the Steam shortcut before normal play.
ROMs, caches and saves are excluded from every distributable kit manifest.
The user's Mac Yellow save and backup are snapshotted and hash-checked without
modifying their original bytes, timestamps or permissions.

Known limits: battles and dialogue retain the reference mono presentation;
current upstream Gen 2/3 and arbitrary Mac mods are outside this pinned port.
No new comfort/settings UI, hand interaction, haptic confirmation or full
campaign acceptance has been established.

## Device verification on 2026-10-09

The Frame installation uses Steam shortcut `Gen1RecompFrame` (AppID
2767704292), with `steam_play=0` and `SteamLinuxRuntime_4-arm64`. The native
bridge binary SHA-256 is
`be1a34471defee8e8194f2fea25d1c059ea8d3c3e625254a97a26e0c91a99310`.
The install check verified all 60 kit hashes, all 381 private assembly hashes,
and native dependency resolution before launch. The copied Yellow save hash
matched its Mac source. The original Mac save and backup retained their bytes,
size, permissions and modification times.

Probe display timing was 13,888,889 ns (72 Hz), not a sustained gameplay FPS
measurement. The first gameplay eye capture was taken on the existing mod
load report, so it verifies mono UI copying. A later overworld capture is still
required to close the stereo image gate. The driver screenshot shows the voxel
scene, and the short VR run's completion status was focused with 300 submitted
frames, two eye dumps and no bridge error.

The native Steam shortcut did not propagate the devkit `-env.json` diagnostic
values in this test. Diagnostic runs therefore used a temporary shell wrapper
that exported their values and executed the unchanged launcher through Steam.
Normal play must use `tools/LAUNCH-STEAM-FRAME.sh` with no test driver or dump
settings. The devkit's empty `env` argument does not clear an old environment
file; clear this title's file explicitly when restoring normal play.
