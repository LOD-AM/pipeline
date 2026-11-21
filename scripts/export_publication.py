#!/usr/bin/env python3
"""Export the records of one publication from the converter output (website#18).

The owner released single publications for the website (2026-11-17: the Arslantepe
dataset of hauptmann2002chemical). This writes only what that publication documents,
plus what those records point to; the rest of the database stays private.

Selection, starting from the publication (found by its citation key, dcterms:identifier):
  1. seeds: every resource with crm:P70i_is_documented_in the publication (finds, analyses);
  2. closure over outgoing links to LOD-AM resources (https://lod-am.net/id/...) and blank
     nodes: parts, samples, measurements, features, sites, places, phases, cultures,
     chronology systems, types and their broader concepts, labs, identifiers, time-spans,
     the publication with its authors and journal, and the source publication of each
     chronology system (dcterms:source, with its authors and journal: bibliographic data
     only, never what is documented in it; owner 2026-11-19);
  3. a helper node <record>/<role> brings its record (e.g. a find without a feature points
     to its site's place, so the site comes along);
  4. the only incoming links followed are sampling events (crmsci:O3_sampled_from /
     crmsci:O5_removed) of selected objects and samples. Nothing else incoming: a site or
     feature never pulls in further finds of other publications.
External resources (AAT, ChEBI, Wikidata, ROR, QUDT, ...) are kept as link targets only.

Usage: scripts/export_publication.py <out/release/lod-am.ttl> <citation-key> <dest.ttl>
The result is checked like the full output (scripts/export_publication.sh). Write it to out/
(private) first; it goes to the public website only as released by the owner.
"""
import sys
from collections import Counter

from rdflib import BNode, Graph, Literal, Namespace, URIRef
from rdflib.namespace import DCTERMS

CRM = Namespace("http://www.cidoc-crm.org/cidoc-crm/")
CRMSCI = Namespace("http://www.cidoc-crm.org/extensions/crmsci/")
BASE = "https://lod-am.net/id/"
SAMPLING_LINKS = (CRMSCI.O3_sampled_from, CRMSCI.O5_removed)

src, key, dest = sys.argv[1:4]
g = Graph().parse(src, format="turtle")

pubs = [s for s in g.subjects(DCTERMS.identifier, Literal(key))]
if len(pubs) != 1:
    sys.exit(f"FAIL: {len(pubs)} publications with citation key {key!r}")
pub = pubs[0]
seeds = set(g.subjects(CRM.P70i_is_documented_in, pub))
if not seeds:
    sys.exit(f"FAIL: nothing is documented in {pub}")


def local(node):
    return isinstance(node, BNode) or (isinstance(node, URIRef) and str(node).startswith(BASE))


selected = set()
todo = [pub, *seeds]
while todo:
    node = todo.pop()
    if node in selected:
        continue
    selected.add(node)
    # A helper node <record>/<role> (e.g. a site's place, which finds without a feature point
    # to) brings its record along; the record contributes its outgoing links only.
    if isinstance(node, URIRef) and str(node).startswith(BASE) and str(node)[len(BASE):].count("/") >= 2:
        record = URIRef(BASE + "/".join(str(node)[len(BASE):].split("/")[:2]))
        if record not in selected and any(True for _ in g.predicate_objects(record)):
            todo.append(record)
    for o in g.objects(node, None):
        if local(o) and o not in selected:
            todo.append(o)
    # the source publication of a chronology system (a doi.org IRI is not local)
    if isinstance(node, URIRef) and str(node).startswith(BASE + "chronology/"):
        for o in g.objects(node, DCTERMS.source):
            if o not in selected:
                todo.append(o)
    for p in SAMPLING_LINKS:
        for s in g.subjects(p, node):
            if s not in selected:
                todo.append(s)

out = Graph()
for prefix, ns in g.namespaces():
    out.bind(prefix, ns, override=True)
for node in selected:
    for p, o in g.predicate_objects(node):
        out.add((node, p, o))

# Guard: every selected record of a converted kind must come with its own triples
kinds = Counter(str(n)[len(BASE):].split("/")[0] for n in selected
                if isinstance(n, URIRef) and str(n).startswith(BASE) and str(n)[len(BASE):].count("/") == 1)
# (local concepts such as :not_detected live in knowledge-graph data/vocab, not in the output)
empty = [n for n in selected if isinstance(n, URIRef) and str(n).startswith(BASE) and "/" in str(n)[len(BASE):]
         and not any(True for _ in g.predicate_objects(n))]
if empty:
    sys.exit(f"FAIL: {len(empty)} selected resources have no triples, e.g. {sorted(map(str, empty))[:3]}")
if len(out) == 0:
    sys.exit("FAIL: empty export")

# Privacy guard: no find or analysis of another publication may slip in. Every exported
# analysis is documented in this publication; every exported find (or part) is, or was
# sampled for an analysis that is.
analysed = {o for a in seeds for smp in g.objects(a, URIRef("http://purl.allotrope.org/ontologies/property#AFX_0000399"))
            for st in g.subjects(CRMSCI.O5_removed, smp) for o in g.objects(st, CRMSCI.O3_sampled_from)}
analysed |= {w for o in analysed for w in g.objects(o, CRM.P46i_forms_part_of)}
for n in selected:
    if not isinstance(n, URIRef):
        continue
    kind = str(n)[len(BASE):].split("/")[0] if str(n).startswith(BASE) and str(n)[len(BASE):].count("/") == 1 else None
    if kind == "analysis" and n not in seeds:
        sys.exit(f"FAIL: analysis {n} is not documented in {key}")
    if kind == "find" and n not in seeds and n not in analysed:
        sys.exit(f"FAIL: find {n} is neither documented in {key} nor sampled for one of its analyses")

out.serialize(dest, format="turtle")
print(f"{key}: {pub}")
print(f"  {len(seeds)} resources documented in it, {len(selected)} resources, {len(out)} triples")
print("  records by kind: " + ", ".join(f"{k} {v}" for k, v in sorted(kinds.items())))
print(f"written: {dest}")
