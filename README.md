# Curium

Curium (`com.appautomaton.curium`) is a native iOS browser with a Liquid Glass shell and a Chromium engine: Blink, jitless V8, and Manifest V3 extensions. One repository and one integration branch, `main`, hold the app and the engine build. GitHub Actions compiles Chromium; Xcode with the iOS 27.2 SDK builds the app locally without an upstream Chromium checkout.

## Local app and engine handoff

Open `Curium.xcodeproj` and select the `Curium` scheme. The Swift shell in `Curium/` builds against the Objective-C interface in [`EngineContract/`](EngineContract/README.md). When engine linking is enabled, the project selects the device or simulator slice from `Vendor/CuriumEngine/`.

```sh
scripts/sync_curium_engine.py                  # Download the Actions artifact and verify the IPA
scripts/sync_curium_engine.py --ipa /path/to/Chromium-Blink-159.0.8149.0-arm64.ipa
scripts/sync_curium_engine.py --status         # Inspect the handoff offline
```

Assembly requires Xcode on Apple silicon; downloads also require the GitHub CLI (`gh`). The tool checks the IPA bytes before assembly. Use `--ipa … --skip-sha256` only for disposable local test IPAs; the manifest marks the result as unverified.

[`Kernel.lock`](Kernel.lock) identifies [run 44328959472](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44328959472) and [artifact 14443178991](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44328959472/artifacts/14443178991) for Chromium `159.0.8149.0`. The run came from `probe/extensions-gn` at `1f76114fbc0d5ca7f2b748a4f19fedc4d39edd79`, the commit carried forward onto `main`. The branch name is historical provenance.

The current `KERNEL_IPA_SHA256` value identifies GitHub's outer artifact ZIP. The downloaded IPA hashes to `b34c8abc851a36e05f9a171c2bf73469f168d4b2eb1cdcc8ff3761f8e5973c88`, matching the checksum published by Actions. Verified assembly rejects the current pin until it records the IPA digest.

The handoff contains `EarlyMallocZoneRegistration.xcframework`, `chrome_framework.xcframework`, and `Lottie.xcframework` when present. Each contains an ad hoc signed `ios-arm64` and `ios-arm64-simulator` slice. `EngineResources/` keeps ICU data, resource packs, localizations, scripts, error pages, and bundled extensions. The manifest records the source digest and the number of files and bytes retained, plus the uncompressed bytes omitted from app resources. It records assembly time in UTC; set `SOURCE_DATE_EPOCH` to fix that timestamp for reproducible runs.

The M159 IPA is an assembly baseline. The shell's standalone mode is the default until the headless bridge and its allocator companion are in the engine artifact. Use the [simulator guide](docs/simulator.md) to run the original Chromium app on a disposable simulator copy.

## Architecture

The remote build uses a pruned, revision-pinned source snapshot from `sync-source.yml`. GitHub Actions stores it in GHCR. Linux cross-compiles arm64 iOS code with `ld64.lld`; macOS supplies the pinned Apple tools and packages the result.

| Stage | Runner | Work |
| --- | --- | --- |
| 0 · SDK stub | macOS | Extract the pinned Xcode iPhoneOS SDK and Swift stub; publish the encrypted artifact. |
| 1 · Codegen | Linux | Apply patches, generate and audit the Ninja graph, and build host tools and generated inputs. |
| 2 · Apple tools | macOS | Run the Apple-only edges for Swift, assets, interface files, and intents. |
| 3 · Compile | Linux | Build target objects across 18 stable partitions in parallel, with a separate `ccache` bucket per partition. |
| 4 · Link | Linux | Verify the partition manifests and object hashes, then link `Chromium.app` without compiling. |
| 5 · Package | macOS | Extract deferred AppIntents metadata, prune unused extension stubs, sign as configured, and publish the IPA and its SHA-256. |

### Checkpoints and resumption

The pipeline plans before compiling and reuses existing GHCR checkpoints for codegen, Apple tools, each compile partition, and link. Keys derive from stage epochs, upstream keys, source and SDK digests, and the files listed in `scripts/plan_pipeline.py`. Workflow YAML and local app files do not shape these keys. Each job checks again before starting; a registry error stops the run, and only a confirmed miss triggers work. Failed attempts can resume missing work without discarding published checkpoints.

### CI efficiency and cache reuse rules

Keep `patches/`, `args/`, `version.lock`, and the planner's `COMMON` scripts unchanged during Swift and Liquid Glass work. Local app and handoff changes keep **100% of existing GHCR checkpoint keys reusable** for the same source and SDK inputs.

Batch engine C++ changes and pin changes into a single candidate. The next wave combines staged patch 0087 (extension action badges, under `staging/patches/`), the headless `CrIOSBrowserHostV1` bridge (0088), and Chromium M160 (`160.0.8171.0`). Prepare the matching source snapshot and SDK stub, then gate the batch with `graph-diagnose.yml` against a known green graph. Build the IPA after the graph audit passes. Update `Kernel.lock` from the verified package after testing the engine contract.

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
