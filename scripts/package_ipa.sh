#!/usr/bin/env bash
# Runs on GitHub's `xcode-27` runner (Stage 5): executes any deferred post-link
# AppIntents metadata extraction against the linked Chromium binary, strips
# unused multi-process .appex stubs, builds and embeds ChromiumExtensionsUI
# as a flat framework with a strong LC_LOAD_DYLIB (when extensions core is
# enabled), unconditionally ad-hoc signs inside-out (applying App Group
# entitlements only to the outer .app if requested), validates Mach-O headers
# and signatures (--deep --strict), and packages the final .ipa.
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

exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Info.plist")"
exe_path="$bundle/$exe"
chrome_fw="$bundle/Frameworks/chrome_framework.framework/chrome_framework"

if grep -Eq '^enable_extensions_core[[:space:]]*=[[:space:]]*true' "$REPO_ROOT/args/device.gn"; then
  for resource in manifest.json content.js rules_1.json; do
    [ -s "$bundle/bundled_extensions/ios_probe/$resource" ] || {
      echo "error: bundled extension probe resource missing after packaging cleanup: $resource" >&2
      exit 1
    }
  done
  python3 - "$bundle/bundled_extensions/ios_probe/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
if "background" in manifest:
    raise SystemExit("error: bundled ios_probe/manifest.json must not declare a background service worker")
PY
  echo "==> Verified bundled extension probe resources (content-script/DNR-only) after .appex cleanup"

  bridge_target="$exe_path"
  [ -f "$chrome_fw" ] && bridge_target="$chrome_fw"
  echo "==> Checking base Mach-O metadata and CrIOSExtensionManagerV1 availability"
  helper_cfg="$(python3 - "$exe_path" "$chrome_fw" "$bridge_target" <<'PY'
import os, re, subprocess, sys

exe_path, chrome_fw, bridge_target = sys.argv[1:4]

def inspect_macho(path: str) -> tuple[str, str, str]:
    archs = subprocess.check_output(["lipo", "-archs", path], text=True).strip()
    if archs != "arm64":
        raise SystemExit(f"error: expected thin arm64 Mach-O for {path}, got '{archs}'")
    vt = subprocess.check_output(["vtool", "-show-build", path], text=True)
    pm = re.search(r"\bplatform\s+(\S+)", vt)
    mm = re.search(r"\bminos\s+(\S+)", vt)
    if not pm or not mm:
        raise SystemExit(f"error: could not parse platform/minos from vtool for {path}:\n{vt}")
    return archs, pm.group(1), mm.group(1)

exe_arch, exe_plat, exe_minos = inspect_macho(exe_path)
if os.path.isfile(chrome_fw):
    fw_arch, fw_plat, fw_minos = inspect_macho(chrome_fw)
    if (fw_arch, fw_plat, fw_minos) != (exe_arch, exe_plat, exe_minos):
        raise SystemExit(
            f"error: chrome_framework mismatch ({fw_arch}/{fw_plat}/{fw_minos}) vs main exe ({exe_arch}/{exe_plat}/{exe_minos})"
        )

if exe_plat == "IOS":
    helper_platform, supported_platform, dt_platform = "device", "iPhoneOS", "iphoneos"
elif exe_plat == "IOSSIMULATOR":
    helper_platform, supported_platform, dt_platform = "simulator", "iPhoneSimulator", "iphonesimulator"
else:
    raise SystemExit(f"error: unsupported Mach-O platform '{exe_plat}' in {exe_path}")

objc_meta = subprocess.check_output(["otool", "-oV", bridge_target], text=True)
has_v1 = bool(
    re.search(
        r"(?:_OBJC_CLASS_\$_CrIOSExtensionManagerV1\b|\bname\s+0x[0-9a-f]+\s+CrIOSExtensionManagerV1\b)",
        objc_meta,
    )
)
if not has_v1:
    raise SystemExit(
        f"error: CrIOSExtensionManagerV1 ObjC class missing from {bridge_target}; "
        "refusing to package silently unavailable Extensions UI"
    )

