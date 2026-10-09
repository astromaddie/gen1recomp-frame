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

The game simulates once before drawing both eyes. The existing voxel mod derives
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

The kit's scoped `GamePresentation` adapter captures the existing `Minimap.draw`
and `Renderer.compositeUi` output into a transparent desktop-layout surface.
The surface is projected separately through each eye's pose/FOV over its world
image. It follows head yaw/pitch while retaining gravity-up, so full eye roll
does not turn identical texture coordinates into mismatched physical locations.
Original palette zones, minimap art and menu/dialogue layout stay in the source
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
orientation, head tracking, IPD and 48 pixels/metre. POV does not move. The 0.75 m
comparison value is explicitly provisional. Native recommended eye dimensions
remain the default; no lower resolution has been adopted.

| Gate | Evidence | State |
| --- | --- | --- |
| Native source and ABI | ARM64 bridge/runtime builds; Lua integration tests; ELF/closure/ABI receipts | Host passed |
| GPU Canvas copy | Baseline fails the new OpenXR-origin test; corrected pinned LÖVE/Xvfb pixels, MSAA, renderbuffer, scale/state/type tests pass | Host passed; corrected device check pending |
| Flat game and real save | Red Pallet Town; copied Yellow Continue at Pewter City (22,19), voxel render | Host passed |
| OpenXR colour probe | SteamVR/OpenXR + Zink GL 4.3, sRGB 1728 x 1728 eyes; corrected source/dump pixels match. Edge labels were outside the visible lens area | Session/copy passed; orientation established by subsequent game wear |
| Actual game on Frame | Copied Yellow save at Pewter City (22,19): corrected native run captured distinct world eyes after 500 submissions; wearer confirmed upright/aligned imagery | Short run/capture passed; performance unaccepted |
| Physical input and camera modes | A/B, stick, Menu, View/recentre, launcher selection and voxel Options | Pending wearer |
| Presentation/comfort | Wearer confirmed corrected upright/aligned world, but rejected closeness, hidden HUD and jitter. New host tests cover actual minimap/Renderer/finishStereo composition, rolls 0/30/90/-45, shared battle plane and CameraMode setback | HUD/setback pending wearer; comfort/performance unaccepted |
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
No lower-resolution default or measured resolution benefit has been adopted.

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
