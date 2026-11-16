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
              inputs (as phonies) so Apple edges stay ordered among
              themselves. `ninja <apple outputs>` then executes exactly the
              Swift / xcassets / ibtool / intents steps against a pre-populated
              gen/ tree (used on macOS with Linux codegen outputs), after
              reporting any generated input that tree lacks.

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

COMPILE_TOOLS = ("cc", "cxx", "objc", "objcxx", "asm", "alink")
UNTOUCHED_TOOLS = (
    "link",
    "solink",
    "solink_module",
    "rust_bin",
    "rust_cdylib",
    "rust_dylib",
    "rust_macro",
    "rust_staticlib",
)
_COMPILE_RE = re.compile(r"^(?:.+_)?(?:%s)$" % "|".join(COMPILE_TOOLS))
_UNTOUCHED_RE = re.compile(r"^(?:.+_)?(?:%s)$" % "|".join(UNTOUCHED_TOOLS))
_STAMP_RE = re.compile(r"^(?:.+_)?stamp$")


class Edge:
    __slots__ = ("file", "start", "end", "outs", "iouts", "rule", "ins", "iins", "oins", "vins", "binds")

    def __init__(self, file: int, start: int, end: int) -> None:
        self.file = file
        self.start = start
        self.end = end
        self.outs: list[str] = []
        self.iouts: list[str] = []
        self.rule = ""
        self.ins: list[str] = []
        self.iins: list[str] = []
        self.oins: list[str] = []
        self.vins: list[str] = []
        self.binds = ""


def tokenize(text: str) -> list[str]:
    """Splits a build statement body on unescaped spaces and colons."""
    toks: list[str] = []
    cur: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "$" and i + 1 < n:
            cur.append(text[i : i + 2])
            i += 2
        elif c == " ":
            if cur:
                toks.append("".join(cur))
                cur = []
            i += 1
        elif c == ":":
            if cur:
                toks.append("".join(cur))
                cur = []
            toks.append(":")
            i += 1
        else:
            cur.append(c)
            i += 1
    if cur:
        toks.append("".join(cur))
    return toks


def unescape(tok: str) -> str:
    return re.sub(r"\$(.)", r"\1", tok)


def parse_build(edge: Edge, body: str) -> None:
    toks = tokenize(body)
    colon = toks.index(":")
    section = edge.outs
    for t in toks[:colon]:
        if t == "|":
            section = edge.iouts
        else:
            section.append(t)
    rest = toks[colon + 1 :]
    edge.rule = rest[0]
    section = edge.ins
    for t in rest[1:]:
        if t == "|":
            section = edge.iins
        elif t == "||":
            section = edge.oins
        elif t == "|@":
            section = edge.vins
        else:
            section.append(t)


def render_build(
    edge: Edge, ins: list[str], iins: list[str], oins: list[str], vins: list[str], rule: str | None = None
) -> str:
    parts = ["build", *edge.outs]
    if edge.iouts:
        parts += ["|", *edge.iouts]
    head = " ".join(parts) + ":"
    tail = [rule or edge.rule, *ins]
    if iins:
        tail += ["|", *iins]
    if oins:
        tail += ["||", *oins]
    if vins:
        tail += ["|@", *vins]
    return head + " " + " ".join(tail) + "\n"


