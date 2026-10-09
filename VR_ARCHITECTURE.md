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
| OpenXR colour probe | Runtime, format, GL context, eyes, frame cadence and projection submission | Pending device |
| Actual game on Frame | Saved scene, projection/stereo render, stable runtime logs | Pending device |
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
