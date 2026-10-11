# Gen1Recomp for Steam Frame — experimental technical preview

Gen1Recomp Frame is a native ARM64 Linux/OpenXR port kit for Pokémon Red, Blue, and Yellow, using SteamLinuxRuntime_4-arm64. It adapts the pinned MIT Polymatic engine and public DRAMALESS_SHAPE renderer to the Steam Frame. It does not stream from a PC.

This port is private and experimental. It uses the Red/Blue/Yellow source fork; it is not the current upstream Gen 2/3 engine. Its engine base is [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp), and its renderer source is [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE). Send generally applicable engine or renderer changes to those upstream projects; Frame-port integration changes belong in this private repository and need owner access for review.

## Capability evidence

| Capability | Host | Frame on desk | Worn |
|---|---|---|---|
| OpenXR runtime and stereo | Historical ARM64 runtime/bridge and Canvas-copy checks are documented; PR0 did not rerun them. | ROM-free probe reached focused OpenXR and submitted projection on older source. | Current DRAMALESS source has no focused wear check. |
| Launcher and controls | Host routing/render tests cover pointer validity, hit, click and gamepad routing. | Short prior run exercised launcher and saved-scene startup. | Actual Frame controller input and current launcher pointer behavior remain open. |
| Overworld and HUD | Camera, UI projection and renderer checks are documented in VR_ARCHITECTURE.md. | Copied Yellow save ran briefly with 300 projection submissions and no bridge error. | Prior wearer saw upright aligned imagery after a correction, but found the HUD inaccessible; current HUD and comfort are unaccepted. |
| Battles | Initial public arena/card presentation passed host rendering checks only. | No complete battle run is documented. | No full battle or campaign result is claimed. |
| Performance | Host results are not Frame performance. | Earlier 1024-square diagnostic logged 40.09 submissions per second and 27.78 ms periods. | Severe jitter was still reported; current-source sustained performance is unmeasured. |

Display refresh is not a substitute for measured application frame rate. The earlier 1024-square sample recorded about 40 submitted frames per second and severe jitter; the current source's real performance is unmeasured. See [VR_ARCHITECTURE.md](VR_ARCHITECTURE.md) and [docs/PR0_READINESS.md](docs/PR0_READINESS.md).

## Sources, game data, and build

The engine pin is Polymatic revision 1d2c421ff47f487d836589d38c6209b031bbce91; the public MIT DRAMALESS_SHAPE pin is 97ca3e1f8f7c3aa0b3e671db497076150f494051. License notices are listed in [LICENSES.md](LICENSES.md). To import a legally obtained supported Pokémon Red, Blue, or Yellow ROM, select a 1 MiB `.gb` or `.gbc` file in the import screen; the importer identifies the supported revision from its contents. Use the file picker, set `POKEPORT_IMPORT_ROM=/absolute/path/to/your-rom`, or, where no picker is available, place the `.gb`/`.gbc` beside the game so the importer can scan it. Yellow images are typically `.gbc`. ROMs, extracted game data, and saves are not included in Git or the kit package.

The copyable native runtime, bridge, local assembly, and package commands are documented in [TOOLS.md](TOOLS.md). They require Docker Buildx with ARM64 support, the pinned Ubuntu 22.04 image inputs, and external directories for build outputs and player-local assembly. The key commands are:

~~~sh
python3 tools/fetch-runtime-sources.py sources
docker buildx build --platform linux/arm64 -f tools/Dockerfile -t gen1recomp-frame-builder:latest .
tools/build-runtime.sh gen1recomp-frame-builder:latest /path/to/runtime-export
python3 tools/fetch-private-sources.py /path/to/private-sources
python3 tools/assemble-local.py --engine /path/to/private-sources/gen1recomp --voxel /path/to/private-sources/DRAMALESS_SHAPE --kit /path/to/gen1recomp-frame --output /path/to/private-local-assembly
tools/build-bridge.sh gen1recomp-frame-builder:latest /path/to/gen1recomp-frame /path/to/runtime-export /path/to/bridge-output/xrbridge.so
python3 tools/package.py --source /path/to/gen1recomp-frame --runtime /path/to/runtime-export --xrbridge /path/to/bridge-output/xrbridge.so --output /path/to/native-kit-release
~~~

The package is a native port kit, not game data. On the Frame, register it as a Steam title with SteamLinuxRuntime_4-arm64 and launch through Steam for controller access. Player data remains under the separate application data directory.

## Known limits and rights

No source change or full runtime build was made during PR0. The current-source renderer replacement has host evidence but no focused Frame/wearer acceptance. Open items include readable HUD placement, real controller acceptance, tracking stability, battle and save behavior across a full play session, normal exit, sleep/resume, comfort, and measured sustained performance. Do not interpret the previous projection count as FPS acceptance.

## PR0 changelog

- Reframed the root page as a private technical preview with exact host/unattended/worn boundaries.
- Preserved the pre-PR0 root text in README_PRE_PR0.md.
- Added source identity and pending acceptance evidence in docs/PR0_READINESS.md.
