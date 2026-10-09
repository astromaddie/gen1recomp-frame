# Runtime and source license inventory

The kit packages the engine's MIT notice in `LICENSE-MIT-ENGINE` and keeps the
complete runtime notices in `runtime/licenses/`. That inventory includes LÖVE,
SDL2, OpenXR, OpenAL Soft, Theora, mpg123, LuaJIT, libmodplug, Vorbis, Ogg, FreeType, libpng, zlib, and Brotli.
The exact package names and notice hashes are recorded in
`PACKAGE-METADATA.json` and `SHA256SUMS`.

The default renderer is DRAMALESS_SHAPE 2.0.4 at
97ca3e1f8f7c3aa0b3e671db497076150f494051, licensed under MIT. Private local
assembly includes its original LICENSE and CREDITS.md. The native kit contains
only source pins and small integration patches, never the complete mod or the
older private DRAMATIC_SHAPE tree. Do not add ROMs, generated game caches,
saves, or extracted game assets to the native package.
