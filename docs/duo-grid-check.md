# Verify tab grid placement on iPhone Duo

On an isolated simulator copy of the Actions IPA, use the receipt helper to read the visible tab cards and UIKit's active divisions. It does not change layout or ship in the IPA. On an Apple silicon Mac with Xcode 27.1 selected:

```sh
probe_dir="$(mktemp -d "${TMPDIR%/}/chromium-duo-grid.XXXXXX")"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator \
  -fobjc-arc -dynamiclib -framework UIKit -framework Foundation \
  -framework CoreGraphics tools/simulator/duo-grid-probe.m \
  -o "$probe_dir/DuoGridProbe.dylib"
codesign --force --sign - "$probe_dir/DuoGridProbe.dylib"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$probe_dir/DuoGridProbe.dylib" \
  xcrun simctl launch --terminate-running-process "$simulator_udid" "$test_bundle_id"
```

Use the simulator UDID and an isolated test bundle ID. Open at least three tabs and show the tab grid. At each pose, capture a fresh receipt:

```sh
xcrun simctl spawn "$simulator_udid" notifyutil -p org.chromium.blink.ios.duo-grid.capture
data_dir="$(xcrun simctl get_app_container "$simulator_udid" "$test_bundle_id" data)"
cat "$data_dir/tmp/duo-grid-receipt.json"
```

The receipt is written on the next main thread callback. Check its modification time after each request. Every rectangle is `[left, top, right, bottom]` in window coordinates. An empty list means the probe could not find a foreground window containing visible grid cards.

1. Start with the inner display flat in landscape. Record the normal three-column positions.
2. Fold to 110° with the grid still open. Confirm no card intersects the active vertical division. Rotate to the other landscape orientation and check again.
3. Return to flat in the original orientation. Confirm the original positions return without reopening the grid. Check the compact outer grid and rotate the inner display to portrait. The vertical-division fix must not alter these layouts.

This check covers vertical fold avoidance. Treat tabletop and horizontal divisions, Split View, keyboard, and accessibility as separate checks. Relaunch the simulator app without the helper after measuring.
