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

## Verify tab binding once action popups are implemented

`tools/simulator/extension-action-check/` is a developer fixture, not a signed package for Files import. It declares `activeTab` and no broad host permissions. Launch its popup from two ordinary tabs and confirm the real tab IDs and hostnames differ. Reload must act on the associated web tab, and Close must dismiss the popup without closing that tab. Repeat while folding the simulator and after switching tabs to verify that stale popup actions cannot target the wrong tab.

## Where changes live

- Put native browser behavior and layout fixes in `patches/`. They ship through the ordinary build.
- Keep separately compiled production UI code in `helpers/`. The packaging job builds and embeds it, so a helper-only change can reuse the matching link checkpoint.
- Keep small simulator tools here under `tools/simulator/`. Historical tweak folders and external diagnostic overlays are not build inputs.
