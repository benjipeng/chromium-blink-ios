# Test a GitHub IPA on the simulator

Use the IPA and checksum from the same successful Actions run. Record the branch, commit, and run ID alongside any screenshots. This procedure prepares a simulator copy on an Apple silicon Mac; it does not compile Chromium or change the original IPA.

From the repository, with Xcode selected:

```sh
ipa=/path/to/Chromium-Blink-version-arm64.ipa
checksum="$(awk 'NR == 1 { print $1 }' "${ipa}.sha256")"
test_dir="$(mktemp -d "${TMPDIR%/}/chromium-ios-test.XXXXXX")"
tools/simulator/prepare-ipa.sh "$ipa" "$checksum" "$test_dir/Chromium.app"
```

The tool verifies the checksum, retargets the app and embedded frameworks for the arm64 simulator, and signs from the inside out. It prints the bundle ID and uses an isolated app identity with Files access for test fixtures.

```sh
xcrun simctl list devices booted
xcrun simctl install "$simulator_udid" "$test_dir/Chromium.app"
xcrun simctl launch "$simulator_udid" com.benjipeng.chromiumblink.chrome.ios.extlifetest
```

Set `simulator_udid` to the intended simulator before running the install and launch commands. A simulator pass is evidence about that runtime. The original artifact remains a device build.

## Current lifecycle build

[Actions run 44222828561](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44222828561)
built `probe/extensions-gn` at `a18ce74`. Artifact `14395797087` contains
the device IPA with SHA-256
`5992706567550591465f1790aa6a77ef8ef6e50da8ed886df2ecd480728145bd`.
The checksum was verified and the simulator copy launched with the
production bridge. The native Store flow installed uBlock Origin Lite
`2026.1116.1650` in the simulator; the extension registry UI showed it
enabled and exposed **Manage**. Filtering, removal, and reinstall still
need their own acceptance checks.

Start in **Settings → Extensions → + → From Chrome Web Store Link…** and
paste the extension's listing URL. The native review verifies the package and
shows its requested access before installation. Google's in-page **Add to
Desktop** action is separate and cannot install into this app. This build
keeps a confirmed installation for the current session only.

The updated package helper presents the listing field on its own navigation
screen. On the iPhone Duo simulator, the form and help text shared 16 pt
side margins in a 466 pt sheet; Review was disabled for empty input and
submitted the verified listing ID once after a valid URL was entered.
This component check used the compiled production helper in a small UIKit
harness; it did not exercise the network download again.

## Verify the extension lifecycle

Use a real Chrome Web Store listing and a publisher-signed CRX of the same extension. Keep neither package in the repository. For Files testing, copy the fixture into `Documents` of the isolated app's data container, found with `xcrun simctl get_app_container "$simulator_udid" com.benjipeng.chromiumblink.chrome.ios.extlifetest data`.

1. Open the Store listing and verify the tab stays open. In **Settings → Extensions**, use the official listing link to reach the native review. Cancel and verify the list does not change.
2. In **Import from Files…**, select a copy of the signed package with a changed archive byte. Verify rejection before the install review. Select the genuine package and confirm. Record the extension's name, version, ID, and declared access from the review.
3. Open **Options** from Settings and verify it belongs to the installed extension. Run the filtering check below. Then remove the extension, confirm the list changes, and run the same check again.
4. Reinstall from the official Store link and verify the same ID and renewed filtering. The app should acquire and verify the package without a staging service or diagnostic bridge.

Verify startup restoration separately on a build that implements it: cold-launch with the extension enabled and disabled, then once more after removal. Check the saved state against filtering behavior rather than the row alone.

## Verify request filtering

From the repository, serve the fixture on loopback:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory tools/simulator/extension-filter-check
```

In Chromium on the simulator, open `http://127.0.0.1:8765/` and tap **Run filter check**. With uBlock Origin Lite and EasyList active, the control loads and the EasyList target does not reach the server. Confirm the request ID against the server log; a network error alone does not prove filtering.