print(f"{exe_plat}\t{exe_minos}\t{helper_platform}\t{supported_platform}\t{dt_platform}")
PY
)"
  IFS=$'\t' read -r base_plat base_minos helper_platform supported_platform dt_platform <<< "$helper_cfg"

  helper_install_name="@rpath/ChromiumExtensionsUI.framework/ChromiumExtensionsUI"
  helper_fw="$bundle/Frameworks/ChromiumExtensionsUI.framework"
  rm -rf "$helper_fw"
  mkdir -p "$helper_fw"

  echo "==> Building production ChromiumExtensionsUI helper ($helper_platform, minos $base_minos)"
  "$REPO_ROOT/helpers/extensions_ui/build.sh" \
    --platform "$helper_platform" \
    --minos "$base_minos" \
    --install-name "$helper_install_name" \
    --out "$helper_fw/ChromiumExtensionsUI" >/dev/null
  chmod 755 "$helper_fw/ChromiumExtensionsUI"

  python3 - "$helper_fw/ChromiumExtensionsUI" "$helper_fw/Info.plist" \
    "$BUNDLE_ID_PREFIX" "$base_plat" "$base_minos" "$supported_platform" "$dt_platform" "$helper_install_name" <<'PY'
import plistlib, re, subprocess, sys

bin_path, plist_path, prefix, base_plat, base_minos, supported_plat, dt_plat, expected_id = sys.argv[1:9]

archs = subprocess.check_output(["lipo", "-archs", bin_path], text=True).strip()
assert archs == "arm64", f"helper arch mismatch: {archs}"
vt = subprocess.check_output(["vtool", "-show-build", bin_path], text=True)
plat = re.search(r"\bplatform\s+(\S+)", vt).group(1)
minos = re.search(r"\bminos\s+(\S+)", vt).group(1)
assert plat == base_plat and minos == base_minos, f"helper build mismatch: {plat}/{minos} vs {base_plat}/{base_minos}"

otool_d = subprocess.check_output(["otool", "-D", bin_path], text=True).splitlines()
assert len(otool_d) >= 2 and otool_d[1].strip() == expected_id, f"unexpected install name: {otool_d}"

nm_u = subprocess.check_output(["nm", "-u", bin_path], text=True)
bad_undef = [l.strip() for l in nm_u.splitlines() if "OBJC_CLASS_$_Cr" in l or "Settings" in l]
assert not bad_undef, f"helper production binary has forbidden undefined ObjC symbols: {bad_undef}"

strings_out = subprocess.check_output(["strings", bin_path], text=True)
for forbidden in ("CrIOSDiagnosticPinnedExtensionManager", "4C4C44C4-5555-3144-A17F-F4148FCB3BF7"):
    assert forbidden not in strings_out, f"production helper leaked diagnostic artifact: {forbidden}"

plist_data = {
    "CFBundleExecutable": "ChromiumExtensionsUI",
    "CFBundleIdentifier": f"{prefix}.extensionsui",
    "CFBundleName": "ChromiumExtensionsUI",
    "CFBundlePackageType": "FMWK",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "CFBundleSupportedPlatforms": [supported_plat],
    "DTPlatformName": dt_plat,
    "MinimumOSVersion": base_minos,
}
with open(plist_path, "wb") as f:
    plistlib.dump(plist_data, f, fmt=plistlib.FMT_XML)
PY

  echo "==> Embedding strong LC_LOAD_DYLIB for ChromiumExtensionsUI into $exe"
  python3 - "$exe_path" "$helper_install_name" <<'PY'
import struct, subprocess, sys
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_RPATH = 0x8000001C

DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB}
EARLY_MALLOC = "@rpath/EarlyMallocZoneRegistration.framework/EarlyMallocZoneRegistration"

exe = Path(sys.argv[1])
install_name = sys.argv[2]

