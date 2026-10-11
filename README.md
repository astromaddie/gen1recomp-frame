# Gen1Recomp for Steam Frame

This is a native Steam Frame port kit for Pokémon Red, Blue and Yellow. It adapts the pinned [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp) engine and [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE) renderer to SteamLinuxRuntime_4-arm64 and OpenXR. It runs on the headset; no PC streaming is needed. This is the Red/Blue/Yellow source fork, not the current Gen 2/3 engine.

**EXPERIMENTAL.** This is a personal-use kit and remains a work in progress. You need your own supported Pokémon Red, Blue or Yellow ROM, which you import through the game. The kit contains no ROM, extracted game data or saves.

## What the Frame port adds

- Head-tracked stereo views for the overworld and staged battles.
- A shared physical screen for the launcher and other flat game screens, with a laser pointer for launcher navigation.
- Original menu, dialogue and battle artwork projected as a head-level HUD.
- ABOVE, first-person and third-person camera choices, with recentering and optional camera setback.
- Frame, Touch and Index launcher bindings alongside the game's usual controls.
- A native ARM64 LÖVE runtime, OpenXR bridge and packaging tools for local installation.

HUD readability and performance still need work in the current renderer.

## Import your game and build

Import a legally obtained 1 MiB `.gb` or `.gbc` Red, Blue or Yellow ROM in the launcher. Yellow images are commonly `.gbc`. The [tools guide](TOOLS.md) has the full build, assembly, packaging and launch steps. The kit builds the public runtime and bridge; your assembled game stays outside the source kit.

For a quick outline, build the ARM64 runtime and bridge with Docker Buildx, fetch the pinned engine and renderer sources into a separate directory, assemble the local game, and package the result. Launch the assembled game through SteamLinuxRuntime_4-arm64 so SteamVR supplies the controller runtime.

The [architecture notes](VR_ARCHITECTURE.md) explain the stereo camera, launcher screen, HUD and battle rendering. The pre-PR0 README is preserved in [README_PRE_PR0.md](README_PRE_PR0.md).

## Credits and licenses

The engine is based on MIT-licensed [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp); the renderer comes from [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE). My original Frame kit and VR additions use the [MIT license](LICENSE). The upstream notices are retained; their pinned versions and runtime licenses are listed in [LICENSES.md](LICENSES.md). The kit does not include Pokémon game data; supply it from your own copy.
