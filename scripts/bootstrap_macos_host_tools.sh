#!/usr/bin/env bash
# Overlays all macOS arm64 host dependencies from Chromium's `src/DEPS` onto a
# Linux-synced `chromium-ios-src` snapshot using `depot_tools/gclient_eval.py`.
# Covers both CIPD (`${{platform}}` / `${{arch}}`) and first-class GCS entries
# (including per-object conditions, SHA-256 + size verification, and archive
# extraction) without hand-picked package lists or system Node fallbacks.
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
work_dir="$(cd "$work_dir" && pwd)"
src_dir="$work_dir/src"
depot_tools="$work_dir/depot_tools"
export PATH="$depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0

echo "==> Evaluating src/DEPS for mac-arm64 CIPD & GCS host dependencies"
python3 - "$src_dir" "$depot_tools" <<'PY'
from __future__ import annotations

import collections.abc
import concurrent.futures
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

src_dir = pathlib.Path(sys.argv[1]).resolve()
depot_tools = pathlib.Path(sys.argv[2]).resolve()
sys.path.insert(0, str(depot_tools))

import gclient_eval  # type: ignore

deps_path = src_dir / "DEPS"
deps_content = deps_path.read_text(encoding="utf-8")

# Match the exact `.gclient` custom_vars used when creating the source snapshot.
CUSTOM_VARS: dict[str, object] = {
    "checkout_configuration": "small",
    "checkout_ios_webkit": False,
    "checkout_js_coverage_modules": False,
    "checkout_telemetry_dependencies": False,
    "checkout_pgo_profiles": False,
}


def make_builtin_vars(host_os: str, host_cpu: str) -> dict[str, object]:
    return {
        "checkout_android": False,
        "checkout_chromeos": False,
        "checkout_fuchsia": False,
        "checkout_ios": True,
        "checkout_linux": False,
        "checkout_mac": False,
        "checkout_win": False,
        "checkout_arm": False,
        "checkout_arm64": False,
        "checkout_x86": False,
        "checkout_mips": False,
        "checkout_mips64": False,
        "checkout_ppc": False,
        "checkout_riscv64": False,
        "checkout_s390": False,
        "checkout_x64": False,
        "checkout_loong64": False,
        "non_git_source": True,
        "host_os": host_os,
        "host_cpu": host_cpu,
    }


mac_builtins = make_builtin_vars("mac", "arm64")
lin_builtins = make_builtin_vars("linux", "x64")

parsed = gclient_eval.Parse(
    deps_content, str(deps_path), CUSTOM_VARS, mac_builtins
)

mac_vars = dict(parsed.get("vars", {}))
mac_vars.update(mac_builtins)
mac_vars.update(CUSTOM_VARS)

lin_vars = dict(parsed.get("vars", {}))
lin_vars.update(lin_builtins)
lin_vars.update(CUSTOM_VARS)


def eval_cond(cond: str | None, variables: dict[str, object]) -> bool:
    if not cond:
        return True
    return bool(gclient_eval.EvaluateCondition(cond, variables))


def rel_under_src(dep_key: str) -> pathlib.Path:
    norm = dep_key.replace("\\", "/").lstrip("/")
    if norm.startswith("src/"):
        norm = norm[len("src/") :]
    return src_dir / norm


# Unused 1.1 GB legacy Intel Swift 5.8 CIPD bundle; builds use system Xcode 27 Swift 6.2.
SKIP_CIPD_KEYS = {"src/third_party/swift-toolchain"}

cipd_entries: list[tuple[str, list[tuple[str, str]]]] = []
gcs_plan: list[tuple[str, str, list[dict[str, object]]]] = []

for dep_key, spec in sorted(parsed.get("deps", {}).items()):
    if not isinstance(spec, collections.abc.Mapping):
        continue
    dep_type = spec.get("dep_type")
    cond = spec.get("condition")

    if dep_type == "cipd":
        if dep_key in SKIP_CIPD_KEYS:
            continue
        on_mac = eval_cond(cond, mac_vars)
        if not on_mac:
            continue
        on_lin = eval_cond(cond, lin_vars)
        pkgs = spec.get("packages", [])
        has_plat_placeholder = any(
            "${" in str(p.get("package", "")) for p in pkgs
        )
        if not on_lin or has_plat_placeholder:
            resolved_pkgs: list[tuple[str, str]] = []
            for p in pkgs:
                pkg_name = (
                    str(p["package"])
                    .replace("${{platform}}", "mac-arm64")
                    .replace("${platform}", "mac-arm64")
                    .replace("${{arch}}", "arm64")
                    .replace("${arch}", "arm64")
                )
                resolved_pkgs.append((pkg_name, str(p["version"])))
            if resolved_pkgs:
                cipd_entries.append((dep_key, resolved_pkgs))

    elif dep_type == "gcs":
        top_mac = eval_cond(cond, mac_vars)
        if not top_mac:
            continue
        top_lin = eval_cond(cond, lin_vars)
        active_objs: list[dict[str, object]] = []
        for obj in spec.get("objects", []):
            obj_mac = top_mac and eval_cond(obj.get("condition"), mac_vars)
            obj_lin = top_lin and eval_cond(obj.get("condition"), lin_vars)
            if obj_mac and not obj_lin:
                active_objs.append(obj)
        if active_objs:
            gcs_plan.append((dep_key, str(spec["bucket"]), active_objs))

