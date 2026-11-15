#!/usr/bin/env bash
# Runs on GitHub's `xcode-27` runner: extracts the minimal iOS SDK + Swift
# headers/interop/runtime files required by Linux `clang`/`ld64.lld`/`sdk_info.py`
# and encrypts the archive with CI_ARTIFACT_KEY so SDK files stay private.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../version.lock
source "$REPO_ROOT/version.lock"

out_enc=""
plain_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output-encrypted)
      out_enc="${2:?missing output path}"
      shift 2
      ;;
    --staging-dir)
      plain_dir="${2:?missing staging dir}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[ -n "$out_enc" ] || { echo "usage: $0 --output-encrypted <file.tar.zst.enc> [--staging-dir <dir>]" >&2; exit 1; }
[ -n "${CI_ARTIFACT_KEY:-}" ] || { echo "error: CI_ARTIFACT_KEY must be set in environment" >&2; exit 1; }

xcode_root="$XCODE_APP"
if [ ! -d "$xcode_root" ]; then
  xcode_root="/Applications/Xcode.app"
fi
[ -d "$xcode_root/Contents/Developer" ] || { echo "error: Xcode not found at $xcode_root" >&2; exit 1; }

cleanup_staging=0
if [ -z "$plain_dir" ]; then
  plain_dir="$(mktemp -d)"
  cleanup_staging=1
fi
trap '[ "$cleanup_staging" -eq 1 ] && rm -rf "$plain_dir"' EXIT

stub="$plain_dir/xcode_stub"
rm -rf "$stub"
mkdir -p \
  "$stub/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs" \
  "$stub/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin" \
  "$stub/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib" \
  "$stub/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/include"

cp -a "$xcode_root/Contents/version.plist" "$stub/Contents/"
[ -f "$xcode_root/Contents/Info.plist" ] && cp -a "$xcode_root/Contents/Info.plist" "$stub/Contents/"

plat_src="$xcode_root/Contents/Developer/Platforms/iPhoneOS.platform"
plat_dst="$stub/Contents/Developer/Platforms/iPhoneOS.platform"
for f in Info.plist version.plist; do
  [ -f "$plat_src/$f" ] && cp -a "$plat_src/$f" "$plat_dst/"
done

cp -RL "$plat_src/Developer/SDKs/iPhoneOS.sdk" "$plat_dst/Developer/SDKs/iPhoneOS.sdk"
sdk_ver="$(/usr/libexec/PlistBuddy -c 'Print :ProductVersion' "$plat_dst/Developer/SDKs/iPhoneOS.sdk/System/Library/CoreServices/SystemVersion.plist")"
ln -s "iPhoneOS.sdk" "$plat_dst/Developer/SDKs/iPhoneOS${sdk_ver}.sdk"

tc_src="$xcode_root/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
tc_dst="$stub/Contents/Developer/Toolchains/XcodeDefault.xctoolchain"
[ -f "$tc_src/ToolchainInfo.plist" ] && cp -a "$tc_src/ToolchainInfo.plist" "$tc_dst/"

# Copy Swift C++ interop headers (`usr/include/swift` & `usr/lib/swift/swiftToCxx`)
# plus all `usr/lib/swift*/iphoneos` compatibility libraries (including swift-6.2).
if [ -d "$tc_src/usr/include/swift" ]; then
  cp -RL "$tc_src/usr/include/swift" "$tc_dst/usr/include/swift"
fi
if [ -d "$tc_src/usr/lib/swift/swiftToCxx" ]; then
  mkdir -p "$tc_dst/usr/lib/swift"
  cp -RL "$tc_src/usr/lib/swift/swiftToCxx" "$tc_dst/usr/lib/swift/swiftToCxx"
fi
for swift_iphoneos in "$tc_src"/usr/lib/swift*/iphoneos; do
  [ -d "$swift_iphoneos" ] || continue
  swift_parent="$(basename "$(dirname "$swift_iphoneos")")"
  mkdir -p "$tc_dst/usr/lib/$swift_parent"
  cp -RL "$swift_iphoneos" "$tc_dst/usr/lib/$swift_parent/iphoneos"
done

if [ -d "$tc_src/usr/lib/clang" ]; then
  cp -RL "$tc_src/usr/lib/clang" "$tc_dst/usr/lib/clang"
fi

echo "==> Extracted Xcode SDK stub size:"
du -sh "$stub"

mkdir -p "$(dirname "$out_enc")"
tar -C "$plain_dir" -cf - xcode_stub \
  | zstd -T0 -6 \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass env:CI_ARTIFACT_KEY -out "$out_enc"

ls -lh "$out_enc"
