# chromium-blink-ios

Zero-local-checkout build pipeline for **Chromium on iOS (`use_blink = true`)** targeting non-jailbroken devices (sideloading / LiveContainer) using 100% free public GitHub Actions infrastructure.

---

## Architecture

Upstream Chromium (`M159+`) supports cross-compiling `target_os = "ios"` (`arm64`) on Linux hosts via `ios_sdk_developer_dir`, `ld64.lld`, `llvm-ar`, and `//build/toolchain/apple/apple_tool_wrapper.gni`. This repository exploits that split across GitHub's free public runners (`xcode-27` + 20-way concurrent `ubuntu-24.04`) and GitHub Container Registry (`ghcr.io`):

1. **Layer 0 — Pruned Source Snapshot (`sync-source.yml`)**
   - Runs once per pinned Chromium revision (`version.lock`).
   - Uses Git Protocol v2 `--filter=blob:none` + `--no-cone` sparse checkout (`scripts/sparse_checkout.conf`) and `.gclient` `checkout_configuration = "small"` (`target_os_only = True`) to exclude `blink/web_tests` (200k+ files) and heavy test corpora before blob download, while preserving `//extensions/`, `//components/crx_file/`, and `//chrome/*/extensions/` for Chrome Web Extensions bring-up.
   - Installs Darwin `compiler-rt` builtins (`libclang_rt.ios.a`) into Linux `llvm-build`, strips `.git` metadata, and pushes 1.5 GB OCI chunks to `ghcr.io/<owner>/<repo>/chromium-ios-src:<rev>`.

2. **Stage 2a — Codegen on a Pruned Graph (`ubuntu-24.04`)**
   - GN makes every action wait on the compiled objects of all its deps. `scripts/rewrite_ninja_graph.py --mode prune` drops those object edges after `gn gen` (keeping each generator's ordering as order-only deps), so codegen builds only host tools, Rust, and generated sources/headers — no target C++.
   - Overlays the Linux-host-only DEPS the iOS snapshot omits (`scripts/overlay_linux_host_deps.py`) and checkpoints the `gen/` tree plus host tools to `ghcr.io`.

3. **Stage 1 — Pre-Link Apple Targets (`xcode-27`)**
   - Unpacks codegen's `gen/` tree and reduces the graph to Apple tool edges (`--mode apple-only`), so the Mac runs only `swift`, `compile_xcassets`, `compile_ib_files`, and `intentbuilderc`, recording host-independent outputs via `scripts/apple_tool_wrapper.py`.
   - A one-off Stage 0 job extracts the minimal `iPhoneOS.sdk` + Swift stub, encrypted with `CI_ARTIFACT_KEY` (`AES-256-CBC` PBKDF2), whenever Xcode changes.

4. **Stage 2b — 18-Way Parallel C/C++/ObjC++ Farm (`ubuntu-24.04`)**
   - Restores codegen and Stage 1, then fans every target object out across 18 concurrent 4-vCPU runners by stable SHA-1 slot, each with its own `ccache` bucket in `ghcr.io` (`symbol_level = 0`, `use_siso = false`, `clang_use_chrome_plugins = false`).

5. **Stage 3 — Link & Cache Persistence (`ubuntu-24.04` + 16 GB SSD Swap)**
   - Merges `ccache` shards (or pulls warm `ccache` from `ghcr.io`), links `Chromium.app` via `ld64.lld`, defers post-link AppIntents metadata extraction, and persists the updated `ccache` back to `ghcr.io`.

6. **Stage 4 — AppIntents Finalizer & IPA Packaging (`xcode-27`)**
   - Runs deferred `appintentsmetadataprocessor` (`extract_metadata.py`) against the linked `Chromium` binary on Xcode 27.1, strips unused BrowserEngineKit `.appex` stubs, optionally applies ad-hoc App Group entitlements, validates Mach-O headers with `vtool`, and emits `Chromium-Blink-<version>-arm64.ipa`.

---

## Repository Setup

1. Create a **public** GitHub repository (`benjipeng/chromium-blink-ios`).
2. Configure a single repository secret for encrypting intra-workflow iOS SDK artifacts:
   ```bash
   gh secret set CI_ARTIFACT_KEY --body "$(openssl rand -hex 32)"
   ```
3. Run workflows in order:
   - **Sync Pruned Source to GHCR** (`sync-source.yml`) — once per `version.lock` revision.
   - **Build Chromium Blink iOS IPA** (`build-ipa.yml`) — every stage checkpoints to `ghcr.io` under a key chained from its inputs, so a re-run resumes at the first stage whose inputs changed or that failed; `force_from` re-runs from a chosen stage.

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
| `scripts/plan_shards.py` | Transitive Ninja graph slicer (`apple-prebuild`, `codegen`, `c-shard`) |
| `scripts/rewrite_ninja_graph.py` | Post-`gn gen` graph rewrite: `prune` object edges from generators, `apple-only` for Stage 1 |
| `scripts/overlay_linux_host_deps.py` | Fetches Linux-host-only DEPS (`lss`, Dawn's Go) missing from the iOS snapshot |
| `scripts/package_ipa.sh` | Post-link `Metadata.appintents` extraction, `.appex` pruning, and IPA build |
| `.github/workflows/` | `sync-source.yml`, `build-ipa.yml`, and `bump-pin.yml` |
