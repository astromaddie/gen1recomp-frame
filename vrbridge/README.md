# xrbridge: optional LOVE/OpenXR bridge

`xrbridge` is a LuaJIT-loadable OpenXR module for the pinned gen1recomp VR
integration. The Windows WGL path remains available. Linux ARM64 uses the
current LÖVE 11.5 GLX context and the static OpenXR SDK loader; it never starts
SteamVR or chooses a runtime itself. SteamVR must already be the active system
OpenXR runtime.

On Linux, two rendered Canvases are copied directly between OpenGL
framebuffers into `GL_SRGB8_ALPHA8` OpenXR swapchain images. The steady-state
projection path does not call `Canvas:newImageData`, read pixels back to the
CPU, or upload RGBA strings. The old string-based calls remain for the
unchanged Windows path and compatibility callers. Linux checks Canvas
userdata against a Canvas created by the exact running LOVE build before it
uses LOVE 11.5's `Proxy` layout or virtual Canvas methods; internal LOVE
symbols are hidden, so the module links to and packages against the exact
`liblove-11.5.so` ABI.

## Linux ARM64 build

Build with headers and libraries from the same LOVE 11.5 runtime that will
load the module. CMake verifies `LOVE_VERSION_STRING` in the source tree and
requires the exact `liblove-11.5.so` filename. The OpenXR loader is linked
statically because SteamOS does not provide a system `libopenxr_loader.so`.

```sh
cmake -S vrbridge -B build/linux-arm64 -G Ninja \
  -DOPENXR_INCLUDE_DIR=/opt/openxr/include \
  -DOPENXR_LOADER_LIBRARY=/opt/openxr/lib/libopenxr_loader.a \
  -DLUAJIT_INCLUDE_DIR=/usr/include/luajit-2.1 \
  -DLUAJIT_LIBRARY=/usr/lib/aarch64-linux-gnu/libluajit-5.1.so \
  -DLOVE_ROOT=/opt/love-11.5 \
  -DLOVE_LIBRARY=/opt/love/lib/liblove-11.5.so
cmake --build build/linux-arm64 --config Release
```

The resulting module is `build/linux-arm64/xrbridge.so`. Package it beside
the matching LOVE runtime and set `POKEPORT_XRBRIDGE` to its path. Set
`POKEPORT_VR=1` to opt into VR; a product launcher may also set
`POKEPORT_VR_REQUIRED=1`, which starts OpenXR before the existing title and
ROM importer are constructed and fails visibly if the bridge is unavailable.
Do not use a module built against a different LOVE source/library pair.

## Integration overlay

The kit deliberately contains only bridge and integration overlay files, not
the proprietary launcher, ROMs, generated game cache, or the separate voxel
mod. During source assembly, copy
`integration/src/vr/Runtime.lua` to `src/vr/Runtime.lua` and apply
`integration/main.lua.patch` to the pinned `main.lua`:

```sh
patch --dry-run -p1 -d /path/to/assembled-gen1recomp \
  < integration/main.lua.patch
patch -p1 -d /path/to/assembled-gen1recomp < integration/main.lua.patch
```

The overlay starts required XR before the title/importer UI, routes the
existing importer A/B, Menu/Select, and left-stick handlers from OpenXR
actions, and submits its unchanged flat UI as a stereo projection layer. The
existing true-3D voxel stereo hook continues to provide its left/right eye
Canvases through `Runtime.submit`. `xrWaitFrame` drives the Linux LOVE loop;
the overlay disables window VSync and FrameCap sleeping while XR is pacing,
and uses the predicted display period for game updates. Focus loss and
standby suspend simulation/audio/input while the loop continues to poll XR
events and close frames. Flat mode and the Windows bridge retain their
existing behavior.

No comfort/settings UI was added. Comfort options beyond the existing
camera safety limits are deferred until device and worn testing can establish
the right controls and defaults.

## ROM-free OpenXR probe

