#!/usr/bin/env python3
"""Audits a codegen plan against the stage contract on the real Ninja graph.

Codegen (Linux) may build host tools, actions, copies and target Rust rlibs.
Target compile/archive/link, Swift and other Apple tools belong to later
stages. Given the planned codegen roots, this reports, without building:

  * the closure composition `ninja <roots>` would execute, by rule and side;
  * every place the closure crosses into off-limits work, grouped by the last
    real (non-phony) edge before the crossing, with one full dependency path;
  * which roots reach off-limits work, and a filtered list without them;
  * generated inputs of the Apple edges the plan would not build (counting
    every output of every planned edge), apart from bundle-ordering-only
    dependencies that are produced after linking and never read.

With --check it exits non-zero if the roots cross into off-limits work, name
unknown nodes, or leave a required Apple input or an --expect path unbuilt.
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from ninja_graph import Contract, Edge, Graph, is_grouping, is_host, unescape  # noqa: E402

_TOOL_RE = re.compile(
    r"(solink_module|solink|alink|link|objcxx|objc|cxx|cc|asm|swift|rust_[a-z]+|"
    r"copy_bundle_data|compile_xcassets|copy|stamp)$"
)


def kind(contract: Contract, e: Edge) -> str:
    side = "host" if is_host(e) else "target"
    if contract.graph.is_apple(e):
        return f"apple {side}"
    if e.rule.startswith("__"):
        return f"action {side}"
    m = _TOOL_RE.search(e.rule)
    return f"{m.group(1) if m else e.rule} {side}"


def path_to(contract: Contract, parent: dict[str, str | None], node: str) -> list[str]:
    chain = []
    cur: str | None = node
    while cur is not None:
        e = contract.edge(cur)
        chain.append(f"{unescape(cur)}  [{e.rule if e else 'source'}]")
        cur = parent[cur]
    return chain[::-1]


def report(contract: Contract, label: str, roots: list[str], out: list[str], top: int) -> tuple[int, set[str]]:
    parent, order = contract.closure(roots)
    kinds: collections.Counter[str] = collections.Counter()
    counted: set[int] = set()
    off_nodes: set[str] = set()
    off_edges = 0
    for node in order:
        idx = contract.graph.producer.get(node)
        if idx is None:
            continue
        e = contract.graph.edges[idx]
        if contract.off_limits(e):
            off_nodes.add(node)
        if idx in counted or is_grouping(e):
            continue
        counted.add(idx)
        kinds[kind(contract, e)] += 1
        off_edges += contract.off_limits(e)
    out.append(f"## {label}: {len(roots)} roots, {sum(kinds.values())} edges in closure")
    out += [f"{n:8d}  {k}" for k, n in kinds.most_common()]

    # Attribute each off-limits node to the crossing that first reached it,
    # keyed by the last real (non-grouping) edge before the crossing.
    entry: dict[str, str] = {}
    for node in order:
        if node in off_nodes:
            p = parent[node]
            entry[node] = entry[p] if p in entry else node
    crossings: collections.Counter[str] = collections.Counter()
    sample: dict[str, str] = {}
    for ent in entry.values():
        cur = parent[ent]
        while cur is not None and parent[cur] is not None:
            e = contract.edge(cur)
            if e is not None and not is_grouping(e):
                break
            cur = parent[cur]
        key = cur if cur is not None else ent
        crossings[key] += 1
        sample.setdefault(key, ent)
    if crossings:
        out.append(f"\n### {label}: {off_edges} off-limits edges, entered via {len(crossings)} crossing(s)")
        for key, n in crossings.most_common(top):
            e = contract.edge(key)
            out.append(f"\n{n:7d} off-limits nodes behind {unescape(key)}  [{e.rule if e else 'source'}]")
            out += [f"         {'  ' * i}{step}" for i, step in enumerate(path_to(contract, parent, sample[key]))]
    return off_edges, contract.built_by(order) | set(parent)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", type=pathlib.Path, required=True)
    ap.add_argument("--roots-file", type=pathlib.Path, required=True)
    ap.add_argument("--app-root", default="chrome")
    ap.add_argument("--write-filtered", type=pathlib.Path)
    ap.add_argument("--report", type=pathlib.Path)
    ap.add_argument("--expect", action="append", default=[], help="Path the plan must build (regression sample)")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--check", action="store_true", help="Fail if the roots violate the contract")
    args = ap.parse_args()

    contract = Contract(Graph(args.out_dir.resolve()))
    out = [f"Loaded {len(contract.graph.edges)} edges from {len(contract.graph.files)} ninja files"]
    names = [l.strip() for l in args.roots_file.read_text().splitlines() if l.strip()]
    roots = [contract.raw_of[n] for n in names if n in contract.raw_of]
    unknown = [n for n in names if n not in contract.raw_of]
    if unknown:
        out.append(f"{len(unknown)} root(s) not declared in the graph, e.g. {unknown[:5]}")

    off_edges, built = report(contract, "Planned roots", roots, out, args.top)

    kept = [r for r in roots if not contract.reaches_off_limits(r)]
    dropped = [r for r in roots if contract.reaches_off_limits(r)]
    if dropped:
        drop_kinds = collections.Counter(kind(contract, contract.edge(r)) for r in dropped)
        out.append(f"\n## {len(dropped)} root(s) reach off-limits work; {len(kept)} remain")
        out += [f"{n:8d}  {k}" for k, n in drop_kinds.most_common()]
        out += [f"  dropped: {unescape(r)}" for r in dropped[: args.top * 4]]
        report(contract, "Filtered roots", kept, out, args.top)

    _, app_order = contract.closure([contract.raw_of.get(args.app_root, args.app_root)])
    apple_edges = contract.apple_edges(app_order)
    required, ordering = contract.apple_inputs(apple_edges)
    missing = sorted(unescape(n) for n in required - built)
    out.append(f"\n## Apple edges in `{args.app_root}`: {len(apple_edges)}; generated inputs required: "
               f"{len(required)}; bundle-ordering-only: {len(ordering)}; required but unplanned: {len(missing)}")
    out += [f"  ordering-only: {unescape(n)}  [{contract.edge(n).rule}]" for n in sorted(ordering)[:40]]
    out += [f"  missing: {p}  [{contract.edge(contract.raw_of[p]).rule}]" for p in missing[:200]]

    unbuilt_expect = [p for p in args.expect if contract.raw_of.get(p) not in built]
    out += [f"expect {'MISS' if p in unbuilt_expect else 'OK  '} {p}" for p in args.expect]

    if args.write_filtered:
        args.write_filtered.write_text("".join(unescape(r) + "\n" for r in kept))
    text = "\n".join(out) + "\n"
    print(text)
    if args.report:
        args.report.write_text(text)

    if args.check:
        problems = []
        if off_edges:
            problems.append(f"{off_edges} off-limits edges in the codegen closure")
        if unknown:
            problems.append(f"{len(unknown)} unknown roots")
        if missing:
            problems.append(f"{len(missing)} required Apple inputs unplanned")
        if unbuilt_expect:
            problems.append(f"expected outputs unplanned: {unbuilt_expect}")
        if problems:
            print("::error::Codegen plan violates the stage contract: " + "; ".join(problems))
            return 1
        print("==> Codegen plan satisfies the stage contract")
    return 0


if __name__ == "__main__":
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(512 * 1024 * 1024)
    result: list[int] = []
    worker = threading.Thread(target=lambda: result.append(main()))
    worker.start()
    worker.join()
    sys.exit(result[0] if result else 1)
