#!/usr/bin/env python3
"""SHACL validation with Apache Jena, in the output format of knowledge-graph tools/validate.py.

  scripts/shacl.py <data.ttl> [<file or directory with .ttl> ...]

Validates the data files (directories: every *.ttl in them) against knowledge-graph's shapes
($KG/shapes/*.ttl) with Jena's validator (jars in $JENA_LIB, shacl/pom.xml). Prints one line per
result, "VIOLATION: <focus> <path>: <message>" or "warning: …" (every severity but sh:Violation),
sorted, then "SHACL: V violation(s), W warning(s), N triples"; exits 1 on violations.

Why not pySHACL (planning review 2026-11-25, section 6): on the full graph it took 34 of a run's 38
minutes on the data LXC and 1.3 GB, growing linearly; Jena gave the same results (the same focus
nodes and paths; only the wording of default messages differs) in under a minute and 0.6 GB at
double the size. scripts/test_fixture.sh compares both on the fixture.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from rdflib import Graph, Namespace

SH = Namespace("http://www.w3.org/ns/shacl#")


def ttl_files(args):
    files = []
    for a in map(Path, args):
        files += sorted(a.rglob("*.ttl")) if a.is_dir() else [a]
    return [str(f) for f in files]


def java(main, *args, stdout):
    lib = os.environ.get("JENA_LIB") or sys.exit("JENA_LIB is not set (make fetch, or the build image)")
    heap = os.environ.get("LODAM_SHACL_HEAP", "1g")
    cmd = ["java", f"-Xmx{heap}", "-cp", f"{lib}/*", main, *args]
    r = subprocess.run(cmd, stdout=stdout, stderr=subprocess.PIPE, text=True)
    noise = ("Picked up JAVA_TOOL_OPTIONS", "Picked up _JAVA_OPTIONS")
    err = "\n".join(l for l in r.stderr.splitlines() if not l.startswith(noise))
    if r.returncode != 0:
        sys.exit(f"FAIL: {main} exited {r.returncode}\n{err}")
    if err:
        print(err, file=sys.stderr)


def main(argv):
    if not argv:
        sys.exit(__doc__)
    kg = os.environ.get("KG") or sys.exit("KG is not set")
    shapes = ttl_files([Path(kg) / "shapes"])
    data = ttl_files(argv)
    with tempfile.TemporaryDirectory() as tmp:
        # one N-Triples file each: riot gives every file's blank nodes their own labels
        data_nt, shapes_nt, report = (Path(tmp) / n for n in ("data.nt", "shapes.nt", "report.ttl"))
        with open(data_nt, "w") as out:
            java("riotcmd.riot", "--output=nt", *data, stdout=out)
        with open(shapes_nt, "w") as out:
            java("riotcmd.riot", "--output=nt", *shapes, stdout=out)
        # the triple count as rdflib gives it: a triple in two files counts once (blank nodes
        # have their own label per file, so equal lines are equal triples)
        with open(data_nt, "rb") as f:
            unique = {line for line in f if line.strip() and not line.startswith(b"#")}
        triples = len(unique)
        with open(data_nt, "wb") as f:
            f.writelines(sorted(unique))
        del unique
        with open(report, "w") as out:
            java("shacl.shacl", "validate", f"--shapes={shapes_nt}", f"--data={data_nt}", stdout=out)
        g = Graph().parse(report, format="turtle")
    lines, violations, warnings = [], 0, 0
    for r in g.subjects(SH.resultSeverity, None):
        severity = g.value(r, SH.resultSeverity)
        kind = "VIOLATION" if severity == SH.Violation else "warning"
        violations += kind == "VIOLATION"
        warnings += kind == "warning"
        path = g.value(r, SH.resultPath)
        lines.append(f"{kind}: {g.value(r, SH.focusNode)} {path or ''}: {g.value(r, SH.resultMessage)}")
    for line in sorted(lines):
        print(line)
    print(f"SHACL: {violations} violation(s), {warnings} warning(s), {triples} triples")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
