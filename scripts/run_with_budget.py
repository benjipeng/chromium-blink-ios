#!/usr/bin/env python3
"""Runs a build command in its own process group under a wall-clock budget.

A step-level timeout kills the shell abruptly, leaving compilers writing into
the work tree and no time to persist caches. Here, once the budget runs out,
the whole group gets SIGINT (ninja stops scheduling and reaps its children),
then SIGKILL after a grace period, and the script returns 124 only after every
process has exited. Output is streamed to stdout and to a log file.

usage: run_with_budget.py [--minutes M] [--deadline-epoch E] --log FILE -- <command> [args...]

The command stops at whichever comes first: M minutes from now, or the
absolute deadline E (seconds since the epoch), which callers derive from the
job's start, its timeout, and the time persisting needs afterwards.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
import time

GRACE_SECONDS = int(os.environ.get("BUDGET_GRACE_SECONDS", "120"))


def signal_group(pgid: int, sig: int) -> bool:
    """Signals the group; False once no member is left to signal."""
    try:
        os.killpg(pgid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def main() -> int:
    argv = sys.argv[1:]
    if "--" not in argv:
        print(__doc__, file=sys.stderr)
        return 2
    split = argv.index("--")
    opts, cmd = argv[:split], argv[split + 1 :]
    budget = float("inf")
    log_path = ""
    for i in range(0, len(opts) - 1, 2):
        key, value = opts[i], opts[i + 1]
        if key == "--minutes":
            budget = min(budget, float(value) * 60)
        elif key == "--deadline-epoch":
            budget = min(budget, float(value) - time.time())
        elif key == "--log":
            log_path = value
    if not cmd or not log_path or budget == float("inf"):
        print(__doc__, file=sys.stderr)
        return 2
    if budget <= 0:
        print("::error::No build time left before the job deadline", flush=True)
        return 124
    print(f"==> Build budget: {budget / 60:.0f} min", flush=True)

    with open(log_path, "wb") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)

        def pump() -> None:
            assert proc.stdout is not None
            for line in iter(proc.stdout.readline, b""):
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
                log.write(line)
            log.flush()

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        try:
            proc.wait(timeout=budget)
        except subprocess.TimeoutExpired:
            print(f"::warning::Build budget of {budget / 60:.0f} min exhausted; stopping to persist progress",
                  flush=True)
            signal_group(proc.pid, signal.SIGINT)
            try:
                proc.wait(timeout=GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                signal_group(proc.pid, signal.SIGKILL)
                proc.wait()
            # Stragglers in the group (e.g. compilers ninja could not reap).
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and signal_group(proc.pid, signal.SIGKILL):
                time.sleep(1)
            reader.join(timeout=30)
            return 124
        reader.join()
        return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
