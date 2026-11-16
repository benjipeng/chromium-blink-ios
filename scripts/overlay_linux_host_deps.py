#!/usr/bin/env python3
"""Overlays the Linux-host-only dependencies that the iOS source snapshot omits.

The snapshot is synced with `target_os = ["ios"]` and `target_os_only = True`,
so DEPS entries gated on `checkout_linux` are absent, yet Linux host toolchains
(`clang_x64*`) still need a few of them. Revisions and package versions are
resolved from `src/DEPS` and its `recursedeps` at the pinned revision, so they
roll with Chromium; only the list of paths is curated here.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

# Paths (gclient-style, rooted at `src/`) needed by Linux host builds.
LINUX_HOST_DEPS = (
    # `base/` on Linux hosts includes linux_syscall_support.h.
    "src/third_party/lss",
    # Tint's generated sources run `tools/run gen`, which needs a host Go.
    "src/third_party/dawn/tools/golang/linux-amd64",
)

# Must match the `.gclient` custom_vars used to create the source snapshot.
CUSTOM_VARS: dict[str, object] = {
    "checkout_configuration": "small",
    "checkout_ios_webkit": False,
    "checkout_js_coverage_modules": False,
    "checkout_telemetry_dependencies": False,
    "checkout_pgo_profiles": False,
}
BUILTIN_VARS: dict[str, object] = {
    "checkout_android": False,
    "checkout_chromeos": False,
    "checkout_fuchsia": False,
    "checkout_ios": True,
    "checkout_linux": True,
    "checkout_mac": False,
    "checkout_win": False,
    "non_git_source": True,
    "host_os": "linux",
    "host_cpu": "x64",
}


def load_specs(src_dir: pathlib.Path, gclient_eval) -> dict[str, dict]:
    """Returns {gclient path: dep spec} for src/DEPS and present recursedeps."""
    top_path = src_dir / "DEPS"
    top = gclient_eval.Parse(top_path.read_text(encoding="utf-8"), str(top_path), CUSTOM_VARS, BUILTIN_VARS)
    parent_vars = dict(top.get("vars", {}))
    parent_vars.update(CUSTOM_VARS)

    specs: dict[str, dict] = dict(top.get("deps", {}))
    for rel in top.get("recursedeps", []):
        name = rel[0] if isinstance(rel, (list, tuple)) else rel
        child_root = src_dir.parent / name
        child_deps = child_root / "DEPS"
        if not child_deps.is_file():
            continue
        child = gclient_eval.Parse(
            child_deps.read_text(encoding="utf-8"), str(child_deps), parent_vars, BUILTIN_VARS
        )
        relative = child.get("use_relative_paths", False)
        for key, spec in child.get("deps", {}).items():
            specs[f"{name}/{key}" if relative else key] = spec
    return specs


def fetch_git(url_at_rev: str, dest: pathlib.Path) -> None:
    url, rev = url_at_rev.rsplit("@", 1)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="git_dep_"))
    try:
        subprocess.run(["git", "init", "-q", str(tmp)], check=True)
        subprocess.run(["git", "-C", str(tmp), "fetch", "-q", "--depth=1", url, rev], check=True)
        subprocess.run(["git", "-C", str(tmp), "checkout", "-q", "--detach", "FETCH_HEAD"], check=True)
        shutil.rmtree(tmp / ".git")
        if dest.exists():
            shutil.rmtree(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(tmp), str(dest))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def fetch_cipd(src_dir: pathlib.Path, subdir: str, packages: list[dict]) -> None:
    lines = [f"@Subdir {subdir}"]
    for p in packages:
        name = str(p["package"])
        for placeholder, value in (("${{platform}}", "linux-amd64"), ("${platform}", "linux-amd64"),
                                   ("${{arch}}", "amd64"), ("${arch}", "amd64")):
            name = name.replace(placeholder, value)
        lines.append(f"{name} {p['version']}")
    with tempfile.NamedTemporaryFile("w", suffix=".ensure", delete=False, encoding="utf-8") as tf:
        tf.write("\n".join(lines) + "\n")
        ensure = tf.name
    try:
        subprocess.run(["cipd", "ensure", "-root", str(src_dir), "-ensure-file", ensure], check=True)
    finally:
        os.unlink(ensure)


def pin_mtimes(root: pathlib.Path) -> None:
    """Back-dates fetched files so outputs restored from codegen stay up to date."""
    epoch = 946684800  # 2000-01-01T00:00:00Z, same as apply_patches.sh
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            os.utime(os.path.join(dirpath, name), (epoch, epoch), follow_symlinks=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=pathlib.Path, required=True, help="Directory holding src/ and depot_tools/")
    args = parser.parse_args()

    work = args.work_dir.resolve()
    src_dir = work / "src"
    depot_tools = work / "depot_tools"
    sys.path.insert(0, str(depot_tools))
    os.environ["PATH"] = f"{depot_tools}{os.pathsep}{os.environ.get('PATH', '')}"
    os.environ.setdefault("DEPOT_TOOLS_UPDATE", "0")
    import gclient_eval  # type: ignore

    specs = load_specs(src_dir, gclient_eval)
    for key in LINUX_HOST_DEPS:
        spec = specs.get(key)
        if spec is None:
            print(f"::error::{key} is not declared in DEPS or its recursedeps", file=sys.stderr)
            return 1
        subdir = key[len("src/") :]
        dest = src_dir / subdir
        if dest.is_dir() and any(dest.iterdir()):
            print(f"  [present] {subdir}")
            continue
        if isinstance(spec, str):
            spec = {"url": spec}
        if spec.get("dep_type") == "cipd":
            print(f"  [cipd] {subdir}: " + ", ".join(f"{p['package']} @ {p['version']}" for p in spec["packages"]))
            fetch_cipd(src_dir, subdir, spec["packages"])
        else:
            print(f"  [git] {subdir}: {spec['url']}")
            fetch_git(str(spec["url"]), dest)
        pin_mtimes(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
