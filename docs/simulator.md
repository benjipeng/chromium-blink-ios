# Test a GitHub IPA on the simulator

This guide covers the standalone Chromium IPA that `build-ipa.yml` packages, not the Curium app. Use the IPA and checksum from the same successful Actions run, and record the branch, commit, and run ID alongside any screenshots. The procedure prepares a disposable simulator copy on an Apple silicon Mac; it does not compile Chromium or change the original IPA.

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

Set `simulator_udid` to the intended simulator, normally the iPhone Duo simulator, before installing. A simulator pass is evidence about that runtime only; the original artifact remains a device build.

## Verify the extension lifecycle

Use a real Chrome Web Store listing and a publisher-signed CRX of the same extension. Keep neither package in the repository. For Files testing, copy the package into `Documents` of the isolated app's data container, found with `xcrun simctl get_app_container "$simulator_udid" com.benjipeng.chromiumblink.chrome.ios.extlifetest data`.

1. Open the Store listing and verify the tab stays open. In **Settings → Extensions → + → From Chrome Web Store Link…**, paste the listing URL to reach the native review. Cancel and verify the list does not change.
2. In **Import from Files…**, select a copy of the signed package with a changed archive byte. Verify rejection before the install review. Select the genuine package and confirm. Record the extension's name, version, ID, and declared access from the review.
3. Open **Options** from Settings and verify it belongs to the installed extension. Verify its effect on a page, remove the extension, confirm the list changes, and verify the effect is gone.
4. Reinstall from the official Store link and verify the same ID and a renewed effect. The app should acquire and verify the package without a staging service or diagnostic bridge.

Verify startup restoration separately: cold-launch with the extension enabled and disabled, then once more after removal. Check the saved state against page behavior rather than the row alone.

Filtering, theme, panel, and popup fixtures were retired in `8ac0abd`; restore them from Git history when a check needs them.