`integration/probe` is a small LOVE program that creates two labeled color
Canvases, logs LOVE's GL renderer plus OpenXR runtime/GL requirements/current
context/swapchain/view sizes/FOV/controller profiles, and exits after 15
seconds by default. It contains no game data. It submits the color projection
whenever `xrWaitFrame` says `shouldRender`; `POKEPORT_XR_PROBE_DRY_RUN=1`
explicitly skips submission while still polling and closing frames. Neither
mode overrides the runtime's `shouldRender` result. For bounded diagnostics,
set `POKEPORT_XR_PROBE_DUMP_DIR` to an absolute existing directory. The probe
saves its source Canvases as `left.png` and `right.png`, and the native bridge
captures the copied OpenXR swapchain images once as `xr-left.ppm` and
`xr-right.ppm` before releasing them. Native dumps are limited to 8,388,608
pixels per eye, use top-left PPM row order, and never read pixels during later
frames. `POKEPORT_XR_SWAPCHAIN_DUMP_AFTER_SUBMITS=N` delays the native capture
until the Nth successful projection submission (default 0 captures the first;
values are capped at 3,600). This is useful when capturing a settled gameplay
scene instead of the launch menu. The legacy `POKEPORT_XR_PROBE_EYE_DUMP_DIR`
still saves source Canvases only; `POKEPORT_XR_SWAPCHAIN_DUMP_DIR` can
independently select the native destination directory.

```sh
POKEPORT_XRBRIDGE="$PWD/build/linux-arm64/xrbridge.so" \
POKEPORT_XR_PROBE_SECONDS=15 \
love integration/probe
```

## Native verification

The test-only module exposes the same production framebuffer-copy routine
through a guarded Canvas entry point. It is excluded from normal builds and
packages. On an ARM64 build host with Xvfb and software OpenGL:

```sh
cmake -S vrbridge -B build/canvas-test -G Ninja \
  -DXRBRIDGE_TESTING=ON \
  -DOPENXR_INCLUDE_DIR=/opt/openxr/include \
  -DOPENXR_LOADER_LIBRARY=/opt/openxr/lib/libopenxr_loader.a \
  -DLUAJIT_INCLUDE_DIR=/usr/include/luajit-2.1 \
  -DLUAJIT_LIBRARY=/usr/lib/aarch64-linux-gnu/libluajit-5.1.so \
  -DLOVE_ROOT=/opt/love-11.5 \
  -DLOVE_LIBRARY=/opt/love/lib/liblove-11.5.so
cmake --build build/canvas-test
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 \
  POKEPORT_XR_PROBE_DUMP_DIR=/tmp/xrbridge-dumps \
  POKEPORT_XRBRIDGE="$PWD/build/canvas-test/xrbridge.so" \
  /opt/love/bin/love integration/tests/canvas_copy
```

Create `/tmp/xrbridge-dumps` before running the diagnostic test. It verifies
both native dump files' metadata, dimensions, top-left orientation and quadrant
colors, plus restoration of the OpenGL read framebuffer and pixel-pack state.
The probe's submit policy can be checked without a headset or runtime:

```sh
luajit integration/tests/probe_policy_test.lua integration/probe/main.lua
```

The Lua overlay behavior checks run without a ROM or headset:

```sh
POKEPORT_XRBRIDGE=/tmp/fake-xrbridge \
  luajit integration/tests/runtime_test.lua integration/src/vr/Runtime.lua
```

After applying the overlay to a pinned `main.lua`, its headless simulation
checks that required XR starts before the importer, native button/stick input
uses existing launcher callbacks, and focus loss gates input and updates:

```sh
POKEPORT_VR_REQUIRED=1 \
  luajit integration/tests/main_overlay_test.lua /path/to/patched/main.lua
```

Build, Xvfb, and fake-bridge checks cannot establish that the headset runtime
accepts the graphics binding, that controllers report the proposed profile,
or that the rendering and controls are comfortable while worn.

## Windows build

The Windows module retains its WGL context and runtime DLL discovery behavior:

```powershell
cmake -S vrbridge -B build -G Ninja `
  -DOPENXR_INCLUDE_DIR=C:/sdk/OpenXR-SDK/include `
  -DLUAJIT_INCLUDE_DIR=C:/sdk/LuaJIT/src `
  -DLUAJIT_LIBRARY=C:/sdk/LuaJIT/src/lua51.lib
cmake --build build --config Release
```
