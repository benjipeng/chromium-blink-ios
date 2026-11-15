#!/usr/bin/env bash
# Runs on GitHub's `xcode-27` runner (Stage 4): executes any deferred post-link
# AppIntents metadata extraction against the linked Chromium binary, strips
# unused multi-process .appex stubs, optionally applies ad-hoc App Group
# entitlements (signing embedded frameworks without entitlements first),
# validates Mach-O headers, and packages the final .ipa.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../version.lock
source "$REPO_ROOT/version.lock"

src_dir=""
out_rel="out/Release"
output_ipa=""
with_app_groups=0

while [ $# -gt 0 ]; do
  case "$1" in
    --src-dir)
      src_dir="${2:?missing path}"
      shift 2
      ;;
    --out-rel)
      out_rel="${2:?missing relative build dir}"
      shift 2
      ;;
    --output-ipa)
      output_ipa="${2:?missing output ipa path}"
      shift 2
      ;;
    --with-app-groups)
      with_app_groups=1
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[ -n "$src_dir" ] || { echo "usage: $0 --src-dir <src> [--out-rel out/Release] --output-ipa <path> [--with-app-groups]" >&2; exit 1; }
[ -n "$output_ipa" ] || { echo "error: --output-ipa is required" >&2; exit 1; }

xcode_root="$XCODE_APP"
[ -d "$xcode_root" ] || xcode_root="/Applications/Xcode.app"
export DEVELOPER_DIR="$xcode_root/Contents/Developer"

build_dir="$src_dir/$out_rel"
app_bundle="$build_dir/Chromium.app"
[ -d "$app_bundle" ] || { echo "error: Chromium.app not found at $app_bundle" >&2; exit 1; }

deferred_dir="$build_dir/.deferred_extract_metadata"
if [ -f "$deferred_dir/manifest.json" ]; then
  echo "==> Executing deferred AppIntents metadata extraction on Xcode"
  python3 - "$src_dir" "$build_dir" "$deferred_dir" "$app_bundle" "$xcode_root" <<'PY'
import json, os, shutil, subprocess, sys

src_dir, build_dir, deferred_dir, app_bundle, xcode_root = sys.argv[1:6]
tc_dir = os.path.join(xcode_root, "Contents/Developer/Toolchains/XcodeDefault.xctoolchain")
sdk_dir = os.path.join(
    xcode_root,
    "Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
)
exe_path = os.path.join(app_bundle, "Chromium")

for sub_name, target_base in (("tree", src_dir), ("build", build_dir)):
    sub_root = os.path.join(deferred_dir, sub_name)
    if not os.path.isdir(sub_root):
        continue
    for root, _, files in os.walk(sub_root):
        for fn in files:
            src_p = os.path.join(root, fn)
            rel_p = os.path.relpath(src_p, sub_root)
            dst_p = os.path.join(target_base, rel_p)
            if not os.path.exists(dst_p):
                os.makedirs(os.path.dirname(dst_p), exist_ok=True)
                shutil.copy2(src_p, dst_p)

items = json.loads(open(os.path.join(deferred_dir, "manifest.json"), encoding="utf-8").read())
for item in items:
    rewritten = []
    out_dir_rel = ""
    args = item["args"]
    i = 0
    while i < len(args):
        if args[i] == "--toolchain-dir" and i + 1 < len(args):
            rewritten.extend(["--toolchain-dir", tc_dir])
            i += 2
        elif args[i] == "--sdk-root" and i + 1 < len(args):
            rewritten.extend(["--sdk-root", sdk_dir])
            i += 2
        elif args[i] == "--binary-file" and i + 1 < len(args):
            rewritten.extend(["--binary-file", exe_path])
            i += 2
        elif args[i] == "--output" and i + 1 < len(args):
            out_dir_rel = args[i + 1]
            rewritten.extend(["--output", out_dir_rel])
            i += 2
        else:
            rewritten.append(args[i])
            i += 1
    cmd = [sys.executable, item["script"], *rewritten]
    print("  running:", " ".join(cmd[:6]), "...")
    subprocess.check_call(cmd, cwd=build_dir)
    if out_dir_rel:
        produced = os.path.join(build_dir, out_dir_rel, "Metadata.appintents")
        bundle_meta = os.path.join(app_bundle, "Metadata.appintents")
        if os.path.isdir(produced):
            if os.path.exists(bundle_meta):
                shutil.rmtree(bundle_meta)
            shutil.copytree(produced, bundle_meta)
PY
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Payload"
ditto "$app_bundle" "$work/Payload/Chromium.app"
bundle="$work/Payload/Chromium.app"

for sub in PlugIns Extensions; do
  if [ -d "$bundle/$sub" ]; then
    echo "==> Removing unused $sub/"
    rm -rf "${bundle:?}/${sub:?}"
  fi
done
find "$bundle" -type d -name _CodeSignature -prune -exec rm -rf {} +

if [ "$with_app_groups" -eq 1 ]; then
  cat > "$work/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array>
    <string>group.$BUNDLE_ID_PREFIX.chrome</string>
    <string>group.$BUNDLE_ID_PREFIX.common</string>
  </array>
</dict>
</plist>
EOF
  echo "==> Signing nested frameworks (without entitlements) then top-level app bundle"
  if [ -d "$bundle/Frameworks" ]; then
    for fw in "$bundle/Frameworks"/*; do
      [ -e "$fw" ] || continue
      codesign --force --sign - --timestamp=none "$fw"
    done
  fi
  codesign --force --sign - --timestamp=none \
    --entitlements "$work/entitlements.plist" "$bundle"
fi

exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")"
echo "==> Validating Mach-O executable ($exe):"
lipo -archs "$bundle/$exe"
vtool -show-build "$bundle/$exe" | grep -E 'platform|minos|sdk' || true
if [ -f "$bundle/Frameworks/chrome_framework.framework/chrome_framework" ]; then
  echo "==> Validating Blink chrome_framework Mach-O:"
  lipo -archs "$bundle/Frameworks/chrome_framework.framework/chrome_framework"
  vtool -show-build "$bundle/Frameworks/chrome_framework.framework/chrome_framework" | grep -E 'platform|minos|sdk' || true
fi
echo "==> Final Chromium.app size: $(du -sh "$bundle" | cut -f1)"

mkdir -p "$(dirname "$output_ipa")"
rm -f "$output_ipa"
(cd "$work" && zip -qry "$output_ipa" Payload)
shasum -a 256 "$output_ipa" > "${output_ipa}.sha256"
ls -lh "$output_ipa"
cat "${output_ipa}.sha256"
