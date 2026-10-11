# Gen1Recomp for Steam Frame

This is a native Linux ARM64 Steam Frame port kit for Pokémon Red, Blue and Yellow. It adapts the pinned [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp) engine and [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE) renderer to OpenXR. It runs on the headset; no PC streaming is needed. This is the Red/Blue/Yellow source fork, not the current Gen 2/3 engine.

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

Import a legally obtained 1 MiB `.gb` or `.gbc` Red, Blue or Yellow ROM in the launcher. Yellow images are commonly `.gbc`. The [tools and installation guide](TOOLS.md) has the host prerequisites, ARM64 Buildx steps, assembly, packaging, first install and Steam launch instructions. The kit builds the public runtime and bridge; your assembled game stays outside the source kit.

For a quick outline, build the ARM64 runtime and bridge with Docker Buildx, fetch the pinned engine and renderer sources into a separate directory, assemble the local game, and package the result. Launch the assembled game from its Steam library entry so SteamVR supplies the controller runtime.

The [architecture notes](VR_ARCHITECTURE.md) explain the stereo camera, launcher screen, HUD and battle rendering. The pre-PR0 README is preserved in [README_PRE_PR0.md](README_PRE_PR0.md).

## Download and install

The [0.1 downloads](https://github.com/astromaddie/gen1recomp-frame/releases/tag/v0.1.0) include the built ARM64 runtime and VR bridge. You don't need Docker, a compiler or a Mac to use them.

Extract the archive, then run `bash tools/SETUP-GAME.sh` from that folder. Setup needs Git, Python 3, `patch` and an internet connection; it downloads the matching public engine and renderer and applies the included Frame changes. It doesn't download a ROM. After setup, add `tools/LAUNCH-STEAM-FRAME.sh` to Steam on the Frame, or upload the complete folder with SteamOS Devkit Client using Steam Linux Runtime 3.0 ARM64 (Sniper). Import your own supported US Red, Blue or Yellow ROM when the game starts.

## Credits and licenses

The engine is based on MIT-licensed [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp); the renderer comes from [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE). My original Frame kit and VR additions use the [MIT license](LICENSE). The upstream notices are retained; their pinned versions and runtime licenses are listed in [LICENSES.md](LICENSES.md). The kit does not include Pokémon game data; supply it from your own copy.
