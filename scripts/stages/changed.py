#!/usr/bin/env python3
"""Has anything changed since the live release? (planning#6, scheduled runs)

Compares the inputs a release would be built from with those in out/release/manifest.json:
the database snapshot (sha256 of out/snapshots/latest.sql), the pipeline commit, the
knowledge-graph commit and the Zotero library version. The release list (config/) and the
release flag (planning#27) are covered: the first is part of the pipeline commit, the second of
the snapshot.

Writes one line to out/run-decision.txt, read by deploy/run.sh:
  changed: <what changed>     a release run is needed
  unchanged: <inputs>         the live release already reflects these inputs
Exits 0 either way; a missing snapshot is an error (run `make snapshot` first).
Usage: scripts/stages/changed.py      (env: KG=../knowledge-graph)
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KG = Path(os.environ.get("KG", ROOT.parent / "knowledge-graph")).resolve()
SNAP = ROOT / "out" / "snapshots" / "latest.sql"
ZOTERO = ROOT / ".cache" / "zotero" / "group-6765723.version"
MANIFEST = ROOT / "out" / "release" / "manifest.json"
DECISION = ROOT / "out" / "run-decision.txt"


def git(repo, *args):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def main():
    if not SNAP.exists():
        sys.exit("FAIL: no snapshot (out/snapshots/latest.sql); run `make snapshot` first")
    meta = json.loads(SNAP.resolve().with_suffix(".json").read_text())
    now = {"snapshot": meta["sha256"], "pipeline": git(ROOT, "rev-parse", "HEAD"),
           "knowledge_graph": git(KG, "rev-parse", "HEAD"),
           "zotero": int(ZOTERO.read_text()) if ZOTERO.exists() else None}
    if not MANIFEST.exists():
        decision = "changed: no release yet"
    else:
        m = json.loads(MANIFEST.read_text())
        live = {"snapshot": m["source"].get("sha256"), "pipeline": m["pipeline"]["commit"],
                "knowledge_graph": m["knowledge_graph"]["commit"], "zotero": m["zotero"]["library_version"]}
        diff = [k for k in now if now[k] != live[k]]
        if diff:
            decision = "changed: " + ", ".join(f"{k} {str(live[k])[:12]} → {str(now[k])[:12]}" for k in diff)
        else:
            decision = f"unchanged: snapshot {now['snapshot'][:12]}, pipeline {str(now['pipeline'])[:12]}"
    DECISION.parent.mkdir(parents=True, exist_ok=True)
    DECISION.write_text(decision + "\n", encoding="utf-8")
    print(decision)


if __name__ == "__main__":
    main()
