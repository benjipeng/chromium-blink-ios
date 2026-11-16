#!/usr/bin/env python3
"""Audits a codegen plan against the stage contract on the real Ninja graph.

Codegen (Linux) may build host tools, actions, copies and target Rust rlibs.
Device compiles, archives, links and Swift belong to later stages. Given the
planned codegen roots, this reports, without building anything:

  * the closure composition `ninja <roots>` would execute, by rule and side;
  * every place the closure crosses into device work, grouped by the last
    real (non-phony) edge before the crossing, with one full dependency path;
  * which roots reach device work, and a filtered root list without them;
  * generator outputs the Apple edges need that the filtered plan would not
    build (what Stage 1 would otherwise miss, e.g. buildflags.h);
  * generator outputs device compiles order-depend on that the plan leaves
    to the shards.

Exits non-zero with --check when the given roots cross into device work or
leave an Apple input unbuilt.
"""

from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import rewrite_ninja_graph as rng  # noqa: E402

_DEVICE_WORK_RE = re.compile(
    r"^(?:.+_)?(?:cc|cxx|objc|objcxx|asm|alink|link|solink|solink_module|swift|"
    r"rust_bin|rust_cdylib|rust_dylib|rust_staticlib)$"
)


_TOOL_RE = re.compile(
    r"(solink_module|solink|alink|link|objcxx|objc|cxx|cc|asm|swift|rust_[a-z]+|"
    r"copy_bundle_data|compile_xcassets|copy|stamp)$"
)


class Audit:
    def __init__(self, out_dir: pathlib.Path) -> None:
        self.graph = rng.Graph(out_dir)
        self.edges = self.graph.edges
        self.producer = self.graph.producer
        self.raw_of = {rng.unescape(k): k for k in self.producer}

    def edge_of(self, node: str) -> rng.Edge | None:
        idx = self.producer.get(node)
        return None if idx is None else self.edges[idx]

    @staticmethod
    def deps(e: rng.Edge) -> list[str]:
        return e.ins + e.iins + e.oins

    @staticmethod
    def is_grouping(e: rng.Edge) -> bool:
        return e.rule == "phony" or bool(rng._STAMP_RE.match(e.rule))

    def is_device_work(self, e: rng.Edge) -> bool:
        if e.rule.startswith("__") or not _DEVICE_WORK_RE.match(e.rule):
            return False
        return not rng.unescape(e.outs[0]).startswith("clang_")

    def kind(self, e: rng.Edge) -> str:
        side = "host" if rng.unescape(e.outs[0]).startswith("clang_") else "target"
        if self.graph.is_apple(e):
            return f"apple {side}"
        if e.rule.startswith("__"):
            return f"action {side}"
        m = _TOOL_RE.search(e.rule)
        return f"{m.group(1) if m else e.rule} {side}"

    def resolve(self, names: list[str]) -> tuple[list[str], list[str]]:
        found, unknown = [], []
        for name in names:
            raw = self.raw_of.get(name)
            (found if raw is not None else unknown).append(raw if raw is not None else name)
        return found, unknown

    def closure(self, roots: list[str]) -> tuple[dict[str, str | None], list[str]]:
        """BFS over every input kind; returns parent links and visit order."""
        parent: dict[str, str | None] = {r: None for r in roots}
        order = list(roots)
        queue = collections.deque(roots)
        while queue:
            node = queue.popleft()
            e = self.edge_of(node)
            if e is None:
                continue
            for d in self.deps(e):
                if d not in parent:
                    parent[d] = node
                    order.append(d)
                    queue.append(d)
        return parent, order

    def reaches_device(self, roots: list[str]) -> dict[str, bool]:
        memo: dict[str, bool] = {}
        for root in roots:
            stack = [(root, False)]
            while stack:
                node, expanded = stack.pop()
                if node in memo:
                    continue
                e = self.edge_of(node)
                if e is None:
                    memo[node] = False
                    continue
                if self.is_device_work(e):
                    memo[node] = True
                    continue
                if not expanded:
                    stack.append((node, True))
                    stack.extend((d, False) for d in self.deps(e) if d not in memo)
                else:
                    memo[node] = any(memo.get(d, False) for d in self.deps(e))
        return memo

    def required_generated(self, start_edges: list[rng.Edge]) -> set[str]:
        """Generator outputs reached through groups from the given edges."""
        need: set[str] = set()
        seen: set[str] = set()
        stack = [d for e in start_edges for d in self.deps(e)]
        while stack:
            node = stack.pop()
            if node in seen:
                continue
            seen.add(node)
            e = self.edge_of(node)
            if e is None:
                continue
            if self.is_grouping(e):
                stack.extend(self.deps(e))
            elif not self.graph.is_apple(e) and not self.is_device_work(e):
                need.add(node)
        return need

    def path(self, parent: dict[str, str | None], node: str) -> list[str]:
        chain = []
        cur: str | None = node
        while cur is not None:
            e = self.edge_of(cur)
            chain.append(f"{rng.unescape(cur)}  [{e.rule if e else 'source'}]")
            cur = parent[cur]
        return chain[::-1]


