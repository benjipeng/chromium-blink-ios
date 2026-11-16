#!/usr/bin/env python3
"""Rewrites a GN-generated Ninja graph in place so each CI stage builds only
what it truly needs.

GN makes every action depend on the *link outputs* of all its deps (source-set
object phonies and static libraries), and every binary target depend on all
recursive hard deps. A generator therefore transitively waits on thousands of
C++ compilations it never reads, which serializes most of the build behind
whichever stage asks for generated headers first.

Modes:
  prune       Drops implicit/order-only references from actions, stamps,
              phonies, copies, Swift, and rlib edges to "compiled" nodes
              (outputs of cc/cxx/objc/objcxx/asm/alink, and phony/stamp nodes
              made only of those). Each dropped node is replaced by its
              generator frontier as order-only deps, so generator ordering is
              preserved exactly; only the object compilations themselves
              leave the closure. Link edges and explicit inputs are untouched,
              and an action keeps any dropped node whose path appears in its
              command (it reads that file).
  apple-only  Turns every edge that does not run `apple_tool_wrapper` into an
              input-less phony, except phony/stamp groups, which keep their
              inputs so Apple edges stay ordered among themselves. Fails first
              if a generated file the Apple edges read is missing from the
              codegen tree (used on macOS).
  link-only   Turns the compile edges of objects imported from the shards into
              input-less phonies, so `ninja chrome` archives, links and
              assembles the bundle without compiling anything.

The rewrite is deterministic and idempotent; every stage applies it right after
`gn gen` so all stages agree on the same graph.
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from ninja_graph import (  # noqa: E402
    _COMPILE_RE,
    _STAMP_RE,
    _UNTOUCHED_RE,
    Contract,
    Graph,
    is_target_object,
    render_build,
    unescape,
)


def prune(graph: Graph) -> dict[int, dict[int, tuple[int, str]]]:
    edges, producer = graph.edges, graph.producer
    compiled: dict[str, bool] = {}

    def is_compiled(node: str) -> bool:
        hit = compiled.get(node)
        if hit is not None:
            return hit
        idx = producer.get(node)
        result = False
        if idx is not None:
            e = edges[idx]
            if _COMPILE_RE.match(e.rule) and not e.rule.startswith("__"):
                result = True
            elif e.rule == "phony" or _STAMP_RE.match(e.rule):
                deps = e.ins + e.iins
                result = bool(deps) and all(is_compiled(d) for d in deps)
        compiled[node] = result
        return result

    frontiers: dict[str, frozenset[str]] = {}

    def frontier(node: str) -> frozenset[str]:
        hit = frontiers.get(node)
        if hit is not None:
            return hit
        e = edges[producer[node]]
        acc: set[str] = set()
        for d in e.ins + e.iins + e.oins:
            if is_compiled(d):
                acc |= frontier(d)
            elif d in producer:
                acc.add(d)
        result = frozenset(acc)
        frontiers[node] = result
        return result

    replacements: dict[int, dict[int, tuple[int, str]]] = collections.defaultdict(dict)
    stats = collections.Counter()
    kept_by_command: list[tuple[str, str]] = []

    for e in edges:
        rule = e.rule
        if _UNTOUCHED_RE.match(rule) and not rule.startswith("__"):
            continue
        is_compile_edge = bool(_COMPILE_RE.match(rule)) and not rule.startswith("__")
        is_grouping = rule == "phony" or bool(_STAMP_RE.match(rule))
        if is_grouping and any(is_compiled(o) for o in e.outs):
            continue  # Pure object groups stay intact; consumers drop them.

        # Any edge that names a dropped node in its command reads it; keep it.
        cmd_text = "" if is_grouping else graph.rules.get(rule, "") + e.binds

        added: set[str] = set()
        changed = False

        def drop(nodes: list[str], allow_keep: bool) -> list[str]:
            nonlocal changed
            kept: list[str] = []
            for d in nodes:
                if not is_compiled(d):
                    kept.append(d)
                    continue
                if allow_keep and cmd_text and unescape(d) in cmd_text:
                    kept.append(d)
                    kept_by_command.append((e.outs[0] if e.outs else "?", d))
                    continue
                changed = True
                stats["dropped_refs"] += 1
                added.update(frontier(d))
            return kept

        ins = drop(e.ins, allow_keep=False) if is_grouping else list(e.ins)
        iins = list(e.iins) if is_compile_edge else drop(e.iins, allow_keep=True)
        oins = drop(e.oins, allow_keep=True)
        if not changed:
            continue

        own = set(e.outs) | set(e.iouts)
        present = set(ins) | set(iins) | set(oins)
        extra = sorted(n for n in added if n not in present and n not in own)
        stats["frontier_refs"] += len(extra)
        stats["edges_rewritten"] += 1
        text = render_build(e, ins, iins, oins + extra, e.vins)
        replacements[e.file][e.start] = (e.end, text)

    compiled_count = sum(1 for v in compiled.values() if v)
    print(
        f"==> prune: {stats['edges_rewritten']} edges rewritten, "
        f"{stats['dropped_refs']} compiled-node refs dropped, "
        f"{stats['frontier_refs']} generator-frontier refs added "
        f"({compiled_count} compiled nodes classified)"
    )
    if kept_by_command:
        print(f"==> prune: kept {len(kept_by_command)} compiled ref(s) that actions name in their command:")
        for out, dep in kept_by_command[:40]:
            print(f"  {out} <- {unescape(dep)}")
    return replacements


def apple_only(graph: Graph) -> dict[int, dict[int, tuple[int, str]]]:
    replacements: dict[int, dict[int, tuple[int, str]]] = collections.defaultdict(dict)
    apple = grouping = 0
    for e in graph.edges:
        if graph.is_apple(e):
            apple += 1
            continue
        bind_lines = e.binds.count("\n")
        if e.rule == "phony" or _STAMP_RE.match(e.rule):
            # Groups carry the ordering between Apple edges (a Swift module
            # waits on its Swift deps through their target phonies), so they
            # keep every input and merely stop touching stamp files.
            grouping += 1
            if e.rule != "phony" or e.binds:
                text = render_build(e, e.ins, e.iins, e.oins, e.vins, rule="phony")
                replacements[e.file][e.start] = (e.end + bind_lines, text)
            continue
        replacements[e.file][e.start] = (e.end + bind_lines, f"build {' '.join(e.outs + e.iouts)}: phony\n")
    print(
        f"==> apple-only: kept {apple} Apple tool edge(s) and {grouping} grouping edge(s); "
        "all other edges are input-less phonies"
    )
    return replacements


def check_apple_inputs(graph: Graph, root: str) -> int:
    """Fails when a generated file an Apple edge needs is not on disk."""
    contract = Contract(graph)
    _, order = contract.closure([contract.raw_of.get(root, root)])
    required, ordering = contract.apple_inputs(contract.apple_edges(order))
    missing = sorted(unescape(n) for n in required if not (graph.out_dir / unescape(n)).exists())
    print(f"==> apple-only: {len(required)} generated input(s) required, "
          f"{len(ordering)} bundle-ordering-only (produced after linking, not read)")
    if missing:
        print(f"::error::{len(missing)} generated input(s) of Apple edges are missing from codegen's tree")
        for path in missing[:200]:
            print(f"  missing: {path}  [{contract.edge(contract.raw_of[path]).rule}]")
        return 1
    return 0


def link_only(graph: Graph, imported: set[str]) -> dict[int, dict[int, tuple[int, str]]]:
    """Turns the compile edges of imported objects into input-less phonies.

    Only target object compiles are replaced, and only when every output of
    the edge was imported; archives, links, Swift replays and bundle steps
    still run normally.
    """
    replacements: dict[int, dict[int, tuple[int, str]]] = collections.defaultdict(dict)
    covered: set[str] = set()
    for e in graph.edges:
        outs = [unescape(o) for o in e.outs + e.iouts]
        if not any(o in imported for o in outs):
            continue
        if not is_target_object(e):
            raise ValueError(f"imported {outs[0]} is produced by rule {e.rule}, not a target compile")
        partial = [o for o in outs if o not in imported]
        if partial:
            raise ValueError(f"compile edge for {outs[0]} also outputs {partial}, which were not imported")
        covered.update(outs)
        replacements[e.file][e.start] = (e.end + e.binds.count("\n"), f"build {' '.join(e.outs + e.iouts)}: phony\n")
    unknown = sorted(imported - covered)
    if unknown:
        raise ValueError(f"{len(unknown)} imported file(s) have no compile edge, e.g. {unknown[:5]}")
    print(f"==> link-only: {len(covered)} imported object(s) replace their compile edges")
    return replacements


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--mode", choices=("prune", "apple-only", "link-only"), required=True)
    parser.add_argument("--root", default="chrome", help="apple-only: app target whose Apple inputs are checked")
    parser.add_argument("--imported-file", type=pathlib.Path, help="link-only: objects restored from the shards")
    args = parser.parse_args()

    out_dir = args.out_dir.resolve()
    graph = Graph(out_dir)
    print(f"==> Loaded {len(graph.edges)} build edges from {len(graph.files)} ninja files")
    if args.mode == "prune":
        replacements = prune(graph)
    elif args.mode == "apple-only":
        if check_apple_inputs(graph, args.root):
            return 1
        replacements = apple_only(graph)
    else:
        if not args.imported_file:
            parser.error("--imported-file is required for link-only")
        imported = {l.strip() for l in args.imported_file.read_text().splitlines() if l.strip()}
        try:
            replacements = link_only(graph, imported)
        except ValueError as err:
            print(f"::error::{err}")
            return 1
    written = graph.write(replacements)
    print(f"==> Rewrote {written} ninja file(s) in {out_dir}")
    return 0


if __name__ == "__main__":
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(512 * 1024 * 1024)
    result: list[int] = []
    worker = threading.Thread(target=lambda: result.append(main()))
    worker.start()
    worker.join()
    sys.exit(result[0] if result else 1)
