# Steam Frame port architecture and acceptance

Target: native AArch64 ELF, SteamOS VR, SteamLinuxRuntime_4-arm64, OpenXR primary
stereo with the active SteamVR runtime. Engine and voxel revisions are pinned in
`tools/fetch-private-sources.py`. User data remains outside the install directory.

LÖVE owns the X11/GLX context. `xrbridge.so` binds that context to OpenXR and uses
the pinned static loader, sRGB eye swapchains and a projection layer. Linux eye
submission copies the LÖVE Canvas on the GPU; steady-state Linux rendering has
no synchronous CPU image readback. The Canvas interface uses the exact packaged
LÖVE 11.5 ABI and validates the canonical Canvas userdata type.
The GPU boundary reverses Canvas rows: LÖVE Canvas logical top is GL row zero,
whereas OpenXR GL images use a bottom-left origin. Diagnostic PPMs reverse
raw glReadPixels rows to show the compositor image truthfully as top-left.

The game simulates once before drawing both eyes. The native host adapter derives
each eye camera from the same frame's predicted pose/FOV. `xrWaitFrame` supplies
pacing; successive predicted display timestamps supply simulation dt, with the
runtime period used on first frame, resume, or invalid/nonmonotonic timestamps.
Unreasonable deltas fall back to that period. Window VSync and FrameCap sleeps
are bypassed while the XR clock is active. Focus/render loss freezes simulation,
audio and input while XR events and empty frames continue.

The existing launcher starts OpenXR before constructing its UI. Its mono Canvas
is projected onto a shared plane, 1.9 m wide at 2 m (tall screens fit within
1.9 m height), using each current eye pose/FOV. The plane anchors to head yaw
and height on mono entry or recentre, preserves the original screen aspect,
and uses projection layers only. The legacy quadScale option applies only to
the Windows quad fallback; Linux uses this physical screen instead of scaling
an identical texture across both eye frusta. Native actions reuse gamepad callbacks.
The Frame controller extension is enabled and suggested only when advertised.
Menu/short View/long View implement Start/Select/recentre. A/B and left stick/
D-pad provide normal game input. No OS keyboard injection is used.

The kit's scoped `GamePresentation` adapter captures `Renderer.compositeUi`
output into a transparent desktop-layout surface. Its legacy Minimap hook is
retained only for older private assemblies; DRAMALESS has no minimap.
The surface is projected separately through each eye's pose/FOV over its world
image. It follows head yaw/pitch while retaining gravity-up, so full eye roll
does not turn identical texture coordinates into mismatched physical locations.
Original palette zones and menu/dialogue layout stay in the source
compositor. Its old 20%-of-eye scale is replaced by the shared physical plane.
Staged battles use the final original desktop composition as that plane's mono
source after the reference hook clears its pending stereo pair.

Within an actual XR draw only, the adapter caches `Player:pose()` once and
restores the original method at draw end. The pinned implementation advances
surf bob and spinner timers inside `pose`; both eye passes now see the same
result. Flat rendering, updates and NPC pose methods remain unchanged. This
correctness fix is not evidence of a stationary-scene performance improvement.

Optional `POKEPORT_VR_CAMERA_SETBACK_METERS` (0–3, default 0) translates ABOVE
and third-person eye/focus backward along the existing view direction, preserving
orientation, head tracking, IPD and 48 pixels/metre. POV does not move. The wearer
accepted an explicitly requested 0.75 m distance during the 1024-square test;
explicit zero or the default preserves the original distance. Native recommended eye dimensions
remain the default; no lower resolution has been adopted.

## DRAMALESS source replacement (2026-10-09)

Default renderer: public MIT DRAMALESS_SHAPE 2.0.4 at
`97ca3e1f8f7c3aa0b3e671db497076150f494051`, with the unchanged pinned MIT
engine. Assemblies contain only `mods/DRAMALESS_SHAPE`, its original MIT
LICENSE and CREDITS, and the small native integration patch. The older private
mod is neither copied nor required. References remain unmodified.

