# iPhone Duo Layout & UIKit Reference for Chromium on iOS

**Scope & Verification Policy:** Every rule in this document cites its source URL. Rules backed by Apple documentation, Human Interface Guidelines (HIG), release notes, Tech Talks (`111461`–`111466`), or Apple Staff replies on Apple Developer Forums are unmarked or cited directly. Measurements derived from Xcode Simulator inspection or developer reports not published in an Apple specification table are explicitly tagged **[third-party]** or **[developer-report]**. Items Apple has not documented (such as exact screen corner radii in points or system virtual keyboard point dimensions) are explicitly marked **[unverified / undocumented by Apple]**.

---

## 1. Display Geometry, Postures, Reserved Regions & Corner Radii

### 1.1 Hardware & Logical Display Dimensions

| Display & Posture | Physical Pixels (Apple Specs) | Screenshot / Render Pixels (Apple ASC) | Logical Size (Points) | Scale Factor | Source & Attribution |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Outer (5.4" / 5.36" rect), Closed Portrait** | `1398 × 2034` px (460 ppi) | `1398 × 2034` px | `466 × 678` pt | `@3x` | [Apple iPhone Duo Specs](https://www.apple.com/iphone-duo/specs/), [App Store Connect Screenshot Specs](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications); `466×678` pt confirmed in [Apple Forums Camera Q&A](https://developer.apple.com/forums/activities/1659080) and **[third-party]** [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/) |
| **Outer, Closed Landscape (e.g., Tent)** | `2034 × 1398` px | `2034 × 1398` px | `678 × 466` pt | `@3x` | [App Store Connect Screenshot Specs](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications); points derived / **[third-party]** [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/) |
| **Inner (7.6" / 7.58" rect), Open Portrait** | `1878 × 2670` px (430 ppi) | `2007 × 2853` px | `669 × 951` pt | `@3x` render (downsampled ~`2.81x` to panel) | [Apple iPhone Duo Specs](https://www.apple.com/iphone-duo/specs/), [App Store Connect Screenshot Specs](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications); `669×951` pt in **[developer-report]** [Apple Forums SwiftUI Q&A](https://developer.apple.com/forums/activities/1664080) & **[third-party]** [iOS Ref](https://iosref.com/res), [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/) |
| **Inner, Open Flat / Book Landscape** | `2670 × 1878` px | `2853 × 2007` px | `951 × 669` pt | `@3x` render (downsampled ~`2.81x`) | [App Store Connect Screenshot Specs](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications); `951×669` pt in **[developer-report]** [Apple Forums UIKit Q&A](https://developer.apple.com/forums/activities/1670080) & **[third-party]** [skarol.dev](https://skarol.dev/posts/getting-your-app-ready-for-iphone-duo/) |
| **Inner, 50/50 Split View Pane (Landscape)** | — | — | ~`469` pt wide per half | `@3x` | **[third-party]** [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/) |

**Enclosure physical dimensions:** `84.1 × 117.8 × 11.3 mm` closed; `164.6 × 117.8 × 5.2 mm` open ([Apple iPhone Duo Specs](https://www.apple.com/iphone-duo/specs/)).

### 1.2 Simulator-Measured Safe Area, Bar & Fold Dimensions

Apple does not publish a numeric point table for safe areas or bar widths in HIG Layout ([HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)). The following point measurements come from Xcode 27.1 / iOS 27.1 Simulator reports:

- **Vertical bar safe-area inset (outer display & inner landscape):** `84 pt` along the vertical bar edge (`x = 84` when `verticalBarEdge == .leading`; `83 pt` visible strip on outer display) (**[developer-report]** [Apple Forums UIKit Q&A](https://developer.apple.com/forums/activities/1670080); **[third-party]** [skarol.dev](https://skarol.dev/posts/getting-your-app-ready-for-iphone-duo/), [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/)).
- **Top camera / status band inset when vertical bar is disabled (`preferredVerticalBarBehavior = .disabled`):** `82 pt` top inset (**[developer-report]** [Apple Forums SwiftUI Q&A](https://developer.apple.com/forums/activities/1664080); **[third-party]** [skarol.dev](https://skarol.dev/posts/getting-your-app-ready-for-iphone-duo/), [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/)).
- **Home indicator bottom inset:** `34 pt`, leaving `669 × 917 pt` usable in inner portrait and `951 × 635 pt` usable in inner landscape (**[third-party]** [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/)).
- **Fold / hinge division (`UIView.ReservedRegion.Kind.division`):** `40 pt` band across the center when partially folded: `x = 455.5..495.5 pt` in `951 × 669 pt` landscape (splitting into two `455.5 pt` halves) and `y = 455.5..495.5 pt` in `669 × 951 pt` portrait (**[developer-report]** [Apple Forums UIKit Q&A](https://developer.apple.com/forums/activities/1670080); **[third-party]** [Chonky Corgo](https://getchonky.app/blog/iphone-duo-screen-sizes/)).

### 1.3 Device Postures

- **Closed:** Uses the outer display (`5.4"`) in portrait or landscape (including tent stand) ([HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).
- **Open flat:** Uses the full inner display (`7.6"`). The fold `.division` reserved region is **inactive** (`width == 0`) ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/), [UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
- **Partially folded:**
  - **Book pose (landscape/horizontal):** Fold runs vertically through the center; content splits left/right ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion), [Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
  - **Laptop / tabletop pose (portrait/vertical):** Fold runs horizontally through the center; top region suits passive/viewable content and bottom region provides a stable surface for interactive touch controls ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion), [Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).
  - Touch input does not work on both displays simultaneously during L-shaped partial folds (**[third-party Group Lab notes]** [Anton Gubarenko Substack](https://antongubarenko.substack.com/p/iphone-duo-group-lab-2-q-and-a)).

### 1.4 Reserved Regions & Hinge APIs

- **`UIView.ReservedRegion` (`iOS 27.1+`):** Represents hardware-reserved areas in a view's coordinate space in points ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)):
  - Properties: `frame: CGRect` (already includes `margins`, in view coordinates; may start negative or extend beyond `bounds` on partial overlap), `margins: UIEdgeInsets`, `isActive: Bool`, `kind: UIView.ReservedRegion.Kind`.
  - Kinds (`UIView.ReservedRegion.Kind`):
    1. `.occlusion`: Areas covering content — **outer front-facing camera** (corner, expands vertically into Dynamic Island for Live Activities; **always active**), **inner front-facing camera** (under-display; hidden and **inactive** when not in use, **active** when camera activates) ([HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
    2. `.division`: Areas splitting a view, i.e., the **fold/hinge** of iPhone Duo. Active when partially folded (or closed per docs) and inactive when flat ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion), [Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
  - Query method: `view.reservedRegions(kind:options:)` (`UIView.ReservedRegion.QueryOptions`, pass `.includeInactive` to inspect inactive regions such as the flat fold or inactive inner camera so layouts do not jump when activated). Calling inside `UIView.updateConstraints()` registers automatic UIKit tracking and re-runs `updateConstraints()` when region activity or frames change ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
- **`UIHingeInteraction` & `UIHinge` (`iOS 27.1+`):**
  - `UIHingeInteraction(updateHandler:)` attaches via `view.addInteraction(_:)`. Delivers `UIHingeInteraction.Update` with `hinge: UIHinge?` (`nil` when leaving a hinge-capable hierarchy) ([UIHingeInteraction](https://developer.apple.com/documentation/uikit/uihingeinteraction)).
  - `UIHinge` exposes `angle: CGFloat` (in radians; `0` shut to `π` open per **[developer-report]** [Apple Forums UIKit Q&A](https://developer.apple.com/forums/activities/1670080)) and `status: UIHinge.Status` (`.closed`, `.partiallyOpen`, `.fullyOpen`, `.unknown`) ([UIHinge](https://developer.apple.com/documentation/uikit/uihinge), [UIKit updates](https://developer.apple.com/documentation/updates/uikit)).
  - **Rule:** Use `UIHingeInteraction` only for live interactive effects/animations — **never** for layout; use `UIArrangementViewController` or `UIView.ReservedRegion` for layout ([Tech Talk 111464](https://developer.apple.com/videos/play/tech-talks/111464/)).

### 1.5 Corner Radii & Concentricity

- **[Unverified numeric values]:** Apple does not publish numeric screen corner-radius values in points for iPhone Duo ([Apple iPhone Duo Specs](https://www.apple.com/iphone-duo/specs/)).
- Outer screen corners are asymmetric — rounded on outer edges and sharper on hinge-side corners (**[third-party]** [iPhone Duo Support Specs](https://iphoneduosupport.com/specs/), **[third-party Group Lab notes]** [Anton Gubarenko Substack](https://antongubarenko.substack.com/p/iphone-duo-group-lab-2-q-and-a)).
- **Required APIs:** Use `UICornerConfiguration` (`view.cornerConfiguration = .corners(radius: .containerConcentric())`, `effectiveRadius(corner:)`, `iOS 26.0+`) in UIKit (or `ConcentricRectangle` in SwiftUI), which Apple updated for iPhone Duo's asymmetric screen shapes ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [UICornerConfiguration](https://developer.apple.com/documentation/uikit/uicornerconfiguration-swift.struct)). For edge-to-edge layouts selectively adapting around hardware cutouts/corners without full safe-area insets, use `UIView.LayoutRegion` (`safeArea(cornerAdaptation:)`, `margins(cornerAdaptation:)`, `readableContent(cornerAdaptation:)`) ([UIView.LayoutRegion](https://developer.apple.com/documentation/uikit/uiview/layoutregion)).

---

## 2. Size Classes, Traits, Orientation, and Change Triggers

### 2.1 Size Class & Idiom Matrix

| Context | `horizontalSizeClass` | `verticalSizeClass` | `userInterfaceIdiom` | `supportedInterfaceOrientations` | Source |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Outer Display (Portrait)** | `.compact` | `.regular` | `.phone` | Honored | [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/) |
| **Outer Display (Landscape)** | `.compact` | `.compact` | `.phone` | Honored | [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/) |
| **Inner Display (Full Screen, Any Orientation)** | `.regular` | `.regular` | `.phone` | **Ignored** (rotates/scales freely) | [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo) |
| **Inner Display (50/50 Split View)** | `.compact` **[third-party]** | `.regular` **[third-party]** | `.phone` | **Ignored** (scales in Split View) | [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/); compact width in Split View reported **[third-party]** [TO THE NEW](https://www.tothenew.com/blog/every-iphone-duo-state-your-video-player-must-handle/), [daily.dev](https://daily.dev/posts/size-classes-on-iphone-duo-lxugngafr) |

### 2.2 Prohibitions & Required Layout Signals

- **Never use `userInterfaceIdiom` for layout:** `userInterfaceIdiom` remains `.phone` on the inner display, and `horizontalSizeClass == .regular` no longer implies iPad ([Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Apple Forums Thread 847903](https://developer.apple.com/forums/thread/847903)).
- **Never use orientation APIs for layout:** Remove layout branches on `UIDevice.current.orientation`, `statusBarOrientation`, `interfaceOrientation`, and `windowScene.effectiveGeometry.interfaceOrientation`. Compare `view.bounds.width` vs `view.bounds.height` (or `superview.bounds`) instead ([Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).
- **Never use `UIScreen.main`:** `UIScreen.main` is ambiguous across dual displays and slated for future deprecation. Create windows via `UIWindow(windowScene:)`, size from `view.bounds` or `window.bounds`, read scale from `traitCollection.displayScale`, and access the active screen dynamically via `view.window?.windowScene?.screen` ([Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).
- **`UIRequiresFullScreen`:** Honored as a preference on iPhone Duo, but the app **still resizes** when opening or closing the device ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).

### 2.3 Vertical Bar Edge Trait & Change Triggers

- **`UITraitCollection.verticalBarEdge` (`UIVerticalBarEdge`, `iOS 27.1+`):** Returns `.leading`, `.trailing`, or `.unspecified`. Reflects the system's preferred vertical bar edge regardless of whether a system vertical bar is currently visible; returns `.unspecified` where no vertical bar is used (e.g., inner portrait) ([verticalBarEdge](https://developer.apple.com/documentation/uikit/uitraitcollection/verticalbaredge), [UIVerticalBarEdge](https://developer.apple.com/documentation/uikit/uiverticalbaredge)).
- **What triggers layout/trait updates:**
  - Opening/closing the device, rotating, entering/exiting or dragging sides in Split View, pinning PiP, or activating/deactivating the inner camera or hinge fold.
  - Hook into:
    - `UIView.layoutSubviews()` / `UIViewController.viewDidLayoutSubviews()` (supports UIKit automatic trait tracking, including `verticalBarEdge` and `horizontalSizeClass` / `verticalSizeClass`) ([Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [UIKit updates](https://developer.apple.com/documentation/updates/uikit)).
    - `registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge, ...)` and `UITraitHorizontalSizeClass.self` / `UITraitVerticalSizeClass.self` ([UIKit updates](https://developer.apple.com/documentation/updates/uikit)).
    - `UIViewController.viewWillTransition(to:with:)` and `viewSafeAreaInsetsDidChange()` ([Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), **[third-party]** [skarol.dev](https://skarol.dev/posts/getting-your-app-ready-for-iphone-duo/)).
    - `UIView.updateConstraints()` for `reservedRegions(kind:options:)` ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
- **Asymmetric safe areas & margins:** Never mirror left/right `safeAreaInsets` or `layoutMargins`; inspect all four sides independently ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).

---

## 3. Toolbars, Navigation Bars, Tab Bars, and Custom Bars

### 3.1 Horizontal vs. Vertical Placement Rules

| Context | Bar Axis | Vertical Bar Edge | Notes | Source |
| :--- | :--- | :--- | :--- | :--- |
| **Outer display (closed, portrait & landscape)** | **Vertical** | Hardware camera side (`.trailing` in LTR; stays on same physical edge in RTL) | Maximizes vertical content height | [HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |
| **Inner display — Landscape** | **Vertical** | `.trailing` (full screen) | Preserves continuity with outer display | [HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |
| **Inner display — Portrait** | **Horizontal** | `.unspecified` | Sufficient vertical height for standard top/bottom bars | [HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |
| **Inner display — Split View (2 apps)** | **Vertical** (landscape) | Outer screen edge (`.leading` for left app, `.trailing` for right app) | Keeps controls away from center split and within thumb reach | [HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/) |
| **Split View Controller (`UISplitViewController`)** | Sidebar & content: **Horizontal**; Detail: **Vertical** | Display outer edge (detail column only) | Only containers touching the display edge go vertical | [Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |
| **Inspectors** | **Horizontal** | N/A | Prevents two adjacent vertical bars | [Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |
| **Sheets (`UISheetPresentationController`)** | Outer: **Vertical** (default); Inner: **Horizontal** (`.center`/`.leading`), **Vertical** (`.trailing`) | Edge-aligned | Can opt out per sheet VC with `preferredVerticalBarBehavior = .disabled` | [Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |

**RTL invariant:** Because vertical controls align with physical hardware (camera/outer edge), they **do not flip** in right-to-left languages ([HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).

### 3.2 Ordering Relative to the Status Bar Pill, Dynamic Island & Camera

- **Shared vertical region:** On the vertical axis, the Dynamic Island (which expands vertically for Live Activities), status bar, camera occlusion, navigation bar items, toolbar items, and tab bar share one edge strip outside `safeAreaInsets` ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).
- **Top-to-bottom placement order below status bar / camera:**
  1. Primary navigation (`Back` added automatically by `UINavigationController`; custom `Back`/`Close` via `UINavigationItem.leadingItemGroups` with `leftItemsSupplementBackButton = false`, the default) ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  2. Prominent actions (e.g., `Done`) via `UINavigationItem.pinnedTrailingGroup` ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/), [Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)).
  3. Remaining top navigation bar groups, followed by an automatic vertical gap separating top-bar items from bottom-toolbar items ([HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  4. Bottom toolbar items (grouped via `UIBarButtonItemGroup`; avoid manual fixed spacers; flexible spacers collapse to `0` on the vertical axis while fixed spacers keep minimum size) ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  5. Tab bar, bottom-aligned at the foot of the vertical stack ([Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).

### 3.3 Item Representations, Axis Behavior, Compression & Overflow

- **Container requirement:** System vertical bars only host items from `UINavigationController` / `UITabBarController`. Standalone `UIToolbar`, `UINavigationBar`, or `UITabBar` views are ignored for vertical bar placement ([Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
- **Icon + title:** Always set **both** an icon (SF Symbol) and a title on every `UIBarButtonItem`. Vertical bars have a fixed width and flexible height, so they render icons only; horizontal bars prefer icons (or text if no icon); overflow menus render both icon and title ([Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)). Use `UIBarButtonItem.badge` (`iOS 26+`) rather than inline counts so items stay symbol-only ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
- **`UIBarButtonItem.axisBehavior` (`UIBarButtonItem.AxisBehavior`, `iOS 27.1+`):**
  - `.automatic`: System infers axis (icon items go vertical; text-only, segmented controls, and custom views stay horizontal) ([UIBarButtonItem.AxisBehavior](https://developer.apple.com/documentation/uikit/uibarbuttonitem/axisbehavior-swift.enum), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - `.horizontalOnly`: Item only appears in horizontal bars; **hidden completely** if no horizontal bar is present (use for items transitioning between text and symbol, or wide controls carrying standalone text like prices) ([UIBarButtonItem.AxisBehavior](https://developer.apple.com/documentation/uikit/uibarbuttonitem/axisbehavior-swift.enum), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - `.verticalPreferred`: Allows a custom view to move into the vertical bar; the custom view should read `traitCollection.verticalBarEdge` to adapt to the vertical bar's fixed width ([UIBarButtonItem.AxisBehavior](https://developer.apple.com/documentation/uikit/uibarbuttonitem/axisbehavior-swift.enum), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
- **Compression (`UINavigationItem.verticalBarCompressionBehavior`: `UIVerticalBarCompressionBehavior`, `iOS 27.1+`):**
  - `.automatic` / `.prefersTabBar` (default for navigation-focused UIs): toolbar items overflow first so primary tab destinations stay visible ([UIVerticalBarCompressionBehavior](https://developer.apple.com/documentation/uikit/uiverticalbarcompressionbehavior), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - `.prefersBarItems`: minimizes the tab bar first so task toolbar actions stay visible ([UIVerticalBarCompressionBehavior](https://developer.apple.com/documentation/uikit/uiverticalbarcompressionbehavior), [HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)).
- **Overflow (`UIBarButtonItem.visibilityPriority` & `UINavigationItem.additionalOverflowItems`):**
  - Items overflow **bottom-to-top** by default ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - Assign `UIBarButtonItemVisibilityPriority` (`.high`, `.standard`, `.low`, custom) on groups first, then individual items ([UIBarButtonItemVisibilityPriority](https://developer.apple.com/documentation/uikit/uibarbuttonitemvisibilitypriority), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - Consolidate app overflow actions into `UINavigationItem.additionalOverflowItems` (`UIDeferredMenuElement`). Reserve the ellipsis (`...`) symbol exclusively for the system overflow menu; give any other menus distinct symbols ([HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
- **Tab bar sidebar on inner display:** Use `UITabBarController.mode = .tabSidebar` (`UITab.preferredPlacement`) when a richer navigation sidebar makes sense on the regular-width inner display ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [UIKit updates](https://developer.apple.com/documentation/updates/uikit)).
- **Opting out (`UIViewController.preferredVerticalBarBehavior`, `iOS 27.1+`):** Override to return `.disabled` (`UIVerticalBarBehavior.disabled`, with `childForPreferredVerticalBarBehavior` and `setNeedsUpdateOfVerticalBarConfiguration()`) **only** for stable non-scrolling/bottom-heavy layouts (e.g., Calculator), fullscreen video players, or single-action sheets ([preferredVerticalBarBehavior](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferredverticalbarbehavior), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)). Never toggle it dynamically per view state. Note: hiding the status bar (`prefersStatusBarHidden`) does **not** remove the `84 pt` side safe-area reservation (**[third-party]** [skarol.dev](https://skarol.dev/posts/getting-your-app-ready-for-iphone-duo/)).
- **Visuals under vertical bars:** Vertical bars have no scroll-edge blur/fade by default (they gain a background only when Reduce Transparency is enabled); extend full-bleed background artwork under them using `UIBackgroundExtensionView` ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/), [Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)).

### 3.4 Rules for Custom Bars (Applicable to Chromium Browser Chrome)

Because Chromium renders custom toolbars, omnibox, and tab strips rather than `UINavigationController`/`UITabBarController` bars:
1. Custom `UIToolbar`/`UINavigationBar`/`UITabBar` or `UIView` bars are **not** automatically moved into the system vertical bar ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
2. Custom bars that extend toward display edges **must** query `view.reservedRegions(kind: .occlusion)` inside `updateConstraints()` and keep interactive controls outside `region.frame` (which already includes protective `margins`) so controls never collide with the outer camera / Dynamic Island or an active inner camera ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).
3. Custom bars that span the inner display **must** also query `view.reservedRegions(kind: .division)` (or host dual panels in `UIArrangementViewController`) so interactive buttons never land in the `40 pt` fold ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
4. Custom layouts must respect asymmetric `safeAreaInsets` / `safeAreaLayoutGuide` (which include the `84 pt` side inset when `verticalBarEdge != .unspecified` and `82 pt` top inset when vertical bar is disabled) and observe `traitCollection.verticalBarEdge` via `UITraitCollection.systemTraitsAffectingVerticalBarEdge` ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [verticalBarEdge](https://developer.apple.com/documentation/uikit/uitraitcollection/verticalbaredge)).
5. UIKit provides `UIView.LayoutRegion.bar(onEdge:extent:)` (`directionalEdgeInsets(for:)`, `layoutGuide(for:)`) for reserving/querying custom bar regions along specific edges ([UIView.LayoutRegion](https://developer.apple.com/documentation/uikit/uiview/layoutregion), [UIKit updates](https://developer.apple.com/documentation/updates/uikit)).
6. Keep keyboard accessory bars anchored to the keyboard, never moved to the vertical axis ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).

---

## 4. Menus, Popovers, Sheets, Alerts, and Keyboard on the Inner Display

### 4.1 Menus, Context Menus, Popovers, and Alerts

- **Automatic pose & fold adaptation:** System `UIAlertController`, `UIMenu` / `UIContextMenuInteraction`, action sheets, and `UIPopoverPresentationController` automatically adapt to every pose and displace away from active reserved regions (fold and camera) so they remain fully visible and tappable ([HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).
- **Coupled displacement:** In book pose, alerts move to the trailing half for continuity with the outer display; in tabletop pose, alerts can move to the top half while interactive controls move to the bottom half. Context menus move together with their anchor element so their visual relationship is preserved ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
- **Custom overflow / popovers:** Any custom floating popover or omnibox dropdown not managed by `UIPopoverPresentationController` will **not** auto-displace and must manually query `reservedRegions(kind: .division)` and `.occlusion` ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
- **Menu icons (iOS 27.0+):** Control menu element icon visibility via `UIMenuElement.preferredImageVisibility` ([iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).

### 4.2 Sheets (`UISheetPresentationController`)

- **Outer display:** Edge-attached; bars inside the sheet present vertically by default. Setting `preferredVerticalBarBehavior = .disabled` keeps bars horizontal and stops the sheet short of the outer front camera ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).
- **Inner display:** **Centered** by default (`UISheetPresentationController.preferredPlacement` with `UISheetPresentationController.Placement`: `.automatic`, `.center`, `.leading`, `.trailing`, `iOS 27.0+`) ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [preferredPlacement](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller/preferredplacement)).
- **Sheet bar axis on inner display:** Toolbars are **horizontal** for `.center` and `.leading` placements, and **vertical** for `.trailing` placement ([Preparing your app](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
- **Fold avoidance:** When partially folded, sheets automatically slide/nudge to avoid straddling the fold ([Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/), [UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).

### 4.3 Keyboard on the Inner Display

- **[Unverified exact keyboard point dimensions]:** Apple does not publish virtual keyboard width/height point dimensions or a dedicated iPhone Duo section in [HIG: Virtual keyboards](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards).
- **Documented system behaviors:**
  - Keyboard appearance on shorter heights (e.g., outer landscape) triggers vertical bar overflow compression ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - Keyboard accessory bars must stay attached to the keyboard and must not move to the vertical bar ([Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/)).
  - Focused search interfaces sit above the keyboard, expanding to take advantage of inner-display width when open and resizing/repositioning over the searched view when folded ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
  - Closing the device during active typing preserves the active text session, keyboard, and scene onto the outer display ([Apple Forums UI Frameworks](https://developer.apple.com/forums/topics/ui-frameworks-topic?sortBy=newest)).
- **Reported pitfalls on inner display & extensions:**
  - **[developer-report]** For inset/centered sheets on the inner display, `UIResponder.keyboardFrameEndUserInfoKey` in screen coordinates does not align with the sheet's container bounds; use `view.keyboardLayoutGuide` or convert frames carefully and test explicitly ([Apple Forums Thread 847946](https://developer.apple.com/forums/thread/847946)).
  - **[developer-report]** In Xcode 27.1 RC, native keyboard Globe/Dictation keys render as standard keys, and `reservedRegions` / `safeAreaInsets` did not report into custom keyboard extensions in beta (`FB24979539`, `FB24979367`) ([Apple Forums Thread 847963](https://developer.apple.com/forums/thread/847963)).

---

## 5. The Fold / Division Region: Content, Column & Straddling Rules

- **What must NOT straddle the fold:**
  - Interactive buttons, toolbars, custom floating overlays, purchase/action controls, alerts, sheets, popovers, context menus, and paired two-view splits must never span the `.division` region ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion), [Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).
  - Static images or media that would distort across the crease should not span the fold ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
- **What MAY span the fold:**
  - Continuous **scrolling** content (articles, web pages, feeds, documents, lists) does **not** displace around the fold, as scrolling adapts naturally and displacing feeds disrupts continuity ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)). Note: `UIScrollView`, `UITableView`, and `UICollectionView` do not split items around `.division` automatically; if an interactive card/row lands across the fold and becomes hard to tap, handle `.division` manually ([UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
- **Column & grid rules:**
  - Use an **even number of columns** in grids and multi-column layouts (e.g., tab grids, NTP shortcuts) so columns divide cleanly on either side of the center hinge ([HIG: Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).
  - Preserve outer margins while increasing center inter-column spacing to clear `.division` when folded ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)). Query `reservedRegions(kind: .division, options: .includeInactive)` to choose even column counts proactively even while flat ([Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
- **System containers & `UIArrangementViewController` (`iOS 27.1+`):**
  - `UISplitViewController` automatically adjusts column widths (e.g., 50/50 split) and margins around the fold ([HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111463](https://developer.apple.com/videos/play/tech-talks/111463/)).
  - Use `UIArrangementViewController` for two-view relationships ([UIArrangementViewController](https://developer.apple.com/documentation/uikit/uiarrangementviewcontroller)):
    - `UISplitArrangement`: places `.primary` and `.secondary` side-by-side in landscape or top/bottom in portrait, keeping both clear of `.division`; on closed landscape outer display, shows `.primary` only; supports `UISplitArrangement.DimensionRange` (`.absolute`, `.fractional`, `.automatic`, `.intrinsic`) and `.axes(_:)` ([UISplitArrangement](https://developer.apple.com/documentation/uikit/uisplitarrangement-swift.struct)).
    - `UIOverlayArrangement`: layers `.primary` over `.secondary` in z-axis when flat, and splits them across the fold when partially folded (`.secondary` leading/top, `.primary` trailing/bottom) ([UIArrangementViewController](https://developer.apple.com/documentation/uikit/uiarrangementviewcontroller)).
  - **Nesting constraint:** Never place `UIArrangementViewController` inside a scroll view, collection view, `UISplitViewController`, or `UITabBarController`; never place `UISplitViewController` or `UITabBarController` inside `UIArrangementViewController` ([UIArrangementViewController](https://developer.apple.com/documentation/uikit/uiarrangementviewcontroller)).
- **Minimal movement rule:** Avoid drastic layout churn when folding; shift only what is necessary to stay visible and tappable ([HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [UIView.ReservedRegion](https://developer.apple.com/documentation/uikit/uiview/reservedregion)).

---

## 6. Multitasking & Split View on iPhone Duo

- **Side-by-side Split View:** All apps participate in 50/50 side-by-side Split View multitasking on the inner display (initiated by dragging the home indicator to the left or right edge) ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [Tech Talk 111464](https://developer.apple.com/videos/play/tech-talks/111464/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)). Stage Manager is not supported on iPhone Duo (**[third-party Group Lab notes]** [Anton Gubarenko Substack](https://antongubarenko.substack.com/p/iphone-duo-group-lab-2-q-and-a)).
- **Vertical bar edge in Split View:** The left app's vertical controls sit on its `.leading` edge; the right app's vertical controls sit on its `.trailing` edge ([HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)). Apps must test both sides in Device Hub because `safeAreaInsets` flip asymmetry ([Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/)).
- **Top-pinned Picture-in-Picture:** Video in PiP can pin to the top half of the inner display (expanding to half-screen when folded), resizing the active app vertically beneath it ([Tech Talk 111464](https://developer.apple.com/videos/play/tech-talks/111464/), [Tech Talk 111466](https://developer.apple.com/videos/play/tech-talks/111466/)).
- **Multiple windows / scenes (`UIApplicationSupportsMultipleScenes`):**
  - iPhone Duo is the first iPhone supporting multiple instances of an app's UI in Split View on the **inner display**. New windows **cannot** be created on the **outer display** ([Tech Talk 111464](https://developer.apple.com/videos/play/tech-talks/111464/)).
  - Use `UIWindowSceneActivationAction` (automatically hides when multi-window is unavailable) and handle scene-request errors ([Tech Talk 111464](https://developer.apple.com/videos/play/tech-talks/111464/)).
  - **Known platform limitation:** `UIApplication.requestSceneSessionDestruction(_:options:errorHandler:)` has been reported to fail on iPhone Duo with `"This functionality is not supported for this device idiom."` (`FB25353479`, Xcode 27), with an Apple DTS engineer noting iPhone Duo runs iOS rather than iPadOS ([Apple Forums Thread 853973](https://developer.apple.com/forums/thread/853973)).
  - **Closing while in Split View:** The active app transitions to the outer display while the second app suspends (**[third-party Group Lab notes]** [Anton Gubarenko Substack](https://antongubarenko.substack.com/p/iphone-duo-group-lab-2-q-and-a)).
- **Dual-display simultaneous scenes restricted:** Showing UI on both outer and inner displays simultaneously is restricted exclusively to active camera apps via `UISceneAccessory.cameraCapture(sceneConfiguration:)` (`CameraCaptureAccessory` / `windowCameraCaptureAccessory`) ([Tech Talk 111464](https://developer.apple.com/videos/play/tech-talks/111464/), [Apple Forums Thread 847847](https://developer.apple.com/forums/thread/847847)).

---

## 7. Older SDK Compatibility & Linked-On-or-After Behaviors

### 7.1 SDK Build-Target Tiers on iPhone Duo

| Linked SDK | Outer Display Behavior | Inner Display Behavior | Vertical Bars & New APIs | Source |
| :--- | :--- | :--- | :--- | :--- |
| **iOS 26 SDK or earlier** | Confined to area left of status bar and camera | Letterboxed/centered at traditional iPhone size with empty surrounding space; does not dynamically resize across poses | Disabled | [Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/) |
| **iOS 27.0 SDK** | Left of status bar/camera | Resizes dynamically to fill most of inner display, stopping short of the right-edge status bar area | Bars stay horizontal; no iOS 27.1 APIs | [Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/) |
| **iOS 27.1 SDK or later (Xcode 27.1+)** | Full edge-to-edge display | Full edge-to-edge display | System bars lay out vertically below status bar (except inner portrait); full `iOS 27.1` APIs active | [Prepare - iPhone Duo](https://developer.apple.com/iphone-duo/prepare/), [Tech Talk 111461](https://developer.apple.com/videos/play/tech-talks/111461/), [Tech Talk 111462](https://developer.apple.com/videos/play/tech-talks/111462/) |

### 7.2 Linked-On-or-After Behavioral Changes (iOS 27.0 & 27.1+)

- **`UIView` default layout margins are zero (iOS 27.1+ SDK):** On iOS 27.1 and later, `UIView` default `layoutMargins` are `0`. A `UIViewController` still supplies `systemMinimumLayoutMargins` to its root view (which vary by presentation context). Subviews must set `preservesSuperviewLayoutMargins = true` to inherit them (`186294594`) ([iOS & iPadOS 27.2 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27_2-release-notes)).
- **Scene-based lifecycle mandatory (iOS 27.0+ SDK):** Apps built with the 27.0+ SDK without adopting `UIWindowScene` lifecycle **fail to launch** (`141837548`) ([UIKit updates](https://developer.apple.com/documentation/updates/uikit), [iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
- **Launch screen mandatory (iOS 27.0+ SDK):** `Info.plist` must include `UILaunchStoryboardName`, `UILaunchStoryboards`, `UILaunchScreen`, or `UILaunchScreens` (`168247372`) ([iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
- **Presented VC trait inheritance (iOS 27.0+ SDK):** Presented view controllers inherit `traitCollection` by walking up the view superview chain through intermediate presentation views rather than jumping directly to `UIPresentationController` (`170005251`) ([iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
- **Deprecated status bar accessors (iOS 27.0+ SDK):** `UIApplication.statusBarFrame`, `statusBarOrientation`, `statusBarStyle`, and `isStatusBarHidden` may return `NaN` or `null` (`162044221`) ([iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
- **Inline scope bar (iOS 27.0+ SDK):** `UISearchController` with center search-bar placement places its scope bar inline on the same row (`173860616`) ([iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
- **Navigation bar minimization rename (iOS 27.0+ SDK):** `UINavigationItem.navigationBarMinimization` replaces `barMinimizeBehavior` and `barMinimizationSafeAreaAdjustment` (`177953926`) ([iOS & iPadOS 27 Release Notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)).
- **App Store screenshot deadline:** Starting **April 2027**, apps built with iOS 27.1 SDK or later require iPhone Duo screenshots (`1398 × 2034` outer, `2007 × 2853` inner) ([App Store Connect Screenshot Specs](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)).
- **Mac Catalyst compile guard (Xcode 27.1):** Wrap iOS 27.1-only symbols in `#if !TARGET_OS_MACCATALYST` / `#if !targetEnvironment(macCatalyst)` (`185924957`) ([Xcode 27.1 Release Notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes)).
