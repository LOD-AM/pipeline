#!/usr/bin/env python3
"""Compare two full graphs, e.g. before and after a schema round (planning#27, round 0).

  scripts/compare_graphs.py OLD.ttl NEW.ttl [--examples N]

Prints whether the graphs are the same (as sets of triples, blank nodes compared canonically) and,
if not, the removed and added triples grouped by the kind of record (the <kind> of
https://lod-am.net/id/<kind>/<uuid>, else the subject's namespace) and the predicate, with up to N
example triples per group (default 3). Exit code: 0 the same, 1 different, 2 usage or parse error.

Every schema round of the research database must give the same graph, except for the changes
the round intends (#27 lists them per round); this report is how a round shows that.
The input and the report are PRIVATE (the database as a whole; pipeline CLAUDE.md): run it on
out/ files only and never commit its output. Single example triples may go into a PR or issue.
"""
import re
import sys
from collections import defaultdict

from rdflib import BNode, Graph, URIRef
from rdflib.compare import to_canonical_graph

ID = re.compile(r"https://lod-am\.net/id/([^/]+)/")


def load(path):
    g = Graph()
    try:
        g.parse(path)
    except Exception as e:  # noqa: BLE001 - any parser error ends the comparison
        sys.exit(f"FAIL: cannot parse {path}: {e}")
    if any(isinstance(t, BNode) for tr in g for t in tr):
        g = to_canonical_graph(g)  # slow, but makes blank nodes comparable; the converter emits none today
    return {(s, p, o) for s, p, o in g}


def kind(s):
    if isinstance(s, URIRef):
        m = ID.match(str(s))
        if m:
            return m.group(1)
        return re.sub(r"[^/#]*$", "", str(s)) or str(s)
    return "(blank node)"


def nt(t):
    return " ".join(x.n3() for x in t) + " ."


def report(label, triples, examples):
    groups = defaultdict(list)
    for t in triples:
        groups[(kind(t[0]), t[1].n3())].append(t)
    print(f"\n{label}: {len(triples)} triple(s)")
    for (k, p), ts in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f"  {len(ts):>7}  {k}  {p}")
        for t in sorted(ts, key=nt)[:examples]:
            print(f"           {nt(t)}")


def main(argv):
    examples = 3
    if "--examples" in argv:
        i = argv.index("--examples")
        try:
            examples = int(argv[i + 1])
        except (IndexError, ValueError):
            sys.exit(2)
        del argv[i:i + 2]
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    old, new = load(argv[0]), load(argv[1])
    removed, added = old - new, new - old
    print(f"old: {argv[0]} ({len(old)} triples)\nnew: {argv[1]} ({len(new)} triples)")
    if not removed and not added:
        print("the same graph")
        return 0
    print(f"DIFFERENT: {len(removed)} removed, {len(added)} added")
    report("removed", removed, examples)
    report("added", added, examples)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            sys.exit(2)
        raise