# 1. Materialize CIPD host packages.
if cipd_entries:
    ensure_lines: list[str] = []
    for dep_key, pkgs in cipd_entries:
        target_dir = rel_under_src(dep_key)
        subdir = target_dir.relative_to(src_dir).as_posix()
        if target_dir.exists():
            shutil.rmtree(target_dir)
        ensure_lines.append(f"@Subdir {subdir}")
        for pkg_name, pkg_ver in pkgs:
            ensure_lines.append(f"{pkg_name} {pkg_ver}")
            print(f"  [cipd] {subdir}: {pkg_name} @ {pkg_ver}")

    with tempfile.NamedTemporaryFile(
        "w", suffix=".ensure", delete=False, encoding="utf-8"
    ) as tf:
        tf.write("\n".join(ensure_lines) + "\n")
        ensure_path = tf.name
    try:
        subprocess.run(
            ["cipd", "ensure", "-root", str(src_dir), "-ensure-file", ensure_path],
            check=True,
        )
    finally:
        os.unlink(ensure_path)

# 2. Download, SHA-256 verify, and unpack first-class GCS host artifacts.
dl_root = pathlib.Path(tempfile.mkdtemp(prefix="gcs_mac_deps_"))


def fetch_and_verify(task: tuple[int, str, dict[str, object]]) -> tuple[int, pathlib.Path]:
    idx, bucket, obj = task
    object_name = str(obj["object_name"])
    expected_sha256 = str(obj["sha256sum"]).lower()
    expected_size = obj.get("size_bytes")
    url = f"https://storage.googleapis.com/{bucket}/{urllib.parse.quote(object_name, safe='/')}"
    dest = dl_root / f"obj_{idx}"

    last_err: Exception | None = None
    for attempt in range(1, 4):
        try:
            hasher = hashlib.sha256()
            total = 0
            req = urllib.request.Request(url, headers={"User-Agent": "chromium-blink-ios-ci/1.0"})
            with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as out_f:
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    out_f.write(chunk)
                    hasher.update(chunk)
                    total += len(chunk)
            actual_sha256 = hasher.hexdigest().lower()
            if expected_size is not None and total != int(expected_size):
                raise RuntimeError(
                    f"Size mismatch for {url}: expected {expected_size}, got {total}"
                )
            if actual_sha256 != expected_sha256:
                raise RuntimeError(
                    f"SHA-256 mismatch for {url}: expected {expected_sha256}, got {actual_sha256}"
                )
            print(
                f"  [gcs] verified {bucket}/{object_name} ({total / 1e6:.1f} MB, sha256={actual_sha256[:12]}...)",
                flush=True,
            )
            return idx, dest
        except Exception as exc:
            last_err = exc
            if dest.exists():
                dest.unlink()
            if attempt < 3:
                time.sleep(2 * attempt)
    raise RuntimeError(f"Failed downloading {url}: {last_err}") from last_err


try:
    flat_tasks: list[tuple[int, str, dict[str, object]]] = []
    task_map: dict[tuple[str, int], int] = {}
    for dep_key, bucket, objs in gcs_plan:
        for obj_i, obj in enumerate(objs):
            tid = len(flat_tasks)
            flat_tasks.append((tid, bucket, obj))
            task_map[(dep_key, obj_i)] = tid

    downloaded: dict[int, pathlib.Path] = {}
    if flat_tasks:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for tid, path in pool.map(fetch_and_verify, flat_tasks):
                downloaded[tid] = path

    for dep_key, _bucket, objs in gcs_plan:
        out_dir = rel_under_src(dep_key)
        if out_dir.exists():
            shutil.rmtree(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)

        for obj_i, obj in enumerate(objs):
            staged_file = downloaded[task_map[(dep_key, obj_i)]]
            output_file = obj.get("output_file")
            gcs_flat_name = str(obj["object_name"]).replace("/", "_").replace("\\", "_")
            artifact_path = out_dir / (str(output_file) if output_file else f".{gcs_flat_name}")
            artifact_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(staged_file), str(artifact_path))

            if tarfile.is_tarfile(artifact_path):
                subprocess.run(
                    ["tar", "-xf", str(artifact_path), "-C", str(out_dir)],
                    check=True,
                )
                artifact_path.unlink(missing_ok=True)
            elif zipfile.is_zipfile(artifact_path):
                with zipfile.ZipFile(artifact_path) as zf:
                    zf.extractall(out_dir)
                artifact_path.unlink(missing_ok=True)
            else:
                artifact_path.chmod(0o755)
finally:
    shutil.rmtree(dl_root, ignore_errors=True)
PY

echo "==> Verifying mac-arm64 host toolchain binaries:"
"$src_dir/buildtools/mac/gn" --version
"$src_dir/third_party/ninja/ninja" --version
"$src_dir/third_party/cpython3/host/bin/python3" --version
"$src_dir/third_party/llvm-build/Release+Asserts/bin/clang" --version | head -n 1
"$src_dir/third_party/rust-toolchain/bin/rustc" --version
"$src_dir/third_party/node/mac_arm64/node-darwin-arm64/bin/node" --version
ls -lh \
  "$src_dir/third_party/llvm-libclang/lib/libclang.dylib" \
  "$src_dir/third_party/llvm-build/Release+Asserts/lib/clang/"*/lib/darwin/libclang_rt.ios.a