`DramalessStereo` supplies native-size independent eye slots through the real
upstream VoxelScene path. Small source seams add asymmetric lens projection
and scoped FirstPerson tracked-eye adoption. Existing angle rungs map to ABOVE,
1ST to POV, and 3RD to third-person for Runtime's unchanged setback rule.
The public mod retains its own free-camera input and collision-boom behavior;
its 3RD rig differs from the former private mod. Glint and Player:pose draw
state advance once per pair. The engine update/pipeline update runs once.

RES and R.DIST default to their built-in FULL rungs through schema defaults,
without overwriting saved choices. R.DIST is the public mod's existing draw
selection, while host culling retains its conservative union of real eye
frusta. The current upstream RES setting controls sky detail; its world pass
does not divide the native eye target. Both eyes use the complete recommended
resolution. AA and other exposed settings retain the upstream implementations.
Telemetry scene identities include `/rdist=<stored value>/res=<stored value>`
(e.g. `-1` and `1` for FULL); GPU scopes retain that issue-time identity.

Host evidence in the private `work/dramaless-qa` folder:

- `above/eye-*.png`: actual Pewter City, two 1728-square source passes, one
  glint step and player pose increment, 3.072-world-pixel runtime IPD, and two
  source GPU scopes. Inspected upright world and continuous visible street.
- `room-roll/eye-*.png`: actual Pewter Mart at +20 degree tracked roll; complete
  visible room floor retained. No whole-map comparison was run.
- `options-battle/options-*.png`: existing Options R.DIST row, FULL RES/R.DIST;
  row API FULL -> MEDIUM -> FULL and normal cancel interaction pass.
- `options-battle/battle-*.png`: actual public standalone arena and 2D cards
  on the common mono plane. Initial battle presentation only, not a complete
  combat playthrough or proof of all transition/animation compatibility.
- `camera-modes/*.png` / `camera-modes.log`: actual ABOVE, 1ST and 3RD
  scenes; measured 36/0/36 world-pixel setback respectively, unchanged 3.072
  world-pixel IPD, and identical strict two-pass/state/scope checks.
- `pure.log`: new production Voxel3D matrices pass yaw 0/90/180, full roll,
  asymmetric lenses and IPD; Runtime, telemetry, continuous driver and main
  integration checks pass. `unit.log`: nearby shared HUD projection and real
  DRAMALESS mesh/frustum selection regressions pass.

This is host GPU evidence (ARM64 LÖVE/Xvfb software OpenGL), not Frame GPU
performance or wearer acceptance. Optional third-party companion/Stadium mods,
all field effects and a full battle playthrough remain unverified. The native
telemetry driver remains alive after its initial measurement marker so the user
can tune settings and end the session themselves.

The following device/wearer evidence predates the DRAMALESS replacement:

| Gate | Evidence | State |
| --- | --- | --- |
| Native source and ABI | ARM64 bridge/runtime builds; Lua integration tests; ELF/closure/ABI receipts | Host passed |
| GPU Canvas copy | Baseline fails the new OpenXR-origin test; corrected pinned LÖVE/Xvfb pixels, MSAA, renderbuffer, scale/state/type tests pass | Host passed; corrected device check pending |
| Flat game and real save | Red Pallet Town; copied Yellow Continue at Pewter City (22,19), voxel render | Host passed |
| OpenXR colour probe | SteamVR/OpenXR + Zink GL 4.3, sRGB 1728 x 1728 eyes; corrected source/dump pixels match. Edge labels were outside the visible lens area | Session/copy passed; orientation established by subsequent game wear |
| Actual game on Frame | Copied Yellow save at Pewter City (22,19): corrected native run captured distinct world eyes after 500 submissions; wearer confirmed upright/aligned imagery | Short run/capture passed; performance unaccepted |
| Physical input and camera modes | A/B, stick, Menu, View/recentre, launcher selection and voxel Options | Pending wearer |
| Presentation/comfort | Wearer confirmed upright/aligned world and accepted 0.75m setback. HUD unreadability was not rechecked before diagnostic exit. Host tests cover actual minimap/Renderer/finishStereo composition and shared battle plane | Distance worn accepted; HUD/battle pending; jitter unaccepted |
| Audio, sustained performance, sleep/resume | Gameplay session and power-button sleep/recovery | Pending device/wearer |

