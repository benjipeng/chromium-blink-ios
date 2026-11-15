#!/usr/bin/env python3
"""Implements Chromium's //build/toolchain/apple/apple_tool_wrapper.gni contract.

Modes (selected via APPLE_TOOL_MODE environment variable):
  - record (macOS `xcode-27` Stage 1): executes the real Apple build script,
    sanitizes absolute Xcode SDK paths out of depfiles (preserving escaped
    spaces), and records all outputs (including loose AppIcon*.png files emitted
    alongside Assets.car) into APPLE_TOOL_CACHE_DIR.
  - replay (Linux `ubuntu-24.04` Stage 2/3): restores recorded outputs from
    APPLE_TOOL_CACHE_DIR for pre-link steps (`swift`, `compile_xcassets`,
    `compile_ib_files`, `intentbuilderc`), and defers post-link
    `extract_metadata` (`appintentsmetadataprocessor`) to Stage 4 packaging.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time


def split_wrapper_argv(argv: list[str]) -> tuple[str, list[str], list[str], list[str]]:
    if "--" not in argv:
        raise ValueError(f"Expected '--' separator in wrapper args: {argv}")
    sep = argv.index("--")
    head = argv[:sep]
    tail = argv[sep + 1 :]
    if not tail:
        raise ValueError("Missing wrapped script command after '--'")

    tool_kind = ""
    inputs: list[str] = []
    outputs: list[str] = []
    i = 0
    while i < len(head):
        arg = head[i]
        if arg.startswith("--tool="):
            tool_kind = arg.split("=", 1)[1]
            i += 1
        elif arg == "--tool":
            tool_kind = head[i + 1]
            i += 2
        elif arg == "--input":
            inputs.append(head[i + 1])
            i += 2
        elif arg == "--output":
            outputs.append(head[i + 1])
            i += 2
        else:
            i += 1
    if not tool_kind:
        raise ValueError(f"Missing --tool=<kind> in wrapper args: {head}")
    return tool_kind, inputs, outputs, tail


def get_opt(args: list[str], names: tuple[str, ...]) -> str:
    for idx, tok in enumerate(args):
        if tok in names and idx + 1 < len(args):
            return args[idx + 1]
        for name in names:
            if tok.startswith(name + "="):
                return tok.split("=", 1)[1]
    return ""


def parse_step_outputs(
    tool_kind: str, wrapper_outputs: list[str], script_args: list[str]
) -> tuple[str, list[str], str]:
    """Returns (primary_key_path, output_paths_or_dirs, depfile_path)."""
    if tool_kind == "swift":
        header = get_opt(script_args, ("--header-path",))
        target_out_dir = get_opt(script_args, ("--target-out-dir",))
        depfile = get_opt(script_args, ("--depfile-path",))
        if not header or not target_out_dir:
            raise RuntimeError(f"Cannot parse swift outputs from: {script_args}")
        outs = [header, target_out_dir]
        if depfile:
            outs.append(depfile)
        return header, outs, depfile

    if tool_kind == "compile_xcassets":
        out_car = get_opt(script_args, ("-o", "--output"))
        partial_plist = get_opt(script_args, ("-P", "--partial-info-plist"))
        if not out_car:
            raise RuntimeError(f"Cannot parse xcassets output from: {script_args}")
        outs = [out_car]
        if partial_plist:
            outs.append(partial_plist)
        return out_car, outs, ""

    if tool_kind == "compile_ib_files":
        out_ib = get_opt(script_args, ("-o", "--output")) or (
            wrapper_outputs[0] if wrapper_outputs else ""
        )
        if not out_ib:
            raise RuntimeError(f"Cannot parse ibtool output from: {script_args}")
        return out_ib, [out_ib], ""

    if tool_kind == "intentbuilderc":
        if not wrapper_outputs:
            raise RuntimeError(f"No --output provided for intentbuilderc: {script_args}")
        return wrapper_outputs[0], list(wrapper_outputs), ""

    if tool_kind == "extract_metadata":
        out_dir = get_opt(script_args, ("--output",))
        depfile = get_opt(script_args, ("--depfile",))
        if not out_dir:
            raise RuntimeError(f"Cannot parse extract_metadata output: {script_args}")
        outs = [out_dir]
        if depfile:
            outs.append(depfile)
        return out_dir, outs, depfile

    raise RuntimeError(f"Unsupported apple_tool_wrapper kind: {tool_kind}")


_DEP_TOKEN_SPLIT_RE = re.compile(r"(?<!\\)\s+")


def sanitize_depfile(depfile_path: pathlib.Path) -> None:
    """Removes host-specific absolute Xcode/SDK paths while preserving '\\ ' escapes."""
    if not depfile_path.is_file():
        return
    raw = depfile_path.read_text(encoding="utf-8", errors="replace")
    joined = raw.replace("\\\n", " ")
    out_lines: list[str] = []
    for line in joined.splitlines():
        if ":" not in line:
            continue
        target, deps_part = line.split(":", 1)
        kept: list[str] = []
        for dep in _DEP_TOKEN_SPLIT_RE.split(deps_part.strip()):
            if not dep:
                continue
            unescaped = dep.replace("\\ ", " ")
            if unescaped.startswith(
                ("/Applications/Xcode", "/Library/Developer", "/System/Library")
            ):
                continue
            kept.append(dep)
        out_lines.append(f"{target.strip()}: {' '.join(kept)}")
    depfile_path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")


def cache_entry_dir(cache_root: pathlib.Path, tool_kind: str, primary_path: str) -> pathlib.Path:
    norm = pathlib.PurePosixPath(primary_path).as_posix()
    digest = hashlib.sha256(f"{tool_kind}\0{norm}".encode("utf-8")).hexdigest()[:24]
    return cache_root / f"{tool_kind}_{digest}"


def copy_path(src: pathlib.Path, dst: pathlib.Path, touch_now: bool = False) -> None:
    if src.is_dir():
        if dst.exists():
            shutil.rmtree(dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst, symlinks=True)
        if touch_now:
            now = time.time()
            for root, _, files in os.walk(dst):
                os.utime(root, (now, now))
                for f in files:
                    p = os.path.join(root, f)
                    if not os.path.islink(p):
                        os.utime(p, (now, now))
    elif src.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists() or dst.is_symlink():
            dst.unlink()
        shutil.copy2(src, dst, follow_symlinks=False)
        if touch_now and not dst.is_symlink():
            now = time.time()
            os.utime(dst, (now, now))


def run_record(
    cache_root: pathlib.Path,
    tool_kind: str,
    wrapper_outputs: list[str],
    tail: list[str],
) -> int:
    script, script_args = tail[0], tail[1:]
    primary, outs, depfile = parse_step_outputs(tool_kind, wrapper_outputs, script_args)

    bundle_dir_before: set[str] = set()
    bundle_parent = pathlib.Path(primary).parent
    if tool_kind == "compile_xcassets" and bundle_parent.is_dir():
        bundle_dir_before = {p.name for p in bundle_parent.iterdir()}

    proc = subprocess.run([sys.executable, script, *script_args])
    if proc.returncode != 0:
        return proc.returncode

    if depfile:
        sanitize_depfile(pathlib.Path(depfile))

    # Capture loose AppIcon*.png / LaunchImage*.png files emitted alongside Assets.car.
    if tool_kind == "compile_xcassets" and bundle_parent.is_dir():
        for child in sorted(bundle_parent.iterdir()):
            if child.is_file() and (
                child.name not in bundle_dir_before
                or child.name.startswith(("AppIcon", "LaunchImage"))
            ):
                rel_child = child.as_posix()
                if rel_child not in outs:
                    outs.append(rel_child)

    entry = cache_entry_dir(cache_root, tool_kind, primary)
    files_root = entry / "files"
    if entry.exists():
        shutil.rmtree(entry)
    files_root.mkdir(parents=True, exist_ok=True)

    recorded: list[str] = []
    for rel in outs:
        p = pathlib.Path(rel)
        if p.exists():
            norm = p.as_posix()
            copy_path(p, files_root / norm, touch_now=False)
            recorded.append(norm)

    meta = {
        "tool": tool_kind,
        "primary": pathlib.PurePosixPath(primary).as_posix(),
        "recorded_paths": recorded,
    }
    (entry / "meta.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    return 0


def defer_extract_metadata(script: str, script_args: list[str]) -> int:
    out_dir = pathlib.Path(get_opt(script_args, ("--output",)))
    depfile = pathlib.Path(get_opt(script_args, ("--depfile",)))
    binary_file = get_opt(script_args, ("--binary-file",))
    module_info_rel = get_opt(script_args, ("--module-info-path",))

    meta_dir = out_dir / "Metadata.appintents"
    meta_dir.mkdir(parents=True, exist_ok=True)
    (meta_dir / "extract.actionsdata").write_text("{}\n", encoding="utf-8")
    (meta_dir / "version.json").write_text('{"version": "1.0"}\n', encoding="utf-8")

    depfile.parent.mkdir(parents=True, exist_ok=True)
    depfile.write_text(
        f"{meta_dir / 'extract.actionsdata'}: {binary_file}\n"
        f"{meta_dir / 'version.json'}: {binary_file}\n",
        encoding="utf-8",
    )

    bundle_dir = pathlib.Path(
        os.environ.get("APPLE_TOOL_DEFERRED_DIR", ".deferred_extract_metadata")
    )
    bundle_dir.mkdir(parents=True, exist_ok=True)

    build_root = pathlib.Path.cwd().resolve()
    src_root = pathlib.Path("../..").resolve()

    def stage_rel_to_build(rel_str: str) -> None:
        if not rel_str:
            return
        p = pathlib.Path(rel_str)
        if not p.is_file():
            return
        resolved = p.resolve()
        try:
            from_build = resolved.relative_to(build_root)
            copy_path(resolved, bundle_dir / "build" / from_build)
            return
        except ValueError:
            pass
        try:
            from_src = resolved.relative_to(src_root)
            copy_path(resolved, bundle_dir / "tree" / from_src)
        except ValueError:
            copy_path(resolved, bundle_dir / "build" / rel_str)

    stage_rel_to_build(script)
    if module_info_rel and pathlib.Path(module_info_rel).is_file():
        stage_rel_to_build(module_info_rel)
        mi_data = json.loads(pathlib.Path(module_info_rel).read_text(encoding="utf-8"))
        for sf in mi_data.get("swift_files", []):
            stage_rel_to_build(sf)
        for cf in mi_data.get("const_files", []):
            stage_rel_to_build(cf)

    manifest_path = bundle_dir / "manifest.json"
    existing: list[dict] = []
    if manifest_path.is_file():
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
    existing.append({"script": script, "args": script_args})
    manifest_path.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
    return 0


def run_replay(
    cache_root: pathlib.Path,
    tool_kind: str,
    wrapper_outputs: list[str],
    tail: list[str],
) -> int:
    script, script_args = tail[0], tail[1:]
    if tool_kind == "extract_metadata":
        return defer_extract_metadata(script, script_args)

    primary, _, _ = parse_step_outputs(tool_kind, wrapper_outputs, script_args)
    entry = cache_entry_dir(cache_root, tool_kind, primary)
    meta_file = entry / "meta.json"
    if not meta_file.is_file():
        sys.stderr.write(
            f"[apple_tool_wrapper] cache miss for tool={tool_kind} primary={primary} "
            f"(expected {meta_file})\n"
        )
        return 1

    meta = json.loads(meta_file.read_text(encoding="utf-8"))
    files_root = entry / "files"
    for rel in meta.get("recorded_paths", []):
        copy_path(files_root / rel, pathlib.Path(rel), touch_now=True)
    return 0


def main(argv: list[str]) -> int:
    mode = os.environ.get("APPLE_TOOL_MODE", "record" if sys.platform == "darwin" else "replay")
    cache_dir_str = os.environ.get("APPLE_TOOL_CACHE_DIR", "")
    if not cache_dir_str:
        sys.stderr.write("error: APPLE_TOOL_CACHE_DIR environment variable is required\n")
        return 1
    cache_root = pathlib.Path(cache_dir_str).resolve()

    tool_kind, _inputs, wrapper_outputs, tail = split_wrapper_argv(argv)
    if mode == "record":
        return run_record(cache_root, tool_kind, wrapper_outputs, tail)
    if mode == "replay":
        return run_replay(cache_root, tool_kind, wrapper_outputs, tail)

    sys.stderr.write(f"error: unknown APPLE_TOOL_MODE={mode!r}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
