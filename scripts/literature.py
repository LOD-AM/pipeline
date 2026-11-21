#!/usr/bin/env python3
"""Literature for the converter (ingest#12, ingest#14): FaBiO records from the owner's public Zotero group.

The owner moved the LOD-AM entries into a public group library (no API key needed):
https://www.zotero.org/groups/6765723/lod-am/library. literature.zotero_key is the Zotero
citation key (ingest#12). Patterns: knowledge-graph CONVENTIONS.md ("Literature").

Offline: reads only the snapshot written by the fetch stage (scripts/fetch_zotero.py,
`make fetch`) and never contacts Zotero (planning#5).

Writes (mode `map`, materialize stage: needed before the views are built)
  <out>/publication.csv  zotero_key,publication_iri: loaded into the build database, so the
                         R2RML views can link finds and analyses to their publication (P70i)
Writes (mode `records`, enrich stage)
  <out>/literature.ttl   FaBiO records (publication, persons, journals, containing books)
Usage: scripts/literature.py map|records <out dir> <psql command ...>
Every citation key of the database must be in the group; the script fails otherwise.
"""
import csv
import hashlib
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GROUP = 6765723
CACHE = ROOT / ".cache" / "zotero" / f"group-{GROUP}.json"
BASE = "https://lod-am.net/id/"
FABIO_CLASS = {"journalArticle": "JournalArticle", "book": "Book", "bookSection": "BookChapter",
               "thesis": "Thesis", "conferencePaper": "ConferencePaper"}


def uid(kind, text):
    """Deterministic uuid for things without a database row (persons, journals)."""
    return f"{BASE}{kind}/{uuid.UUID(hashlib.md5(f'{kind}:{text}'.encode()).hexdigest())}"


def lit(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").strip() + '"'


def pub_iri(d):
    doi = re.sub(r"^(https?://(dx\.)?doi\.org/|doi:)", "", (d.get("DOI") or "").strip(), flags=re.I)
    return (f"https://doi.org/{doi}", doi) if doi else (f"{BASE}pub/{d['citationKey']}", None)


def main(mode, out, psql):
    if not CACHE.exists():
        sys.exit(f"FAIL: no Zotero snapshot ({CACHE.relative_to(ROOT)}); run `make fetch`")
    items = json.loads(CACHE.read_text(encoding="utf-8"))
    pubs = {i["data"]["citationKey"]: i["data"] for i in items
            if i["data"]["itemType"] not in ("attachment", "note") and i["data"].get("citationKey")}
    keys = subprocess.run(psql + ["-At", "-c", "SELECT zotero_key FROM cau.literature ORDER BY 1"],
                          check=True, capture_output=True, text=True).stdout.split()
    missing = [k for k in keys if k not in pubs]
    if missing:
        sys.exit(f"FAIL: citation keys not in the Zotero group: {missing}")

    t = ["@prefix fabio: <http://purl.org/spar/fabio/> .", "@prefix prism: <http://prismstandard.org/namespaces/basic/2.0/> .",
         "@prefix dcterms: <http://purl.org/dc/terms/> .", "@prefix foaf: <http://xmlns.com/foaf/0.1/> .",
         "@prefix crm: <http://www.cidoc-crm.org/cidoc-crm/> .", "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .", ""]
    persons, journals, rows = {}, {}, []

    def person(c):
        if c.get("name") and c["name"].lower() in ("others", "et al.", "u. a."):
            return None                                   # "et al." is no person
        fam, giv = (c.get("lastName") or c.get("name") or "").strip(), (c.get("firstName") or "").strip()
        iri = uid("person", f"{fam}|{giv}")
        persons[iri] = (fam, giv)
        return iri

    for key in keys:
        d = pubs[key]
        iri, doi = pub_iri(d)
        rows.append((key, iri))
        cls = FABIO_CLASS.get(d["itemType"])
        if not cls:
            sys.exit(f"FAIL: no FaBiO class for Zotero type {d['itemType']} ({key})")
        p = [f"<{iri}> a fabio:{cls}, crm:E31_Document", f"    dcterms:title {lit(d.get('title') or key)}",
             f"    dcterms:identifier {lit(key)}"]                     # the citation key (ingest#12)
        year = re.search(r"\b(\d{4})\b", d.get("date") or "")
        if year:
            p.append(f'    fabio:hasPublicationYear "{year.group(1)}"^^xsd:gYear')
        if doi:
            p.append(f"    prism:doi {lit(doi)}")
        for c in d.get("creators", []):
            who = person(c)
            if who and c.get("creatorType") == "author":
                p.append(f"    dcterms:creator <{who}>")
            elif who and c.get("creatorType") == "editor" and d["itemType"] != "bookSection":
                p.append(f"    dcterms:contributor <{who}>")
        pages = (d.get("pages") or "").strip()
        m = re.fullmatch(r"(\w+)\s*[-–—]\s*(\w+)", pages)
        if m:
            p += [f"    prism:startingPage {lit(m.group(1))}", f"    prism:endingPage {lit(m.group(2))}"]
        elif pages:
            p.append(f"    prism:pageRange {lit(pages)}")
        for field, prop in (("volume", "prism:volume"), ("issue", "prism:issueIdentifier"), ("ISBN", "prism:isbn"),
                            ("publisher", "dcterms:publisher")):
            if (d.get(field) or "").strip():
                p.append(f"    {prop} {lit(d[field])}")
        if d["itemType"] == "journalArticle" and (d.get("publicationTitle") or "").strip():
            j = uid("journal", d["publicationTitle"].strip())
            journals[j] = d["publicationTitle"].strip()
            p.append(f"    dcterms:isPartOf <{j}>")
        if d["itemType"] == "bookSection" and (d.get("bookTitle") or "").strip():
            book = f"{iri}/book" if not doi else f"{BASE}pub/{key}/book"
            p.append(f"    dcterms:isPartOf <{book}>")
            b = [f"<{book}> a fabio:Book, crm:E31_Document", f"    dcterms:title {lit(d['bookTitle'])}"]
            if year:
                b.append(f'    fabio:hasPublicationYear "{year.group(1)}"^^xsd:gYear')
            for c in d.get("creators", []):
                who = person(c)
                if who and c.get("creatorType") == "editor":
                    b.append(f"    dcterms:contributor <{who}>")
            t.append(" ;\n".join(b) + " .\n")
        t.append(" ;\n".join(p) + " .\n")
    for iri, (fam, giv) in sorted(persons.items()):
        name = f"{giv} {fam}".strip()
        t.append(f"<{iri}> a foaf:Person ;\n    foaf:name {lit(name)}" + (f" ;\n    foaf:familyName {lit(fam)}" if fam else "")
                 + (f" ;\n    foaf:givenName {lit(giv)}" if giv else "") + " .\n")
    for iri, title in sorted(journals.items()):
        t.append(f"<{iri}> a fabio:Journal ;\n    dcterms:title {lit(title)} .\n")

    out.mkdir(parents=True, exist_ok=True)
    if mode == "map":
        with open(out / "publication.csv", "w", newline="", encoding="utf-8") as f:
            csv.writer(f, lineterminator="\n").writerows(rows)
        print(f"literature: {len(rows)} citation keys -> publication IRIs")
    else:
        (out / "literature.ttl").write_text("\n".join(t), encoding="utf-8")
        print(f"literature: {len(rows)} publications, {len(persons)} persons, {len(journals)} journals")


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[1] not in ("map", "records"):
        sys.exit(__doc__)
    main(sys.argv[1], Path(sys.argv[2]), sys.argv[3:])
