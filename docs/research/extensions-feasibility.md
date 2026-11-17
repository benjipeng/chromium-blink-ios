# Feasibility Memo: Chromium Extensions in iOS Blink (`benjipeng/chromium-blink-ios`)

- **Pinned Chromium revision:** `34d81e7bfe669b8eccaaf35c6e14c7bfc0689703` (M159, `159.0.8149.0`, `version.lock`)
- **Target configuration:** `target_os = "ios"`, `target_cpu = "arm64"`, `target_environment = "device"`, `use_blink = true`, `is_component_build = false` (`args/device.gn`, `ci/gn_args.linux`)
- **Baseline build graph (`graph-diagnose.yml` run `43868838103`):** `263,702` raw Ninja edges across `13,769` ninja files; `43,494` codegen roots (`49,500` edges in closure) ([run 43868838103](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43868838103)).

---

## Executive Summary

### Snapshot Matrix (Current Reality as of Run `44107240450` / `e5d03a4`)

| Snapshot | Scope Included | Proven Status | Remaining / Unproven |
| :--- | :--- | :--- | :--- |
| **Installed diagnostic Simulator app** (`25552fd` base + local binary patches + prototype UI) | `0060`/`0061` binary patches, `ios_probe` content-script fixture (`content.js` + `manifest.json`, no DNR rules), prototype `ChromiumExtensionsUI` | **Simulator runtime proven:** startup, `https://example.com/*` content-script injection, `chrome.runtime.id`/`getManifest()`, DOM badge, detached restart (`PID 55921`), and UI toggle (`PID 94392`) | Does not include `0062`–`0064`, DNR interception, or `CrIOSExtensionManagerV1` core bridge |
| **Current GitHub snapshot** (`e5d03a4`, `build-ipa.yml` [run 44107240450](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44107240450), artifact `14345375150`) | Source `0060`–`0064` + `helpers/extensions_ui` (`CrIOSExtensionManagerV1` production framework) + 1-rule `ios_probe` static DNR fixture (`rules_1.json`) | **Compiled, linked, symbol-verified, and IPA-packaged:** all 18 shards, zero-recompile `4 Link`, `5 Package IPA` Mach-O/dylib/`--deep --strict` codesign gates passed | **Runtime pending** in Simulator: static DNR blocking, `CrIOSExtensionManagerV1` bridge, disable-reason persistence, and `chrome.storage` not yet exercised on this IPA |
| **Headless uBOL / real `UnpackedInstaller` experiment** (separate, **not** in `44107240450`) | Real `UnpackedInstaller` loading of official ~9 MB uBOL package | **Not in active build** | Blocked by strict `ios_probe` single-fixture allowlist and unimplemented MV3 service-worker hooks; uBOL install, runtime, and ad-blocking are unproven |

### Full Source-Rebuilt IPA Receipt (`e5d03a4`, Run `44107240450`)

- **Workflow & inputs:** `build-ipa.yml` on `probe/extensions-gn` (`e5d03a4ae8848f15feb44e24adff2d414d2a7c89`), `with_app_groups=false`, `publish_release=false`, `inject_failure=none`, `shards=''` (18 shards), concluding **`success`**.
- **Stage keys, cache hits, and checkpoints:**
  - `0 SDK stub (Mac)` (`27A9275-22b39adc55cd`): **reused** (`skipped`, `need_sdk=false`).
  - `1 Codegen (Linux)` (`c46285f394090979b9e4`, job `134123066896`): `success`; `47,345` codegen roots (`11,143` edges in closure, `26` Apple edges, `32,751` generated inputs required, `0` unplanned); `ccache` **`6,715 / 6,715` (`100.0%`, `6,715` direct, `0` misses)**; OCI `sha256:d4a98b828223850a68bff100051d177211027e3faf041b055aed1c634e2b7b33`.
  - `2 Apple tools (Mac)` (`3f3c08e4d8076496756b`, job `134140135755`): `success`; `26` Apple tool targets (`17,405` generated inputs required, `286` bundle-ordering-only); `apple_tool_cache.tar.zst` (`36.7 MiB -> 17.0 MiB`); OCI `sha256:8e118b08ae7921d7540d91ea2b15e80c9b9c5b937cac9d47d5decd2f94a5e18b`.
  - `3 Compile × 18 (Linux)` (`8bd3dac7f997bd5a991f`): **`18 / 18` shards `success`**; combined `ccache` **`37,580 / 37,590` (`99.97%`, `37,578` direct, `2` preprocessed, `10` misses)**.
  - `4 Link (Linux)` (`e887ede3f9132152a8a5`, job `134159927090`): `success`; **`37,480` verified imported objects** replaced their compile edges across all 18 shards (`106,199` edges loaded); **zero-recompile gate passed** (`0` `C`/`C++`/`ObjC`/`ASM`/`Rust` compile edges across `2,762` link-stage edges); `bundled_extensions/ios_probe/{content.js,manifest.json,rules_1.json}` copied; OCI `sha256:75cfbc8c52e727149d71c837a80fe2447dd4e0fa9a78a32e5d9bd9b328a2b2f3`.
  - `5 Package IPA (Mac)` (`59aab9a3c03d55653e6c`, job `134165825348`): `success`; verified `CrIOSExtensionManagerV1` availability in `chrome_framework`, built production `ChromiumExtensionsUI` (`arm64`, `platform IOS`, `minos 26.0`, `sdk 27.1`, `78,944` B), appended strong `LC_LOAD_DYLIB` (`88` B, `@rpath/ChromiumExtensionsUI.framework/ChromiumExtensionsUI`) after `libSystem.B.dylib` preserving `EarlyMallocZoneRegistration`-first load order, ad-hoc signed nested frameworks then outer `.app` (`with_app_groups=false`), and passed `codesign --verify --deep --strict`. Final `Chromium.app` size `415M`.
- **Artifact & linked Mach-O verification (`Chromium-Blink-159.0.8149.0-arm64`, ID [`14345375150`](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44107240450/artifacts/14345375150)):**
  - Zip size `146,731,499` bytes (`sha256:fece2b8900f2a75c732f6b2cdc3ad5103a4e665bf4dfbe9488de7a820e50d9cf`); extracted `Chromium-Blink-159.0.8149.0-arm64.ipa` `147,008,421` bytes (`140M`, `sha256:2ec447e3293fc5bd0af0a7f5f5e63f13c42ee3c29c79be17c5cdf22ed5f93c32`).
  - `Payload/Chromium.app/bundled_extensions/ios_probe/` contains `content.js` (`1024` B), `manifest.json` (`811` B), and `rules_1.json` (`312` B).
  - `chrome_framework` `nm -U` / `otool -oV` confirmed linked (non-dead-stripped) DNR and V1 symbols: `WebRequestAPI::MaybeProxyURLLoaderFactory` (`3` symbols), `WebRequestProxyingURLLoaderFactory::InProgressRequest` (`125` symbols), `declarative_net_request::RulesetManager` (`40` symbols, including `EvaluateRequestInternal` and `EvaluateRequestWithHeaders`), `IOSContentBrowserClient::WillCreateURLLoaderFactory`, `declarative_net_request::RulesMonitorService` (`115` symbols), and `CrIOSExtensionManagerV1` (`14` symbols plus `__OBJC_$_CLASS_METHODS_CrIOSExtensionManagerV1`, `__OBJC_$_INSTANCE_METHODS_CrIOSExtensionManagerV1`, and `__OBJC_CLASS_PROTOCOLS_$_CrIOSExtensionManagerV1`).
