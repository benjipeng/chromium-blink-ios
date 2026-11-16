#!/usr/bin/env python3
"""Shared Ninja graph model and stage-contract rules for the CI scripts.

Loads a GN-generated graph (following subninja/include), keeps every build
statement with its rule, inputs by kind and bindings, and classifies edges by
who may run them:

  host work     anything whose outputs live under a host toolchain (clang_*)
  target work   device compile, archive, link and Swift (later stages)
  Apple work    edges run through apple_tool_wrapper (macOS only)
  generators    everything else (actions, copies) that produces files
"""

from __future__ import annotations

import collections
import pathlib
import re

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




# --- Stage contract ---------------------------------------------------------

# Rules that compile, archive or link target code, or run Swift.
_TARGET_WORK_RE = re.compile(
    r"^(?:.+_)?(?:cc|cxx|objc|objcxx|asm|alink|link|solink|solink_module|swift|"
    r"rust_bin|rust_cdylib|rust_dylib|rust_staticlib)$"
)
# Rules whose single output is one compiled object.
_OBJECT_RE = re.compile(r"^(?:.+_)?(?:cc|cxx|objc|objcxx|asm)$")
# GN groups a bundle's dependencies under `<bundle>.inputdeps`; the bundle
# steps only wait on them, they do not read the files behind them.
_BUNDLE_ORDER_SUFFIX = ".inputdeps"


def is_grouping(e: Edge) -> bool:
    return e.rule == "phony" or bool(_STAMP_RE.match(e.rule))


def is_host(e: Edge) -> bool:
    return unescape(e.outs[0]).startswith("clang_")


def is_target_work(e: Edge) -> bool:
    return not e.rule.startswith("__") and bool(_TARGET_WORK_RE.match(e.rule)) and not is_host(e)


def is_target_object(e: Edge) -> bool:
    return not e.rule.startswith("__") and bool(_OBJECT_RE.match(e.rule)) and not is_host(e)


def deps(e: Edge) -> list[str]:
    return e.ins + e.iins + e.oins


class Contract:
    """Answers stage-boundary questions on a loaded graph (raw node names)."""

    def __init__(self, graph: Graph) -> None:
        self.graph = graph
        self.raw_of = {unescape(k): k for k in graph.producer}
        self._reach: dict[str, bool] = {}

    def edge(self, node: str) -> Edge | None:
        idx = self.graph.producer.get(node)
        return None if idx is None else self.graph.edges[idx]

    def off_limits(self, e: Edge) -> bool:
        """Work codegen must never run: target compile/link/Swift or Apple tools."""
        return is_target_work(e) or self.graph.is_apple(e)

    def reaches_off_limits(self, node: str) -> bool:
        """True if building `node` would run target or Apple work."""
        memo = self._reach
        stack = [(node, False)]
        while stack:
            cur, expanded = stack.pop()
            if cur in memo:
                continue
            e = self.edge(cur)
            if e is None:
                memo[cur] = False
            elif self.off_limits(e):
                memo[cur] = True
            elif not expanded:
                stack.append((cur, True))
                stack.extend((d, False) for d in deps(e) if d not in memo)
            else:
                memo[cur] = any(memo.get(d, False) for d in deps(e))
        return memo[node]

    def closure(self, roots: list[str]) -> tuple[dict[str, str | None], list[str]]:
        """BFS over every input kind; returns parent links and visit order."""
        parent: dict[str, str | None] = {r: None for r in roots}
        order = list(roots)
        queue = collections.deque(roots)
        while queue:
            node = queue.popleft()
            e = self.edge(node)
            if e is None:
                continue
            for d in deps(e):
                if d not in parent:
                    parent[d] = node
                    order.append(d)
                    queue.append(d)
        return parent, order

    def built_by(self, nodes: set[str] | list[str]) -> set[str]:
        """Every output (incl. implicit) of the edges producing `nodes`."""
        out: set[str] = set()
        for n in nodes:
            e = self.edge(n)
            if e is not None:
                out.update(e.outs)
                out.update(e.iouts)
        return out

    def apple_edges(self, closure_nodes: list[str]) -> list[Edge]:
        seen: set[int] = set()
        result = []
        for n in closure_nodes:
            idx = self.graph.producer.get(n)
            if idx is not None and idx not in seen:
                seen.add(idx)
                if self.graph.is_apple(self.graph.edges[idx]):
                    result.append(self.graph.edges[idx])
        return result

    def _generated_inputs(self, edges: list[Edge], through_bundle_order: bool) -> set[str]:
        need: set[str] = set()
        seen: set[str] = set()
        stack = [d for e in edges for d in deps(e)]
        while stack:
            node = stack.pop()
            if node in seen:
                continue
            seen.add(node)
            e = self.edge(node)
            if e is None:
                continue
            if is_grouping(e):
                if through_bundle_order or not unescape(node).endswith(_BUNDLE_ORDER_SUFFIX):
                    stack.extend(deps(e))
            elif not self.graph.is_apple(e) and not is_target_work(e) and not is_host(e):
                need.add(node)
        return need

    def apple_inputs(self, edges: list[Edge]) -> tuple[set[str], set[str]]:
        """Generated files the Apple edges need, and bundle-ordering-only ones.

        A file counts as ordering-only when it is reachable solely through a
        bundle `.inputdeps` group and is itself produced after target work
        (e.g. an embedded framework's binary); everything else is required.
        """
        full = self._generated_inputs(edges, through_bundle_order=True)
        direct = self._generated_inputs(edges, through_bundle_order=False)
        ordering = {n for n in full - direct if self.reaches_off_limits(n)}
        return full - ordering, ordering
