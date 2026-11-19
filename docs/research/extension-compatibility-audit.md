# Extension Compatibility Audit

Audited on 2026-11-18 against the consolidated branch at `1e003fc` and the
existing Chromium M159 simulator build from
[run 44222828561](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44222828561).
The Store manifest and JavaScript checks below are static observations.
The simulator result for Dark Reader is recorded separately.

| Chrome Web Store package | Version | Compatibility evidence |
| --- | --- | --- |
| [Dark Reader](https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh) | 4.9.135 | Manifest V3. Its Dynamic Theme scripts run at `document_start` in both the page and isolated worlds, including child frames; the worker calls `chrome.tabs.query` and `chrome.scripting.executeScript`. It provides an action popup. The popup has a fallback when `chrome.fontSettings` is absent. |
| [Tampermonkey](https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo) | 5.5.1 | Manifest V3. Declares `tabs`, `userScripts`, `scripting`, `webNavigation`, `offscreen`, and other APIs. Check the actual failing call before expanding scope. Ordinary Manifest V3 installations do not get unrestricted `webRequestBlocking`. |
| [Violentmonkey](https://chromewebstore.google.com/detail/violentmonkey/jinjaccalgkegednnccohejagnlnfdag) | 2.50.0 | The Chrome package is Manifest V3. It also declares `tabs`, `userScripts`, `webNavigation`, and `offscreen`, and observes tab events. Use it to check that the implementation is shared. |

The three CRX3 packages were fetched through Google's Store update endpoint
with product version `159.0.8149.0`. File SHA-256, in table order:

```text
0b7857ae92fd3aeab4292bb755aa0f108de6b68bc12f18d0c87fe757cdd40a9d
b5167937817e636adeba462ed9bf9b32ff01c2888f78a9afc6aa4f8e655fe872
4344181e4ec3f3495763e5dadcd57fd733a6c099589adc2cdf69d2cda0e7d653
```

## Product gates

1. **Dark Reader plus uBlock Origin Lite.** From the existing install flow,
   install the Store builds together. Verify Dark Reader recolors a controlled
   light page and a permitted child frame; adding a site exception leaves
   another origin dark. Confirm uBlock Origin Lite still blocks the fixture
   request. Reload and relaunch with both installed. Use runtime evidence to
   separate install, worker startup, messaging, and script injection failures.
2. **Page actions.** Use the toolbar menu to open the extension's actual
   action popup against the browser tab that invoked it. In two tabs, verify
   distinct tab IDs and that an action can only reach the intended tab.
   Settings continues to own installation, removal, and global enablement.
   A settings tab does not supply the popup's active-page context. Verify a
   count or badge against real per-tab data before exposing it in the UI.
   Label Declarative Net Request counts as blocked requests, since the browser
   cannot infer how many individual ads those requests would have displayed.
3. **User scripts.** Start with Tampermonkey, then run the same test with
   Violentmonkey. Require [per-extension consent](https://developer.chrome.com/docs/extensions/reference/api/userScripts/)
   and an explicit match for a controlled test origin. A harmless DOM marker
   must appear on a matching page, never on a nonmatching page or when access is
   revoked. Repeat after restart. Keep Chrome's existing permission boundaries.

The consolidated branch contains browser-side tab identity and lookup
(`0077`, `0078`) and Declarative Net Request accounting (`0079`). These are
not a complete JavaScript `chrome.tabs` binding or a native popup host. The
iOS browser API provider registers `commands.getAll`; the shared extensions
core already supplies pieces of `scripting` and `userScripts`. In the pinned
[scripting implementation](https://github.com/chromium/chromium/blob/34d81e7bfe669b8eccaaf35c6e14c7bfc0689703/extensions/browser/scripting_utils.cc#L346-L359),
script execution needs both a valid tab lookup and a `ScriptExecutor`; the iOS
client does not override `GetScriptExecutorForTab`. Verify the iOS tab,
frame, and consent adapters before broadening the linked API surface.
The package helper can present a panel and call a native bridge; browser and
renderer capabilities need to be implemented and linked in the core if absent.

The pinned [`ProcessMap`](https://github.com/chromium/chromium/blob/34d81e7bfe669b8eccaaf35c6e14c7bfc0689703/extensions/browser/process_map.cc#L66-L78)
accepts one extension ID per renderer process ID. With the single-process app,
an extension working alone does not demonstrate coexistence. If the two
workers interfere, trace frame and worker identity before changing any
authorization logic; do not grant extension privileges to a shared process
as a whole.

The independent Carbon source review also found that iOS still uses the base
messaging delegate, which does not resolve tab metadata or tab-targeted
messages. Browser-side identity alone is insufficient: check renderer tab
identity and frame/document attribution as well. For Dark Reader, use a light
system appearance and inspect its dynamic styles or verify a per-site toggle;
its fallback content script can darken a page under system dark mode without
a healthy service worker. These are source findings, not recorded runtime failures.

## Simulator result

On the iPhone Duo simulator with iOS 27.1 in Light appearance, the existing
`a18ce74` core plus the updated Store form (`Duo Extensions Test`) downloaded,
verified, and installed Dark Reader 4.9.135 from its official listing. Review
advanced with one tap and the extension appeared enabled. A local white page
still reported `rgb(255, 255, 255)`, zero dynamic styles, and zero fallback
styles. The background worker reported `Platform information unavailable`,
an undefined `onRemoved` listener, and unavailable `storage.sync`. The iOS
runtime delegate explicitly returns failure for platform information.
Opening Dark Reader's own settings tab loads its HTML and CSS, but it stays
at “Loading, please wait.” The shipped UI waits for `connector.getData()`;
its worker throws at `chrome.tabs.onRemoved.addListener` in
`TabManager.init()`, before `Extension.init()` constructs `startBarrier`.
Later requests cannot collect settings; `collectData()` also calls
`chrome.extension.isAllowedFileSchemeAccess`. The periodic platform query
fails independently. The current IPA lacks `storage.sync`, which Dark Reader
also calls when migrating its settings. This supports fixing shared APIs
before expecting the unchanged Store package to complete startup.

## Blink inspection

The inspected IPA contains Blink, V8, and Content inspection agents and the
element highlighting overlay. It lacks a DevTools frontend and has no wired
Chrome DevTools Protocol (CDP) listener. The new graph already lists the
HTTP and pipe handler objects as link inputs; that does not establish that
a handler is reachable in a shipped binary. The iOS `chrome://inspect` JavaScript
console and Safari's WebKit inspector are different tools; neither is desktop
DevTools for Blink. The smallest useful follow-up is an opt-in simulator build
that attaches desktop DevTools over loopback and lists real Blink tab targets.
Keep the listener off in release builds. None of the three packages declares a
`devtools_page`; inspection is independent of extension compatibility.

## GitHub evidence

[Run 44305429827](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44305429827)
applied `0041` and `0076`–`0079`, passed the codegen graph contract, and
uploaded the graph report. All 64 selected object targets exist. Tracing the
uploaded graph identifies `composebox_view_controller.o` as the only selected
root that reaches forbidden producers: its order-only `ui.harddeps` edge
reaches the Swift-generated `util_swift.h`. Leave Composebox out of the
Linux-only extension probe; verify it with the ordinary compile stage after
Apple outputs are restored. Keep the Apple-edge guard. The probe stopped
before compilation, so neither the new objects nor a combined IPA were tested.

The framework link graph already lists `scripting_api.o`, `user_scripts_api.o`,
and `offscreen_api.o`. The question is which APIs and delegates are reachable
and behave correctly in the iOS embedder, not whether to add those files to GN.

The narrow probe fix at `145be9b` removes Composebox from the selected objects
and retains the Apple-edge guard. Replaying that guard against the saved
graph verified exactly 63 device objects and no Apple or undeclared device
work. [Run 44310667836](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44310667836)
compares against the same graph and runs the object probe without linking an IPA.
It kept the graph unchanged and compiled with 831 cache hits out of 840
cacheable calls. Its only compiler error was the obsolete two-argument
`ManagementPolicy::UserMayLoad` call in `0076`. Commit `70b70f0` fixes
the call while keeping the policy check. The repeated
[object probe](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44317105924)
passed at that commit. It did not link or package an IPA.

Commit `576302c` adds real iOS platform metadata plus tab queries, lookup, and
close notifications from the profile's existing browser/tab model.
[Run 44321871634](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44321871634)
passed the 64-object dependency guard. The Tabs and Runtime objects compiled,
but the feature and schema generators rejected a missing release channel and
an inline enum. Commit `8d65227` corrected both and passed the pinned
generators; [run 44324717645](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44324717645)
verifies that revision, including the read-only file-access setting and
quota-enforced, on-device storage for the `sync` namespace.
Both generators passed remotely. The storage wiring then needed a direct
`ValueStoreFactory` include, fixed in `7b348cb`.

Dark Reader calls `action.setIcon` before resolving its startup barrier.
It uses relative paths inside the extension package. Tab-to-script messaging
must also preserve the originating tab, document, and frame. Commit
`7b348cb` reuses Chromium's action state and renderer messaging delegate.
[Run 44326969228](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44326969228)
passed 67 device objects and reused 838 of 847 cacheable compiler calls.
Commit `1f76114` connects `scripting.executeScript` to the real iOS tab and
sends the frame a tab ID at creation. The
[IPA build](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44328959472)
checks that final integration. Runtime verification is still required before
advancing to per-page UI.

The IPA build completed and produced Actions artifact `14443178991`
(device IPA SHA-256
`b34c8abc851a36e05f9a171c2bf73469f168d4b2eb1cdcc8ff3761f8e5973c88`).
An update of the disposable Duo test app on iOS 27.1 retained Dark Reader
4.9.135 and its enabled state. **Manage → Options** rendered its controls
instead of the loading screen. After a reload, a controlled white page in
Light appearance reported `rgb(24, 26, 27)` and one dynamic style. An
initial restored navigation did not darken; first-load ordering, uBlock
coexistence, and per-site settings are separate checks. The session also
reported the missing `chrome.action.setBadgeText` method.
