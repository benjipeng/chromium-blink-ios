#!/usr/bin/env python3
"""Extracts exact Ninja target lists strictly within `chrome`'s transitive graph.

  - `apple-prebuild`: pre-link `swift`, `compile_xcassets`, `compile_ib_files`,
    and `intentbuilderc` targets (resolving directory outputs like `.storyboardc`
    to their declared inner Ninja file targets).
  - `codegen`: generated sources/headers/snapshots (`gen/**`, including V8's
    `embedded.S`), host executables (`clang_x64*/**`), and Rust `.rlib`/`.rmeta`
    inside `chrome`'s true `ninja -t inputs` closure so parallel C++ shards
    never re-run host tools or codegen.
  - `c-shard`: round-robin slice of target iOS `.o` object compilations.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import shlex
import subprocess
import sys


def run_ninja_tool(ninja_bin: str, out_dir: pathlib.Path, *tool_args: str) -> list[str]:
    out = subprocess.check_output(
        [ninja_bin, "-C", str(out_dir), "-t", *tool_args],
        text=True,
        errors="replace",
    )
    return [line.strip() for line in out.splitlines() if line.strip()]


def get_declared_targets(ninja_bin: str, out_dir: pathlib.Path) -> dict[str, str]:
    declared: dict[str, str] = {}
    for line in run_ninja_tool(ninja_bin, out_dir, "targets", "all"):
        tgt, sep, rule = line.partition(":")
        if sep:
            declared[tgt.strip()] = rule.strip()
    return declared


def extract_flag_value(tokens: list[str], flags: tuple[str, ...]) -> str:
    for idx, tok in enumerate(tokens):
        if tok in flags and idx + 1 < len(tokens):
            return tokens[idx + 1]
        for fl in flags:
            if tok.startswith(fl + "="):
                return tok.split("=", 1)[1]
    return ""


def collect_apple_prebuild_targets(
    commands: list[str], declared: dict[str, str]
) -> list[str]:
    targets: list[str] = []
    seen: set[str] = set()
    declared_keys = sorted(declared.keys())

    def add_resolved(candidate: str) -> None:
        if not candidate:
            return
        if candidate in declared:
            if candidate not in seen:
                seen.add(candidate)
                targets.append(candidate)
            return
        # Directory outputs (e.g. LaunchScreen.storyboardc) are declared in GN
        # via their inner files (LaunchScreen.storyboardc/Info.plist, etc.).
        prefix = candidate.rstrip("/") + "/"
        for k in declared_keys:
            if k.startswith(prefix):
                if k not in seen:
                    seen.add(k)
                    targets.append(k)
                return

    for cmd in commands:
        if "extract_metadata.py" in cmd or "--tool=extract_metadata" in cmd:
            continue
        is_apple = any(
            marker in cmd
            for marker in (
                "--tool=swift",
                "--tool=compile_xcassets",
                "--tool=compile_ib_files",
                "--tool=intentbuilderc",
                "swiftc.py",
                "compile_xcassets.py",
                "compile_ib_files.py",
            )
        )
        if not is_apple:
            continue
        try:
            tokens = shlex.split(cmd)
        except ValueError:
            continue

        if "swiftc.py" in cmd or "--tool=swift" in cmd:
            add_resolved(extract_flag_value(tokens, ("--header-path",)))
        elif "compile_xcassets.py" in cmd or "--tool=compile_xcassets" in cmd:
            add_resolved(extract_flag_value(tokens, ("-o", "--output")))
        elif "compile_ib_files.py" in cmd or "--tool=compile_ib_files" in cmd:
            add_resolved(extract_flag_value(tokens, ("--output", "-o")))
        elif "--tool=intentbuilderc" in cmd:
            add_resolved(extract_flag_value(tokens, ("--output",)))

    return targets


_OBJ_OUT_RE = re.compile(r"(?:^|\s)-o\s+([^\s;&\"']+\.o)(?:\s|$)")


def collect_compile_object_targets(commands: list[str]) -> list[str]:
    objs: list[str] = []
    seen: set[str] = set()
    for cmd in commands:
        if " -c " not in cmd:
            continue
        m = _OBJ_OUT_RE.search(cmd)
        if not m:
            continue
        obj = m.group(1)
        # Host toolchain objects (`clang_x64*`) are built once in Stage 2a codegen.
        if obj.startswith("clang_x64"):
            continue
        if obj not in seen:
            seen.add(obj)
            objs.append(obj)
    return objs


def collect_codegen_targets(
    ninja_bin: str,
    out_dir: pathlib.Path,
    root_target: str,
    declared: dict[str, str],
) -> list[str]:
    """Selects strictly transitive `chrome` inputs that produce `gen/**`, host tools, or Rust libs."""
    closure = run_ninja_tool(ninja_bin, out_dir, "inputs", root_target)
    selected: list[str] = []
    seen: set[str] = set()
    skip_rules = {"phony", "stamp", "swift", "compile_xcassets"}

    for item in closure:
        rule = declared.get(item)
        if not rule or rule in skip_rules:
            continue
        # Exclude post-link metadata extraction from pre-C++ codegen.
        if "metadata" in item and item.endswith((".actionsdata", "version.json")):
            continue
        is_gen = item.startswith("gen/")
        is_rust = item.startswith("local_rustc_sysroot/") or item.endswith((".rlib", ".rmeta"))
        is_host_bin = (
            item.startswith("clang_x64")
            and "/" in item
            and "/obj/" not in item
            and not item.endswith((".o", ".a", ".d", ".stamp"))
        )
        if (is_gen or is_rust or is_host_bin) and item not in seen:
            seen.add(item)
            selected.append(item)
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ninja", default="ninja", help="Path to ninja binary")
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--root-target", default="chrome")
    parser.add_argument(
        "--mode",
        choices=("apple-prebuild", "codegen", "c-shard"),
        required=True,
    )
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=0)
    args = parser.parse_args()

    if args.mode == "apple-prebuild":
        commands = run_ninja_tool(args.ninja, args.out_dir, "commands", args.root_target)
        declared = get_declared_targets(args.ninja, args.out_dir)
        targets = collect_apple_prebuild_targets(commands, declared)
    elif args.mode == "codegen":
        declared = get_declared_targets(args.ninja, args.out_dir)
        targets = collect_codegen_targets(args.ninja, args.out_dir, args.root_target, declared)
    else:
        if not (0 <= args.shard_index < args.shard_count):
            raise ValueError("Invalid --shard-index / --shard-count")
        commands = run_ninja_tool(args.ninja, args.out_dir, "commands", args.root_target)
        all_objs = collect_compile_object_targets(commands)
        targets = [
            obj
            for obj in all_objs
            if int(hashlib.sha1(obj.encode("utf-8")).hexdigest(), 16) % args.shard_count
            == args.shard_index
        ]

    for t in targets:
        print(t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
