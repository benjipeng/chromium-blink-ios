# iPhone Duo browser UI

Use the current Duo layout as the starting point: its browser shell, focused
address bar, New Tab Page, menu model, modal presentations, and capability policy
work together. A simulator copy of the reference UI runs on iOS 27.1. The
draft branch currently contains the source fixes for the omnibox inset and
tab-grid fold; the runtime UI is not in a shipped IPA.

| Surface | Expected behavior |
| --- | --- |
| Inner browser chrome | Two rows share one browser surface. The tab strip is above the address bar. Both avoid UIKit's top status region and preserve button spacing; the browser surface ends at the status region's bottom when it fits. |
| Outer browser chrome | The address bar stays at the bottom. Navigation and tab controls use the reserved side regions. No tab strip on the outer display. |
| Focused address bar | Editing stays in the address bar's row. Suggestions extend toward the content and stay in the same column. Check fold and unfold while editing, including keyboard dismissal. |
| New Tab Page | Keep the actual browser address bar. Use the full safe content width, with no fake search field, clipped card, or empty gap after trimming unavailable features. |
| Menu and sheets | Keep actions grouped by purpose, including Extensions when available. Adapt sheet width and anchoring to the display. |
| Tab grid | Respect the live hinge division and keep a usable regular tab picker without an Incognito segment. |
| Capabilities | Keep unavailable Incognito, Google sign-in, AI Mode / Ask Google, and promos out of navigation, settings, and context menus. |

The inner landscape reference measured a top trailing occlusion of
134 × 82 pt and a toolbar from y=38 to y=82. Derive layout from UIKit's reserved
region frame and margins and the corner-adapted safe area, using these numbers
as regression evidence. The browser controls and its painted surface are
separate from the status indicators that iOS draws.

## Current simulator evidence

The combined test app uses the extension core from
[Actions 44222828561](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44222828561),
the native Store form helper, and the full Duo reference UI with local
polish experiments. Nothing in this preview is required to run the CI
pipeline.

- The inner portrait header still ends at y=82. The steady address bar
  widened from 259 to 273 pt without changing button bounds or the status
  region. Removing the old centering adjustment narrowed the bar to 143 pt;
  keep that adjustment until the native constraints have a single owner.
- On the 678 × 466 outer landscape display, the focused input started at
  y=402.7. The single suggestion ended at y=394.7, leaving 8 pt above the input.
- Unfolding with the input focused kept the edit view active. On the inner
  display, the input ended at y=82 and the suggestion began at y=86. This
  proves positioning and focus for a short list, not text retention,
  software keyboard behavior, or scrolling with many results.

Next, move the safe behavior into the native toolbar and composebox
constraints. Validate inner portrait and landscape, outer portrait and both
landscape directions, and an uninterrupted fold/unfold with typed text.
Exercise the real controls on each display, including menus and Settings;
a dylib loading or a build completing proves only that step.
