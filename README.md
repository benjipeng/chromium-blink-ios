# chromium-blink-ios

Zero-local-checkout build pipeline for **Chromium on iOS (`use_blink = true`)** targeting non-jailbroken devices (sideloading / LiveContainer) using 100% free public GitHub Actions infrastructure.

---

## Architecture

Upstream Chromium (`M159+`) supports cross-compiling `target_os = "ios"` (`arm64`) on Linux hosts via `ios_sdk_developer_dir`, `ld64.lld`, `llvm-ar`, and `//build/toolchain/apple/apple_tool_wrapper.gni`. This repository exploits that split across GitHub's free public runners (`xcode-27` + 20-way concurrent `ubuntu-24.04`) and GitHub Container Registry (`ghcr.io`):

1. **Layer 0 — Pruned Source Snapshot (`sync-source.yml`)**
   - Runs once per pinned Chromium revision (`version.lock`).
   - Uses Git Protocol v2 `--filter=blob:none` + `--no-cone` sparse checkout (`scripts/sparse_checkout.conf`) and `.gclient` `checkout_configuration = "small"` (`target_os_only = True`) to exclude `blink/web_tests` (200k+ files) and heavy test corpora before blob download, while preserving `//extensions/`, `//components/crx_file/`, and `//chrome/*/extensions/` for Chrome Web Extensions bring-up.
   - Installs Darwin `compiler-rt` builtins (`libclang_rt.ios.a`) into Linux `llvm-build`, strips `.git` metadata, and pushes 1.5 GB OCI chunks to `ghcr.io/<owner>/<repo>/chromium-ios-src:<rev>`.

2. **0 SDK stub (`xcode-27`)**
   - Extracts the minimal `iPhoneOS.sdk` + Swift stub from exactly the pinned Xcode build (any other build fails), encrypted with `CI_ARTIFACT_KEY` (`AES-256-CBC` PBKDF2). Runs only when that Xcode's stub is missing.

