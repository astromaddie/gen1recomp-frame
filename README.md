# Gen1Recomp for Steam Frame

Native ARM64 Linux / OpenXR port kit for Pokémon Red, Blue and Yellow. It adapts
the existing Polymatic Labs voxel VR fork to standalone Steam Frame, using a
pinned LÖVE 11.5 runtime and SteamLinuxRuntime_4-arm64. No PC streaming is needed.

The overworld uses the reference mod's tracked stereo cameras. Launcher, menus,
dialogue and battles keep the reference UI. Flat fallback screens are rendered
onto a shared 1.9 m screen at 2 m through each eye's projection, preserving
aspect ratio and binocular alignment. This port preserves the existing camera
and settings interfaces.
The existing minimap, dialogue and menu artwork is collected into a transparent
surface and projected per eye over the world. Staged battles use the completed
original battle screen on the shared plane instead of filling both eye textures.
Physical controller behavior, comfort, sustained performance and sleep/resume
still require device and worn acceptance.

## Sources and distribution

The engine/bridge base is the MIT-licensed
[Polymatic engine revision](https://github.com/polymathiclabs/gen1recomp/tree/1d2c421ff47f487d836589d38c6209b031bbce91).
The player-local voxel source is
[Dramatic Shape revision](https://github.com/polymathiclabs/DramaticShapeVoxelMod/tree/38d8238785716b82af2d29fb9291d01d316e16f7).
This is a Red/Blue/Yellow port of that fork, rather than the current upstream
Gen 2/3 engine. The newer upstream launcher has separate proprietary terms.
The complete voxel mod has no broad redistribution license; the kit fetches it
only for a private local assembly and excludes it from the release archive.

No ROMs, extracted game data, or saves are included in Git or release packages.
Your original Mac player data is independent of the Frame data directory.
Runtime source download pins and license notices are included; see
[LICENSES.md](LICENSES.md).

## Build and assemble

See [TOOLS.md](TOOLS.md) for the pinned ARM64 Docker runtime build, native bridge
build, private source fetch, assembly and package verification commands.
The bridge is compiled against the exact LÖVE 11.5 headers and runtime shipped
with the kit. A different system LÖVE must not be substituted for this ABI.

Use `tools/LAUNCH-STEAM-FRAME.sh` in the assembled package. `--flat` explicitly
disables VR; `--probe` runs the ROM-free OpenXR diagnostic. The normal launch
requires OpenXR and reports startup failure instead of silently showing a flat
window. Startup logs are in `~/.local/share/Gen1RecompFrame/logs/`.

Register the native shortcut through the Frame devkit with `steam_play="0"`
and `compat_tool="SteamLinuxRuntime_4-arm64"`, then launch through Steam so the
headset controller runtime is available. Keep the game and kit in
`~/devkit-game/Gen1RecompFrame`, and player data outside that installation under
`~/.local/share/Gen1RecompFrame/love/pokemon-love2d`.

## Controls

Left stick / D-pad move in game, and move the existing launcher pointer.
Right A confirms, B cancels in game. Right Menu is Start; short left View is
Select; holding View for one second recentres the VR camera. In the launcher,
A clicks a tab/button and Menu plays the selected imported game.
These bindings are source-implemented; physical input acceptance remains open.

The existing voxel Options menu selects its ABOVE, third-person and POV modes.
Fresh VR player data defaults to voxel level 35; an explicit existing voxel
setting is preserved, including OFF.
Custom Mac mods are not automatically carried into this pinned assembly. A
copied save can show the game's existing mod load report before Continue.

`POKEPORT_VR_CAMERA_SETBACK_METERS` optionally moves ABOVE and third-person
cameras back along their existing viewing direction (0–3 m, default 0.75).
POV, head tracking and the 48 pixels/metre world scale remain unchanged.
The wearer accepted 0.75 m in the Pewter City comparison. Explicit zero restores
the original camera distance. HUD readability remains unverified.

## Verification

ARM64 native builds, Runtime/main integration tests and actual GPU Canvas copy
tests under LÖVE/Xvfb passed. The corrected native test checks OpenXR's
bottom-left image convention, graphics-state restoration, MSAA/renderbuffer
copying and rejection of non-Canvas userdata. The original bridge fails this
orientation regression. Camera tests cover recenter yaw, full tracked roll and
IPD preservation; rendered mono tests cover asymmetric eye projections and
the existing screen aspect ratio. An isolated
copy of the user's Yellow save passed the production Continue path and rendered
its saved Pewter City location; the original save and backup were unchanged.

The native kit has also been installed and launched through Steam on Frame.
The ROM-free probe reached focused SteamVR/OpenXR operation, used sRGB
1728 x 1728 eye swapchains, and logged 1,588 projection submissions without a
submission failure. The wearer confirmed clear patterns in both eyes. The
old source/dump pixel comparison incorrectly interpreted raw OpenGL rows as
top-left and did not prove compositor orientation. The
native game restored the copied Yellow save in flat mode and completed a short
focused VR saved-scene run with 300 projection submissions and no bridge error.
After the origin/pose correction, the wearer confirmed upright imagery and
binocular alignment, but reported excessive closeness, an inaccessible HUD and
very low/jittery frame rate. The HUD/battle projection passed host render tests
and still requires wearer verification; the wearer accepted the 0.75 m setback.
The focused 1024-square diagnostic submitted 1,203 frames in 30.0046 seconds
(40.09 per second), with most runtime periods at 27.78 ms. The wearer still
reported severe jitter. This is one diagnostic sample, not evidence that lowering
resolution improves performance or that tracking is fault-free.
Native recommended resolution remains unchanged. Performance remains unresolved;
this is an unaccepted prototype.
Current device evidence and remaining gates are recorded in
[VR_ARCHITECTURE.md](VR_ARCHITECTURE.md).

Foveation profile negotiation is implemented without reducing native eye
resolution. It requests medium eye-tracked foveation where advertised, with a
fixed-profile fallback and full-rate recovery if the GL request is rejected.
`POKEPORT_XR_FOVEATION=off` disables the request for comparison. Whether Valve's
underlying Vulkan injection foveates the LÖVE scene passes remains unverified;
no frame-rate improvement is claimed. See [VR_ARCHITECTURE.md](VR_ARCHITECTURE.md)
for the API/effectiveness distinction and device acceptance gate.
