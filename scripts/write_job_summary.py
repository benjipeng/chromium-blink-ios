#!/usr/bin/env python3
"""Appends a structured diagnostic report to $GITHUB_STEP_SUMMARY in `always()`
steps: stage checkpoint key & hit/miss status, elapsed wall-clock, disk usage,
ccache hit rate & size, and all `FAILED:` blocks from Ninja logs.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import time


def run_capture(cmd: list[str], env: dict[str, str] | None = None) -> str:
    try:
        out = subprocess.check_output(
            cmd, stderr=subprocess.STDOUT, text=True, errors="replace", env=env
        )
        return out.strip()
    except Exception as exc:
        return f"(unavailable: {exc})"


def extract_ninja_failures(log_path: pathlib.Path, max_blocks: int = 40) -> str:
    if not log_path.is_file():
        return ""
    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    blocks: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if line.startswith("FAILED:") or " FAILED: " in line:
            snippet = [line]
            j = i + 1
            while j < n and len(snippet) < 14:
                nxt = lines[j]
                if nxt.startswith("[") and "/" in nxt[:20] and "] " in nxt:
                    break
                if nxt.startswith("FAILED:"):
                    break
                snippet.append(nxt)
                j += 1
            blocks.append("\n".join(snippet))
            if len(blocks) >= max_blocks:
                blocks.append(f"... (truncated after {max_blocks} FAILED targets)")
                break
            i = j
        else:
            i += 1
    return "\n\n".join(blocks)[:48000]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--title", required=True)
    parser.add_argument("--key", default="")
    parser.add_argument("--checkpoint", default="")
    parser.add_argument("--outcome", default="")
    parser.add_argument("--start-epoch", type=int, default=0)
    parser.add_argument("--ccache-dir", type=pathlib.Path)
    parser.add_argument("--ninja-log", type=pathlib.Path)
    args = parser.parse_args()

    elapsed_str = "n/a"
    if args.start_epoch > 0:
        secs = max(0, int(time.time()) - args.start_epoch)
        elapsed_str = f"{secs // 60}m {secs % 60:02d}s"

    parts: list[str] = [f"## {args.title}", ""]
    parts.append("| Metric | Value |")
    parts.append("| :--- | :--- |")
    if args.key:
        parts.append(f"| Stage Key | `{args.key}` |")
    if args.checkpoint:
        parts.append(f"| Checkpoint | `{args.checkpoint}` |")
    if args.outcome:
        parts.append(f"| Outcome | `{args.outcome}` |")
    parts.append(f"| Elapsed | `{elapsed_str}` |")
    parts.append("")

    if args.ninja_log:
        failures = extract_ninja_failures(args.ninja_log)
        if failures:
            parts.append("### Ninja Failed Targets (`FAILED:`)")
            parts.append("```text")
            parts.append(failures)
            parts.append("```")
            parts.append("")

    if args.ccache_dir and args.ccache_dir.is_dir() and shutil.which("ccache"):
        env = dict(os.environ)
        env["CCACHE_DIR"] = str(args.ccache_dir)
        du_out = run_capture(["du", "-sh", str(args.ccache_dir)])
        stats_out = run_capture(["ccache", "-s"], env=env)
        parts.append(f"### ccache (`{du_out}`)")
        parts.append("```text")
        parts.append(stats_out)
        parts.append("```")
        parts.append("")

    df_cmd = ["df", "-h", "/"]
    if pathlib.Path("/mnt").exists():
        df_cmd.append("/mnt")
    parts.append("### Disk Usage (`df -h`)")
    parts.append("```text")
    parts.append(run_capture(df_cmd))
    parts.append("```")
    parts.append("")

    report = "\n".join(parts) + "\n"
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as sf:
            sf.write(report)
    else:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