- **Pre-full-run receipts (`0060`–`0064` + package isolation):**
  - `0060`–`0062` narrow compile probe ([run 44088941518](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44088941518), `2f769b4`): `success` (`[3430/3430]`, `811 / 813` direct `ccache` hits, `99.75%`).
  - `0063`–`0064` narrow compile probe ([run 44103825076](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44103825076), `532870d`): `success` (`[3436/3436]`), adding the 6 retained-graph `WebRequest`/DNR `.o` targets (`web_request_api.o`, `web_request_proxying_url_loader_factory.o`, `extension_web_request_event_router.o`, `rules_monitor_service.o`, `ruleset_manager.o`, `declarative_net_request_api.o`).
  - Package-only hybrid UI commits (`f2dff1b`, `e5d03a4`): moved canonical helper into `helpers/extensions_ui/`, isolated `k_package` (`helpers/extensions_ui` + `scripts/package_ipa.sh` + `scripts/stages/package.sh` + `=xcode:{XCODE_BUILD}` + `=prefix:{BUNDLE_ID_PREFIX}` + immutable `=link:{k_link}`) so helper/flag edits re-key only `5 Package IPA`, and verified `python3 scripts/plan_pipeline.py check`.
- **Diagnostic Simulator & prior startup-failure receipts:**
  - `vtool`-retargeted iPhone Duo CoreSimulator derivative (`C229AC75-8053-4B7F-A2F8-DFE983E26C13`, `com.benjipeng.chromiumblink.chrome.ios.extprobe`) with persistent binary patches (`WebstorePrivateApi::EnsureAssociatedFactoryBuilt` early `RET` and `112` B `RegisterIOSExtensionPrefs` trampoline) cleared startup (`PID 47357`) and detached restart without LLDB (`PID 55921`, `3.052s` SpringBoard / `8.109s` test-app readiness upper bound including `simctl` + AXe overhead), emitting `CHROMIUM_IOS_EXTENSION_PROBE ilpkfbhghnmiapddaoenpemkcjeknbbo` and rendering the green DOM badge (`example-extension-badge.png`, `detached-restart-extension.png`).
  - Prior startup crashes (`Chromium-2026-11-17-070110.ips` `SIGSEGV` in `PendingApprovalsShutdownNotifierFactory`; `FATAL components/prefs/pref_service.cc:690` unregistered `extensions.user_permissions`) were resolved by `0060`–`0061`; the `44084451425` preflight 404 in `scripts/check_remote_patches.py` was fixed in `f2ccdc4`.

### Read-Only MV3 Service Worker Gap Analysis (Not in `44107240450`)

- **Not blockers:** `GetProcessManagerDelegate() == nullptr` does not block MV3 service workers (`ProcessManager::CreateBackgroundHost()` null-checks it and is legacy background-host-only). `BaseContentBrowserClient::AllowServiceWorker`, `MayDeleteServiceWorkerRegistration`, and `ShouldTryToUpdateServiceWorkerRegistration` already permit service workers by default without redundant iOS overrides.
- **Required hooks for future MV3 SW milestone:**
  1. Renderer: forward the 4 service-worker context/lifecycle callbacks (`DidInitializeServiceWorkerContextOnWorkerThread`, `WillEvaluateServiceWorkerOnWorkerThread`, `DidStartServiceWorkerContextOnWorkerThread`, `WillDestroyServiceWorkerContextOnWorkerThread`) in `IOSContentRendererClient` to `extensions::Dispatcher`.
  2. Browser: implement the 2 non-network worker / service-worker script `URLLoaderFactory` hooks and `OverrideURLLoaderFactoryParams` forwarding to `extensions::URLLoaderFactoryManager` (including `ignore_factory_reset` for service workers).
  3. Gate: replace/extend the strict `noSW` / single-fixture check with a controlled single-extension SW allowlist gate.
- **Additional uBOL dependency:** Even with MV3 service workers active, uBOL separately relies on `chrome.commands.onCommand` module-evaluation support.

### Implementation checkpoint (November 16)

The experimental branch contains actual common, renderer, browser, profile,
and resource integration, and has now completed a full end-to-end production
compile, link, and IPA package on `25552fd` ([run 44004466870](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44004466870)).
Device sideloading and runtime verification remain pending; this establishes
build/link/packaging readiness for the bundled `https://example.com/*`
content-script fixture, not yet runtime execution on iOS.

- Extension flags live in shared, hashed `args/device.gn` for Linux and Mac.
- Common API/permission providers, renderer dispatcher/frame hooks, extension
  schemes, resource packs, and localized extension strings are wired in.
- The browser client registers real profile prefs, context services,
  `ExtensionRegistrar`, script management, and WebContents/Mojo bindings.
- The extension system depends on prefs/registry; iOS process-manager,
  registrar, and renderer-startup services depend on the system. This avoids
  constructor reentrancy and keeps registrar delegates alive during teardown.
- A bundled MV3 content-script fixture targets only `https://example.com/*`.
  It requires `chrome.runtime.id` and `getManifest()` before adding its DOM
  marker. Background hosts and MV3 workers remain rejected until the shared
  process-identity checks are adapted and tested.
- GN roots live in the patched `.gn`, shared by both hosts and nested `gn desc`
  queries, and enter the stage keys through the patch series. The app-directory root pattern
  keeps production app and explicit object-probe targets without disabling
  `components_unittests`' extension dependency assertions.
- GitHub checks the full patch series against pinned file slices before
  downloading the source snapshot. Narrow object probes save compiler progress
  with `actions/cache`, including after failure; formal stages still use
  immutable GHCR checkpoints and verified shard object packages.

The previous next-step architecture notes remain useful as background; this
checkpoint is the current implementation state. No device validation or local
Chromium compilation has been performed during this implementation round.

[Run 43969268760](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43969268760)
passed patch preflight, GN generation, and the codegen contract. It compiled the
new `IOSExtensionSystem`, factory, and WebContents observer objects, plus the
previously sampled common/process-manager objects. The browser client failed on
a misspelled `manifest_url_handlers.h` include. V8 metagen separately failed
because its nested GN query lost the command-line root scope; this blocked the
renderer/common client objects. Those two issues are addressed in the next
revision. The failed run saved its compiler cache successfully: 780 hits out of
785 cacheable calls. The follow-up probe also covers the three content-client
hooks and three service factory objects before scheduling the full IPA build.

[Run 43972551829](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43972551829)
then passed metagen and compiled **14 of the 15 selected iOS objects**, including
all new extension clients, system services, renderer hooks, and service-factory
lifetime changes. `IOSContentBrowserClient` reported only two explicit-conversion
errors: `SecurityPrincipal::GetHost()` returns `std::string_view`, while
`ExtensionSet::GetByID()` takes `ExtensionId` (`std::string`). Both call sites now
construct the string explicitly. The run restored the prior failed run's cache,
recorded 785 hits out of 794 cacheable calls, and saved its cache on failure.
The next validation is the real staged IPA workflow, which also verifies the
remaining production objects, libraries, resources, and final link.

[Full IPA run 43974478096](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43974478096)
completed production codegen with **6,715/6,715 compiler-cache hits** and verified
its immutable GHCR checkpoint remotely. A parallel source audit then found two
runtime blockers before the expensive device compilation: packaging deletes the
reserved `Extensions/` directory, and frame permission checks dereference an
`ExtensionWebViewHelper` created by the missing `WebViewCreated` hook. The run
was cancelled while preparing Apple tools. The fixture now lives under
`bundled_extensions/ios_probe`, packaging checks that both resources survive
cleanup, and `IOSContentRendererClient` forwards `WebViewCreated` to the generic
extension renderer client. These are source-verified fixes awaiting the next
full build and runtime validation. Existing checkpoints and compiler caches
remain retained; the conservative all-patches identity re-keys stages for these
source changes. Narrowing that invalidation remains a later efficiency task.

### Full-production compile checkpoint (`cdd6a31`)

[Run 43978092520](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43978092520)
passed production codegen and Apple tools, then compiled all 18 partitions.
Nine partitions produced successful immutable object checkpoints. The automatic
retry preserved those results; the other nine failed on the same 15 object
outputs, with all successful cacheable calls hitting their saved compiler cache.
Link and packaging have not run for this extension-enabled build.