The ROM-free color probe submits whenever OpenXR says `shouldRender`; an
explicit dry-run flag skips submission. Optional probe diagnostics capture the
source Canvases and each copied swapchain eye once, with native dumps capped at
8,388,608 pixels per eye. The probe exits automatically.
Probe/test settings must be removed from the Steam shortcut before normal play.
ROMs, caches and saves are excluded from every distributable kit manifest.
The user's Mac Yellow save and backup are snapshotted and hash-checked without
modifying their original bytes, timestamps or permissions.

Known limits: staged battles retain the reference mono scene rendered on a
physical screen; current upstream Gen 2/3 and arbitrary Mac mods are outside this pinned port.
No new comfort/settings UI, hand interaction, haptic confirmation or full
campaign acceptance has been established.

The corrected `0e9b122` world capture reported a 27.78 ms runtime period, but
capture/readback was enabled and no clean timing interval completed. This is
not a performance baseline. A subsequent 1024-square diagnostic remained in
standby before its driver began; it produced no measurement and was stopped.
The normal title shortcut and empty environment were restored afterwards.
On the next installed `2baa88c` test, the wearer completed a continuously focused,
dump-free 1024-square interval: 1,203 submits / 30.0046 s = 40.09 per second,
frame median/p95 27.61/28.24 ms. Runtime period counts were 929 at about 27.78 ms,
260 at 13.89 ms and 14 at 41.67 ms. Jitter remained severe when worn. These are
application submission rates, not compositor output rates. `draw` includes
`beginFrame`, whose wall duration includes runtime waiting; stage medians cannot
be summed or treated as CPU-only costs. Full-resolution comparison is pending.
No lower-resolution default or measured resolution benefit has been adopted.

## Opt-in CPU and GPU telemetry

Set `POKEPORT_VR_TELEMETRY=1` for diagnostics. With it unset, the telemetry
module and native timing/counter paths are inactive. `integration/tests/vr_telemetry_driver.lua`
restores the copied Yellow slot through the supplied saved-scene setup, warms
for 10 seconds, then marks completion of an initial 90-second outdoor/indoor
interval (`POKEPORT_VR_TELEMETRY_SECONDS` accepts 10–300 seconds). Telemetry
continues after that marker while the player adjusts renderer settings. It does
not lower eye resolution. The driver is optional and must be copied to the
diagnostic install. It keeps yielding without changing controls so the game
stays open until the player closes it.

Per-stage wall and CPU deltas cover the game update/draw, XR begin, and XR
submission. `draw` contains XR begin/wait; these stage values overlap and must
not be added together. `xrWaitFrame` wall and calling-thread CPU are reported
separately. Process and main-thread CPU percentages use elapsed monotonic wall
time as the denominator: 100% is one full core, so process usage can exceed
100% when Zink or other worker threads are active. One-second summaries carry
map/camera identity; intervals crossing a map change or focus/render loss are
marked as excluded or transitional. Sampled draw-distance index counts describe
only eligible map geometry and sum the observed per-frame status snapshots.

OpenGL timer queries bracket each actual VoxelScene render by eye and each
native Canvas-to-swapchain copy. LÖVE batches are flushed at scope boundaries
only while telemetry is enabled. A fixed 64-entry query ring checks a bounded
batch of pending queries each XR frame and only reads results after both
queries report ready; proc/sysfs counters remain one-second samples. Output
includes pending, dropped, unsupported, and error states plus the frame and
scene captured when the query was issued. A timestamp span is elapsed GPU
command-stream time, not hardware utilization or exclusive shader-busy time.