3. **1 Codegen (`ubuntu-24.04`)**
   - GN makes every action wait on the compiled objects of all its deps. `scripts/rewrite_ninja_graph.py --mode prune` drops those object edges after `gn gen` (keeping each generator's ordering as order-only deps).
   - `scripts/plan_shards.py --mode codegen` plans host tools, Rust, generated files and every generated input of the Apple edges on the real graph, minus anything whose build would run target compile/link/Swift or Apple tools. `scripts/diagnose_graph.py --check` gates the plan before compiling, so codegen never strays into later stages.

4. **2 Apple tools (`xcode-27`)**
   - Unpacks codegen's tree, verifies every generated file the Apple edges read is present, and reduces the graph to those edges (`--mode apple-only`), so the Mac runs only `swift`, `compile_xcassets`, `compile_ib_files`, and `intentbuilderc`, recording host-independent outputs via `scripts/apple_tool_wrapper.py`.

5. **3 Compile × 18 (`ubuntu-24.04`, parallel)**
   - Splits every target object across 18 fixed partitions by SHA-1, compiled concurrently on 4-vCPU runners with a `ccache` bucket per partition (`symbol_level = 0`, `use_siso = false`, `clang_use_chrome_plugins = false`).
   - Each partition publishes its objects with a manifest (identity, paths, sha256) as its own checkpoint, so a failed partition is the only one a later run repeats.

6. **4 Link (`ubuntu-24.04` + 16 GB SSD swap)**
   - Imports all partitions, verifies each against today's plan and its sha256s, replaces exactly those compile edges (`--mode link-only`), proves the remaining plan compiles nothing, then links `Chromium.app` via `ld64.lld` and defers AppIntents metadata extraction.

7. **5 Package IPA (`xcode-27`)**
   - Runs deferred `appintentsmetadataprocessor` (`extract_metadata.py`) against the linked `Chromium` binary, strips unused BrowserEngineKit `.appex` stubs, optionally applies ad-hoc App Group entitlements, validates Mach-O headers with `vtool`, and emits `Chromium-Blink-<version>-arm64.ipa`.

### Checkpoints and resumption

Each stage (and each compile partition) publishes one **write-once** checkpoint in `ghcr.io`, named by a key over exactly the inputs that shape its output: its epoch in `ci/epochs.json`, the upstream key, the source and SDK artifacts by digest, and the scripts and config listed for it in `scripts/plan_pipeline.py`. Workflow YAML is orchestration only and never part of a key. A run plans first and then does only the missing work; every job re-checks its checkpoint before starting, so re-running failed jobs reuses anything already published. Registry errors stop the run rather than being mistaken for missing checkpoints. Builds stop before the job deadline to leave time to persist caches and checkpoints.

---

## Repository Setup

1. Create a **public** GitHub repository (`benjipeng/chromium-blink-ios`).
2. Configure a single repository secret for encrypting intra-workflow iOS SDK artifacts:
   ```bash
   gh secret set CI_ARTIFACT_KEY --body "$(openssl rand -hex 32)"
   ```
3. Run workflows in order:
   - **Sync Pruned Source to GHCR** (`sync-source.yml`) — once per `version.lock` revision.
   - **Build Chromium Blink iOS IPA** (`build-ipa.yml`) — reuses every finished checkpoint and runs only what is missing. To rebuild a stage on purpose, bump its epoch in `ci/epochs.json`. `inject_failure` exercises recovery paths.
   - **Diagnose Build Graph** (`graph-diagnose.yml`) — regenerates the real graph and audits the codegen plan without compiling, comparing against a baseline run.

---

## Layout

| Path | Purpose |
|---|---|
| `version.lock` | Locked upstream `chromium/ci/ios-blink-rel-fyi` green SHA and metadata |
| `args/device.gn` | Stripped release GN configuration (`use_blink = true`, `enable_rlz = false`) |
| `patches/` | Ordered patch queue (`series` + single-process/jitless/UI/de-Googled fixes) |
| `scripts/resolve_pin.py` | Queries Buildbucket `ios-blink-rel-fyi` for latest compile-green revision |
| `scripts/sync_pruned_source.sh` | Blobless sparse checkout + pruned `gclient` sync + Darwin clang runtime |
| `scripts/apple_tool_wrapper.py` | Record/replay wrapper for `//build/toolchain/apple/apple_tool_wrapper.gni` |
| `ci/` | Stage epochs, per-host GN args, `ccache` settings |
| `scripts/stage.sh` | The one driver every job calls: `./scripts/stage.sh <stage> <step>` |
| `scripts/stages/<stage>.sh` | Each stage's own steps; editing one re-keys only that stage and the ones after it |
| `scripts/plan_pipeline.py` | Keys, checkpoint probes, and the run plan (missing compile partitions only) |
| `scripts/ninja_graph.py` | Ninja graph model and the stage contract (what each stage may run) |
| `scripts/plan_shards.py` | Target lists: `codegen`, `apple-prebuild`, `c-shard` partitions |
| `scripts/rewrite_ninja_graph.py` | Post-`gn gen` graph rewrites: `prune`, `apple-only`, `link-only` |
| `scripts/diagnose_graph.py` | Audits a codegen plan against the stage contract (also the pre-build gate) |
| `scripts/shard_artifact.py` | Packs a partition's objects with a manifest; verifies them on import |
| `scripts/oci_artifacts.sh` | GHCR push/pull: tri-state existence, digest resolution, write-once pushes |
| `scripts/run_with_budget.py` | Runs a build under a deadline and stops its whole process group cleanly |
| `scripts/overlay_linux_host_deps.py` | Fetches Linux-host-only DEPS (`lss`, Dawn's Go) missing from the iOS snapshot |
| `scripts/package_ipa.sh` | Post-link `Metadata.appintents` extraction, `.appex` pruning, and IPA build |
| `.github/workflows/` | `sync-source.yml`, `build-ipa.yml`, `graph-diagnose.yml`, and `bump-pin.yml` |
