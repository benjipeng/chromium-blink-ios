#!/usr/bin/env python3
"""Extracts exact Ninja target lists strictly within `chrome`'s transitive graph.

  - `apple-prebuild`: pre-link `swift`, `compile_xcassets`, `compile_ib_files`,
    and `intentbuilderc` targets (resolving directory outputs like `.storyboardc`
    to their declared inner Ninja file targets).
  - `codegen`: on the real graph, generated files (`gen/**`), host tools
    (`clang_x64*/**`), Rust libs, and every generated input of the Apple edges
    (e.g. unzipped `obj/**/*.xcassets`), minus any candidate whose build would
    run target compile/link/Swift or Apple tools (those belong to later stages).
  - `c-shard`: SHA-1 slice of the target object compiles (cc/cxx/objc/objcxx/asm)
    in `chrome`; with --shard-count 1 it lists every object the link imports.
"""

from __future__ import annotations

import argparse
import collections
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


# Ninja shell-escapes `$out`, so object paths containing characters such as `=`
# (e.g. XNNPACK's `..._arch=armv8.2-a+fp16/` dirs) appear single-quoted.
_OBJ_OUT_RE = re.compile(r"(?:^|\s)-o\s+(?:'([^']+\.o)'|([^\s;&\"']+\.o))(?:\s|$)")


_TARGET_OBJECT_RULE_RE = re.compile(r"^(?!__)(?:.+_)?(?:cc|cxx|objc|objcxx|asm)$")


def collect_compile_object_targets(commands: list[str]) -> list[str]:
    objs: list[str] = []
    seen: set[str] = set()
    for cmd in commands:
        if " -c " not in cmd:
            continue
        m = _OBJ_OUT_RE.search(cmd)
        if not m:
            continue
        obj = m.group(1) or m.group(2)
        # Host toolchain objects (`clang_x64*`) are built once in Stage 2a codegen.
        if obj.startswith("clang_x64"):
            continue
        if obj not in seen:
            seen.add(obj)
            objs.append(obj)
    return objs


def collect_codegen_targets(out_dir: pathlib.Path, root_target: str) -> tuple[list[str], list[str]]:
    """Plans codegen on the real graph: generated files, host tools, Rust libs,
    and every generated input of the Apple edges, minus any candidate whose
    build would run target compile/link/Swift or Apple tools.

    Returns (planned, dropped); dropped candidates belong to later stages.
    """
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from ninja_graph import Contract, Graph, is_grouping, unescape

    contract = Contract(Graph(out_dir))
    _, order = contract.closure([contract.raw_of.get(root_target, root_target)])
    apple_required, _ = contract.apple_inputs(contract.apple_edges(order))

    planned: list[str] = []
    dropped: list[str] = []
    for node in order:
        e = contract.edge(node)
        if e is None or is_grouping(e):
            continue
        path = unescape(node)
        is_gen = path.startswith("gen/")
        is_rust = path.startswith("local_rustc_sysroot/") or path.endswith((".rlib", ".rmeta"))
        is_host_bin = (
            path.startswith("clang_x64")
            and "/obj/" not in path
            and not path.endswith((".o", ".a", ".d", ".stamp"))
        )
        if not (is_gen or is_rust or is_host_bin or node in apple_required):
            continue
        (dropped if contract.reaches_off_limits(node) else planned).append(path)
    return sorted(planned), sorted(dropped)


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
    parser.add_argument("--split-dir", type=pathlib.Path,
                        help="c-shard: also write every shard's list to DIR/shard-<i>.txt")
    args = parser.parse_args()

    if args.mode == "apple-prebuild":
        commands = run_ninja_tool(args.ninja, args.out_dir, "commands", args.root_target)
        declared = get_declared_targets(args.ninja, args.out_dir)
        targets = collect_apple_prebuild_targets(commands, declared)
    elif args.mode == "codegen":
        targets, dropped = collect_codegen_targets(args.out_dir, args.root_target)
        print(f"plan_shards: {len(targets)} codegen targets; {len(dropped)} candidates left to later "
              f"stages (they need target or Apple work), e.g. {dropped[:3]}", file=sys.stderr)
    else:
        if not (0 <= args.shard_index < args.shard_count):
            raise ValueError("Invalid --shard-index / --shard-count")
        commands = run_ninja_tool(args.ninja, args.out_dir, "commands", args.root_target)
        declared = get_declared_targets(args.ninja, args.out_dir)
        # Only plain target compiles: these are exactly the edges the link
        # stage replaces with imported objects (Swift objects come from Stage 1).
        all_objs = [o for o in collect_compile_object_targets(commands) if _TARGET_OBJECT_RULE_RE.match(declared.get(o, ""))]
        def shard_of(obj: str) -> int:
            return int(hashlib.sha1(obj.encode("utf-8")).hexdigest(), 16) % args.shard_count

        targets = [obj for obj in all_objs if shard_of(obj) == args.shard_index]
        if args.split_dir:
            args.split_dir.mkdir(parents=True, exist_ok=True)
            for i in range(args.shard_count):
                (args.split_dir / f"shard-{i}.txt").write_text("".join(o + "\n" for o in all_objs if shard_of(o) == i))
            (args.split_dir / "all.txt").write_text("".join(o + "\n" for o in all_objs))

    for t in targets:
        print(t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