GPU busy time is derived from the process's DRM `drm-engine-gpu` nanosecond
counters in `/proc/self/fdinfo`, deduplicated by device/client identity. The
reported percentage is per-process engine busy time divided by the sampled wall
interval, not whole-system GPU utilization. New, removed, or regressing clients
are marked warming/partial; counter regressions retain a high-water baseline.
`drm-cycles-gpu`, max frequency, and the sampled devfreq current frequency are
reported only when available. Frequency is not a utilization measure. Missing
busy counters remain unavailable. No CPU/GPU diagnosis or new performance
acceptance has been made from these diagnostics yet.

For a short off-headset diagnostic only, `POKEPORT_XR_FORCE_RENDER=1` together
with `POKEPORT_VR_TELEMETRY=1` authorizes rendering while the runtime reports
`shouldRender=false`. The authorization starts after XR initialization and
expires within 120 seconds; `POKEPORT_XR_FORCE_RENDER_SECONDS` may shorten it.
Raw runtime `focused` and `shouldRender` values remain unchanged in status and
logs. Forced frames use real runtime eye positions only after a stable pose is
observed, otherwise a fixed synthetic center/orientation with eye separation
measured from valid runtime views; rendering stays blocked if no valid eye
separation is available. Runtime asymmetric FOV is preserved. Every affected
summary is tagged `mode=unattended`, including raw/effective frame counts and
pose/IPD source. These are unattended renderer measurements and do not claim
wearer-focused performance. Leave both flags unset for ordinary play.

A read-only pose review found locate/render/submit using the same predicted pose
and time. Conditional tracking risks remain unmeasured: the small head-translation
clamp, invalid-pose fallback versus native submission, and reference-space changes.
The low submission rate does not establish jitter's sole cause. During `off`
diagnostics, `eyeFoveationSupported=false` is unqueried rather than proof of missing
hardware support, because the META extension/property is enabled only for `eye`.

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

The wearer later reported an inverted, improperly scaled and misaligned view
after an initially good view. A later diagnostic run stopped after 234 submits,
before its requested 250-submit eye capture. Its driver asserted missing dumps;
the engine catches driver errors and queues quit(1), rather than directly
entering the LÖVE error handler. This diagnostic failure does not rule out the
independently confirmed production render defects.

The corrections convert Canvas origin once at the GPU copy boundary, project
mono fallback screens instead of stretching them, and map eye translation and
full orientation through the same recentered game-camera basis. The Runtime
supplies focus/up directly so the reference mod's legacy roll-stripping branch
cannot disagree with the full pose submitted to OpenXR. Head-centre lean is
clamped before adding eye offsets, preserving runtime IPD at the clamp boundary.
World units remain 48 pixels/metre; no camera modes or settings UI were added.

The native Steam shortcut did not propagate the devkit `-env.json` diagnostic
values in this test. Diagnostic runs therefore used a temporary shell wrapper
that exported their values and executed the unchanged launcher through Steam.
Normal play must use `tools/LAUNCH-STEAM-FRAME.sh` with no test driver or dump
settings. The devkit's empty `env` argument does not clear an old environment
file; clear this title's file explicitly when restoring normal play.

### Runtime foveation negotiation (effectiveness awaiting device proof)

The Linux bridge requests a medium `XR_FB_foveation_configuration` profile when
`XR_FB_foveation` and `XR_FB_swapchain_update_state` are advertised. The default
`POKEPORT_XR_FOVEATION=eye` also enables `XR_META_foveation_eye_tracked` when
available, checks the system property, and chains its eye-tracked profile request.
`fixed` requests medium fixed foveation; `off` provides a comparable full-rate
control. Rejected eye profiles fall back to fixed; rejected swapchain creation or
updates recreate **both** eyes without foveation. Profile handles are destroyed
once the runtime has copied their parameters, or on teardown after failure.
Native recommended eye dimensions are unchanged.