The failures reduce to three platform/configuration gaps. Shared core C++ code
includes `scripts_internal.h` and `icon_variants.h`, but their schemas were
gated behind full extensions, desktop Android, or guest view. The iOS
configuration now generates these as **types only**, without enabling their
public APIs. The storage-specific `SystemInfoProvider` code is excluded on iOS,
matching Android; this avoids a missing schema and unsupported storage-monitor
backend together. Extension command manifest parsing uses the same
Linux keybinding fallback as desktop Android; no native shortcut registration is
claimed. Policy dictionary merging excludes `ExtensionSettings` on iOS, where
the upstream policy generator does not define that policy key. Patch `0057`
addresses those three demonstrated failures. The failed run and successful
object checkpoints remain available as evidence and reusable data. The narrow
compile probe now also selects the 15 failed outputs, checking their fixes
before scheduling Mac work and another 18-runner compile.

Hydrogen's follow-up audit also confirmed a downstream link blocker:
`CpuInfoProvider::QueryCpuTimePerProcessor()` has no iOS implementation, while
generated function registration would keep its callers live. Patch `0058`
excludes `system.cpu` from both the iOS schema registration list and the API
implementation dependencies. It does not add a placeholder backend. A suspected
`system.display` gap was disproved: the shared embedder implementation exists
and returns the standard API-unavailable error without a provider, so that code
is preserved. The two patches apply in sequence to pinned source snippets in
memory; actual compilation remains exclusively on GitHub Actions.

[Run 43987674096](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43987674096)
successfully compiled all 30 selected objects on `5f8e221`, with 792 cache hits
and 18 misses (97.78% hits), then saved the updated cache. This validates the
three compile-failure fixes against real iOS compiler invocations. The next
[full IPA run 43989071368](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43989071368)
uses `cc0165e`, which also contains the source-reviewed CPU API exclusion.

### Link boundary checkpoint (`cc0165e` -> `0059`)

[Full IPA run 43989071368](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43989071368)
(`cc0165e`) passed Codegen, Apple tools, and all 18 compile shards (`37,820 / 37,837`
cacheable hits, `99.96%`), verified every shard manifest under the zero-recompile gate,
and failed at `4 Link (Linux)` (`133745505155`) on `chrome_framework` with two boundary
errors (automatic retry `run_attempt: 2` was cancelled to preserve checkpoints):

- **Unbuilt `SessionTabHelper` symbols:** `components/sessions/BUILD.gn` compiles `ios/*`
  rather than `content/session_tab_helper.cc` when `is_ios && target_platform == "iphoneos"`,
  leaving `sessions::SessionTabHelper::IdForTab` and `IdForWindowContainingTab` undefined
  for `script_executor.o`, `script_injection_tracker.o`, and `runtime_api.o`.
- **Global `TabGroup` symbol collision:** `extensions/browser/BUILD.gn` pulled full
  `//components/permissions`, whose `//components/tabs:impl` dependency defines global
  `::TabGroup` (`impl/tab_group.cc`) alongside `ios/chrome`'s `web_state_list/tab_group.mm`.

Patch `0059` scopes `//components/permissions` in `extensions/browser/BUILD.gn` behind
`if (!is_ios)` (keeping `//components/permissions:permissions_common` explicit in
`extensions/browser/api/content_settings`) and guards the `SessionTabHelper` calls in
`extensions/browser` on `BUILDFLAG(IS_IOS)` to return `-1` (`SessionID::InvalidValue`),
matching unattached helper semantics and granting no tab-specific privileges. Until
full `SetTabId` IPC and navigation/close cleanup are wired, `activeTab`, tab-ID
scripting targets, `MessageSender.tab`, and `chrome.runtime` tab/window IDs remain
unsupported on iOS while validating the bundled content-script fixture.

### Link and IPA packaging checkpoint (`25552fd`)

After [run 43998457806](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43998457806)
(`e92328d`) passed Codegen (`6,715 / 6,715`), Apple tools, and 17 of 18 compile shards
(`37,638` hits + `4` misses = `37,642` cacheable calls; `1` uncacheable, `11` ccache errors)
but failed on shard 15 (`runtime_api.cc`: incomplete `content::WebContents` after guarding
`session_tab_helper.h`), `0059` added an explicit `#include "content/public/browser/web_contents.h"`
in `25552fd`. That revision passed the 34-object `graph-diagnose.yml` probe
([run 44004726159](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44004726159),
`[3522/3522]`, `808 / 814` cacheable hits) and then completed all stages of full IPA
[run 44004466870](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44004466870):

- **Codegen & Apple tools:** `1 Codegen (Linux)` (`133776442427`) hit `6,715 / 6,715` (`100.0%`,
  `codegen-640f9d4b496a8a91876d` -> `sha256:3e3ed3c780c98bf4b681063598873286fdd1a97805b86da4f97404cc73387c94`);
  `2 Apple tools (Mac)` (`133782943531`) persisted `apple-3d361daef8a91c6ad7c2` ->
  `sha256:d4afe464c9c303eb4e14c43ce836a69fe28a3f4927bc9a35a39d6ef06db53c9b`.
- **All 18 compile shards:** 18/18 succeeded with `37,642` hits and `1` miss (shard 15) across
  `37,643` cacheable calls (`99.997%`), `0` uncacheable calls, and `11` non-fatal ccache errors
  (`37,654` total calls).
- **Zero-recompile link (`133794101975`):** Verified all 18 shard manifests (`37,533` imported objects
  replaced their compile edges across `5,475` rewritten ninja files; `restored_work` confirmed
  zero remaining compile, Rust, or host-tool edges in the `2,761`-step link plan), copied
  `Chromium.app/bundled_extensions/ios_probe/{content.js,manifest.json}`, and persisted
  `stage-cache:link-2f2c6f4a5ea86043bcd2` ->
  `sha256:bbe1b764627ac6caa018ea788457b804204eb2bfd31df0564d32232c0bf13ee5`.
- **Packaging & Mach-O validation (`133798522525`):** Removed unused `.appex` `Extensions/`,
  verified `bundled_extensions/ios_probe/{manifest.json,content.js}` survived cleanup, validated
  Mach-O headers for `Chromium` and `chrome_framework` (`arm64`, `platform IOS`, `minos 26.0`,
  `sdk 27.1`), and uploaded artifact `Chromium-Blink-159.0.8149.0-arm64` (ID `14296203868`,
  `145,930,009` bytes, expires `2026-12-17T03:37:10Z`, ZIP artifact digest
  `sha256:3aed7c3817645124285f02028828b2605182ec67f49e8f59d889ce9c24763283`; inner
  `Chromium-Blink-159.0.8149.0-arm64.ipa` SHA-256
  `a0e40c0524e8d22c490776ee5a73970bd98b11a97ceb97e8a7c416eabb72858b`).

**Remaining runtime and feature limitations:**
- **Device execution unverified:** The packaged IPA has not been sideloaded or run on iOS hardware;
  `https://example.com` content-script injection, renderer `WebViewCreated` helper lifecycle, and
  `--single-process --jitless` stability remain to be verified on device.
- **No tab/window identity or `activeTab`:** With `SessionTabHelper` absent on iOS (`0059` returns
  `-1`), `activeTab`, tab-ID `scripting` targets, `MessageSender.tab`, and `chrome.runtime`
  tab/window IDs remain unsupported until `SetTabId` IPC and navigation/close cleanup are wired.
- **No MV3 service workers or platform-gated APIs:** Background hosts, MV3 service workers,
  multi-extension security isolation, `chrome.system.cpu` (`0058`), `chrome.system.storage` (`0057`),
  `ExtensionSettings` enterprise policy merging (`0057`), and native `chrome.commands` shortcut
  registration remain unsupported.

