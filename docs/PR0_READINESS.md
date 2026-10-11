# PR0 readiness — Gen1Recomp Frame

Visibility remains private. No kit release or publication is included in this work.

## Source and test identity

- Source revision: 966711ed0904a14472b86a442d9f072b802ff37a.
- PR0 makes documentation-only changes; no executable files or test sources changed.
- Focused ROM-free host tests passed at source revision `966711ed0904a14472b86a442d9f072b802ff37a`; the tested `integration/` tree is `456e8548d4e4565363b51f6727a9fffda6efaa01`. The pinned ARM64 builder image was `sha256:9d5562925b15d74f956e263434df866a225946fd81eaf3f840f266aa26eea402`. Presentation, runtime, runtime-loader, telemetry, runtime-telemetry, VR telemetry driver, startup trace, probe policy, and launcher pointer tests passed. No full runtime build or package was run.
- The fresh authenticated private clone at this path began clean at the listed source revision. The old Documents checkout was not used because Git object reads stalled. The repository is private by design; no anonymous root checkout is claimed.
- The coordinator's remote audit at this same source revision covered 19 commits and 226 blobs and reported zero Gitleaks findings and no inventory flags. This is source-history evidence, not runtime acceptance.

## Supported target and dependencies

Target: native Linux AArch64 Steam Frame under SteamLinuxRuntime_4-arm64, OpenXR, and LÖVE 11.5. There is no Android/Lepton target and no PC streaming mode.

The reproducible recipes and dependency pins are in TOOLS.md and sources/SHA256SUMS. They use Ubuntu 22.04 in Docker, buildx for linux/arm64, the pinned LÖVE runtime, the pinned Polymatic source, and the pinned public DRAMALESS_SHAPE source. License notices are retained in LICENSE-MIT-ENGINE and LICENSES.md. Build outputs, local game assembly, ROMs, saves, and extracted game data must stay outside the distributable kit and repository.

The root README gives the copyable runtime, bridge, assembly, and packaging commands. No build or package was run for PR0.

## Verification by level

| Level | Evidence |
|---|---|
| Host | Historical native builds, Runtime/main integration, camera, renderer and GPU Canvas-copy tests are described in VR_ARCHITECTURE.md and TOOLS.md. PR0 did not rerun these checks at source 966711e. |
| Unattended Frame | Older source installed through Steam. A ROM-free probe reached focused OpenXR and submitted projection; a short copied-save run logged 300 projection submissions without bridge errors. Exact candidate package source identity is not established by the historical docs. |
| Worn | Older renderer source was worn. The wearer reported upright/aligned imagery after a correction, accepted a 0.75 m setback, and also reported an inaccessible HUD and severe jitter. The current public DRAMALESS replacement has not been accepted while worn. |

The prior 1024-square sample counted 1,203 submissions in 30.0046 seconds, about 40.09 per second, with most runtime periods at 27.78 ms. The wearer still reported severe jitter. This is not a sustained-performance result for current source. No complete gameplay, battle, or campaign result is claimed.

## Clean checkout, rights, and blockers

The fresh private clone was clean at source revision 966711e before these documentation edits. In a separate temporary directory with an empty HOME, no system/global Git configuration, and credential prompts/tokens unset, tools/fetch-private-sources.py fetched clean detached checkouts at Polymatic 1d2c421ff47f487d836589d38c6209b031bbce91 and DRAMALESS_SHAPE 97ca3e1f8f7c3aa0b3e671db497076150f494051. tools/fetch-runtime-sources.py fetched all six pinned runtime archives under the same environment and every SHA-256 matched sources/SHA256SUMS. No build was run. The private project root intentionally remains private.

MIT notices cover the pinned open-source components as recorded in the repository. They do not grant rights to commercial Pokémon ROMs or extracted game data. No game data is included in source or kit output. No source-license blocker was found in the coordinator's history audit, but this is not a rights determination for user-supplied data.

## Pending wearer acceptance

For a candidate package tied to an exact source and dependency receipt, record:

- Install/update the kit and launch the registered Steam title.
- Exercise actual Frame controller input in launcher and game, including laser clicks, gamepad navigation, and recenter.
- Verify tracking, stereo alignment, both eyes, menu/pointer behavior, HUD position/readability, and comfort.
- Play representative overworld gameplay and a complete battle; pause, resume, save, reload, and exit normally.
- Verify sleep/resume and recovery from focus/tracking loss.
- Measure sustained frame pacing at native recommended eye resolution in named scenes while worn. A display refresh rate or projection-submission count is not this measurement.