def report(audit: Audit, label: str, roots: list[str], out: list[str], top: int) -> tuple[dict, set[str]]:
    parent, order = audit.closure(roots)
    kinds = collections.Counter()
    counted: set[int] = set()
    device_set: set[str] = set()
    device_edges = 0
    for node in order:
        idx = audit.producer.get(node)
        if idx is None:
            continue
        e = audit.edges[idx]
        if audit.is_device_work(e):
            device_set.add(node)
        if idx in counted or audit.is_grouping(e):
            continue
        counted.add(idx)
        kinds[audit.kind(e)] += 1
        device_edges += audit.is_device_work(e)
    out.append(f"## {label}: {len(roots)} roots, {sum(kinds.values())} edges in closure")
    out += [f"{n:8d}  {k}" for k, n in kinds.most_common()]

    # Attribute each device node to the crossing that first reached it.
    entry: dict[str, str] = {}
    for node in order:
        if node in device_set:
            p = parent[node]
            entry[node] = entry[p] if p in entry else node
    culprits = collections.Counter()
    sample: dict[str, str] = {}
    for node, ent in entry.items():
        cur = parent[ent]
        while cur is not None:
            e = audit.edge_of(cur)
            if e is not None and not audit.is_grouping(e):
                break
            if parent[cur] is None:
                break
            cur = parent[cur]
        key = cur if cur is not None else ent
        culprits[key] += 1
        sample.setdefault(key, ent)
    if culprits:
        out.append(f"\n### {label}: {device_edges} device edges, entered via {len(culprits)} crossing(s)")
        for key, n in culprits.most_common(top):
            e = audit.edge_of(key)
            out.append(f"\n{n:7d} device nodes behind {rng.unescape(key)}  [{e.rule if e else 'source'}]")
            out += [f"         {'  ' * i}{step}" for i, step in enumerate(audit.path(parent, sample[key]))]
    return {"edges": sum(kinds.values()), "device": device_edges}, set(parent)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", type=pathlib.Path, required=True)
    ap.add_argument("--roots-file", type=pathlib.Path, required=True)
    ap.add_argument("--app-root", default="chrome")
    ap.add_argument("--write-filtered", type=pathlib.Path)
    ap.add_argument("--report", type=pathlib.Path)
    ap.add_argument("--expect", action="append", default=[], help="Path that must be built by the filtered plan")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--check", action="store_true", help="Fail if the given roots violate the contract")
    args = ap.parse_args()

    audit = Audit(args.out_dir.resolve())
    out: list[str] = [f"Loaded {len(audit.edges)} edges from {len(audit.graph.files)} ninja files"]
    names = [l.strip() for l in args.roots_file.read_text().splitlines() if l.strip()]
    roots, unknown = audit.resolve(names)
    if unknown:
        out.append(f"{len(unknown)} root(s) not declared in the graph, e.g. {unknown[:5]}")

    planned, _ = report(audit, "Planned roots", roots, out, args.top)

    reach = audit.reaches_device(roots)
    dropped = [r for r in roots if reach.get(r)]
    kept = [r for r in roots if not reach.get(r)]
    drop_kinds = collections.Counter(audit.kind(audit.edge_of(r)) for r in dropped if audit.edge_of(r))
    out.append(f"\n## {len(dropped)} root(s) reach device work; {len(kept)} remain")
    out += [f"{n:8d}  {k}" for k, n in drop_kinds.most_common()]
    out += [f"  dropped: {rng.unescape(r)}" for r in dropped[: args.top * 4]]
    filtered, built = report(audit, "Filtered roots", kept, out, args.top)

    app = audit.raw_of.get(args.app_root, args.app_root)
    _, app_order = audit.closure([app])
    app_edges = {audit.producer[n] for n in app_order if n in audit.producer}
    apple_edges = [audit.edges[i] for i in app_edges if audit.graph.is_apple(audit.edges[i])]
    device_compiles = [
        audit.edges[i] for i in app_edges
        if audit.is_device_work(audit.edges[i]) and not audit.graph.is_apple(audit.edges[i])
    ]

    apple_need = audit.required_generated(apple_edges)
    apple_missing = sorted(rng.unescape(n) for n in apple_need - built)
    out.append(f"\n## Apple edges in `{args.app_root}`: {len(apple_edges)}; "
               f"generated inputs needed: {len(apple_need)}; not built by filtered plan: {len(apple_missing)}")
    out += [f"  missing: {p}  [{audit.edge_of(audit.raw_of[p]).rule}]" for p in apple_missing[:200]]

    compile_need = audit.required_generated(device_compiles)
    compile_missing = compile_need - built
    out.append(f"\n## Device compile/link edges in `{args.app_root}`: {len(device_compiles)}; "
               f"generated inputs they need: {len(compile_need)}; left to shards: {len(compile_missing)}")
    left = collections.Counter(audit.kind(audit.edge_of(n)) for n in compile_missing)
    out += [f"{n:8d}  {k}" for k, n in left.most_common()]
    out += [f"  left: {rng.unescape(n)}" for n in sorted(compile_missing)[:40]]

    failed_expect = []
    for p in args.expect:
        raw = audit.raw_of.get(p)
        ok = raw is not None and raw in built
        if not ok:
            failed_expect.append(p)
        out.append(f"expect {'OK  ' if ok else 'MISS'} {p}")

    if args.write_filtered:
        args.write_filtered.write_text("".join(rng.unescape(r) + "\n" for r in kept))
    text = "\n".join(out) + "\n"
    print(text)
    if args.report:
        args.report.write_text(text)

    if args.check:
        problems = []
        if planned["device"]:
            problems.append(f"{planned['device']} device edges in the codegen closure")
        if apple_missing:
            problems.append(f"{len(apple_missing)} Apple inputs unbuilt")
        if failed_expect:
            problems.append(f"expected outputs unbuilt: {failed_expect}")
        if problems:
            print("::error::Codegen plan violates the stage contract: " + "; ".join(problems))
            return 1
    return 0


if __name__ == "__main__":
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(512 * 1024 * 1024)
    result: list[int] = []
    worker = threading.Thread(target=lambda: result.append(main()))
    worker.start()
    worker.join()
    sys.exit(result[0] if result else 1)