1. **Core-only graph generation and three representative iOS object compilations pass with two narrow dependency guards.** [Run 43940083679](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43940083679) (`442b330`) passed `gn gen` and the codegen contract with `enable_extensions_core = true`; [run 43944365971](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43944365971) (`632a261`) also compiled `extension.cc`, `process_manager.cc`, and `dispatcher.cc`. Unpatched Chromium still fails. The full extensions libraries, embedder integration, linking, and runtime behavior remain unverified.
2. **Turning on GN flags alone would not wire extensions into the browser anyway.** `benjipeng/chromium-blink-ios` builds `//ios/chrome/app:chrome`, which uses the `//ios/chrome/browser` embedder (`ProfileIOS`, `Browser`, `WebStateList`) rather than `//chrome/browser` (`Profile`, `BrowserWindowInterface`, `TabModel`). Desktop Android succeeded by running inside `//chrome/browser`, whereas `//chrome` asserts `!is_ios` in multiple GN files (`//chrome/BUILD.gn:77`, `//chrome/chrome_repack_locales.gni:10`).
3. **The existing `WKWebExtension` / `BuiltInWebExtension` code in `chrome_framework` is WebKit-only and inert under `use_blink = true`.** It attaches solely to `WKWebViewConfiguration` inside `WKWebViewConfigurationProvider`, which `ContentWebState` never uses.
4. **The only realistic architecture to run Chromium extensions on iOS Blink** is to (a) decouple `//extensions` from its residual `//chrome` GN deps and desktop-only assumptions (notably `//extensions/renderer/BUILD.gn:256`'s `"//chrome:resources"`), (b) build a dedicated iOS Blink embedder in `//ios/web/content` + `//ios/chrome/browser` implementing `ExtensionsClient`, `ExtensionsBrowserClient`, `ExtensionsRendererClient`, and core API delegates (mirroring Desktop Android's `enable_extensions_core` split), and (c) build mobile extension UI (`chrome://extensions` or native UIKit/SwiftUI) against `ProfileIOS` / `WebStateList` while respecting sideloading's `--single-process` + `--jitless` constraints.

---

## 1. GN-Only CI Probe Results (`probe/extensions-gn`)

All probes were run on `benjipeng/chromium-blink-ios` branch `probe/extensions-gn` using `.github/workflows/graph-diagnose.yml` with `scripts/stage.sh` modified to append `extra_gn_args` to `out/Release/args.gn` and capture `gn gen` output (`gn_gen.log`) without compiling.

| Probe | Extra GN args | CI Run | Blocking file:line |
|---|---|---|---|
| 1 | `enable_extensions_core = true` | [43925398726](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43925398726) | `//chrome/chrome_repack_locales.gni:10:1` via `//extensions/renderer/BUILD.gn:256:5` |
| 2 | `enable_extensions = true` | [43925411473](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43925411473) | `//extensions/BUILD.gn:15:1` via `//BUILD.gn:297:9` |
| 3 | `enable_extensions = true; enable_guest_view = true` | [43927150887](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43927150887) | `//components/web_modal/BUILD.gn:5:1` via `//extensions/browser/BUILD.gn:839:15` |
| 4 | `enable_extensions = true; enable_guest_view = true; enable_platform_apps = false` | [43928163373](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43928163373) | `//extensions/browser/api/app_current_window_internal/BUILD.gn:7:1` via `//extensions/browser/api/BUILD.gn:64:7` |
| 5 | `enable_extensions_core = true`; guard renderer's `//chrome:resources` on iOS | [43938061454](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43938061454) | `//chrome/common/net/BUILD.gn:8:1`, reached through the desktop test-support buildflags dependency |
| 6 | Core-only; also guard test support's `//chrome/common:buildflags` on iOS | [43940083679](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43940083679) | **GN and codegen contract passed**; no compilation |

The two guards preserve the platform assertions and the test target definitions. Removing all extensions test targets would leave unresolved dependencies in sibling GN files. Their presence in the generated graph does not establish that those tests compile on iOS.

### Probe 1: `enable_extensions_core = true` ([run 43925398726](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43925398726))

**Verbatim `gn gen` error:**
```text
ERROR at //chrome/chrome_repack_locales.gni:10:1: Assertion failed.
assert(!is_ios, "Chromium/iOS shouldn't use anything in //chrome")
^-----
Chromium/iOS shouldn't use anything in //chrome
See //chrome/chrome_paks.gni:17:1: whence //chrome/chrome_repack_locales.gni was imported.
import("chrome_repack_locales.gni")
^---------------------------------
See //chrome/BUILD.gn:19:1: whence //chrome/chrome_paks.gni was imported.
import("//chrome/chrome_paks.gni")
^--------------------------------
See //extensions/renderer/BUILD.gn:256:5: which caused the file to be included.
    "//chrome:resources",
    ^-------------------
```

**Why this triggers even without `//ios/chrome` depending on `//extensions`:**
- Existing components already compiled on iOS Blink depend on `//extensions/common:common_constants` and `//extensions/common:extension_features` whenever `enable_extensions_core` is true — specifically `//components/omnibox/browser/BUILD.gn:500-504` and `//components/no_state_prefetch/common/BUILD.gn:31-33`.
- Evaluating `//extensions/common/BUILD.gn` parses all targets in that file; `static_library("common")` depends on `"//extensions:extensions_resources"` (`//extensions/common/BUILD.gn:614`).
- Evaluating `//extensions/BUILD.gn` parses `test_support` (`//extensions/BUILD.gn:180`) and `extensions_unittests` (`//extensions/BUILD.gn:296`), both of which depend on `"//extensions/renderer"`.
- `//extensions/renderer/BUILD.gn:256` unconditionally includes `"//chrome:resources"` in `deps`. Evaluating `//chrome/BUILD.gn` imports `//chrome/chrome_paks.gni` (`:19`), which imports `//chrome/chrome_repack_locales.gni` (`:17`), hitting `assert(!is_ios, "Chromium/iOS shouldn't use anything in //chrome")` at `:10:1`.
- **Desktop Android comparison:** Desktop Android (`is_android = true`) satisfies `!is_ios` and compiles `//chrome` natively (`//chrome/BUILD.gn:1743` defines `group("resources")`). Note that `//extensions/DEPS` explicitly forbids `//chrome` dependencies (`# Do not add Chrome dependencies`) and `//extensions/renderer/DEPS` has no `+chrome` include rules, suggesting `"//chrome:resources"` in `//extensions/renderer/BUILD.gn:256` may be a stale build dep, though whether any renderer target reads a `//chrome:resources` pak at runtime/compile time is **unverified**.

### Probe 2: `enable_extensions = true` ([run 43925411473](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43925411473))

**Verbatim `gn gen` error:**
```text
ERROR at //extensions/BUILD.gn:15:1: Assertion failed.
assert(!enable_extensions || enable_guest_view)
^-----
See //BUILD.gn:297:9: which caused the file to be included.
        "//extensions:extensions_unittests",
        ^----------------------------------
```

**Why this triggers:**
- Root `//BUILD.gn:295-300` adds `"//extensions:extensions_unittests"` and `"//extensions/browser/api/declarative_net_request/filter_list_converter"` when `enable_extensions` is true.
- `//components/guest_view/buildflags/buildflags.gni:12` defaults `enable_guest_view = !is_ios && !is_castos` (`false` on iOS).
- `//extensions/BUILD.gn:15`, `//extensions/common/BUILD.gn:18`, `//extensions/browser/BUILD.gn:20`, and `//extensions/renderer/BUILD.gn:12` all enforce `assert(!enable_extensions || enable_guest_view)`.
- **Desktop Android comparison:** Desktop Android leaves `enable_extensions = false` and instead sets `enable_desktop_android_extensions = is_desktop_android` -> `enable_extensions_core = true` (`//extensions/buildflags/buildflags.gni:45-68`), avoiding `//BUILD.gn:295` and the `enable_guest_view` coupling unless `enable_guest_view` is explicitly turned on.

### Probe 3: `enable_extensions = true; enable_guest_view = true` ([run 43927150887](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43927150887))

**Verbatim `gn gen` error:**
```text
ERROR at //components/web_modal/BUILD.gn:5:1: Assertion failed.
assert(!is_android && !is_ios)
^-----
See //extensions/browser/BUILD.gn:839:15: which caused the file to be included.
    deps += [ "//components/web_modal" ]
              ^-----------------------
```

