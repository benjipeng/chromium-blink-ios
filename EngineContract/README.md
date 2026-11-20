# Curium Engine Contract

This Clang module is the Objective-C boundary between Curium
(`com.appautomaton.curium`) and its embedded Blink engine. Add this directory to
the module search path and use `import CuriumEngineContract` in Swift or
`@import CuriumEngineContract;` in Objective-C. In Objective-C++, enable
`-fcxx-modules` for `@import`, or include `CuriumEngineContract.h` directly.
The module contains declarations; `chrome_framework` supplies the implementations.

On the main thread, register the shell bootstrap delegate before calling
`ChromeMain`. The bootstrap class retains the registration until replacement or
explicit clearing. The engine calls the delegate for each scene that needs a
root controller, supplying its browser host and, when available, an extension
manager. In standalone previews where the framework may not export
`CrIOSEngineBootstrap`, resolve it with `NSClassFromString("CrIOSEngineBootstrap")`
and dispatch dynamically only if present. A direct class reference needs the
framework export, an appropriate weak link, or a preview stub.

The engine owns browser state and creates the views exposed by tab and popup
hosts. The shell owns its root controller, attaches and detaches those views,
and retains the browser host's weak delegate for as long as it needs updates.
Treat the tab list as a snapshot and re-read it on a list update. A tab's string
ID identifies it in the browser host; only its assigned numeric extension tab
ID belongs in per-tab extension calls. After a tab closes, discard its tab
reference and view.

Call the contract and deliver UI delegate callbacks, completions, and observer
notifications on the main thread. New UI declarations and blocks import with
Swift main actor isolation. The legacy extension declarations preserve their
existing Swift import signatures; call them on the main actor too. Completions
for a single request must be called once, including when an accepted request is
cancelled.

The shell and Blink run in one process and share the engine's regular browsing
context. V1 does not expose an off-the-record (Incognito) context. The tab's
`webView` is the live engine view. When using the optional compositor controls
on a tab, give `webView` its full viewport, leave `scrollView.contentInset.top`
at zero, and set `topControlsHeight` to the full address bar band in points.
Keep that height fixed while scrolling. Observe `topControlsShownRatio` via
KVO on the main thread to morph the shell's chrome; the engine moves the page.
A height of zero disables the band. These selectors are additive to V1. In
Swift, conditionally cast the tab to `CrIOSTabBrowserControlsV1` to read and
write the properties. Objective-C callers on `CrIOSTabHostingV1` can probe
the two getters and the height setter. For an older engine, the tab's
`scrollView.contentInset` remains available for static chrome insets.

Record history from the optional navigation-commit callback rather than from
tab updates, which are coalesced. It reports each main-frame commit once, after
it happens, and excludes error pages. Same-document commits cover fragment and
History API changes; `isReload` marks reloads, including script reloads.

Probe each optional extension selector before calling it. Use the module or
the legacy helper header as the declaration source in a given translation unit.
For new extension queries with an error out parameter, a nil return indicates
failure; use an empty collection or a zero count for a successful empty result.

| Result | Values |
| --- | --- |
| Action presentation | Immutable dictionary. `isEnabled` and `hasPopup` are boolean `NSNumber` values. Optional keys: `title` and `badgeText` (`NSString`), `icon` (`UIImage`), and `badgeBackgroundColor` (`UIColor`). An absent or empty badge text means no badge. |
| DNR block count | `NSNumber` holding a nonnegative count for the extension and tab. |
| Commands | Array of string dictionaries with `name`, `description`, and `shortcut`. An empty shortcut means no binding. Pass the name to the command dispatcher. |

Retain an action observation token to receive updates; release it on the main
thread to end observation. A nil ID in a notification means re-read all
snapshots. The shell retains a popup while it is presented. When dismissing it,
including in response to `onRequestClose`, clear the handler, detach the view,
and call `close`.
