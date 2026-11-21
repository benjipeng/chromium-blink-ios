# Curium TODO

The single ledger of open work. Check an entry against git before acting on it, and
update this file in the same change that starts, finishes, or reshapes the work.
Entries follow the [iteration lifecycle](../AGENTS.md#iteration-lifecycle): fix on
the pinned engine first, translate to `patches/` once proven.

## Pinned

- **Engine:** build 37, `Kernel.lock` → `b25e8e3` (run `44875353052`, Chromium
  160.0.8171.0), patches through `0104` + `fb14c22`, with separate 83.4 MB
  unstripped symbols artifact (`Chromium-Blink-160.0.8171.0-arm64-symbols`).
- **On `ac_duo`:** `Curium-0.1.11-b15-arm64.ipa` (hot-swapped into LiveContainer
  `com.appautomaton.curium.app` and copied to LiveContainer `Documents/`).

## App (on the pinned engine)

- [x] **PiP in one tap.** The start hook (Live hooks) holds the engine's start until
  the fresh controller has settled and its layer renders, and retries one reported
  failure. Root cause: the engine started a 5 ms old controller, before Pegasus
  confirmed it (`failed; status = 0`) or the layer had a frame (`-1003`). Confirmed
  by Sire on `ac_duo` in 0.1.7 (8), 2026-11-20.
- [x] **Dark Reader and uBlock Origin Lite interfere in one session.** On `ac_duo`,
  uBlock's dashboard showed unstyled HTML; after a relaunch with both extensions
  enabled, Dark Reader's Options stalled at “Loading, please wait.” Root cause
  in single-process Build 35: `ProcessMap` stores one extension ID per renderer
  ID (renderer 3), so whichever extension claims it first locks other enabled
  extensions out of private subresource loads (`ERR_BLOCKED_BY_CLIENT`), MV3
  service worker registration (`ServiceWorkerHost::DidInitialize/Start/Stop`),
  extension messaging (`CanProcessHostExtensionMessaging` →
  `EMF_INVALID_MESSAGE_FROM_SANDBOXED_PROCESS` (38) → `ShutdownForBadMessage`),
  privileged API dispatch (`CanProcessHostContextType`), and `EventRouter`
  listener validation / context classification. The extension coexistence hook
  (Live hooks, `CuriumExtensionCoexistenceHook.m`) patches 26 `__DATA_CONST`
  vtable slots pinned to Build 35's UUID (`4C4C4483-5555-3144-A14F-B2F89F30C28A`)
  and scopes `ProcessMap` per synchronous UI-thread call to the browser-verified
  document origin (`request_initiator_origin` / `RenderFrameHost::GetLastCommittedOrigin`)
  or live worker identity (`ServiceWorkerTaskQueue::IsCurrentActivation` /
  `ProcessManager::HasServiceWorker`), hiding `ProcessMap` for non-extension and
  sandboxed origins. Verified on `iphone_duo_27_2` Simulator (`sdk 27.2`): both
  cold-launch orders load uBlock Origin Lite Dashboard (`0` failed requests,
  live `getOptionsPageData` worker response, 14 enabled rulesets) and Dark Reader
  Options (`loader--complete`, 40 controls, `chrome.storage.sync` live) with both
  MV3 service workers running; on `/ubol` in the same session, uBlock blocks all
  three filter targets (`allowed: +2`, `easylist/easyprivacy/ublock_filters: 0`)
  while Dark Reader dynamic mode darkens the background to `rgb(27, 29, 30)`;
  cross-extension and webpage fetches to either extension's private resources
  fail with `net::ERR_BLOCKED_BY_CLIENT`. Shipped to `ac_duo` in 0.1.8 (9) / 0.1.9 (10).
- [x] **Blink web-page paste silently inserts nothing.** Tapping Paste in Blink
  inputs (`<input>`, `<textarea>`, `contenteditable`, Google search) inserted
  zero characters even though copying out of Blink worked. Root cause in Build 35:
  (1) `ClipboardIOS::GetAllAvailableFormats` matches `[[UIPasteboard generalPasteboard] items]`
  dictionary keys by exact string equality against `ClipboardFormatType::PlainTextType()`
  (`"public.plain-text"`), whereas iOS stores copied text under `"public.utf8-plain-text"`
  (conforming subtype), so `IsFormatAvailable` and `ReadAvailableTypes` returned empty
  and Blink aborted `Editor::Paste` before calling `ReadText`; (2) `-[RenderWidgetUIView paste:]`
  dispatches `handleEditCommands:{"paste"}` asynchronously over Mojo IPC, exiting
  UIKit's trusted `-paste:` authorization scope before `ClipboardIOS` reads the
  pasteboard. `CuriumClipboardHook.m` snapshots `UIPasteboard.generalPasteboard`
  synchronously inside `-[RenderWidgetUIView paste:]` (with `changeCount` + 2 s TTL
  validation and empty-dict fallback to `pb.string`/`pb.URL`), normalizes conforming
  UTIs (`public.plain-text`, `public.html`, `public.rtf`, `public.png`, `public.svg-xml`,
  `public.image`), and intercepts `_UIConcretePasteboard` reads strictly for callers
  inside `chrome_framework`'s `__TEXT` segment (zero Build 35 offset coupling).
  Verified on `iphone_duo_27_2` Simulator (`sdk 27.2`, 11/11 unit tests, live DOM
  `paste` event with `types: ["text/plain"]` and hands-on paste test).
- [x] **Multi-touch cancellation `SIGTRAP` on `ac_duo`.** On `ac_duo` in 0.1.8 (9),
  `RenderWidgetUIView -touchesCancelled:withEvent:` crashed with `SIGTRAP` at
  `content/browser/renderer_host/input/motion_event_web.cc:42`
  (`DCHECK(WebTouchEventTraits::AllTouchPointsHaveState(event, kStateCancelled))`).
  Root cause: `RenderWidgetUIView` forwards cancelled touches one at a time to
  `WebTouchEventBuilder::Build(kTouchCancel, ...)`, which appends any other
  remaining touch in its process-global 16-slot array as `kStateStationary`.
  `CuriumTouchCancelHook.m` mirrors the 16-slot touch set across
  `RenderWidgetUIView` touch methods, drains extra/stale touches cleanly via
  `touchesEnded:withEvent:` (`ACTION_POINTER_UP`), and only forwards
  `touchesCancelled:withEvent:` for the sole remaining touch with
  `UITouchPhaseCancelled`. Verified on Simulator via LLDB multi-touch cancel,
  partial cancel, and untracked touch cancel stress test (`111`, zero `SIGTRAP`).
  Shipped in 0.1.9 (10).
- [x] **uBlock Origin Lite filtering mode switching & clipped extension popup.**
  Raising filtering mode in uBOL's popup or Options failed because
  `IOSExtensionsBrowserClient::GetNativeWindowForFunction` returned empty
  (`"Could not find an active window."` in `chrome.permissions.request`), while
  setting level `0` (No filtering) threw a synchronous `TypeError` in
  `dnr.updateSessionRules` because `chrome.tabs.TAB_ID_NONE` was missing from
  the compiled `tabs` schema (leaving `popup.html` stuck in `body.busy`).
  `CuriumExtensionCoexistenceHook.m` now also patches Build 35's
  `GetNativeWindowForFunction` (`+0x368`) and `CreateInstallPromptForNativeWindow`
  (`+0x360`, presenting a native `UIAlertController` Allow/Deny prompt for new
  optional permissions) plus `IOSGeneratedSchemas`'s `tabs` schema entry to expose
  `TAB_ID_NONE = -1`; `CuriumExtensionsSheet.swift` presents `CuriumPopupView` via
  `.sheet` + `.presentationSizing(.fitted)` so popups are never clipped to 349 pt.
  Verified on Simulator: all 4 uBOL filtering levels (`3 → 1 → 0 → 2 → 0 → 3 → 2`)
  switch cleanly via physical AXe taps, Options default filtering mode radio cards
  switch (`1 → 3 → 2`), and both uBOL and Dark Reader popups render unclipped.
  Shipped in 0.1.9 (10).
- [x] **Form accessory with a hardware keyboard.** The engine's previous/next/done
  toolbar docked alone at the bottom edge, clipped by the display corner and over
  Curium's bottom chrome. The input accessory hook (Live hooks) drops it while a
  hardware keyboard is attached. Verified on Simulator: a focused Google search field
  shows no bar. Shipped to `ac_duo` in 0.1.8 (9).
- [ ] **Floating PiP button over the playing video.** Requested. Open question:
  placement over the in-page video or in the top chrome.
- [x] **Readable guest logs on `ac_duo`.** Under LiveContainer, `log collect` showed
  every Curium `os_log` line as `<compose failure>`. Added `CuriumDiagnostics.swift`
  (lock-guarded 200-line ring buffer + async `.utility` rolling file writer to
  `<CuriumLibraryLocation>/curium-diagnostics.log`, 128 KB rotation, zero main-thread
  I/O) reporting startup metadata, `CuriumRuntimeHookStatuses()` (`8/8 active`),
  `os_proc_available_memory()`, memory warnings, and deduplicated occlusion regions,
  with an in-app viewer + Copy/ShareLink in Settings. Verified on Simulator.
- [x] **Address bar buttons are unreachable to accessibility.** Separated leading
  PiP and trailing Clear/Reload controls into non-overlapping `.overlay` layers
  above `.glassEffect` in `CuriumBrowserView.swift`. Verified on Simulator via
  `axe tap --agent` on `Reload` (`enqueuedAndDrained`, zero `targetCovered`).
- [x] **Swift/Obj-C shell stability, 120 Hz scroll smoothness & idle-efficiency sweep.**
  Fixed uninitialized `ScopedProcessMap` stack reads, extension popup `window.close()`
  synchronous UAF, `RenderWidgetUIView` detached-view touch desync (`removeView`),
  `CuriumBlinkViewportHost` dangling KVO + `MainActor.assumeIsolated` traps,
  `NSProcessInfo.arguments` `dispatch_once` deadlock hazard, `CuriumExpectMethod`
  superclass matching, `permissions.request` alert dismissal retain cycle, LiveContainer
  SQLite WAL `0xdead10cc` (`willDeactivate` + `beginBackgroundTask` + xattr) & legacy
  adoption fail-closed, LiveContainer durable download path (`Documents/Curium/Downloads`),
  synchronous `@MainActor` `layer.render` snapshot freezes (switched to async
  `takeSnapshot` + off-main downscale), `CuriumReadingEdge` masked blur mount hitch,
  120 Hz `CuriumAddressBar` layout/TextField/KVO churn, extension badge rebuild storms,
  and all 10 `idle-auditor` wasted-work findings. Added standalone `CuriumTests` target
  (9/9 passing). Verified on Simulator (`sdk 27.2`, `8/8` hooks active, `2.0% CPU` /
  `221M` idle).
- [x] **Top chrome follows reserved regions exactly.** The bar meets the occlusion
  frame with no extra gap, and the collapsed pill stays in the status row unless a
  region crosses the center (`CuriumBrowserView.swift`, `CuriumOcclusionReader.swift`).
  Verified on Simulator: idle, Live Activity, a simulated `413,0,256,82` region, a
  centered cutout, landscape, and folded landscape. Shipped in 0.1.6.

## Live hooks

Permanent shell-side runtime guards in `Curium/Engine/CuriumRuntime.m`. All five
temporary Build 35 engine hooks (`CuriumExtensionCoexistenceHook`,
`CuriumClipboardHook`, `CuriumTouchCancelHook`, `CuriumInputAccessoryHook`, and
`CuriumPictureInPictureHooks`) were upstreamed into `patches/0099`–`0104` (+
`fb14c22`) and retired when `Kernel.lock` repinned to Build 37.

| Hook | Effect | Exit |
| --- | --- | --- |
| `-[NSProcessInfo arguments]` (`CuriumRuntime.m`) | Adds launch switches: Google features off, `--disable-sync` when `CuriumEngineSupportsDisableSync` is set, JIT mode, and Skia Graphite off on Simulator. | Permanent: the app's channel for launch switches. |
| `V8IOSJitPrepareForProcess` pre-`ChromeMain` probe (`CuriumRuntime.m`) | Prepares V8's iOS TXM / Simulator JIT pool before Crashpad installs exception handlers. | Permanent: shell-controlled JIT preference. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` (`CuriumRuntime.m`) | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |

## Engine wave (Build 37 landed & pinned in `Kernel.lock`)

Built in run `44875353052` (`b25e8e3`) after green `graph-diagnose.yml` (`44874478610`).
All five matching runtime hooks have been retired from `Curium/Engine/`.

- [x] **Unstripped framework symbols artifact (`0098-ios-save-unstripped-symbols.patch`).**
  `build/toolchain/apple/toolchain.gni` already declares `.unstripped` outputs when
  `save_unstripped_output` is true (`enable_stripping && !enable_dsyms`) and
  `scripts/stages/link.sh` already uploads `chrome_framework*.unstripped`, while
  Linux Stage 4 Link cannot run macOS-only `dsymutil`. Added `-Wcrl,unstripped,`
  with `rebase_path(root_out_dir, root_build_dir)` to `build/config/ios/BUILD.gn`
  for zero-overhead full `LC_SYMTAB` crash symbolication without bloating compile
  shards or the IPA.
- [x] **Single-process extension coexistence (`0099-ios-extensions-single-process-coexistence.patch`).**
  Translated all 6 context-scoped authorization boundaries under
  `content::RenderProcessHost::run_renderer_in_process()` (`extension_protocols`,
  `url_request_util`, `extension_function_dispatcher`, `message_service_bindings`,
  `extension_message_port`, `service_worker_host`, `event_router`, `web_request_api`,
  and `process_map`, guarding speculative RFHs before `IsErrorDocument()` and
  scoping `ProcessHasWebUIBindings` in `GetMostLikelyContextType`). Retires
  `CuriumExtensionCoexistenceHook.m` once `Kernel.lock` repins.
- [x] **Extension APIs & native permissions prompt (`0100-ios-extensions-scripting-tabs-and-permissions-prompt.patch`).**
  Added `tabs.TAB_ID_NONE = -1` to `tabs.json`, registered `APIPermissionID::kScripting`
  and `ios_permission_features.json` in `IOSExtensionsAPIProvider`, and implemented
  `GetNativeWindowForFunction` + `CreateInstallPromptForNativeWindow` (`UIAlertController`
  with requested host/API listing, `transitionCoordinator` retry, and dealloc sentinel)
  in `IOSExtensionsBrowserClient`.
- [x] **Blink clipboard UTI conformance & trusted paste (`0101-ios-blink-clipboard-uti-and-trusted-paste.patch`).**
  Added `UniformTypeIdentifiers.framework` to `ui/base/clipboard/BUILD.gn`,
  `UTType` conformance matching across `ClipboardIOS`, `Clipboard::PrepareForPaste()`
  called synchronously in `-[RenderWidgetUIView paste:]`, and `hasURLs || hasImages`
  in `canPerformAction:`. Retires `CuriumClipboardHook.m` once `Kernel.lock` repins.
- [x] **Multi-touch cancellation `SIGTRAP` guard (`0102-ios-blink-multitouch-cancel-guard.patch`).**
  Replaced raw global `UITouch*` tracking in `WebTouchEventBuilder` with
  `base::NoDestructor` weak-view slots, stale-touch draining, `ClearTouchesForView`
  in `removeView`, and `BuildTouchEvents` lifting preceding/partial-cancel touches
  as `kTouchEnd` (`kStateReleased`) before emitting `kTouchCancel` solely for the
  last remaining cancelled touch. Retires `CuriumTouchCancelHook.m` once `Kernel.lock` repins.
- [x] **Hide `inputAccessoryView` for hardware keyboards (`0103-ios-blink-hide-accessory-for-hardware-keyboard.patch`).**
  Linked `GameController.framework` in `content/browser/BUILD.gn`, suppressed
  `inputAccessoryView` while `GCKeyboard.coalescedKeyboard` is present, and reloaded
  input views on connect/disconnect notifications. Retires `CuriumInputAccessoryHook.m`
  once `Kernel.lock` repins.
- [x] **PiP close crash (`fb14c22`) & start-when-ready (`0104-ios-curium-pip-start-when-ready.patch`).**
  Moved the 0.15 s settle + 0.6 s readiness gate and single 0.25 s failure retry
  into `CuriumPiPBridge` (and added an auto-skip guard in `CuriumPictureInPictureHooks.m`).
  Retires `CuriumPictureInPictureHooks.m` once `Kernel.lock` repins.
- [ ] **Authentic Chrome dual identity, Client Hints delegate & `Accept-Language` (`0105-ios-curium-chrome-identity-and-accept-language.patch`).**
  Fixes DataDome / Cloudflare / `wsj.com` bot rejections caused by missing
  `Accept-Language` headers on Blink requests, `nullptr`
  `ClientHintsControllerDelegate` (zero `Sec-CH-UA*` on HTTPS navigations and
  dead `Accept-CH` / `Critical-CH`), unbranded 2-brand `Chromium` Client Hints,
  impossible `iPhone OS 18_7 + Chrome/ + Sec-CH-UA-Platform: "iOS"` mobile UA,
  empty macOS Desktop `platform_version`, `/favicon.ico` dual-UA `CriOS` split,
  and lost Desktop override on `window.open` / `target="_blank"`. Configurable
  via Swift-owned launch switches (`--curium-ua-brand`, `--curium-mobile-ua`,
  `--curium-accept-lang`, `--curium-mobile-platform-version`,
  `--curium-mobile-model`, `--curium-desktop-platform-version`) persisted in
  Curium Settings.
- [ ] **Drop `helpers/extensions_ui` from packaging.** It hooks Chrome's Settings
  screen, which Curium never shows, and `scripts/sync_curium_engine.py` does not
  carry it into `Vendor/CuriumEngine/`. Retire the extension steps in
  `docs/simulator.md` with it. Deferred.

## Environment

- The `iPhone Duo` simulator device type has `PiPOverlay` and `PiPPinned` set to
  `true` (original saved as `capabilities.plist.orig`). Xcode updates overwrite it.
- Simulator PiP always fails with `-1003`: the PiP layer never receives a frame (its
  renderer never reaches rendering), so Pegasus sees `0 x 0` content. Verify PiP on
  `ac_duo`. Engine PiP needs a video playing with sound; for a silent test, serve a
  video whose audio track is digital silence.
- Simulator SpringBoard shows no Now Playing island for in-simulator audio; use
  `tools/simulator/island-probe` to widen the island.
