#!/usr/bin/env python3
"""Packs a compile shard's objects with a manifest, and verifies them on import.

  pack     After a shard builds, archive exactly its planned objects together
           with manifest.json: the build identity, and every object's path,
           size and sha256. Fails if any planned object is missing.
  verify   After the link stage extracts a shard archive, require that the
           manifest names the expected identity and exactly the objects the
           planner assigns to that shard today, and that every file on disk
           matches its recorded sha256.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import tarfile


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_list(path: pathlib.Path) -> list[str]:
    return [l.strip() for l in path.read_text().splitlines() if l.strip()]


def pack(out_dir: pathlib.Path, targets: list[str], dest: pathlib.Path, identity: dict) -> int:
    missing = [t for t in targets if not (out_dir / t).is_file()]
    if missing:
        print(f"::error::{len(missing)} planned object(s) were not built, e.g. {missing[:5]}")
        return 1
    dest.mkdir(parents=True, exist_ok=True)
    entries = [{"path": t, "size": (out_dir / t).stat().st_size, "sha256": sha256(out_dir / t)} for t in targets]
    with tarfile.open(dest / "objects.tar", "w") as tar:
        for t in targets:
            tar.add(out_dir / t, arcname=t, recursive=False)
    manifest = {"identity": identity, "objects": entries}
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True))
    total = sum(e["size"] for e in entries)
    print(f"==> Packed {len(entries)} objects ({total / 1e6:.0f} MB) for {identity}")
    return 0


def verify(out_dir: pathlib.Path, manifest_path: pathlib.Path, expected: list[str], identity: dict) -> int:
    manifest = json.loads(manifest_path.read_text())
    problems: list[str] = []
    if manifest.get("identity") != identity:
        problems.append(f"identity {manifest.get('identity')} != expected {identity}")
    recorded = {e["path"]: e for e in manifest.get("objects", [])}
    extra = sorted(set(recorded) - set(expected))
    absent = sorted(set(expected) - set(recorded))
    if extra or absent:
        problems.append(f"object list differs from the plan: {len(absent)} missing, {len(extra)} unexpected, "
                        f"e.g. missing {absent[:3]} unexpected {extra[:3]}")
    for path, entry in recorded.items():
        f = out_dir / path
        if not f.is_file():
            problems.append(f"{path} not extracted")
        elif sha256(f) != entry["sha256"]:
            problems.append(f"{path} sha256 mismatch")
        if len(problems) > 20:
            break
    if problems:
        print(f"::error::Shard artifact {identity} failed verification:")
        for p in problems:
            print(f"  {p}")
        return 1
    print(f"==> Verified {len(recorded)} objects for {identity}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=("pack", "verify"))
    ap.add_argument("--out-dir", type=pathlib.Path, required=True)
    ap.add_argument("--targets", type=pathlib.Path, required=True, help="Objects planned for this shard")
    ap.add_argument("--identity", required=True, help="JSON object naming the build key and shard")
    ap.add_argument("--dest", type=pathlib.Path, help="pack: directory for objects.tar + manifest.json")
    ap.add_argument("--manifest", type=pathlib.Path, help="verify: manifest.json from the artifact")
    args = ap.parse_args()

    identity = json.loads(args.identity)
    targets = read_list(args.targets)
    if args.action == "pack":
        if not args.dest:
            ap.error("--dest is required for pack")
        return pack(args.out_dir, targets, args.dest, identity)
    if not args.manifest:
        ap.error("--manifest is required for verify")
    return verify(args.out_dir, args.manifest, targets, identity)


if __name__ == "__main__":
    sys.exit(main())