**Why this triggers:**
- `enable_extensions = true` defaults `enable_platform_apps = enable_extensions` (`//extensions/buildflags/buildflags.gni:57`).
- Inside `if (enable_platform_apps)` at `//extensions/browser/BUILD.gn:819-840`, `browser_sources` adds `"//components/web_modal"` (`:839`), whose `//components/web_modal/BUILD.gn:5` asserts `assert(!is_android && !is_ios)`.
- **Desktop Android comparison:** Desktop Android keeps `enable_extensions = false` -> `enable_platform_apps = false`, so `//components/web_modal` is excluded (see also Ultimatum's `args.gn` explicitly setting `enable_platform_apps = false`).

### Probe 4: `enable_extensions = true; enable_guest_view = true; enable_platform_apps = false` ([run 43928163373](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43928163373))

**Verbatim `gn gen` error:**
```text
ERROR at //extensions/browser/api/app_current_window_internal/BUILD.gn:7:1: Assertion failed.
assert(enable_platform_apps,
^-----
Cannot depend on platform apps because enable_platform_apps=false.
See //extensions/browser/api/BUILD.gn:64:7: which caused the file to be included.
      "//extensions/browser/api/app_current_window_internal",
      ^-----------------------------------------------------
```

**Why this triggers:**
- `//extensions/browser/api/BUILD.gn:60-66` gates `app_current_window_internal`, `app_runtime`, and `app_window` behind `if (enable_extensions)` rather than `if (enable_platform_apps)`, even though `//extensions/browser/api/app_current_window_internal/BUILD.gn:7` asserts `enable_platform_apps`.
- Combined with Probes 2 and 3, this shows `enable_extensions = true` is self-contradictory on iOS unless either `//components/web_modal` is enabled on iOS (`enable_platform_apps = true`) or `//extensions/browser/api/BUILD.gn` is patched to gate app APIs on `enable_platform_apps`.
- **Desktop Android comparison:** Desktop Android avoids this deadlock entirely because `enable_extensions` stays `false` (`enable_extensions_core = true`, `enable_platform_apps = false`).

### Probe 5 (Core Iteration 1): `enable_extensions_core = true` + guard `//chrome:resources` ([run 43938061454](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43938061454))

- **Extra GN args:** `enable_extensions_core = true`
- **Patch added (`0056a38`):** `patches/0047-ios-extensions-guard-renderer-chrome-resources.patch` — guards `"//chrome:resources"` behind `if (!is_ios)` in `//extensions/renderer/BUILD.gn:256`.

**Verbatim `gn gen` error:**
```text
ERROR at //chrome/common/net/BUILD.gn:8:1: Assertion failed.
assert(!is_ios, "Chromium/iOS shouldn't use anything in //chrome")
^-----
Chromium/iOS shouldn't use anything in //chrome
See //chrome/common/BUILD.gn:197:5: which caused the file to be included.
    "//chrome/common/net",
    ^--------------------
```

**Why this triggers:**
- With `//extensions/renderer/BUILD.gn` unblocked, GN finishes parsing `//extensions/BUILD.gn`, where `static_library("test_support")` (`//extensions/BUILD.gn:159`) unconditionally depends on `"//chrome/common:buildflags"`.
- Parsing `//chrome/common/BUILD.gn` (`assert(!is_fuchsia)` only) evaluates `static_library("common")`, whose `public_deps` at `:197` includes `"//chrome/common/net"`, hitting `assert(!is_ios)` at `//chrome/common/net/BUILD.gn:8:1`.

### Probe 6 (Core Iteration 2): `enable_extensions_core = true` + guard `//chrome/common:buildflags` ([run 43940083679](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43940083679))

- **Extra GN args:** `enable_extensions_core = true`
- **Cumulative patches (`442b330`):**
  1. `patches/0047-ios-extensions-guard-renderer-chrome-resources.patch` (`//extensions/renderer/BUILD.gn`)
  2. `patches/0048-ios-extensions-guard-test-support-chrome-buildflags.patch` — guards `"//chrome/common:buildflags"` behind `if (!is_ios)` in `//extensions/BUILD.gn:159`.

**Verbatim `gn gen` output (`exit 0`):**
```text
Done. Made 34280 targets from 4878 files in 6426ms
```

**Offline `compare_graphs.py` & `chrome` reachability audit on downloaded `graph-diagnosis` artifacts (`43940083679` vs. `43868838103`):**
- `graph-raw`: `13,870` archive entries (`13,869` `.ninja` files + `args.gn`; `23` changed, `0` only in baseline, `100` only in current — `78` under `obj/extensions/**`, `17` under `obj/components/{enterprise/browser/promotion,onc,safe_browsing/content,services/app_service,services/unzip/content,zoom}/**`, `4` under `obj/services/accessibility/public/mojom/**`, `1` under `obj/tools/json_schema_compiler/**`). Total edges: `265,988` vs. `263,702` (`+2,286` edges).
- `codegen` plan: `43,247` planned roots (`10,939` closure edges; `0` off-limits crossings) vs. baseline artifact's `43,467` (`0` added, `220` removed due to the Stage 1/2 storyboard/intents planner split between `5edf7b1` and `c1c326f`; re-running the current `plan_shards.py` on both pruned graphs gives `43,247` vs. `43,247`, `0` delta).
- **Reachability from `//ios/chrome/app:chrome` (`chrome`):** Out of `370` `phony/extensions/*` GN target nodes emitted in `out/Release`, `chrome`'s transitive closure grows by only `+15` nodes / `+11` unique edges (`73,712` -> `73,723`), adding 4 `.o` compiles: `obj/extensions/common/constants_impl/constants.o`, `obj/extensions/common/extension_features/extension_features.o`, `obj/components/omnibox/browser/browser/omnibox_input_watcher.o`, and `obj/components/omnibox/browser/browser/omnibox_suggestions_watcher.o` (pulled via `//components/omnibox/browser` and `//components/saved_tab_groups/public`). None of `//extensions/common`, `//extensions/common/api`, `//extensions/browser`, `//extensions/browser/api`, `//extensions/renderer`, `//extensions:extensions_resources`, or `//extensions/strings` is reachable from `chrome` yet; wiring those core runtime roots into `chrome` adds `+2,182` unique Ninja edges (`+1,006` target C/C++/ObjC `.o` compiles) on top of `chrome`'s existing closure.

### Additional static `//chrome` / `!is_ios` traps found in `//extensions` at `34d81e7bfe669b8eccaaf35c6e14c7bfc0689703`
- `//extensions/BUILD.gn:159`: `static_library("test_support")` depends on `"//chrome/common:buildflags"` (unconditionally inside `//extensions/BUILD.gn`, which imports `//chrome` -> hits `assert(!is_ios)` in `//chrome/BUILD.gn:77` whenever `//extensions/BUILD.gn` is parsed, unless `//chrome/common:buildflags` is removed or guarded).
- `//extensions/BUILD.gn:280`: `test("extensions_unittests")` lists `data = [ ..., "//chrome/test/data/extensions/" ]`.
- `//extensions/browser/mime_handler/BUILD.gn:7`: `assert(enable_extensions && !is_android)` (if `enable_extensions = true`, `mime_handler` itself doesn't assert `!is_ios`, though `//extensions/browser/BUILD.gn:767` pulls `mime_handler_page` / `stream_container` for `!is_android`).

### Build-graph size impact
The successful core-only probe has **265,988 edges across 13,869 Ninja files**. Its codegen audit reports 43,247 roots, 10,939 edges in their closure, zero forbidden work, and zero unplanned required Apple inputs; `buildflags.h` is covered. The older baseline (`43868838103`) has 263,702 raw edges, but it predates planner and workflow changes, so the difference is not a controlled measure of extension overhead.

The actual `chrome` closure contains only `extensions/common/constants_impl.ninja` and `extensions/common/extension_features.ninja` from the extensions tree. Full `extensions/common:common` and renderer targets would pull in 15,940 and 27,318 device C-family compilations respectively. The next compile probe therefore selects individual object outputs rather than those transitive targets.

The first successful run's comparison step did not execute: `compare_graphs.py` lacked executable permission and `tee` masked that error. Commit `8ec9f1d` invokes Python explicitly, propagates pipeline failures, and reports expected feature-probe graph changes without treating them as baseline regressions. The GN and codegen checks were separate and did pass. The corrected comparison ran successfully in `43944365971`.

### Minimal remote compile probe

[Run 43944365971](https://github.com/benjipeng/chromium-blink-ios/actions/runs/43944365971) used the existing Linux source/SDK preparation and budget helpers, then built only:

| Layer | Object output | Result |
|---|---|---|
| Common extension model | `obj/extensions/common/common/extension.o` | Pass |
| Browser process/lifecycle manager | `obj/extensions/browser/browser_sources/process_manager.o` | Pass |
| Renderer dispatcher | `obj/extensions/renderer/renderer/dispatcher.o` | Pass |

The graph gate verified exactly these three device C-family objects and no Apple tools in their prerequisite closure. All compilation ran on GitHub; no source checkout or compilation was needed locally. Of 783 cacheable compiler calls, **780 were cache hits (99.62%) and only the three sampled iOS objects were misses**. Ninja executed 3,439 steps, mostly prerequisites; its build budget interval took 4m16s. Total job time was 15m33s, including runner cleanup, source preparation, graph checks, comparison, and report upload.

The probe reads the existing codegen ccache bucket but never writes GHCR checkpoints. Run provenance records the branch, commit, source/SDK digests, GN overrides, and probe mode. The default workflow mode remains graph-only; at this revision, `compile_extensions=true` enabled the three-object probe, subsequently expanded to 15 objects for embedder integration.

---

## 2. Upstream & Downstream Research

### 2.1 Desktop Android Extensions Port (`enable_desktop_android_extensions` / `enable_extensions_core`)

- **Origin & Tracking:** Introduced in August 2024 under [crbug.com/356905053](https://issues.chromium.org/issues/356905053) ("Support extensions on experimental desktop android builds") to bring Chromium extensions to Android desktop form factors (`is_desktop_android = true` in `//build/config/chrome_build.gni:41` and `:69-75`, which asserts `target_os == "android"`).
- **Build Flag Architecture (`//extensions/buildflags/buildflags.gni` and `//extensions/docs/buildflags.md`):**
  - `enable_extensions = !is_android && !is_ios && !is_castos && !is_fuchsia`: legacy flag covering Win/Mac/Linux/ChromeOS (`ENABLE_EXTENSIONS`).
  - `enable_desktop_android_extensions = is_desktop_android`: internal implementation detail flag (`ENABLE_DESKTOP_ANDROID_EXTENSIONS`), actively being replaced by `IS_ANDROID && ENABLE_EXTENSIONS_CORE` (e.g., [CL 8615887](https://chromium-review.googlesource.com/c/chromium/src/+/8615887), Oct 2026).
  - `enable_extensions_core = enable_extensions || enable_desktop_android_extensions`: primary gate for shared extensions code across desktop and desktop Android (`ENABLE_EXTENSIONS_CORE`), tracked for eventual consolidation back into `enable_extensions` under [crbug.com/546631276](https://issues.chromium.org/issues/546631276) ([CL 8435498](https://chromium-review.googlesource.com/c/chromium/src/+/8435498)).
  - `enable_platform_apps = enable_extensions` and `enable_hosted_apps = enable_extensions`: both stay `false` on desktop Android.
  - Desktop Android officially supports **Manifest V3 only** (`//extensions/docs/buildflags.md:22-24`).
- **Enabled Directories / Targets at `34d81e7bfe669b8eccaaf35c6e14c7bfc0689703`:**
  - `//extensions/common`, `//extensions/common/api`, `//extensions/browser`, `//extensions/renderer`, `//extensions/strings`: all assert `enable_extensions_core` (plus `//extensions/BUILD.gn:15` asserts `!enable_extensions || enable_guest_view`).
  - **Core APIs enabled under `enable_extensions_core`** (`//extensions/browser/api/BUILD.gn:27-57`, `//extensions/common/api/schema.gni:11-37`): `alarms`, `contentSettings`, `cookies`, `declarativeNetRequest`, `dns`, `fileHandlers`, `i18n`, `idle`, `management`, `messaging` + `native_messaging`, `metricsPrivate`, `offscreen`, `permissions`, `power`, `proxy`, `runtime`, `scripting`, `storage`, `system.cpu`, `system.display`, `system.memory`, `system.network`, `test`, `userScripts`, `webstorePrivate`.
  - **APIs still excluded under `if (enable_extensions)`** (`//extensions/browser/api/BUILD.gn:60-103`): `app_*`, `automationInternal`, `feedbackPrivate`, `fileSystem`, `mimeHandler` / `mimeHandlerPrivate`, `networkingPrivate`, `printerProvider`, `protocolHandlers`, `socket` / `sockets.*`, `systemInfo`, `systemStorage`, and ChromeOS-only hardware APIs.
  - **`//chrome/browser/extensions` and `//chrome/common/extensions`:** Both assert `enable_extensions_core` (`//chrome/browser/extensions/BUILD.gn:26`, `//chrome/common/extensions/BUILD.gn:8`). Files not yet ported to Android remain inside `if (enable_extensions)` (`//chrome/browser/extensions/BUILD.gn:790-1231`).
  - **Android UI & Bridges:** `//chrome/browser/ui/extensions/BUILD.gn:8` asserts `enable_extensions_core`; Android-specific JNI/Java bridges live in `//chrome/browser/ui/android/extensions/BUILD.gn` (`if (enable_extensions_core)`), including `ExtensionsToolbarAndroid`, `ExtensionsMenuDelegateAndroid`, `ExtensionActionDelegateAndroid`, `ExtensionActionPopupContents`, `ExtensionInstallDialogViewAndroid`, `ExtensionKeybindingRegistryAndroid`, `ExtensionDeveloperPrivateBridge`, plus `//chrome/browser/ui/android/extensions/windowing` and `side_panel` ([CL 8499267](https://chromium-review.googlesource.com/c/chromium/src/+/8499267)). `chrome://extensions` WebUI (`//chrome/browser/ui/webui/extensions/BUILD.gn:7`) is also gated on `enable_extensions_core`.
- **Desktop-Only Pieces Replaced or Stubbed for Desktop Android:**
  - `//chrome/browser/extensions/chrome_extensions_browser_client_android.cc`: temporary lightweight `ChromeExtensionsBrowserClient` implementation (explicitly marked `TODO(https://crbug.com/356905053)` to be deleted as code moves up to `//extensions` or is made cross-platform). Stubs out `GetProcessManagerDelegate()`, `GetControlledFrameEmbedderURLLoader()`, and full Safe Browsing (`SafeBrowsingDelegate` stub instead of `ChromeSafeBrowsingDelegate` when `safe_browsing_mode != 1`; `//chrome/browser/extensions/BUILD.gn:1880-1892`).
  - `//chrome/browser/extensions/api/chrome_extensions_api_client_android.cc`: stubs out `CreateUsbDevicePermissionsPrompt()` returning `nullptr`.
  - `//chrome/browser/extensions/extension_menu_model_android.cc`, `api/tabs/windows_util_android.cc`, `api/tabs/tabs_event_router_platform_delegate_android.cc`, `api/management/chrome_management_api_delegate_android.cc`, `extension_disabled_ui_android.cc`, `extension_error_ui_android.cc`, `external_install_error_android.cc`, `system_display/display_info_provider_android.cc`: Android-native delegates replacing Views/Aura/Cocoa UI and desktop `Browser` assumptions (`//chrome/browser/extensions/BUILD.gn:690-729`).
- **Status at our rev & on `main` (Nov 2026):** Mature enough for Chrome Web Store installs, `chrome://extensions`, extension toolbar/popups, side panel ([CL 8307120](https://chromium-review.googlesource.com/c/chromium/src/+/8307120)), keyboard shortcut reordering ([CL 8749247](https://chromium-review.googlesource.com/c/chromium/src/+/8749247)), and `image_writer_private` ([CL 8228184](https://chromium-review.googlesource.com/c/chromium/src/+/8228184)), with ongoing CLs migrating remaining `ENABLE_DESKTOP_ANDROID_EXTENSIONS` checks to `ENABLE_EXTENSIONS_CORE` and `ChromeExtensionsBrowserClient` pieces out of `_android.cc`. Public snapshot builds (`AndroidDesktop_arm64`) and downstream ports use it directly (see [Brave PR #40844](https://github.com/brave/brave-core/pull/40844) / [brave-browser#59354](https://github.com/brave/brave-browser/issues/59354) and [Ultimatum](https://github.com/gonzazoid/Ultimatum)).

### 2.2 Prior Art: iOS Blink, Android Forks (Kiwi, Ultimatum, Brave)

- **Google's experimental iOS Blink port (`use_blink = true`):**
  - Tracked under [crbug.com/40254930](https://issues.chromium.org/40254930) ("Create a content_shell iOS port"), which introduced the `use_blink` GN variable (`//build/config/features.gni:39`, default `use_blink = !is_ios`) and `USE_BLINK` buildflag for `content_shell` and `ios_chrome` experimental builds (`ios-blink-rel-fyi`, [crbug.com/514423253](https://issues.chromium.org/issues/514423253)).
  - **No upstream `//extensions` work exists for iOS Blink.** In `//ios/BUILD.gn`, `//ios/chrome/app/BUILD.gn`, `//ios/chrome/browser/BUILD.gn`, and `//ios/web/content/BUILD.gn`, there are zero references to `enable_extensions`, `enable_extensions_core`, or `//extensions/`. All "extension" references in `ios/` Blink commits refer to iOS `.appex` helper processes (`//content/shell/app/ios/extensions.gni`, e.g., `chrome_content_process.appex`) or Apple's `WKWebExtension` (below).
  - **No public third-party port of Chromium `//extensions` to iOS Blink** was found in web searches (status: none verified / likely nonexistent).
- **Kiwi Browser (`kiwibrowser/src`, `kiwibrowser/src.next`, [crbug.com/40686993](https://issues.chromium.org/issues/40686993)):**
  - Enabled the legacy `enable_extensions = true` + `enable_plugins = true` on `target_os = "android"` by patching ~400 build/runtime issues: replacing `<if expr="not is_android">` and `if (!is_android)` guards with `enable_extensions`, removing `is_android` assertions in `guest_view`, and providing Android shims for desktop `Browser` / `TabStripModel` / extension popups and `chrome://extensions`. Discontinued in Jan 2025; code later absorbed into Microsoft Edge Android.
  - **Key lesson vs. iOS:** Kiwi still ran inside `//chrome/browser` on Android (where `//chrome` already compiles). On iOS, `//chrome` is excluded by design (`assert(!is_ios)`), so Kiwi's approach cannot simply flip `enable_extensions = true` without either porting `//chrome/browser/extensions` into `//ios/chrome/browser` or building an embedder directly on `//extensions`.
- **Ultimatum (`gonzazoid/Ultimatum`) & Brave Android ([brave-browser#59354](https://github.com/brave/brave-browser/issues/59354), [brave-core#40844](https://github.com/brave/brave-core/pull/40844)):**
  - Ultimatum builds on upstream Desktop Android using `enable_desktop_android_extensions = true`, `enable_guest_view = true`, `enable_platform_apps = false`, adding a two-window (`regular`/`incognito`) `chrome.windows` shim and `chrome.tabs` wiring.
  - Brave enables `enable_extensions_core = true` (keeping `enable_extensions = false`) across Android in 45 files / 8 commits ([brave-core#40844](https://github.com/brave/brave-core/pull/40844)), patching `theme_resources.grd`, `ui/webui/resources/BUILD.gn`, `chrome/browser/profiles/BUILD.gn`, and `TabModel` / `BraveActivity` bridges. Both rely on `//chrome/browser`.

### 2.3 How `WKWebExtension` / `BuiltInWebExtension` Is Wired at `34d81e7bfe669b8eccaaf35c6e14c7bfc0689703`

The existing extension symbols in `benjipeng/chromium-blink-ios`'s built `chrome_framework` belong exclusively to Apple's WebKit-based built-in Global Privacy Control (GPC) extension (`web_extensions/gpc_web_extension`), and are **completely inert under `use_blink = true`**:

1. **Profile service creation (`//ios/chrome/browser/profile/model/keyed_service_factories.mm:370` -> `//ios/chrome/browser/web_extension/model/extension_service_factory.mm:24-56`):**
   - `ExtensionServiceFactory` is registered for every `ProfileIOS` (`ServiceCreation::kCreateWithProfile`). When `universal_optout::IsGPCExtensionEnabled(&profile)` or `IsUniversalOptOutExtensionSilentEnabled()` holds on iOS 18.4+ (`kUniversalOptOut` and `kUniversalOptOutExtension` are enabled by default in `//components/universal_optout/features.cc:21-23`), it constructs `ExtensionServiceImpl` (`//ios/chrome/browser/web_extension/model/extension_service_impl.mm`) owning `web::ExtensionController::Create()`.
2. **Apple `WKWebExtension` wrapper (`//ios/web/extension/`):**
   - `web::ExtensionController::Create()` (`//ios/web/extension/extension_controller_impl.mm:40-45`) instantiates `ExtensionControllerImpl`, which creates a `WKWebExtensionController` (`:49-53`) and loads `web::GPCWebExtension` (`//ios/web/extension/gpc_web_extension/gpc_web_extension.mm:22-26`, pointing to `web_extensions/gpc_web_extension` in the framework bundle) via `BuiltInWebExtension::CreateWKWebExtension` (`//ios/web/extension/built_in_web_extension.mm:53-57`, calling `[WKWebExtension extensionWithResourceBaseURL:completionHandler:]`).
3. **Sole attachment point (`//ios/web/web_state/ui/wk_web_view_configuration_provider.mm:215-225`):**
   - `WKWebViewConfigurationProvider::UpdateConfiguration()` calls `GetWebClient()->GetExtensionController(browser_state_)` (implemented in `//ios/chrome/browser/web/model/chrome_web_client.mm:735-740`) and sets `[configuration_ setWebExtensionController:extension_controller_impl->GetWKWebExtensionController()]` on a `WKWebViewConfiguration`.
4. **Why it is inert under Blink (`use_blink = true`):**
   - `web::WebState::Create()` (`//ios/web/web_state/web_state_factory.mm:12-23`) switches on `BUILDFLAG(USE_BLINK)`: when true, it constructs `web::ContentWebState` (`//ios/web/content/web_state/content_web_state.mm`) backed by `content::WebContents`, instead of `web::WebStateImpl` / `CRWWebController` / `WKWebViewConfigurationProvider`.
   - `//ios/web/content/BUILD.gn` has zero dependencies on `//ios/web/extension` or `//ios/web/web_state/ui:wk_web_view_configuration_provider`, and `//ios/web/content/init/ios_content_browser_client.cc` and `content_browser_context.mm` never call `GetExtensionController`. Thus `WKWebExtensionController` may allocate in the background on iOS 18.4+, but no Blink tab ever attaches to it.

---

## 3. Architectural Gap & Realistic Implementation Routes

### Core Architectural Differences: Desktop Android vs. iOS Blink

| Dimension | Desktop Android (`is_desktop_android`) | iOS Blink Sideload (`benjipeng/chromium-blink-ios`) |
|---|---|---|
| Browser layer | `//chrome/browser` (`Profile`, `BrowserWindowInterface`, `TabModel`) | `//ios/chrome/browser` (`ProfileIOS`, `Browser`, `WebStateList`) |
| Content wrapper | Direct `content::WebContents` / `content::BrowserContext` | `web::ContentWebState` wraps `content::WebContents`; `web::ContentBrowserContext` is attached via `SupportsUserData` on `web::BrowserState` (`//ios/web/content/content_browser_context.mm:15-45`) |
| `//chrome` availability | Full `//chrome` targets available | Forbidden by `assert(!is_ios)` in `//chrome/BUILD.gn:77`, `//chrome/chrome_repack_locales.gni:10` |
| Process & JIT model | Multi-process (content/extension renderer processes), V8 JIT enabled | Single-process + jitless (`--single-process`, `--jitless --wasm-jitless` in `patches/0001-ios-sideload-single-process-jitless-switches.patch:47-76`); incognito disabled because single-process `//content` supports only one `BrowserContext` (`patches/0016-ios-sideload-disable-incognito.patch:62-67`) |
| Embedder `ContentBrowserContext` delegates | Full `Profile` delegates | `ContentBrowserContext` returns `nullptr` for `GetGuestManager()`, `GetSpecialStoragePolicy()`, `GetSSLHostStateDelegate()`, etc. (`//ios/web/content/content_browser_context.mm:82-156`); `IOSContentBrowserClient` (`127` lines) and `IOSContentRendererClient` (`68` lines) are minimal |

### Route A — Minimal `//extensions` Core Embedder in `//ios/web/content` + `//ios/chrome/browser` (Recommended)

Use Desktop Android's `enable_extensions_core` boundary (avoiding `//chrome/browser/extensions`, `enable_platform_apps`, and `enable_guest_view` initially), and build a thin iOS Blink embedder directly on `//extensions/common`, `//extensions/browser`, and `//extensions/renderer`:
1. **Unblock `gn gen` (~small patchset):**
   - Introduce an iOS-compatible GN path (either enable `enable_extensions_core` for `is_ios && use_blink` or override in `args.gn`).
   - Remove or guard `"//chrome:resources"` in `//extensions/renderer/BUILD.gn:256` (`if (!is_ios)` or investigate removing it upstream, since `//extensions/renderer/DEPS` forbids `//chrome`).
   - Guard `"//chrome/common:buildflags"` (`//extensions/BUILD.gn:159`) and `"//chrome/test/data/extensions/"` (`//extensions/BUILD.gn:280`) with `if (!is_ios)` (or avoid pulling `//extensions:test_support` unless needed).
   - Add `//extensions/strings` and `//extensions:extensions_resources` pak files to `chrome_framework` resource repacking in `//ios/chrome/app/resources/BUILD.gn` (`repack_unscaled_resources` / `ios_chrome_repack_locales`).
2. **Core Embedder Wiring in `//ios/web/content` + `//ios/chrome/browser` (~medium-large):**
   - Implement `IOSExtensionsClient` (`//extensions/common/extensions_client.h`), `IOSExtensionsBrowserClient` (`//extensions/browser/extensions_browser_client.h`), `IOSExtensionsAPIClient` (`//extensions/browser/api/extensions_api_client.h`), and `IOSExtensionsRendererClient` (`//extensions/renderer/extensions_renderer_client.h`).
   - Hook `IOSContentBrowserClient` (`//ios/web/content/init/ios_content_browser_client.cc`) for `chrome-extension://` `URLLoaderFactory`, `OverrideWebkitPrefs`, Mojo interface binders, `AppendExtraCommandLineSwitches`, and `SiteInstance` / `WebContents` lifecycle (`ExtensionWebContentsObserver`), following the pattern already used by `patches/0034-ios-sideload-chrome-scheme-pages.patch` and `patches/0026-ios-sideload-site-permissions.patch`.
   - Hook `IOSContentRendererClient` (`//ios/web/content/init/ios_content_renderer_client.cc`) to forward `RenderThreadStarted`, `RenderFrameCreated`, `RunScriptsAtDocumentStart/End/Idle`, `WillSendRequest`, etc. to `ExtensionsRendererClient`.
   - Bridge `ContentBrowserContext` (`content::BrowserContext*`) <-> `ProfileIOS` (`PrefService*`, state path, incognito pairing) and call `extensions::EnsureBrowserContextKeyedServiceFactoriesBuilt()`.
   - Implement an extension lifecycle manager (`ExtensionRegistrar` / `ExtensionService`-equivalent, `CrxInstaller`, `UnpackedInstaller`, `ExtensionSystem`, `ProcessManagerDelegate` without `//chrome/browser/extensions`, or extract `ExtensionService` / `CrxInstaller` glue from `//chrome/browser/extensions`).
3. **Browser APIs & Mobile UI (~large):**
   - Core APIs (`storage`, `runtime`, `scripting`, `declarativeNetRequest`, `webRequest`, `cookies`, `alarms`, `offscreen`, `permissions`, `i18n`) live mostly in `//extensions/browser/api/`, though `tabs`, `windows`, `action`, `contextMenus`, `management`, `webNavigation`, `sidePanel`, and `developerPrivate` live in `//chrome/browser/extensions/api/` and would need iOS `WebStateList` / `Browser` / `ContentWebState` reimplementations or extracted shared delegates.
   - Management & action UI: build native UIKit/SwiftUI views (extension list, unpacked/CRX loader, toolbar action button, popup `ContentWebState` sheet) or port `chrome://extensions` (`//chrome/browser/ui/webui/extensions` currently depends heavily on `//chrome/browser/*`).
- **Estimated size & risk:** **Large (multi-month engineering effort; high maintenance surface).** High risk around `//chrome/browser/extensions/api/tabs` + `ExtensionTabUtil` + `ExtensionViewHost` coupling to `//chrome/browser`, WebExtension popup presentation inside iOS `UIViewController`s, and single-process memory pressure (Jetsam) when running extension service workers / content scripts alongside tabs in one jitless process.

### Route B — Port `//chrome/browser/extensions` onto iOS (Not Recommended)

Attempting to compile `//chrome/browser/extensions` (`//chrome/browser/extensions/BUILD.gn`) directly on iOS would require resolving transitive dependencies across `//chrome/browser/profiles`, `//chrome/browser/ui/browser_window`, `//chrome/browser/tab_list`, `//chrome/browser/safe_browsing`, `//chrome/browser/download`, etc., all of which live behind `assert(!is_ios)`. This is effectively rebuilding `//ios/chrome` on top of `//chrome/browser`. **Size:** prohibitive.

### Route C — Lightweight Userscript / WebExtension Subset in `//ios/web/content`

If the goal is content-blocking + userscripts rather than full Chrome Web Store `.crx` compatibility:
- `//components/js_injection` is **already wired** into `IOSContentRendererClient` (`//ios/web/content/init/ios_content_renderer_client.cc:20-35`) and `//ios/web/content/BUILD.gn:64-65`.
- A lightweight WebExtension subset (manifest parser + isolated-world script/CSS injection + `browser.storage` + `declarativeNetRequest` or `URLLoaderThrottle`) could avoid most of `//extensions/browser` and all of `//chrome/browser/extensions`, at the cost of incomplete Chrome Web Store API compatibility.

---

## 4. Open Questions (Unverified)

1. **Production resource and dependency coverage:** Graph generation passes after two dependency guards, but which resources and generated headers will the eventual iOS renderer integration actually need? The full emitted graph includes test targets; its total size must not be confused with the browser's production closure.
2. **Actual compile/link errors in `//extensions/` for `target_os = "ios"`:** Upstream `//extensions/` has never been compiled for `is_ios = true` (POSIX/Apple paths in `//extensions` often assume `is_mac` rather than `is_apple`, e.g., `//extensions/browser/BUILD.gn:875` `CoreServices.framework` under `if (is_mac)`, or `//extensions/common/file_util.cc`, `//extensions/browser/updater/`, `native_messaging`, `services/data_decoder` out-of-process unzipping under `--single-process`).
3. **Single-process (`--single-process`) & `--jitless` compatibility for extension service workers and isolated worlds:** Whether `extensions::ServiceWorkerTaskQueue`, `ExtensionHost`, and `NativeExtensionBindingsSystem` run cleanly in-process on iOS Blink, and what the Jetsam RAM overhead is on 4–6 GB devices (`patches/0001-ios-sideload-single-process-jitless-switches.patch:55-66`).
4. **In-process CRX unzipping / JSON parsing:** `//extensions/browser/sandboxed_unpacker.cc` uses `//components/services/unzip` and `//services/data_decoder` out-of-process services by default; under sideloaded iOS without `.appex` helper processes, in-process service execution must be verified.
5. **Whether `//extensions/renderer/BUILD.gn:256` (`"//chrome:resources"`) is genuinely unused by C++ sources in `//extensions/renderer`:** Unverified without checking all `#include`s or compiling `//extensions/renderer`.
