#!/usr/bin/env python3
"""Scans Ninja's input closure right after `gn gen` to surface ALL missing
source or host-toolchain files in a single pass instead of failing one file per
CI run inside `ninja`.

Computes:
  required_on_disk = ninja_inputs(targets) - ninja_build_outputs(all)
and stats every remaining path relative to `--out-dir`.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys


def unquote_ninja_path(raw: str) -> str:
    """Strips POSIX single-quote shell escaping emitted by Ninja 1.11+ `-t inputs`."""
    if len(raw) >= 2 and raw[0] == "'" and raw[-1] == "'":
        return raw[1:-1].replace("'\\''", "'")
    return raw


def run_ninja_lines(ninja_bin: str, out_dir: pathlib.Path, *tool_args: str) -> list[str]:
    proc = subprocess.run(
        [ninja_bin, "-C", str(out_dir), "-t", *tool_args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
    )
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ninja", required=True, help="Path to ninja binary")
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("--targets", nargs="*", default=[])
    parser.add_argument("--targets-file", type=pathlib.Path)
    args = parser.parse_args()

    out_dir = args.out_dir.resolve()
    targets: list[str] = list(args.targets)
    if args.targets_file and args.targets_file.is_file():
        for line in args.targets_file.read_text(encoding="utf-8").splitlines():
            t = line.strip()
            if t:
                targets.append(t)

    if not targets:
        print("==> Input preflight: no targets requested; skipping.")
        return 0

    declared_outputs: set[str] = set()
    declared_norm: set[str] = set()
    for line in run_ninja_lines(args.ninja, out_dir, "targets", "all"):
        tgt, sep, _rule = line.partition(":")
        if sep:
            clean = tgt.strip()
            declared_outputs.add(clean)
            declared_norm.add(os.path.normpath(clean))

    raw_inputs_set: set[str] = set()
    for i in range(0, len(targets), 500):
        for line in run_ninja_lines(
            args.ninja, out_dir, "inputs", *targets[i : i + 500]
        ):
            raw_inputs_set.add(unquote_ninja_path(line))
    raw_inputs = sorted(raw_inputs_set)

    checked = 0
    missing: list[str] = []
    for item in raw_inputs:
        if item in declared_outputs or os.path.normpath(item) in declared_norm:
            continue
        candidate = pathlib.Path(item) if os.path.isabs(item) else (out_dir / item)
        checked += 1
        if not candidate.exists():
            missing.append(item)

    if missing:
        missing_sorted = sorted(set(missing))
        msg_lines = [
            f"ERROR: Input preflight found {len(missing_sorted)} missing source/toolchain file(s) "
            f"(out of {checked} non-generated inputs):"
        ]
        for m in missing_sorted:
            msg_lines.append(f"  MISSING: {m}")
        report = "\n".join(msg_lines)
        print(report, file=sys.stderr)
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as sf:
                sf.write("\n### Missing Input Preflight Failure\n```text\n")
                sf.write(report[:32000] + "\n```\n")
        return 1

    print(
        f"==> Input preflight passed: verified {checked} source/toolchain inputs exist on disk."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
