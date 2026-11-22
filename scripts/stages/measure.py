#!/usr/bin/env python3
"""Run one pipeline step and record its peak memory and duration (planning#6).

Usage: scripts/stages/measure.py <step name> -- <command ...>

Appends {"step", "seconds", "peak_rss_mb"} as one line to out/.build/resources.jsonl; the package
stage puts the list and the overall peak into out/internal/manifest.json, so that growth of the
database shows up run by run instead of as a run killed for lack of memory. The command's exit
code is passed on unchanged. Peak memory is the largest resident set of the command and its
descendants (getrusage of the waited-for process tree), as the kernel's OOM killer sees it.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

RESOURCES = Path(os.environ.get("LODAM_RESOURCES") or
                 Path(__file__).resolve().parents[2] / "out" / ".build" / "resources.jsonl")   # tests: elsewhere


def main():
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        sys.exit(__doc__)
    step, cmd = sys.argv[1], sys.argv[3:]
    start = time.monotonic()
    proc = subprocess.Popen(cmd)
    _, status, usage = os.wait4(proc.pid, 0)
    seconds = round(time.monotonic() - start, 1)
    code = os.waitstatus_to_exitcode(status)
    rss_mb = round(usage.ru_maxrss / 1024)                # Linux: ru_maxrss is in KiB
    RESOURCES.parent.mkdir(parents=True, exist_ok=True)
    with open(RESOURCES, "a", encoding="utf-8") as f:
        f.write(json.dumps({"step": step, "seconds": seconds, "peak_rss_mb": rss_mb,
                            **({"exit_code": code} if code else {})}) + "\n")
    print(f"resources: {step}: {rss_mb} MB peak, {seconds} s", file=sys.stderr)
    sys.exit(code if code >= 0 else 128 - code)          # killed by a signal → 128 + signal, as a shell does


if __name__ == "__main__":
    main()
