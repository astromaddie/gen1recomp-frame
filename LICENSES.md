# Runtime and source license inventory

The kit packages the engine's MIT notice in `LICENSE-MIT-ENGINE` and keeps the
complete runtime notices in `runtime/licenses/`. That inventory includes LÖVE,
SDL2, OpenXR, OpenAL Soft, Theora, mpg123, LuaJIT, libmodplug, Vorbis, Ogg, FreeType, libpng, zlib, and Brotli.
The exact package names and notice hashes are recorded in
`PACKAGE-METADATA.json` and `SHA256SUMS`.

The complete DramaticShapeVoxelMod tree is not distributable. It is fetched at
its pinned revision only for private local assembly, and `package.py` never
copies the local `game/` assembly or fetched source tree into a kit. Do not add
ROMs, generated game caches, saves, or game assets to the native package.
