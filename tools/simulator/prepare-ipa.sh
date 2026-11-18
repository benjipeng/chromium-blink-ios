#!/usr/bin/env bash
# Prepare an isolated simulator copy of a verified Chromium device IPA.
set -euo pipefail

if [[ $# != 3 || "$3" != *.app ]]; then
  echo "usage: $0 <device.ipa> <expected-sha256> <new-simulator.app>" >&2
  exit 2
fi
ipa="$1"
expected="$2"
out="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")"
bundle=com.benjipeng.chromiumblink.chrome.ios.extlifetest
[[ ! -e "$out" && ! -L "$out" ]]
actual="$(shasum -a 256 "$ipa" | awk '{print $1}')"
if [[ "$expected" != "$actual" ]]; then
  echo "IPA SHA-256 does not match the expected artifact" >&2
  exit 1
fi

work="$(mktemp -d "$(dirname "$out")/.chromium-simulator.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$ipa" "$work"
app="$work/Payload/Chromium.app"
[[ -d "$app/Frameworks" && ! -e "$app/PlugIns" ]]
python3 - "$app" "$bundle" <<'PY'
from pathlib import Path
import plistlib
import sys

app, bundle = Path(sys.argv[1]), sys.argv[2]
for path in [app / "Info.plist", *sorted(app.glob("Frameworks/*.framework/Info.plist"))]:
    info = plistlib.loads(path.read_bytes())
    info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
    info["DTPlatformName"] = "iphonesimulator"
    if info.get("DTSDKName", "").startswith("iphoneos"):
        info["DTSDKName"] = info["DTSDKName"].replace("iphoneos", "iphonesimulator", 1)
    if path.parent == app:
        former = info["CFBundleIdentifier"]
        info["CFBundleIdentifier"] = bundle
        info["CFBundleDisplayName"] = "Chromium Extensions Test"
        info["UIFileSharingEnabled"] = True
        if "BGTaskSchedulerPermittedIdentifiers" in info:
            info["BGTaskSchedulerPermittedIdentifiers"] = [
                item.replace(former, bundle) for item in info["BGTaskSchedulerPermittedIdentifiers"]
            ]
        for entry in info.get("CFBundleURLTypes", []):
            entry["CFBundleURLSchemes"] = [
                scheme + "-extlifetest" for scheme in entry.get("CFBundleURLSchemes", [])
            ]
    path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
PY

retarget() {
  local binary="$1" build minos sdk
  [[ "$(lipo -archs "$binary")" == arm64 ]]
  build="$(xcrun vtool -show-build "$binary")"
  grep -Eq '^[[:space:]]+platform IOS$' <<<"$build"
  minos="$(awk '$1 == "minos" {print $2}' <<<"$build")"
  sdk="$(awk '$1 == "sdk" {print $2}' <<<"$build")"
  [[ -n "$minos" && -n "$sdk" ]]
  xcrun vtool -set-build-version iossim "$minos" "$sdk" -replace \
    -output "$work/retargeted" "$binary"
  chmod +x "$work/retargeted"
  mv "$work/retargeted" "$binary"
  build="$(xcrun vtool -show-build "$binary")"
  grep -Eq '^[[:space:]]+platform IOSSIMULATOR$' <<<"$build"
}

retarget "$app/Chromium"
for framework in "$app"/Frameworks/*.framework; do
  name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$framework/Info.plist")"
  retarget "$framework/$name"
  codesign --force --sign - "$framework"
  codesign --verify --strict "$framework"
done
rm -f "$app/embedded.mobileprovision"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
python3 - "$app" "$out" <<'PY'
import os
import sys

if os.path.lexists(sys.argv[2]):
    sys.exit("The destination already exists.")
os.rename(sys.argv[1], sys.argv[2])
PY
printf 'device_ipa_sha256=%s\napp=%s\nbundle_id=%s\n' "$actual" "$out" "$bundle"
