#!/usr/bin/env bash
# Fetches a deterministically pruned Chromium iOS checkout at version.lock,
# installs Linux amd64 sysroot + Darwin clang runtime libraries, strips .git
# bloat, and optionally packs a zstd tarball for ghcr.io persistence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../version.lock
source "$REPO_ROOT/version.lock"

work_dir="$REPO_ROOT/work"
output_archive=""

while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir)
      work_dir="${2:?missing path}"
      shift 2
      ;;
    --output-archive)
      output_archive="${2:?missing archive path}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$work_dir"
work_dir="$(cd "$work_dir" && pwd)"
DEPOT_TOOLS="$work_dir/depot_tools"

if [ ! -x "$DEPOT_TOOLS/gclient" ]; then
  echo "==> Cloning depot_tools (shallow)"
  git clone --depth=1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
fi
export PATH="$DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0

# Bypass any global git-lfs smudge filters for unused prebuilt test blobs.
export GIT_CONFIG_COUNT=4
export GIT_CONFIG_KEY_0="filter.lfs.process"   GIT_CONFIG_VALUE_0=""
export GIT_CONFIG_KEY_1="filter.lfs.smudge"    GIT_CONFIG_VALUE_1=""
export GIT_CONFIG_KEY_2="filter.lfs.clean"     GIT_CONFIG_VALUE_2=""
export GIT_CONFIG_KEY_3="filter.lfs.required"  GIT_CONFIG_VALUE_3="false"

echo "==> Initializing blobless sparse checkout of chromium/src @ $CHROMIUM_REV"
mkdir -p "$work_dir/src"
if [ ! -d "$work_dir/src/.git" ]; then
  git -C "$work_dir/src" init -q
  git -C "$work_dir/src" remote add origin https://chromium.googlesource.com/chromium/src.git
fi
git -C "$work_dir/src" config protocol.version 2
git -C "$work_dir/src" config core.sparseCheckout true
git -C "$work_dir/src" config core.sparseCheckoutCone false
mkdir -p "$work_dir/src/.git/info"
cp "$REPO_ROOT/scripts/sparse_checkout.conf" "$work_dir/src/.git/info/sparse-checkout"

git -C "$work_dir/src" fetch --filter=blob:none --depth=1 --no-tags origin "$CHROMIUM_REV"
git -C "$work_dir/src" checkout -q --detach FETCH_HEAD

echo "==> Writing pruned .gclient configuration (target_os=ios, small)"
cat > "$work_dir/.gclient" <<'EOF'
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {
      "src/third_party/hunspell_dictionaries": None,
      "src/docs/website": None,
      "src/chrome/test/data/perf/canvas_bench": None,
      "src/chrome/test/data/perf/frame_rate/content": None,
      "src/chrome/test/data/xr/webvr_info": None,
    },
    "custom_vars": {
      "checkout_configuration": "small",
      "checkout_ios_webkit": False,
      "checkout_js_coverage_modules": False,
      "checkout_telemetry_dependencies": False,
      "checkout_pgo_profiles": False,
    },
  },
]
target_os = ["ios"]
target_os_only = True
EOF

echo "==> Running gclient sync --nohooks --no-history"
(cd "$work_dir" && gclient sync --nohooks --no-history --shallow)

echo "==> Running gclient runhooks"
(cd "$work_dir" && gclient runhooks)

if [ "$(uname -s)" = "Linux" ]; then
  echo "==> Installing Linux amd64 host sysroot (required by clang_x64 host tools)"
  python3 "$work_dir/src/build/linux/sysroot_scripts/install-sysroot.py" --arch=amd64

  echo "==> Installing Darwin/iOS compiler-rt builtins into Linux llvm-build"
  python3 - "$work_dir/src" <<'PY'
import os, sys
src_dir = sys.argv[1]
sys.path.insert(0, os.path.join(src_dir, "tools", "clang", "scripts"))
import update
update.DownloadAndUnpackClangMacRuntime(update.LLVM_BUILD_DIR)
print("Installed Darwin clang runtime into:", update.LLVM_BUILD_DIR)
PY
fi

echo "==> Stripping .git metadata directories to seal clean source tree"
find "$work_dir/src" -name ".git" -prune -exec rm -rf {} +
rm -rf "$DEPOT_TOOLS/.git"

echo "==> Pruned workspace sizes:"
du -sh "$work_dir/src" "$DEPOT_TOOLS"

if [ -n "$output_archive" ]; then
  mkdir -p "$(dirname "$output_archive")"
  echo "==> Packing zstd source archive -> $output_archive"
  tar -C "$work_dir" -I "zstd -T0 -6" -cf "$output_archive" src depot_tools
  ls -lh "$output_archive"
fi