Run the same check after removal and again after reinstalling. Both paths should reach the server while the extension is absent. The EasyList path should stop reaching it after reinstalling, while the control remains reachable. Check on a newly loaded page each time.

## Verify Dark Reader on two sites

[Actions run 44328959472](https://github.com/benjipeng/chromium-blink-ios/actions/runs/44328959472)
built `1f76114` and produced artifact `14443178991`. On the iOS 27.1 Duo
simulator, an update retained the installed Dark Reader 4.9.135 and its
enabled state. Its Options page rendered. After reload in Light appearance,
the white test page had one dynamic theme stylesheet and a computed
background of `rgb(24, 26, 27)`. The initially restored tab stayed light
until reload. Site isolation and uBlock coexistence have not been checked
on this IPA.

A later check on the same core changed Dark Reader from Auto to On with
system appearance still Light. Returning to the existing web tab without a
reload changed its computed background from `rgb(255, 255, 255)` to
`rgb(24, 26, 27)` and the dynamic stylesheet count from zero to one. The Duo
outer landscape right gutter stayed `rgb(18, 18, 18)` during that change.
Reloading brought it to the page color without changing the theme. Check the
gutter separately from content injection; patch `0037` keeps the page inside
the safe area and assigns the gutter color in `UpdateBackgroundColor()`.

Serve the white test page locally:

```sh
python3 -m http.server 8786 --bind 127.0.0.1 --directory tools/simulator/extension-theme-check
```

On the Duo simulator in Light appearance, install Dark Reader from its
official listing. Open `http://127.0.0.1:8786/` and the other test origin in
separate tabs. The page reports its computed background and the extension's
dynamic and fallback styles. Confirm **Manage → Options** finishes loading
and the sites darken with dynamic styles present. Once a site-specific control
is available, disable the theme for one origin; the other must stay dark.

## Preview the UIKit Extensions menu

`tools/simulator/extension-panel-preview.m` is a simulator-only helper for the
`1f76114` core. It adds **⋯ → Extensions** on ordinary websites and lists the
enabled extensions. Choose **Open Options** to open an extension's global
settings in a separate tab; the original page stays open. A row without
Options is read-only. The preview does not expose page actions or request counts.

From the repository root, using the existing simulator app and its bundle ID:

```sh
preview=$(mktemp -d "${TMPDIR:-/tmp}/chromium-page-panel.XXXXXX")
xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator \
  -dynamiclib -fobjc-arc -framework Foundation -framework UIKit \
  -framework CoreGraphics tools/simulator/extension-panel-preview.m \
  -o "$preview/PageExtensionsPreview.dylib"
codesign --force --sign - "$preview/PageExtensionsPreview.dylib"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$preview/PageExtensionsPreview.dylib" \
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID"
```

## Verify page-specific blocking once the Extensions panel is connected

Run the filter check twice in tab A and confirm the extension's **Requests
blocked** count rises by two. Open the same fixture in tab B and confirm it
starts at zero, increases by one on a single check, and leaves tab A's count
intact. A same-document fragment change preserves the count; a committed
navigation to a new document resets it. Check that the allowlisted control,
redirects, and header-only actions never add to the blocked request count.

## Verify tab binding once action popups are implemented

`tools/simulator/extension-action-check/` is a developer fixture, not a signed package for Files import. It declares `activeTab` and no broad host permissions. Launch its popup from two ordinary tabs and confirm the real tab IDs and hostnames differ. Reload must act on the associated web tab, and Close must dismiss the popup without closing that tab. Repeat while folding the simulator and after switching tabs to verify that stale popup actions cannot target the wrong tab.

## Where changes live

- Put native browser behavior and layout fixes in `patches/`. They ship through the ordinary build.
- Keep separately compiled production UI code in `helpers/`. The packaging job builds and embeds it, so a helper-only change can reuse the matching link checkpoint.
- Keep small simulator tools here under `tools/simulator/`. Historical tweak folders and external diagnostic overlays are not build inputs.