The OpenGL swapchain foveation create flags are zero. This is a legal generic
request; the bridge does not claim QCOM scaled-bin support or pass Vulkan FDM
flags through an OpenGL binding. Frame's current Zink GL inventory has no
`GL_QCOM_texture_foveated`. Valve's implicit Vulkan FDM layer may inject density
maps into underlying matching-size render passes. This route needs actual
`FDM_DEBUG` evidence of attachment to LÖVE's **source eye scene passes**, plus
comparable timing; an accepted profile or foveated final copy proves neither.
The bridge's `status()` exposes `foveationAvailable`, `eyeFoveationSupported`,
`foveationRequested`, `foveationApplied`, `foveationMessage`, and
`foveationSourceShading`. `Applied` means both OpenXR updates succeeded;
source shading remains explicitly `unverified-runtime-injection`.

Protocol details follow the Khronos [swapchain foveation create flags](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrSwapchainCreateFoveationFlagBitsFB.html),
[level profile chain](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrFoveationLevelProfileCreateInfoFB.html),
and [profile lifetime](https://registry.khronos.org/OpenXR/specs/1.1/man/html/xrDestroyFoveationProfileFB.html).

### Conservative stereo-frustum mesh selection

`src/vr/DrawDistance.lua` scopes hooks to the native XR draw and captures both
cameras returned by `Runtime.views` before the first eye renders. It uses the
same pinned Mat4 projection/look-at convention, full eye roll and asymmetric
FOV. A map chunk is skipped only if its conservative 3D bounds lie outside
**both** eye frusta. There is no scrolling-viewport cut, distance limit, or
floor removal. The developer baseline bypass is `POKEPORT_VR_DRAW_DISTANCE=off`.

Immutable map meshes returned by ChunkMesher are analysed once per source
identity into 32-world-pixel XZ groups, each with its full vertical extent.
Preparation has a shared 2 ms frame budget (checked every 256 quads); both eyes
continue using the full mesh until preparation completes on a later draw.
Selected meshes attach the original vertex attributes and only supply a filtered
index list in original order. The list is uploaded only when the visible group
set changes, and shared by both eyes. Neighbor translation is applied before the
frustum test. Unsupported model transforms conservatively use the original.
Unused entries and derived GPU meshes are retired after two absent draws;
replacement source identities invalidate selection naturally. The cache uses
explicit retirement because attached vertex buffers retain the original mesh;
weak Lua keys alone cannot break that reference chain. Diagnostic off mode also
retires old entries, and Runtime shutdown releases all proxies without releasing
source meshes owned by ChunkMesher.

`DrawDistance.status()` exposes the last draw's mode, active XR use, cache
readiness, pending draws, index uploads and full/selected eligible map index
counts. Divide the index counts by three for triangles; they include both eyes
but exclude actors, untouched water and the shadow pass. It does not read GPU
resources or log each frame.

The test expands each group by 8 world pixels and the side frustum planes by 4%.
It bounds the exact quadratic WorldCurve vertical displacement, including
interior extrema, then expands for the shader's camera-facing depth pull. This
also conservatively covers geometry pulled through a very close eye. Near/far
plane rejection is intentionally omitted. Actors and full shadow
casters remain unchanged. The pinned water reflection is screen-space: it reads
the already-rendered color/depth image and falls back to sky outside that image;
it does not render a separate reflected camera. Water stays on its original
complete mesh/index stream, including when its shader falls back to Voxel3D,
preserving the existing reflective surface path. The pinned terrain/water vertex
shaders have no wind displacement; water relief is evaluated in the fragment
shader inside the original surface footprint.

Full-resolution same-update image comparisons are the acceptance evidence for
this selection. Primitive-count reduction is host geometry evidence only; it is
not a Steam Frame FPS measurement. Earlier viewport-window screenshots are a
rejected experiment and do not describe the production behavior.
