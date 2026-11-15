#!/usr/bin/env python3
"""Resolves the latest compile-green iOS Blink revision from Chromium CI.

Queries Buildbucket's public `chromium/ci/ios-blink-rel-fyi` builder, selects
the most recent build whose `compile` step succeeded (ignoring unrelated
simulator unit-test flakes), and resolves matching `chrome/VERSION`, V8, and
ANGLE revisions from `chromium.googlesource.com`.
"""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import re
import sys
import urllib.request

BUILDBUCKET_URL = (
    "https://cr-buildbucket.appspot.com/prpc/buildbucket.v2.Builds/SearchBuilds"
)
GITILES_RAW_FMT = (
    "https://chromium.googlesource.com/chromium/src/+/{rev}/{path}?format=TEXT"
)


def fetch_gitiles_text(rev: str, path: str) -> str:
    url = GITILES_RAW_FMT.format(rev=rev, path=path)
    with urllib.request.urlopen(url, timeout=20) as resp:
        return base64.b64decode(resp.read()).decode("utf-8", errors="replace")


def find_latest_compile_green_build(page_size: int = 20) -> dict:
    payload = json.dumps(
        {
            "predicate": {
                "builder": {
                    "project": "chromium",
                    "bucket": "ci",
                    "builder": "ios-blink-rel-fyi",
                }
            },
            "fields": (
                "builds.*.number,builds.*.id,builds.*.status,"
                "builds.*.input.gitilesCommit,builds.*.steps"
            ),
            "pageSize": page_size,
        }
    ).encode("utf-8")
    req = urllib.request.Request(
        BUILDBUCKET_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode("utf-8")
    if raw.startswith(")]}'"):
        raw = raw[4:]
    builds = json.loads(raw).get("builds", [])
    for build in builds:
        commit_id = (
            build.get("input", {}).get("gitilesCommit", {}).get("id", "")
        )
        if not commit_id:
            continue
        steps = build.get("steps", [])
        if any(
            s.get("name") == "compile" and s.get("status") == "SUCCESS"
            for s in steps
        ):
            return {
                "build_number": build.get("number"),
                "build_id": build.get("id"),
                "overall_status": build.get("status"),
                "chromium_rev": commit_id,
            }
    raise RuntimeError(
        "No compile-green build found in recent ios-blink-rel-fyi runs."
    )


def resolve_metadata(chromium_rev: str) -> dict[str, str]:
    ver_txt = fetch_gitiles_text(chromium_rev, "chrome/VERSION")
    kv = dict(
        line.strip().split("=", 1)
        for line in ver_txt.splitlines()
        if "=" in line
    )
    version = f"{kv['MAJOR']}.{kv['MINOR']}.{kv['BUILD']}.{kv['PATCH']}"

    deps_txt = fetch_gitiles_text(chromium_rev, "DEPS")
    v8_m = re.search(r"'v8_revision':\s*'([0-9a-f]{40})'", deps_txt)
    angle_m = re.search(r"'angle_revision':\s*'([0-9a-f]{40})'", deps_txt)
    if not v8_m or not angle_m:
        raise RuntimeError("Failed to parse v8_revision/angle_revision in DEPS")
    return {
        "CHROMIUM_REV": chromium_rev,
        "CHROMIUM_VERSION": version,
        "V8_REV": v8_m.group(1),
        "ANGLE_REV": angle_m.group(1),
    }


def update_lockfile(lock_path: pathlib.Path, updates: dict[str, str]) -> None:
    lines = lock_path.read_text(encoding="utf-8").splitlines()
    out: list[str] = []
    seen: set[str] = set()
    for line in lines:
        if "=" in line and not line.lstrip().startswith("#"):
            k, _ = line.split("=", 1)
            k = k.strip()
            if k in updates:
                out.append(f"{k}={updates[k]}")
                seen.add(k)
                continue
        out.append(line)
    for k, v in updates.items():
        if k not in seen:
            out.append(f"{k}={v}")
    lock_path.write_text("\n".join(out) + "\n", encoding="utf-8")


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--lockfile",
        type=pathlib.Path,
        default=repo_root / "version.lock",
        help="Path to version.lock",
    )
    parser.add_argument(
        "--rev",
        default="",
        help="Specific Chromium commit SHA to resolve instead of querying CI",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="Update version.lock in place",
    )
    args = parser.parse_args()

    if args.rev:
        info = {"chromium_rev": args.rev, "build_number": "manual"}
    else:
        info = find_latest_compile_green_build()

    meta = resolve_metadata(info["chromium_rev"])
    print(
        f"Resolved build=#{info['build_number']} "
        f"version={meta['CHROMIUM_VERSION']} rev={meta['CHROMIUM_REV']}"
    )
    for k, v in meta.items():
        print(f"  {k}={v}")

    if args.write:
        update_lockfile(args.lockfile, meta)
        print(f"Updated {args.lockfile}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
