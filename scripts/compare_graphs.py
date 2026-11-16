#!/usr/bin/env python3
"""Compares a graph-diagnosis artifact with a baseline run's artifact.

The raw and pruned Ninja graphs must be byte-identical by default (a refactor
must not change what GN generates or how it is pruned). Feature probes can
allow graph differences while retaining the comparison report. The codegen
plan is reported as a difference against the baseline's filtered plan, since
planner fixes are expected to change it.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import subprocess
import sys
import tarfile


def graph_digests(archive: pathlib.Path) -> dict[str, str]:
    proc = subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE)
    out: dict[str, str] = {}
    with tarfile.open(fileobj=proc.stdout, mode="r|") as tar:
        for member in tar:
            if member.isfile():
                data = tar.extractfile(member).read()  # type: ignore[union-attr]
                out[member.name.removeprefix("./")] = hashlib.sha256(data).hexdigest()
    if proc.wait() != 0:
        sys.exit(f"::error::cannot read {archive}")
    return out


def read_list(path: pathlib.Path) -> set[str]:
    return {l.strip() for l in path.read_text().splitlines() if l.strip()} if path.exists() else set()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--baseline", type=pathlib.Path, required=True)
    ap.add_argument("--current", type=pathlib.Path, required=True)
    ap.add_argument("--allow-differences", action="store_true",
                    help="Report expected feature-probe changes without failing")
    args = ap.parse_args()

    lines: list[str] = []
    identical = True
    for name in ("graph-raw", "graph-pruned"):
        base = graph_digests(args.baseline / f"{name}.tar.zst")
        cur = graph_digests(args.current / f"{name}.tar.zst")
        changed = sorted(k for k in base.keys() & cur.keys() if base[k] != cur[k])
        only_base, only_cur = sorted(base.keys() - cur.keys()), sorted(cur.keys() - base.keys())
        same = not (changed or only_base or only_cur)
        identical &= same
        lines.append(f"{name}: {'IDENTICAL' if same else 'DIFFERENT'} ({len(cur)} files; {len(changed)} changed, "
                     f"{len(only_base)} only in baseline, {len(only_cur)} only in current)")
        for label, items in (("changed", changed), ("only in baseline", only_base), ("only in current", only_cur)):
            lines += [f"  {label}: {p}" for p in items[:10]]

    base_plan = read_list(args.baseline / "codegen_targets_filtered.txt")
    cur_plan = read_list(args.current / "codegen_targets.txt")
    lines.append(f"codegen plan: {len(cur_plan)} targets vs baseline filtered {len(base_plan)}; "
                 f"{len(cur_plan - base_plan)} added, {len(base_plan - cur_plan)} removed")
    lines += [f"  added: {p}" for p in sorted(cur_plan - base_plan)[:20]]
    lines += [f"  removed: {p}" for p in sorted(base_plan - cur_plan)[:20]]

    print("\n".join(lines))
    if not identical and not args.allow_differences:
        print("::error::The generated or pruned graph differs from the baseline")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
