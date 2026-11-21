# Curium TODO

The single ledger of open work. Check an entry against git before acting on it, and
update this file in the same change that starts, finishes, or reshapes the work.
Entries follow the [iteration lifecycle](../AGENTS.md#iteration-lifecycle): fix on
the pinned engine first, translate to `patches/` once proven.

## Pinned

- **Engine:** build 35, `Kernel.lock` → `3b973e0` (Chromium 160.0.8171.0), patches
  through 0097. Patch 0095 (page scrolls under the floating top chrome) is live.
- **On `ac_duo`:** 0.1.9 (10) Release, `Curium-0.1.9-engine35-20261120.ipa`,
  also in LiveContainer `Documents/`. Packaged and released via Pipeline 2
  (`.github/workflows/build-curium.yml` + `scripts/build_curium_ipa.sh`).

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
- [ ] **Readable guest logs on `ac_duo`.** Under LiveContainer, `log collect` shows
  every Curium `os_log` line as `<compose failure>`, so device occlusion margins are
  still unknown. Route diagnostics through a path the archive can decode.
- [ ] **Address bar buttons are unreachable to accessibility.** The address field's
  element covers the leading Picture in Picture and trailing Reload buttons: AXe
  refuses both with `targetCovered`, so VoiceOver likely cannot reach them either.
- [x] **Top chrome follows reserved regions exactly.** The bar meets the occlusion
  frame with no extra gap, and the collapsed pill stays in the status row unless a
  region crosses the center (`CuriumBrowserView.swift`, `CuriumOcclusionReader.swift`).
  Verified on Simulator: idle, Live Activity, a simulated `413,0,256,82` region, a
  centered cutout, landscape, and folded landscape. Shipped in 0.1.6.

## Live hooks

Runtime hooks on the pinned engine, in `Curium/Engine/`. Each one fails closed when
the engine's layout differs from what it expects (`CuriumHookSupport.h`).

| Hook | Effect | Exit |
| --- | --- | --- |
| `-[NSProcessInfo arguments]` (`CuriumRuntime.m`) | Adds launch switches: Google features off, `--disable-sync` when `CuriumEngineSupportsDisableSync` is set, JIT mode, and Skia Graphite off on Simulator. | Permanent: the app's channel for launch switches. |
| `+[MetricsMediator logLaunchMetricsWithStartupInformation:connectedScenes:]` (`CuriumRuntime.m`) | No-op. Launch metrics walk Chrome's tab model for uploads Curium never makes. | None planned. |
| `-[CuriumPiPBridge dealloc]` (`CuriumPictureInPictureHooks.m`) | Replaces the dealloc that crashed on PiP close. Steps aside when the engine has `-detachObservers`. | `fb14c22`; delete once `Kernel.lock` pins it. |
| `-[CuriumPiPBridge startPiPForGeneration:]` and its `failedToStartPictureInPictureWithError:` (`CuriumPictureInPictureHooks.m`) | Holds the start up to 0.6 s until the controller is 150 ms old, possible, and rendering; retries one reported failure after 0.25 s. | The upstream form in the Engine wave, once `ac_duo` proves it. |
| `-[RenderWidgetUIView inputAccessoryView]` (`CuriumInputAccessoryHook.m`) | Returns no accessory while `GCKeyboard.coalescedKeyboard` is set; reloads input views on keyboard connect or disconnect. | Upstream the same condition in `render_widget_host_view_ios_uiview.mm`. |
| `-[RenderWidgetUIView touchesBegan/Moved/Ended/Cancelled:withEvent:]` (`CuriumTouchCancelHook.m`) | Mirrors `WebTouchEventBuilder`'s 16-slot global touch table so multi-touch, partial, stale, and untracked cancellations never violate `MotionEventWeb`'s `AllTouchPointsHaveState(kStateCancelled)` `DCHECK` or `WebTouchEventBuilder` traps. | Fix `WebTouchEventBuilder::Build(kTouchCancel, ...)` and `RenderWidgetUIView -touchesCancelled:` in the Engine wave. |
| Build 35 `__DATA_CONST` vtable & schema slots (`CuriumExtensionCoexistenceHook.m`, 28 vtable slots + `tabs` schema) | Authorizes single-process extension subresources, messaging, MV3 service worker lifecycle, API dispatch, and event listeners by browser-verified document origin/worker identity (preserving private resource isolation); implements `GetNativeWindowForFunction` + native `UIAlertController` consent for `CreateInstallPromptForNativeWindow` (`chrome.permissions.request`); adds `chrome.tabs.TAB_ID_NONE = -1` to `IOSGeneratedSchemas`. Pinned to UUID `4C4C4483-5555-3144-A14F-B2F89F30C28A`, fail-closed. | Upstream per-context authorization, `permissions.request` prompt support, and `TAB_ID_NONE` in `tabs.json` in the Engine wave, then delete once `Kernel.lock` repins. |

## Engine wave (banked, not built)

Build once the wave is complete and approved. Gate it with `graph-diagnose.yml`
before `build-ipa.yml`.

- [ ] **Authorize extension operations by their originating context.** In
  single-process mode, Chromium reuses one renderer host, but `ProcessMap`
  stores one extension ID per renderer ID. The Build 35 runtime hook
  (`CuriumExtensionCoexistenceHook.m`, Live hooks) proves the five browser-side
  decision points that need context-scoped authorization: subresource factory
  origin binding (`extension_protocols.cc` / `ios_content_browser_client.cc`),
  extension messaging (`message_service_bindings.cc`, where the prior resource
  experiment hit `EMF_INVALID_MESSAGE_FROM_SANDBOXED_PROCESS` = 38 →
  `ShutdownForBadMessage`), MV3 worker lifecycle (`service_worker_host.cc`),
  API dispatch (`extension_function_dispatcher.cc`), and event listener
  validation / dispatch classification (`event_router.cc` / `process_map.cc`).
  Translate those checks into `patches/` using browser-verified document origins
  and worker identities without broadening `ProcessMap` globally, then retire
  the vtable hook once `Kernel.lock` repins. Not written.
- [x] **PiP close crash** (`fb14c22`, on `main`). The bridge's `-dealloc` no longer
  captures `self` in a render-queue block. Upstream form of the `dealloc` hook.
- [ ] **PiP in one tap, upstream form.** Proven on `ac_duo` in 0.1.7 (8). Move the
  start hook's readiness gate and single retry into `CuriumPiPBridge`
  (`-startPiPForGeneration:` and the failure delegate), then delete the hook.
  Not written.
- [ ] **Symbolicated crashes.** `args/device.gn` sets `enable_dsyms = false`, which no
  app change can reach. Emit dSYMs as a separate artifact, never inside the IPA.
  Not written.
- [ ] **Drop `helpers/extensions_ui` from packaging.** It hooks Chrome's Settings
  screen, which Curium never shows, and `scripts/sync_curium_engine.py` does not
  carry it into `Vendor/CuriumEngine/`. Retire the extension steps in
  `docs/simulator.md` with it. Not written.

## Environment

- The `iPhone Duo` simulator device type has `PiPOverlay` and `PiPPinned` set to
  `true` (original saved as `capabilities.plist.orig`). Xcode updates overwrite it.
- Simulator PiP always fails with `-1003`: the PiP layer never receives a frame (its
  renderer never reaches rendering), so Pegasus sees `0 x 0` content. Verify PiP on
  `ac_duo`. Engine PiP needs a video playing with sound; for a silent test, serve a
  video whose audio track is digital silence.
- Simulator SpringBoard shows no Now Playing island for in-simulator audio; use
  `tools/simulator/island-probe` to widen the island.
