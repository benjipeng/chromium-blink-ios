# Curium · 96 Cm

Curium is a native iOS browser shell for embedded Blink and Manifest V3 extensions.
Build it with Xcode 27.2. The deployment floor is iOS 26.0; the system vertical
bar and reserved fold regions are available on iOS 27.1 and later.

The ordinary Debug and Release configurations start in standby. The address
field and tab history stay in memory. Standby neither loads websites nor
installs extensions. The shell never substitutes WebKit for Blink.

To run with Blink after patch 0088 is available:

1. Supply `Vendor/CuriumEngine/chrome_framework.xcframework` and its matching
   `EarlyMallocZoneRegistration.xcframework`. The default slice names are
   `ios-arm64` and `ios-arm64-simulator`; override `CURIUM_ENGINE_SLICE`
   if the vendor uses a different slice identifier. The handoff also provides
   `EngineResources/` and, when needed, `Lottie.xcframework`. The build copies
   engine resources into the app bundle where Blink expects them.
2. Pass `CURIUM_USE_ENGINE_XCFRAMEWORK=YES` to the build or enable it in
   `Version.xcconfig`. For a device build, select the signing team and
   provisioning appropriate to the engine artifact.
3. The link flags put `-Wl,-framework,EarlyMallocZoneRegistration` first.
   The embed phase checks the first strong Mach-O load command and signs the
   embedded frameworks before the app is signed.

Curium registers its shell delegate before entering `ChromeMain`. The engine
owns the scene lifecycle, browsing context, and live tab and popup views. The
shell mounts those views, owns the native chrome, and reviews extension
permissions returned by the engine before confirming an install. A signed CRX
or Chrome Web Store listing is always prepared and verified by the engine.
Only the shared regular browsing context is exposed.
