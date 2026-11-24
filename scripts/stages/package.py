#!/usr/bin/env python3
"""Stage package (planning#5, #6): the checked output → out/release/ and out/internal/.

Runs only after the check and publish stages left out/.build/checks.json and published.json.

out/release/    what may leave the server: the released publications (published/<key>.ttl, one
                file each) + manifest.json. Never the full graph (owner, 2026-11-21).
out/internal/   private, stays on the server: the full graph lod-am.ttl, skip report, SHACL
                reports, manifest.json with the full graph's counts and hashes.
Each is built in out/.build/ and swapped in with one rename; the one it replaces is kept as
out/release.prev/ or out/internal.prev/ (local rollback). A failed run before this point leaves
both as they were.

The manifest traces every file to its inputs (planning#3 "Done when"):
  source          the database snapshot (sha256, time, server version) or a dump file (sha256,
                  and the commit that last changed it, if it is in a git repository)
  pipeline        commit of this repository, modified?, image tag (PIPELINE_IMAGE, set by the
                  build image), Ontop version
  knowledge_graph commit of the checkout whose tools and shapes checked the output, modified?
  zotero          group and library version of the snapshot
  publications    per released publication: file, triples, sha256, canonical sha256, SHACL result
  checks          full graph: terms, SHACL (violations 0), source rows vs. output: passed
The internal manifest adds the full graph's triples, hashes, SHACL warning count and skipped rows,
and the peak memory and duration of each heavy step (out/.build/resources.jsonl, written by
scripts/stages/measure.py; planning#6), so that the growth of the database shows up run by run.
The public one leaves out these figures about the unreleased database.
With RELEASE_STRICT=1 the stage refuses uncommitted code, and a source it cannot trace (a dump file
neither committed nor a snapshot), so that the manifest really describes the release.

Usage: scripts/stages/package.py      (env: KG=../knowledge-graph)
"""
import copy
import hashlib
import json
import os
import re
import resource
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "out" / ".build"
KG = Path(os.environ.get("KG", ROOT.parent / "knowledge-graph")).resolve()
ZOTERO_VERSION = ROOT / ".cache" / "zotero" / "group-6765723.version"
PIPELINE_PATHS = ["Makefile", "mapping", "scripts", "config", "Dockerfile", "docker"]
INTERNAL_FILES = {"lod-am.ttl": "lod-am.ttl", "skip-report.csv": "skip-report.csv",
                  "shacl.txt": "shacl-report.txt", "shacl-warnings.txt": "shacl-warnings.txt"}


def git(repo, *args):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def modified(repo, paths=()):
    status = git(repo, "status", "--porcelain", "--", *paths)
    return None if status is None else bool(status)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def graph_digest(ttl):
    """Triple count and sha256 of the sorted N-Triples (blank nodes renamed canonically)."""
    from rdflib import BNode, Graph
    from rdflib.compare import to_canonical_graph
    g = Graph().parse(ttl, format="turtle")
    if any(isinstance(t, BNode) for triple in g for t in triple):
        g = to_canonical_graph(g)                         # slow; the converter emits no blank nodes today
    lines = sorted(l for l in g.serialize(format="nt").splitlines() if l.strip())
    return len(g), hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


def fail(msg):
    sys.exit(f"FAIL: {msg}")


def source_info(dump):
    meta = dump.with_suffix(".json")
    if meta.exists():                                     # a snapshot of the live database
        info = json.loads(meta.read_text())
        if info.get("sha256") != sha256(dump):
            fail(f"snapshot {dump.name} does not match its {meta.name}")
        return info
    info = {"kind": "file", "file": dump.name, "sha256": sha256(dump), "commit": None, "modified": None}
    repo = git(dump.parent, "rev-parse", "--show-toplevel")
    if repo:                                              # e.g. a dump in a checkout of LOD-AM/ingest
        rel = str(dump.relative_to(repo))
        if git(repo, "rev-parse", "--is-shallow-repository") != "true":   # shallow: commit unknown, not wrong
            info["commit"] = git(repo, "log", "-1", "--format=%H", "--", rel) or None
        info["modified"] = modified(repo, [rel])
    return info


def ontop_version():
    pom = (ROOT / "mapping" / "pom.xml").read_text()
    m = re.search(r"<artifactId>ontop-cli</artifactId>\s*<version>([^<]+)<", pom)
    v = m and m.group(1)
    prop = v and re.fullmatch(r"\$\{([\w.-]+)\}", v)
    if prop:                                              # <version>${ontop.version}</version>
        m = re.search(rf"<{re.escape(prop.group(1))}>([^<]+)</", pom)
        v = m and m.group(1)
    return v


