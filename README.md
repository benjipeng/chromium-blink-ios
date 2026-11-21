# Curium

Curium (`com.appautomaton.curium`) is a native iOS browser with a Liquid Glass shell and a Chromium engine: Blink, V8, and Manifest V3 extensions. The engine runs in a single process, as iOS and LiveContainer require. V8 runs jitless by default and switches to JIT when a debugger enables it. One repository and one integration branch, `main`, hold the app and the engine build. GitHub Actions fetches, prunes, compiles, and links Chromium. Xcode with the iOS 27.2 SDK builds and iterates on the app locally, with no upstream Chromium checkout.

## Local app and engine handoff

Open `Curium.xcodeproj` and select the `Curium` scheme. The Swift shell in `Curium/` builds against the Objective-C interface in [`EngineContract/`](EngineContract/README.md). When engine linking is enabled, the project selects the device or simulator slice from `Vendor/CuriumEngine/`.

```sh
scripts/sync_curium_engine.py                  # Download the Actions artifact and verify the IPA
scripts/sync_curium_engine.py --ipa /path/to/Chromium-Blink-<version>-arm64.ipa
scripts/sync_curium_engine.py --status         # Inspect the handoff offline
```

Assembly requires Xcode on Apple silicon; downloads also require the GitHub CLI (`gh`). The tool checks the IPA bytes before assembly. Use `--ipa … --skip-sha256` only for disposable local test IPAs; the manifest marks the result as unverified.

[`Kernel.lock`](Kernel.lock) is the single record of the engine in use: its commit, Actions run, artifact, Chromium version, and two digests. `KERNEL_ARTIFACT_ZIP_SHA256` covers the ZIP that GitHub serves; `KERNEL_IPA_SHA256` covers the IPA inside it, and verified assembly checks the IPA against it. Update the pin only from a verified `build-ipa.yml` package.

The handoff contains `EarlyMallocZoneRegistration.xcframework`, `chrome_framework.xcframework`, and `Lottie.xcframework` when present. Each contains an ad hoc signed `ios-arm64` and `ios-arm64-simulator` slice. `EngineResources/` keeps ICU data, resource packs, localizations, scripts, error pages, and bundled extensions. The manifest records the source digest and the number of files and bytes retained, plus the uncompressed bytes omitted from app resources. It records assembly time in UTC; set `SOURCE_DATE_EPOCH` to fix that timestamp for reproducible runs.

With `CURIUM_USE_ENGINE_XCFRAMEWORK = YES` in `Version.xcconfig`, the app links the engine and starts Blink; with `NO`, it builds without the engine and starts in standby. See the [app guide](Curium/README.md). To run the standalone Chromium IPA instead, use the [simulator guide](docs/simulator.md).

## Architecture

The remote build uses a pruned, revision-pinned source snapshot from `sync-source.yml`. GitHub Actions stores it in GHCR. Linux cross-compiles arm64 iOS code with `ld64.lld`; macOS supplies the pinned Apple tools and packages the result.

| Stage | Runner | Work |
| --- | --- | --- |
| 0 · SDK stub | macOS | Extract the iPhoneOS SDK and Swift stub from the Xcode pinned in `version.lock`; publish the encrypted artifact. |
| 1 · Codegen | Linux | Apply patches, generate and audit the Ninja graph, and build host tools and generated inputs. |
| 2 · Apple tools | macOS | Run the Apple-only edges for Swift, assets, interface files, and intents. |
| 3 · Compile | Linux | Build target objects across 18 stable partitions in parallel, with a separate `ccache` bucket per partition. |
| 4 · Link | Linux | Verify the partition manifests and object hashes, then link `Chromium.app` without compiling. |
| 5 · Package | macOS | Extract deferred AppIntents metadata, prune unused extension stubs, sign as configured, and publish the IPA and its SHA-256. |

### Checkpoints and resumption

The pipeline plans before compiling and reuses existing GHCR checkpoints for codegen, Apple tools, each compile partition, and link. Keys derive from stage epochs, upstream keys, source and SDK digests, and the files listed in `scripts/plan_pipeline.py`. Workflow YAML and local app files do not shape these keys. Each job checks again before starting; a registry error stops the run, and only a confirmed miss triggers work. Failed attempts can resume missing work without discarding published checkpoints.

### CI efficiency and cache reuse rules

Keep `patches/`, `args/`, `version.lock`, and the planner's `COMMON` scripts unchanged during Swift and Liquid Glass work. Local app and handoff changes keep **100% of existing GHCR checkpoint keys reusable** for the same source and SDK inputs.

Batch engine C++ changes and pin changes into a single candidate. Prepare the matching source snapshot and SDK stub, then gate the batch with `graph-diagnose.yml` against a known green graph; its optional extension object probe compiles the affected objects without linking. Build the IPA after the audit passes, and update `Kernel.lock` from the verified package after testing the engine contract.

## Repository setup

For a new GitHub deployment, use a public repository and configure the `CI_ARTIFACT_KEY` secret for SDK artifact encryption. Dispatch `sync-source.yml` for a new Chromium revision, and use `build-ipa.yml` to build the package and create any missing checkpoints. `graph-diagnose.yml` audits a candidate against its selected baseline. Bump a stage epoch in `ci/epochs.json` only when intentionally invalidating that checkpoint and its downstream keys.

## Layout

| Path | Purpose |
| --- | --- |
| `Curium/`, `Curium.xcodeproj` | Native app and local Xcode build. |
| `EngineContract/` | Browser host and extension interfaces shared by the app and engine. |
| `Kernel.lock`, `scripts/sync_curium_engine.py` | Pin and assemble the contents of ignored `Vendor/CuriumEngine/`. |
| `version.lock`, `patches/`, `args/` | Upstream Chromium pin, ordered patch series, and GN configuration. |
| `ci/`, `scripts/plan_pipeline.py`, `scripts/stages/` | Checkpoint inputs and the GitHub Actions build stages. |
| `tools/simulator/` | Diagnostics for the standalone Chromium IPA. |
