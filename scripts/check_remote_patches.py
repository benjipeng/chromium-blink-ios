#!/usr/bin/env python3
"""Checks the patch series on GitHub using only the pinned files it modifies."""

from __future__ import annotations

import concurrent.futures
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")


def collect_upstream_files(patches_dir: pathlib.Path, series_path: pathlib.Path) -> set[str]:
    """Return upstream paths required before applying patches/series in order."""
    upstream_files: set[str] = set()
    created_in_series: set[str] = set()
    for raw in series_path.read_text(encoding="utf-8").splitlines():
        name = raw.split("#", 1)[0].strip()
        if not name:
            continue
        lines = (patches_dir / name).read_text(encoding="utf-8", errors="replace").splitlines()
        i = 0
        old_rem = 0
        new_rem = 0
        while i < len(lines):
            line = lines[i]
            if line.startswith("diff --git "):
                old_rem = 0
                new_rem = 0
                i += 1
                continue
            if old_rem > 0 or new_rem > 0:
                if line.startswith(" "):
                    old_rem = max(0, old_rem - 1)
                    new_rem = max(0, new_rem - 1)
                elif line.startswith("-"):
                    old_rem = max(0, old_rem - 1)
                elif line.startswith("+"):
                    new_rem = max(0, new_rem - 1)
                i += 1
                continue
            hunk = HUNK_RE.match(line)
            if hunk:
                old_rem = int(hunk.group(1)) if hunk.group(1) is not None else 1
                new_rem = int(hunk.group(2)) if hunk.group(2) is not None else 1
                i += 1
                continue
            if line.startswith("rename from ") and i + 1 < len(lines) and lines[i + 1].startswith("rename to "):
                src = line[len("rename from "):].strip()
                dst = lines[i + 1][len("rename to "):].strip()
                if src not in created_in_series:
                    upstream_files.add(src)
                else:
                    created_in_series.discard(src)
                created_in_series.add(dst)
                i += 2
                continue
            if line.startswith("copy from ") and i + 1 < len(lines) and lines[i + 1].startswith("copy to "):
                src = line[len("copy from "):].strip()
                dst = lines[i + 1][len("copy to "):].strip()
                if src not in created_in_series:
                    upstream_files.add(src)
                created_in_series.add(dst)
                i += 2
                continue
            if line.startswith("--- ") and i + 1 < len(lines) and lines[i + 1].startswith("+++ "):
                old_raw = line[4:].split("\t", 1)[0].strip()
                new_raw = lines[i + 1][4:].split("\t", 1)[0].strip()
                if old_raw == "/dev/null" and new_raw.startswith("b/"):
                    created_in_series.add(new_raw[2:])
                elif old_raw.startswith("a/"):
                    old_path = old_raw[2:]
                    if old_path not in created_in_series:
                        upstream_files.add(old_path)
                    if new_raw == "/dev/null":
                        created_in_series.discard(old_path)
                i += 2
                continue
            i += 1
    return upstream_files


def main() -> int:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        sys.exit("Run this source-file preflight on GitHub Actions, not locally.")
    root = pathlib.Path(__file__).resolve().parent.parent
    lock = dict(line.split("=", 1) for line in (root / "version.lock").read_text().splitlines()
                if "=" in line and not line.lstrip().startswith("#"))
    files = collect_upstream_files(root / "patches", root / "patches/series")
    base = f"https://raw.githubusercontent.com/chromium/chromium/{lock['CHROMIUM_REV']}/"
    with tempfile.TemporaryDirectory(prefix="patch-preflight-") as directory:
        source = pathlib.Path(directory)

        def fetch(relative: str) -> int:
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(base + relative, timeout=30) as response:
                        data = response.read()
                    destination = source / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(data)
                    return len(data)
                except OSError:
                    if attempt == 2:
                        raise
                    time.sleep(attempt + 1)
            raise AssertionError("unreachable")

        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            size = sum(pool.map(fetch, sorted(files)))
        print(f"Checking the full series against {len(files)} pinned files ({size:,} bytes)", flush=True)
        subprocess.run([str(root / "scripts/apply_patches.sh"), "--src-dir", str(source), "--check"], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
