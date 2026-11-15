#!/usr/bin/env bash
# Overlays macOS arm64 host toolchains (gn, ninja, cpython3, clang, rust, node)
# onto a Linux-synced chromium-ios-src workspace so `xcode-27` Stage 1 can run
# `gn gen` and compile pre-link Swift/xcassets/ibtool targets natively.
set -euo pipefail

work_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --work-dir)
      work_dir="${2:?missing path}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[ -n "$work_dir" ] || { echo "usage: $0 --work-dir <work_dir>" >&2; exit 1; }
src_dir="$work_dir/src"
depot_tools="$work_dir/depot_tools"
export PATH="$depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0

echo "==> Bootstrapping mac-arm64 gn, ninja, and cpython3 via CIPD"
ensure_file="$(mktemp)"
trap 'rm -f "$ensure_file"' EXIT

python3 - "$src_dir/DEPS" "$ensure_file" <<'PY'
import re, sys
deps = open(sys.argv[1], encoding="utf-8", errors="replace").read()

def get_var(name, default):
    m = re.search(rf"'{name}':\s*'([^']+)'", deps)
    return m.group(1) if m else default

gn_ver = get_var("gn_version", "latest")
ninja_ver = get_var("ninja_version", "latest")
py_ver = get_var("cpython3_version", "latest")
ninja_pkg = get_var("ninja_package", "infra/3pp/tools/ninja/")

with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write("@Subdir buildtools/mac\n")
    f.write(f"gn/gn/mac-arm64 {gn_ver}\n")
    f.write("@Subdir third_party/ninja\n")
    f.write(f"{ninja_pkg}mac-arm64 {ninja_ver}\n")
    f.write("@Subdir third_party/cpython3/host\n")
    f.write(f"infra/3pp/tools/cpython3/mac-arm64 {py_ver}\n")
PY

rm -rf "$src_dir/third_party/ninja" "$src_dir/third_party/cpython3/host" "$src_dir/buildtools/mac"
cipd ensure -root "$src_dir" -ensure-file "$ensure_file"

echo "==> Installing mac-arm64 LLVM/Clang and Rust host toolchains"
python3 "$src_dir/tools/clang/scripts/update.py" --host-os=mac-arm64
python3 "$src_dir/tools/rust/update_rust.py"

if command -v node >/dev/null 2>&1; then
  node_dir="$src_dir/third_party/node/mac_arm64/node-darwin-arm64/bin"
  mkdir -p "$node_dir"
  ln -sf "$(command -v node)" "$node_dir/node"
fi

echo "==> mac-arm64 host tools ready:"
"$src_dir/buildtools/mac/gn" --version
"$src_dir/third_party/ninja/ninja" --version
"$src_dir/third_party/cpython3/host/bin/python3" --version
