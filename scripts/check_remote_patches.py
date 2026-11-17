#!/usr/bin/env python3
"""Checks the patch series on GitHub using only the pinned files it modifies."""

from __future__ import annotations

import base64
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")
CONST_ID_RE = re.compile(r'kIOSBundledExtensionId\[\]\s*=\s*"([a-p]{32})"')


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


def derive_extension_id_from_b64_key(key_b64: str) -> str:
    der = base64.b64decode(key_b64, validate=True)
    digest = hashlib.sha256(der).digest()[:16]
    return "".join(chr(ord("a") + (b >> 4)) + chr(ord("a") + (b & 0xF)) for b in digest)


def validate_patched_probe_identity(patched_src: pathlib.Path) -> str:
    probe_dir = patched_src / "ios/chrome/app/resources/extensions/ios_probe"
    for rel in ("manifest.json", "content.js", "rules_1.json", "sw.js", "sw_helper.js"):
        path = probe_dir / rel
        if not path.is_file() or path.stat().st_size == 0:
            raise AssertionError(f"missing or empty bundled probe file: {path}")

    manifest = json.loads((probe_dir / "manifest.json").read_text(encoding="utf-8"))
    key_b64 = manifest.get("key")
    if not isinstance(key_b64, str) or not key_b64:
        raise AssertionError("ios_probe/manifest.json missing non-empty public key")
    derived_id = derive_extension_id_from_b64_key(key_b64)

    permissions = manifest.get("permissions")
    if not isinstance(permissions, list) or not {"declarativeNetRequest", "storage"}.issubset(permissions):
        raise AssertionError("ios_probe/manifest.json must declare declarativeNetRequest and storage permissions")

    background = manifest.get("background")
    if not isinstance(background, dict) or background.get("service_worker") != "sw.js" or background.get("type") != "module":
        raise AssertionError("ios_probe/manifest.json must configure module service_worker sw.js")

    sw_text = (probe_dir / "sw.js").read_text(encoding="utf-8")
    if "./sw_helper.js" not in sw_text or "chrome.runtime.onMessage.addListener" not in sw_text:
        raise AssertionError("ios_probe/sw.js must statically import ./sw_helper.js and register runtime.onMessage")

    header_path = patched_src / "ios/chrome/browser/extensions/model/ios_extensions_browser_client.h"
    header_text = header_path.read_text(encoding="utf-8")
    match = CONST_ID_RE.search(header_text)
    if not match:
        raise AssertionError("kIOSBundledExtensionId constant not found in ios_extensions_browser_client.h")
    source_id = match.group(1)
    if derived_id != source_id:
        raise AssertionError(f"manifest key ID {derived_id} != source constant {source_id}")

    rules = json.loads((probe_dir / "rules_1.json").read_text(encoding="utf-8"))
    if not isinstance(rules, list) or not rules:
        raise AssertionError("ios_probe/rules_1.json must be a non-empty rule list")
    return derived_id


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
        subprocess.run([str(root / "scripts/apply_patches.sh"), "--src-dir", str(source)], check=True)
        probe_id = validate_patched_probe_identity(source)
        print(f"Verified bundled probe files and manifest key ID: {probe_id}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
