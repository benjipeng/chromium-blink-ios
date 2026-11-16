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


def main() -> int:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        sys.exit("Run this source-file preflight on GitHub Actions, not locally.")
    root = pathlib.Path(__file__).resolve().parent.parent
    lock = dict(line.split("=", 1) for line in (root / "version.lock").read_text().splitlines()
                if "=" in line and not line.lstrip().startswith("#"))
    files: set[str] = set()
    for raw in (root / "patches/series").read_text().splitlines():
        name = raw.split("#", 1)[0].strip()
        if name:
            files.update(re.findall(r"^--- a/(.+)$", (root / "patches" / name).read_text(), re.M))
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
