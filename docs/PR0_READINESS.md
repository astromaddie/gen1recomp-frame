# PR0 — Gen1Recomp Frame

**EXPERIMENTAL — public source.** The Frame kit contains the launcher, VR bridge and renderer patches. Bring your own Pokémon game data; it is kept outside the kit. No binary release was uploaded.

The clean build at `61b98277b0516bc9d9819edbbea866de8f96b520` fetched both pinned source projects and all six runtime archives from public URLs without personal Git credentials. Every archive matched `sources/SHA256SUMS`. The complete Linux ARM64 runtime image was rebuilt from those sources, then the native bridge was compiled and packaged against it. Dependency closure, ABI ceilings and a real LÖVE native-module import passed.

All 17 Lua regression scripts passed on the rebuilt runtime. They cover the current renderer's stereo camera, physical scale, launcher controls and transitions, battle presentation, frame ordering, diagnostics and error cleanup. The camera test now uses the current public renderer instead of the replaced CameraMode module.

The final package passed 76 checksum checks and the strict 75-file allowlist, with 17 license notices. It includes no ROMs, saves or assembled game directory. The original kit's [MIT license](../LICENSE), engine MIT notice and all renderer/runtime notices are retained; none grants rights to Pokémon game data. The history and new-source scans found no personal credentials or game payloads.

See [PR0_METADATA.json](PR0_METADATA.json) for exact build identities and [TOOLS.md](../TOOLS.md) for commands. The [README](../README.md) describes current features; this source/build review did not change or run the installed Frame game.