class Graph:
    def __init__(self, out_dir: pathlib.Path) -> None:
        self.out_dir = out_dir
        self.files: list[pathlib.Path] = []
        self.lines: list[list[str]] = []
        self.edges: list[Edge] = []
        self.rules: dict[str, str] = {}
        self.producer: dict[str, int] = {}
        self._load(out_dir / "build.ninja")

    def _load(self, root: pathlib.Path) -> None:
        queue = collections.deque([root])
        seen: set[pathlib.Path] = set()
        while queue:
            path = queue.popleft()
            if path in seen:
                continue
            seen.add(path)
            file_idx = len(self.files)
            self.files.append(path)
            raw = path.read_text(encoding="utf-8").splitlines(keepends=True)
            self.lines.append(raw)
            i, n = 0, len(raw)
            while i < n:
                start = i
                logical = raw[i].rstrip("\n")
                while _continues(logical) and i + 1 < n:
                    i += 1
                    logical = logical[:-1] + raw[i].rstrip("\n").lstrip(" ")
                i += 1
                if logical.startswith("build "):
                    edge = Edge(file_idx, start, i)
                    parse_build(edge, logical[len("build ") :])
                    binds: list[str] = []
                    while i < n and raw[i].startswith((" ", "\t")) and raw[i].strip():
                        binds.append(raw[i])
                        i += 1
                    edge.binds = "".join(binds)
                    idx = len(self.edges)
                    self.edges.append(edge)
                    for o in edge.outs + edge.iouts:
                        self.producer[o] = idx
                elif logical.startswith("rule "):
                    name = logical[len("rule ") :].strip()
                    body: list[str] = []
                    while i < n and raw[i].startswith((" ", "\t")) and raw[i].strip():
                        body.append(raw[i])
                        i += 1
                    self.rules[name] = "".join(body)
                elif logical.startswith(("subninja ", "include ")):
                    rel = unescape(logical.split(" ", 1)[1].strip())
                    queue.append(self.out_dir / rel)

    def is_apple(self, edge: Edge) -> bool:
        return "apple_tool_wrapper" in self.rules.get(edge.rule, "") or "apple_tool_wrapper" in edge.binds

    def write(self, replacements: dict[int, dict[int, tuple[int, str]]]) -> int:
        for file_idx, repl in replacements.items():
            raw = self.lines[file_idx]
            out: list[str] = []
            i = 0
            while i < len(raw):
                if i in repl:
                    end, text = repl[i]
                    out.append(text)
                    i = end
                else:
                    out.append(raw[i])
                    i += 1
            self.files[file_idx].write_text("".join(out), encoding="utf-8")
        return len(replacements)


def _continues(line: str) -> bool:
    stripped = line.rstrip("$")
    return (len(line) - len(stripped)) % 2 == 1


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
        outs = " ".join(e.outs + e.iouts)
        if e.rule == "phony" or _STAMP_RE.match(e.rule):
            # Groups carry the ordering between Apple edges (a Swift module
            # waits on its Swift deps through their target phonies), so they
            # keep every input and merely stop touching stamp files.
            grouping += 1
            if e.rule != "phony" or e.binds:
                text = render_build(e, e.ins, e.iins, e.oins, e.vins, rule="phony")
                replacements[e.file][e.start] = (e.end + bind_lines, text)
            continue
        replacements[e.file][e.start] = (e.end + bind_lines, f"build {outs}: phony\n")
    print(
        f"==> apple-only: kept {apple} Apple tool edge(s) and {grouping} grouping edge(s); "
        "all other edges are input-less phonies"
    )
    report_missing_generated(graph)
    return replacements


def report_missing_generated(graph: Graph) -> None:
    """Lists generator outputs the Apple edges reach that are not on disk.

    Those come from Linux codegen; a gap here otherwise surfaces as a puzzling
    'file not found' deep inside swiftc or actool.
    """
    edges, producer = graph.edges, graph.producer
    stack = [d for e in edges if graph.is_apple(e) for d in e.ins + e.iins + e.oins]
    seen: set[str] = set()
    missing: list[str] = []
    while stack:
        node = stack.pop()
        if node in seen:
            continue
        seen.add(node)
        idx = producer.get(node)
        if idx is None:
            continue
        e = edges[idx]
        rule = e.rule
        if rule == "phony" or _STAMP_RE.match(rule):
            stack.extend(e.ins + e.iins + e.oins)
            continue
        if graph.is_apple(e):
            continue
        builtin = not rule.startswith("__")
        if builtin and (_COMPILE_RE.match(rule) or _UNTOUCHED_RE.match(rule) or rule.endswith("rust_rlib")):
            continue  # Objects and binaries come from the Linux shards.
        if node.startswith("clang_"):
            continue  # This host's tools are never built here.
        if not (graph.out_dir / unescape(node)).exists():
            missing.append(unescape(node))
    if missing:
        missing.sort()
        print(f"::warning::{len(missing)} generated input(s) of Apple edges are missing from codegen's tree")
        for path in missing[:200]:
            print(f"  missing: {path}")
    else:
        print("==> apple-only: every generated input of the Apple edges is present")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--mode", choices=("prune", "apple-only"), required=True)
    args = parser.parse_args()

    out_dir = args.out_dir.resolve()
    graph = Graph(out_dir)
    print(f"==> Loaded {len(graph.edges)} build edges from {len(graph.files)} ninja files")
    replacements = prune(graph) if args.mode == "prune" else apple_only(graph)
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
