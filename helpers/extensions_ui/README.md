# ChromiumExtensionsUI

Native UIKit extension manager (`Settings -> Extensions`) compiled as a standalone Objective-C dylib without Chromium headers or build artifacts.

## Architecture and Contract

- **Production UI (`ExtensionsManager.m`)**: Foundation-only consumer of the `0063` runtime ObjC contract (`CrIOSExtensionManagingV1.h`): looks up `CrIOSExtensionManagerV1` via `NSClassFromString`, acquires `+sharedManager`, reads immutable `{id, name, version, enabled}` dictionaries from `-extensionsWithError:`, and toggles via `-setExtensionWithID:enabled:error:` with readback. Contains no hardcoded C++ offsets, no `Cr*` structs, and no undefined ObjC class symbol imports.
- **Pinned diagnostic adapter (`DiagnosticPinnedBridge.m`)**: Compiled only when `--diagnostic` is explicitly passed to `build.sh`. Exposes a distinct `CrIOSDiagnosticPinnedExtensionManager` fallback class (never duplicating `CrIOSExtensionManagerV1`) validated fail-closed via `LC_UUID` (`4C4C44C4-5555-3144-A17F-F4148FCB3BF7`), `ChromeMain` `dladdr`, and three pinned instruction checks for the M159 `34d81e7` `extprobe` build.
- **UI entry and controls**: Inserts `Extensions` at index `0` of `SettingsTableViewController`'s `TableViewModel` via `-[ListModel insertSectionWithIdentifier:atIndex:]`, supports full-row and `UISwitch` toggling with accessibility metadata, and provides a native `Done` bar button calling `-[SettingsNavigationController closeSettings]` (with guarded modal/navigation fallback).

## Scope and Limitations

- **Known cold-restart reset**: `UnpackedInstaller::AddNewOrUpdatedExtension` reloads unpacked fixtures with default `GetDisableReasonsOnInstalled() == {}`, clearing canonical user-disabled state across cold restarts in the diagnostic build. No `NSUserDefaults` workaround is included.
- **No uBOL support**: Supports basic extension listing and enable/disable toggling for installed extensions; uBlock Origin Lite (`uBOL`), extension installation, and `chrome://extensions` routing are out of scope.
- **Optional Files CRX import (`CrIOSExtensionManagingV1.h`, `ExtensionsManager.m`)**: When the active bridge responds to `-prepareSignedExtensionAtPath:completion:`, `-confirmPreparedExtensionWithToken:completion:`, and `-cancelPreparedExtensionWithToken:error:`, `ExtensionsManagerViewController` shows an `Import from Files…` section using `UIDocumentPickerViewController` (`asCopy:YES`, `.crx` validation, app-local path) followed by a session-only permission review sheet (`permissions` and `hostPermissions`). Cancel invokes `-cancelPreparedExtensionWithToken:error:`; confirmation reloads the extension list.
- **CI integration**: CI patch `0063` provides `CrIOSExtensionManagerV1` natively inside `chrome_framework`; production builds of this helper require `0063` and include no diagnostic fallback.

## Build

Outputs default to `/tmp` so no binaries are stored in this directory:

```sh
./build.sh --platform simulator --out /tmp/ExtensionsManager-v4.dylib
./build.sh --platform device --out /tmp/ExtensionsManager-v4-device.dylib
./build.sh --platform simulator --diagnostic --out /tmp/ExtensionsManager-v4-diag.dylib
```