def resources():
    """Peak memory and duration per step, plus this stage's own peak."""
    f = BUILD / "resources.jsonl"
    steps = [json.loads(l) for l in f.read_text(encoding="utf-8").splitlines() if l.strip()] if f.exists() else []
    steps.append({"step": "package", "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)})
    peak = max(steps, key=lambda s: s["peak_rss_mb"])
    return {"peak_rss_mb": peak["peak_rss_mb"], "peak_step": peak["step"],
            "seconds": round(sum(s.get("seconds", 0) for s in steps)), "steps": steps}


def swap(stage, dest):
    prev = dest.with_name(dest.name + ".prev")
    if dest.exists():
        shutil.rmtree(prev, ignore_errors=True)
        dest.rename(prev)
    stage.rename(dest)


def main():
    os.umask(0o077)                                       # owner-only files, as in the shell stages
    for f in ("checks.json", "published.json", "test_materialize.txt", "dump.path", *INTERNAL_FILES):
        if not (BUILD / f).exists():
            fail(f"out/.build/{f} missing: an earlier stage did not pass; nothing packaged")
    checks = json.loads((BUILD / "checks.json").read_text())
    published = json.loads((BUILD / "published.json").read_text())
    if not published["publications"]:
        fail("no released publication; nothing packaged")
    if not ZOTERO_VERSION.exists():
        fail("Zotero snapshot has no version file; run `make fetch`")

    triples, canon = graph_digest(BUILD / "lod-am.ttl")
    m = re.search(r"ok\s+(\d+) triples", (BUILD / "test_materialize.txt").read_text())
    if not m or int(m.group(1)) != triples:
        fail(f"triple count differs between check ({m and m.group(1)}) and package ({triples})")
    pubs = []
    for p in published["publications"]:
        f = BUILD / p["file"]
        n, c = graph_digest(f)
        if n == 0:
            fail(f"{p['file']} is empty")
        pubs.append({**p, "triples": n, "sha256": sha256(f), "canonical_sha256": c})

    public = {
        "manifest_version": 2,
        "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": source_info(Path((BUILD / "dump.path").read_text().strip())),
        "pipeline": {"commit": git(ROOT, "rev-parse", "HEAD"), "modified": modified(ROOT, PIPELINE_PATHS),
                     "image": os.environ.get("PIPELINE_IMAGE"), "ontop": ontop_version()},
        "knowledge_graph": {"commit": git(KG, "rev-parse", "HEAD"), "modified": modified(KG)},
        "zotero": {"group": 6765723, "library_version": int(ZOTERO_VERSION.read_text())},
        "publications": {"selected_from": published["selected_from"], "files": pubs},
        "checks": {"terms": checks["terms"], "shacl_violations": checks["shacl"]["violations"],
                   "test_materialize": checks["test_materialize"]},
    }
    internal = copy.deepcopy(public)
    internal["graph"] = {"file": "lod-am.ttl", "triples": triples, "sha256": sha256(BUILD / "lod-am.ttl"),
                         "canonical_sha256": canon}
    internal["checks"] = checks
    internal["resources"] = res = resources()

    if os.environ.get("RELEASE_STRICT") == "1":
        src = public["source"]
        problems = [k for k in ("pipeline", "knowledge_graph")
                    if public[k]["commit"] is None or public[k]["modified"] is not False]
        if src["kind"] != "snapshot" and (src.get("commit") is None or src.get("modified") is not False):
            problems.append("source (neither a snapshot nor a committed dump)")
        if problems:
            fail(f"RELEASE_STRICT: untraceable inputs: {', '.join(problems)}")

    rel, intl = BUILD / "release", BUILD / "internal"
    for d in (rel, intl):
        shutil.rmtree(d, ignore_errors=True)
    (rel / "published").mkdir(parents=True)
    intl.mkdir()
    for p in pubs:
        shutil.copy2(BUILD / p["file"], rel / p["file"])
    for src, dst in INTERNAL_FILES.items():
        shutil.copy2(BUILD / src, intl / dst)
    for d, m in ((rel, public), (intl, internal)):
        (d / "manifest.json").write_text(json.dumps(m, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    swap(intl, ROOT / "out" / "internal")
    swap(rel, ROOT / "out" / "release")
    print(f"package: out/release/ ({len(pubs)} publication(s): {', '.join(p['key'] for p in pubs)}), "
          f"out/internal/ ({triples} triples, {checks['shacl']['warnings']} SHACL warnings, "
          f"zotero v{public['zotero']['library_version']}); peak memory {res['peak_rss_mb']} MB ({res['peak_step']}), "
          f"{res['seconds']} s in measured steps")


if __name__ == "__main__":
    main()