def has_code_sig(blob: bytes) -> bool:
    ncmds = struct.unpack_from("<I", blob, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<2I", blob, off)
        if cmd == LC_CODE_SIGNATURE:
            return True
        off += cmdsize
    return False

raw = exe.read_bytes()
magic = struct.unpack_from("<I", raw, 0)[0]
if magic != MH_MAGIC_64:
    raise SystemExit(f"error: {exe} is not a thin 64-bit Mach-O (magic={hex(magic)})")

if has_code_sig(raw):
    subprocess.run(["codesign", "--remove-signature", str(exe)], check=True)
    raw = exe.read_bytes()

data = bytearray(raw)
magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data, 0)
if magic != MH_MAGIC_64:
    raise SystemExit(f"error: {exe} changed magic unexpectedly")

offset = 32
first_section = None
rpaths = []
dylibs = []

for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<2I", data, offset)
    if cmd == LC_CODE_SIGNATURE:
        raise SystemExit(f"error: unexpected LC_CODE_SIGNATURE remaining in {exe}")
    if cmd == LC_RPATH:
        path_off = struct.unpack_from("<I", data, offset + 8)[0]
        rpath = data[offset + path_off : offset + cmdsize].split(b"\0", 1)[0].decode("utf-8")
        rpaths.append(rpath)
    elif cmd in DYLIB_CMDS:
        name_off = struct.unpack_from("<I", data, offset + 8)[0]
        dname = data[offset + name_off : offset + cmdsize].split(b"\0", 1)[0].decode("utf-8")
        dylibs.append((cmd, dname))
    elif cmd == LC_SEGMENT_64:
        nsects = struct.unpack_from("<I", data, offset + 64)[0]
        for i in range(nsects):
            sect_off = struct.unpack_from("<I", data, offset + 72 + i * 80 + 48)[0]
            if sect_off and (first_section is None or sect_off < first_section):
                first_section = sect_off
    offset += cmdsize

assert offset == 32 + sizeofcmds, "Mach-O load command size mismatch"
if "@executable_path/Frameworks" not in rpaths:
    raise SystemExit(f"error: missing @executable_path/Frameworks LC_RPATH in {exe}: {rpaths}")
if not dylibs or dylibs[0] != (LC_LOAD_DYLIB, EARLY_MALLOC):
    raise SystemExit(f"error: EarlyMallocZoneRegistration is not first strong LC_LOAD_DYLIB: {dylibs[:3]}")

existing = [(cmd, name) for cmd, name in dylibs if name == install_name]
if existing:
    if existing[0][0] != LC_LOAD_DYLIB:
        raise SystemExit(f"error: {install_name} already present with non-strong command {hex(existing[0][0])}")
    if dylibs[-1][1] != install_name:
        raise SystemExit(f"error: {install_name} already present but not at end of dylib list: {dylibs}")
    print(f"  {install_name} already loaded strongly at end (idempotent)")
