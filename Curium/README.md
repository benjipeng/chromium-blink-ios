# Curium · 96 Cm

Curium is a native iOS browser shell for embedded Blink and Manifest V3 extensions.
Build it with Xcode 27.2. The deployment floor is iOS 26.0; the system vertical
bar and reserved fold regions are available on iOS 27.1 and later.

`CURIUM_USE_ENGINE_XCFRAMEWORK` in `Version.xcconfig` selects the build mode.
With `NO`, the app builds without the engine and starts in standby: the
address field and tab history stay in memory, and standby neither loads
websites nor installs extensions. The shell never substitutes WebKit for Blink.

To run with Blink:

1. Run `scripts/sync_curium_engine.py` to assemble the engine pinned in
   `Kernel.lock` into `Vendor/CuriumEngine/`: `chrome_framework.xcframework`
   and its matching `EarlyMallocZoneRegistration.xcframework`. The default
   slice names are `ios-arm64` and `ios-arm64-simulator`; override
   `CURIUM_ENGINE_SLICE` if the vendor uses a different slice identifier. The handoff also provides
   `EngineResources/` and, when needed, `Lottie.xcframework`. The build copies
   engine resources into the app bundle where Blink expects them.
2. Pass `CURIUM_USE_ENGINE_XCFRAMEWORK=YES` to the build or enable it in
   `Version.xcconfig`. For a device build, select the signing team and
   provisioning appropriate to the engine artifact.
3. The link flags put `-Wl,-framework,EarlyMallocZoneRegistration` first.
   The embed phase checks the first strong Mach-O load command and signs the
   embedded frameworks before the app is signed.

To build and package an ad-hoc signed `arm64` IPA locally or in CI against the
engine pinned in `Kernel.lock`:

```sh
./scripts/build_curium_ipa.sh --output-dir dist
```

On GitHub Actions, `.github/workflows/build-curium.yml` runs the same script on
`xcode-27` (`/Applications/Xcode_27.2.app`), uploads the IPA artifact, and
publishes a GitHub Release on `curium-v*` tag pushes or manual
`workflow_dispatch`.

Curium registers its shell delegate before entering `ChromeMain`. The engine
owns the scene lifecycle, browsing context, and live tab and popup views. The
shell mounts those views, owns the native chrome, and reviews extension
permissions returned by the engine before confirming an install. A signed CRX
or Chrome Web Store listing is always prepared and verified by the engine.
Only the shared regular browsing context is exposed.
