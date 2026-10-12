# Gen1Recomp for Steam Frame

This is a native Linux ARM64 Steam Frame port kit for Pokémon Red, Blue and Yellow. It adapts the pinned [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp) engine and [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE) renderer to OpenXR. It runs on the headset; no PC streaming is needed. This is the Red/Blue/Yellow source fork, not the current Gen 2/3 engine.

**EXPERIMENTAL.** This is a personal-use kit and remains a work in progress. You need your own supported Pokémon Red, Blue or Yellow ROM, which you import through the game. The kit contains no ROM, extracted game data or saves.

**Want to play on Steam Frame?** Download the prebuilt ARM64 runtime and setup helper from the [v0.2.1 release](https://github.com/astromaddie/gen1recomp-frame/releases/tag/v0.2.1); no compiler is needed. The helper sets up the matching public engine and renderer. You still need your own supported Pokémon Red, Blue or Yellow ROM.

## What the Frame port adds

- Head-tracked stereo views for the overworld and staged battles.
- A shared physical screen for the launcher and other flat game screens, with a laser pointer for launcher navigation.
- Original menu, dialogue and battle artwork projected as a head-level HUD.
- ABOVE, first-person and third-person camera choices, with recentering and optional camera setback.
- Frame, Touch and Index launcher bindings alongside the game's usual controls.
- A native ARM64 LÖVE runtime, OpenXR bridge and packaging tools for local installation.

HUD readability and performance still need work in the current renderer.

## Import your game and build

Import a legally obtained 1 MiB `.gb` or `.gbc` US Red, Blue or Yellow ROM in the launcher. Yellow images are commonly `.gbc`. For native Frame launches, put the ROM directly in the install's `roms/` folder beside `game/` and `tools/`; the headset has no desktop file picker. Flat Linux desktop runs keep their native picker. The importer also checks the install root, legacy `game/` folder and app save folder for existing drop workflows. The [tools and installation guide](TOOLS.md) has the host prerequisites, ARM64 Buildx steps, assembly, packaging, first install and Steam launch instructions. The kit builds the public runtime and bridge; your assembled game stays outside the source kit.

For a quick outline, build the ARM64 runtime and bridge with Docker Buildx, fetch the pinned engine and renderer sources into a separate directory, assemble the local game, and package the result. Launch the assembled game from its Steam library entry so SteamVR supplies the controller runtime.

The [architecture notes](VR_ARCHITECTURE.md) explain the stereo camera, launcher screen, HUD and battle rendering. The pre-PR0 README is preserved in [README_PRE_PR0.md](README_PRE_PR0.md).

## Download and install

The [v0.2.1 release](https://github.com/astromaddie/gen1recomp-frame/releases/tag/v0.2.1) includes the built ARM64 runtime and VR bridge. You don't need Docker, a compiler or a Mac to use it.

Extract the archive into a new folder and run setup there:

```sh
cd /path/to/new-install
bash tools/SETUP-GAME.sh
mkdir -p roms
```

Setup needs Git, Python 3, `patch` and an internet connection; it downloads the matching public engine and renderer and applies the included Frame changes. It doesn't download a ROM. Put your own supported ROM directly in the new `roms/` folder. Add `tools/LAUNCH-STEAM-FRAME.sh` to Steam on the Frame or upload the complete folder with SteamOS Devkit Client using Steam Linux Runtime 3.0 ARM64 (Sniper). In the launcher, choose **Import ROM**, wait for extraction to complete, then choose **Play**.

To update an existing install, set up v0.2.1 in a fresh folder, then point the existing Steam shortcut or SteamOS Devkit upload at that folder. Do not unpack over an existing `game/` directory: `SETUP-GAME.sh` deliberately refuses to replace one. The launcher keeps game data under its XDG data root, which defaults to `$HOME/.local/share/Gen1RecompFrame`; keep that folder, and keep the same `GEN1_FRAME_DATA_DIR` value if you customized it, to retain saves and caches.

The importer recognizes these clean US ROM SHA-1 hashes and requires each image to be exactly 1 MiB:

| Game | SHA-1 |
| --- | --- |
| Pokémon Red | `ea9bcae617fdf159b045185467ae58b2e4a48b9a` |
| Pokémon Blue | `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2` |
| Pokémon Yellow | `cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1` |

For troubleshooting, the image must be exactly 1 MiB. An unsupported-ROM error includes the observed SHA-1; compare it with the table and use a clean, untrimmed US dump. For a read error, check that the file is readable. The folder scan is limited to files directly inside `roms/` and the compatibility roots above; it doesn't search subfolders or move, copy or delete ROMs. If you copy a ROM while the game is open, press **Import ROM** again to retry.

## Credits and licenses

The engine is based on MIT-licensed [Polymatic Gen1Recomp](https://github.com/polymathiclabs/gen1recomp); the renderer comes from [DRAMALESS_SHAPE](https://github.com/artyrambles/DRAMALESS_SHAPE). My original Frame kit and VR additions use the [MIT license](LICENSE). The upstream notices are retained; their pinned versions and runtime licenses are listed in [LICENSES.md](LICENSES.md). The kit does not include Pokémon game data; supply it from your own copy.