else:
    name_bytes = install_name.encode("utf-8") + b"\0"
    cmdsize = (24 + len(name_bytes) + 7) & ~7
    end = 32 + sizeofcmds
    if first_section is None or end + cmdsize > first_section:
        raise SystemExit(
            f"error: insufficient Mach-O header room in {exe}: end={end}, need={cmdsize}, first_section={first_section}"
        )
    if any(b != 0 for b in data[end : end + cmdsize]):
        raise SystemExit(f"error: non-zero bytes in Mach-O header padding [{end}:{end + cmdsize}] of {exe}")

    command = struct.pack("<6I", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000)
    command += name_bytes + b"\0" * (cmdsize - 24 - len(name_bytes))
    data[end : end + cmdsize] = command
    struct.pack_into("<2I", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    tmp_out = exe.with_suffix(".tmp_macho")
    tmp_out.write_bytes(data)
    tmp_out.chmod(exe.stat().st_mode)
    tmp_out.replace(exe)
    print(f"  appended strong LC_LOAD_DYLIB ({cmdsize} bytes) for {install_name}")

otool_l = subprocess.check_output(["otool", "-L", str(exe)], text=True).splitlines()[1:]
loaded = [line.strip().split(" (compatibility version", 1)[0] for line in otool_l if line.strip()]
assert loaded[0] == EARLY_MALLOC, f"EarlyMalloc order broken: {loaded}"
assert loaded[-1] == install_name, f"helper not last in otool -L: {loaded}"
PY
fi

echo "==> Verifying stripped chrome_framework exports Curium engine ABI"
chrome_fw_bin="$bundle/Frameworks/chrome_framework.framework/chrome_framework"
[ -f "$chrome_fw_bin" ] || { echo "error: missing chrome_framework binary at $chrome_fw_bin" >&2; exit 1; }
python3 - "$chrome_fw_bin" <<'PY'
import subprocess, sys
bin_path = sys.argv[1]
exports = subprocess.check_output(["nm", "-gU", bin_path], text=True)
assert "_ChromeMain" in exports, "chrome_framework missing exported _ChromeMain symbol"
objc_meta = subprocess.check_output(["otool", "-oV", bin_path], text=True)
for cls in ("CrIOSEngineBootstrap", "CrIOSExtensionManagerV1"):
    assert cls in objc_meta, f"chrome_framework missing required ObjC class metadata: {cls}"
print(f"  verified Curium ABI in {bin_path} (_ChromeMain, CrIOSEngineBootstrap, CrIOSExtensionManagerV1)")
PY

echo "==> Signing nested frameworks (without entitlements) then top-level app bundle"
if [ -d "$bundle/Frameworks" ]; then
  for fw in "$bundle/Frameworks"/*; do
    [ -e "$fw" ] || continue
    codesign --force --sign - --timestamp=none "$fw"
  done
fi

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
  codesign --force --sign - --timestamp=none \
    --entitlements "$work/entitlements.plist" "$bundle"
else
  codesign --force --sign - --timestamp=none "$bundle"
fi

echo "==> Verifying bundle signature (--deep --strict)"
codesign --verify --deep --strict "$bundle"
if [ -d "$bundle/Frameworks" ]; then
  for fw in "$bundle/Frameworks"/*; do
    [ -e "$fw" ] || continue
    if codesign -d --entitlements - "$fw" 2>/dev/null | grep -q 'com.apple.security.application-groups'; then
      echo "error: nested framework unexpectedly received app-group entitlements: $fw" >&2
      exit 1
    fi
  done
fi

echo "==> Validating Mach-O executable ($exe):"
lipo -archs "$exe_path"
vtool -show-build "$exe_path" | grep -E 'platform|minos|sdk' || true
if [ -f "$chrome_fw" ]; then
  echo "==> Validating Blink chrome_framework Mach-O:"
  lipo -archs "$chrome_fw"
  vtool -show-build "$chrome_fw" | grep -E 'platform|minos|sdk' || true
fi
if [ -f "$bundle/Frameworks/ChromiumExtensionsUI.framework/ChromiumExtensionsUI" ]; then
  echo "==> Validating ChromiumExtensionsUI Mach-O:"
  lipo -archs "$bundle/Frameworks/ChromiumExtensionsUI.framework/ChromiumExtensionsUI"
  vtool -show-build "$bundle/Frameworks/ChromiumExtensionsUI.framework/ChromiumExtensionsUI" | grep -E 'platform|minos|sdk' || true
  otool -L "$exe_path"
fi
echo "==> Final Chromium.app size: $(du -sh "$bundle" | cut -f1)"

mkdir -p "$(dirname "$output_ipa")"
rm -f "$output_ipa"
(cd "$work" && zip -qry "$output_ipa" Payload)
shasum -a 256 "$output_ipa" > "${output_ipa}.sha256"
ls -lh "$output_ipa"
cat "${output_ipa}.sha256"
