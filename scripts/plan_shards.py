#!/usr/bin/env python3
"""Extracts exact Ninja target lists strictly within `chrome`'s transitive graph.

  - `apple-prebuild`: pre-link `swift`, `compile_xcassets`, `compile_ib_files`,
    and `intentbuilderc` targets (resolving directory outputs like `.storyboardc`
    to their declared inner Ninja file targets).
  - `codegen`: generated sources/headers/snapshots (`gen/**`, including V8's
    `embedded.S`), host executables (`clang_x64*/**`), and Rust `.rlib`/`.rmeta`
    inside `chrome`'s true `ninja -t inputs` closure so parallel C++ shards
    never re-run host tools or codegen, plus every other generated input of
    the Apple tool edges (e.g. unzipped `obj/**/*.xcassets`) for Stage 1.
  - `c-shard`: round-robin slice of target iOS `.o` object compilations.
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


def unquote_ninja_path(raw: str) -> str:
    """Strips POSIX single-quote shell escaping emitted by Ninja 1.11+ `-t inputs`."""
    if len(raw) >= 2 and raw[0] == "'" and raw[-1] == "'":
        return raw[1:-1].replace("'\\''", "'")
    return raw


def _arg_chunks(items: list[str], limit: int = 256 * 1024) -> list[list[str]]:
    chunks: list[list[str]] = [[]]
    size = 0
    for item in items:
        if chunks[-1] and size + len(item) + 1 > limit:
            chunks.append([])
            size = 0
        chunks[-1].append(item)
        size += len(item) + 1
    return [c for c in chunks if c]


_PHONY_INPUTS: dict[str, dict[str, list[str]]] = {}


def load_phony_inputs(out_dir: pathlib.Path) -> dict[str, list[str]]:
    """Maps every phony output to its direct inputs, read from the Ninja files.

    Parsed directly rather than via `ninja -t query`, which also prints every
    consumer of each node and would emit gigabytes on Chromium's graph.
    """
    cached = _PHONY_INPUTS.get(str(out_dir))
    if cached is not None:
        return cached
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import rewrite_ninja_graph as rng

    result: dict[str, list[str]] = {}
    queue = collections.deque([out_dir / "build.ninja"])
    seen: set[pathlib.Path] = set()
    while queue:
        path = queue.popleft()
        if path in seen:
            continue
        seen.add(path)
        raw = path.read_text(encoding="utf-8").splitlines()
        i, n = 0, len(raw)
        while i < n:
            logical = raw[i]
            while rng._continues(logical) and i + 1 < n:
                i += 1
                logical = logical[:-1] + raw[i].lstrip(" ")
            i += 1
            if logical.startswith("build ") and ": phony" in logical:
                edge = rng.Edge(0, 0, 0)
                rng.parse_build(edge, logical[len("build ") :])
                if edge.rule == "phony":
                    deps = [rng.unescape(d) for d in edge.ins + edge.iins + edge.oins]
                    for out in edge.outs + edge.iouts:
                        result[rng.unescape(out)] = deps
            elif logical.startswith(("subninja ", "include ")):
                queue.append(out_dir / rng.unescape(logical.split(" ", 1)[1].strip()))
    _PHONY_INPUTS[str(out_dir)] = result
    return result


def collect_closure(
    ninja_bin: str,
    out_dir: pathlib.Path,
    roots: list[str],
) -> list[str]:
    """Returns every node the roots transitively depend on.

    Ninja 1.12's `-t inputs` walks phony edges but never prints their direct
    inputs. GN routes hard deps through phonies (`*.harddeps`), so header-only
    generators such as buildflag headers would otherwise vanish from the
    closure. Direct inputs of every reachable phony are added back here.
    """
    closure: set[str] = set()
    for chunk in _arg_chunks(roots):
        closure.update(unquote_ninja_path(x) for x in run_ninja_tool(ninja_bin, out_dir, "inputs", *chunk))
    phony_inputs = load_phony_inputs(out_dir)
    stack = [n for n in (*roots, *closure) if n in phony_inputs]
    seen: set[str] = set()
    while stack:
        node = stack.pop()
        if node in seen:
            continue
        seen.add(node)
        for dep in phony_inputs[node]:
            closure.add(dep)
            if dep in phony_inputs and dep not in seen:
                stack.append(dep)
    return sorted(closure)


def collect_codegen_targets(
    ninja_bin: str,
    out_dir: pathlib.Path,
    root_target: str,
    declared: dict[str, str],
) -> list[str]:
    """Selects strictly transitive `chrome` inputs that produce `gen/**`, host tools, or Rust libs."""
    closure = collect_closure(ninja_bin, out_dir, [root_target])
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


_COMPILED_RULE_RE = re.compile(
    r"^(?:.+_)?(?:cc|cxx|objc|objcxx|asm|alink|link|solink|solink_module|swift|compile_xcassets)$"
)


def collect_apple_input_targets(
    ninja_bin: str,
    out_dir: pathlib.Path,
    apple_targets: list[str],
    declared: dict[str, str],
) -> list[str]:
    """Selects generated inputs of the Apple tool edges that live outside gen/.

    Stage 1 runs only the Apple edges on macOS against codegen's tree, so every
    non-Apple file they read must come from codegen (e.g. the asset catalogs
    that actions unzip into obj/**/*_zip/*.xcassets).
    """
    if not apple_targets:
        return []
    selected: list[str] = []
    for item in collect_closure(ninja_bin, out_dir, apple_targets):
        rule = declared.get(item)
        if not rule or rule in ("phony", "stamp") or rule.endswith("_stamp"):
            continue
        if _COMPILED_RULE_RE.match(rule) and not rule.startswith("__"):
            continue
        if item.startswith(("gen/", "clang_x64", "local_rustc_sysroot/")):
            continue  # Already covered by the codegen selection.
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
        commands = run_ninja_tool(args.ninja, args.out_dir, "commands", args.root_target)
        apple_targets = collect_apple_prebuild_targets(commands, declared)
        extra = collect_apple_input_targets(args.ninja, args.out_dir, apple_targets, declared)
        print(f"plan_shards: +{len(extra)} non-gen inputs of {len(apple_targets)} Apple targets", file=sys.stderr)
        known = set(targets)
        targets += [t for t in extra if t not in known]
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
