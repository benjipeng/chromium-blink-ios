#!/usr/bin/env bash
# Overlays macOS arm64 host toolchains (gn, ninja, cpython3, typescript/tsgo,
# clang, rust, node) onto a Linux-synced chromium-ios-src workspace so `xcode-27`
# Stage 1 can run `gn gen` and compile the 26 pre-link Apple targets natively.
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

echo "==> Bootstrapping mac-arm64 gn, ninja, cpython3, and typescript via CIPD"
ensure_file="$(mktemp)"
trap 'rm -f "$ensure_file"' EXIT

python3 - "$src_dir/DEPS" "$ensure_file" <<'PY'
import re, sys

deps_txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()

class Var:
    def __init__(self, name): self.name = name
    def __add__(self, other): return f"{{Var:{self.name}}}{other}"
    def __radd__(self, other): return f"{other}{{Var:{self.name}}}"

env = {"Var": Var, "Str": str}
exec(deps_txt, env)
vars_d = env.get("vars", {})
deps_d = env.get("deps", {})

def resolve(val):
    if isinstance(val, Var):
        return str(vars_d[val.name])
    if isinstance(val, str):
        for k, v in vars_d.items():
            val = val.replace(f"{{Var:{k}}}", str(v)).replace(f"{{{k}}}", str(v))
    return str(val)

wanted_paths = (
    "src/buildtools/mac",
    "src/third_party/ninja",
    "src/third_party/cpython3/host",
    "src/third_party/typescript/mac-arm64/src",
)

with open(sys.argv[2], "w", encoding="utf-8") as f:
    for dep_path in wanted_paths:
        spec = deps_d.get(dep_path)
        if not isinstance(spec, dict) or spec.get("dep_type") != "cipd":
            continue
        subdir = dep_path[len("src/"):]
        f.write(f"@Subdir {subdir}\n")
        for pkg in spec.get("packages", []):
            p = (
                resolve(pkg["package"])
                .replace("${{platform}}", "mac-arm64")
                .replace("${{arch}}", "arm64")
            )
            v = resolve(pkg["version"])
            f.write(f"{p} {v}\n")
PY

cat "$ensure_file"
rm -rf \
  "$src_dir/third_party/ninja" \
  "$src_dir/third_party/cpython3/host" \
  "$src_dir/buildtools/mac" \
  "$src_dir/third_party/typescript/mac-arm64"
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
