# Island probe

Starts a compact Live Activity so the Simulator's Dynamic Island widens, the way
Now Playing does on `ac_duo`. Safari audio does not raise the island on Simulator.

```sh
cd tools/simulator/island-probe
xcodegen generate && unset SDKROOT
xcodebuild -project IslandProbe.xcodeproj -scheme IslandProbe \
  -destination 'id=763CD37E-F210-4EBA-ABAF-963FE7FDCB48' -derivedDataPath /private/tmp/islandprobe-dd build
xcrun simctl install booted /private/tmp/islandprobe-dd/Build/Products/Debug-iphonesimulator/IslandProbe.app
xcrun simctl launch booted com.appautomaton.probe.island   # starts the activity
xcrun simctl launch booted com.appautomaton.curium         # island shows over Curium
xcrun simctl uninstall booted com.appautomaton.probe.island # ends it
```

Curium logs each occlusion change under subsystem `com.appautomaton.curium`, category `layout`.
