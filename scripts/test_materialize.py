#!/usr/bin/env python3
"""Checks the materialised RDF against the database it came from (ingest#14).

Every source row must be converted or listed in the skip report, and the output
must contain exactly the resources the source rows give (by id_uuid).
Usage: scripts/test_materialize.py <out.ttl> <skip-report.csv> <postgresql://...>
"""
import csv
import subprocess
import sys

from rdflib import Graph, Literal, Namespace, RDF, RDFS, URIRef

CRM = Namespace("http://www.cidoc-crm.org/cidoc-crm/")
GEO = Namespace("http://www.opengis.net/ont/geosparql#")
SKOS = Namespace("http://www.w3.org/2004/02/skos/core#")
BASE = "https://lod-am.net/id/"

ttl, skip_csv, dburl = sys.argv[1:4]
g = Graph().parse(ttl, format="turtle")
skips = list(csv.DictReader(open(skip_csv, encoding="utf-8")))


def sql(q):
    out = subprocess.run(["psql", dburl, "-At", "-F", "\t", "-c", q], check=True,
                         capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line]


def iris(kind, q):
    return {URIRef(f"{BASE}{kind}/{r[0]}") for r in sql(q)}


def skipped(table, reason_prefix=""):
    return {r["source_key"] for r in skips if r["source_table"] == table and r["reason"].startswith(reason_prefix)}


errors = []


def same(name, expected, actual):
    missing, extra = expected - actual, actual - expected
    if missing or extra:
        errors.append(f"{name}: {len(missing)} missing, {len(extra)} unexpected "
                      f"(e.g. {sorted(missing)[:2]} / {sorted(extra)[:2]})")
    else:
        print(f"ok   {name}: {len(actual)}")


# Sites: converted + skipped = all rows
all_sites = {r[0] for r in sql("SELECT site_id FROM cau.site")}
no_label = skipped("site", "no site_latin")
if len(all_sites) != len(all_sites - no_label) + len(no_label & all_sites):
    errors.append("site skip report inconsistent")
expected_sites = iris("site", "SELECT id_uuid FROM cau.site WHERE nullif(btrim(site_latin), '') IS NOT NULL")
same("sites (E27_Site)", expected_sites, set(g.subjects(RDF.type, CRM.E27_Site)))
if len(expected_sites) + len(no_label) != len(all_sites):
    errors.append(f"sites: {len(expected_sites)} converted + {len(no_label)} skipped != {len(all_sites)} rows")
else:
    print(f"ok   sites: {len(expected_sites)} converted + {len(no_label)} skipped = {len(all_sites)} rows")

# Every site: an English label, one place; geometry where the source has one
for s in expected_sites:
    labels = [o for o in g.objects(s, RDFS.label) if isinstance(o, Literal) and o.language == "en"]
    places = list(g.objects(s, CRM.P53_has_former_or_current_location))
    if len(labels) != 1 or len(places) != 1:
        errors.append(f"{s}: {len(labels)} @en labels, {len(places)} places")
with_geom = iris("site", "SELECT s.id_uuid FROM cau.site s JOIN cau.geography g USING (geography_id) "
                 "WHERE g.geography IS NOT NULL AND nullif(btrim(s.site_latin), '') IS NOT NULL")
same("site and region places with geometry",
     {URIRef(f"{s}/location") for s in with_geom} | iris("region", "SELECT id_uuid FROM cau.region WHERE geography IS NOT NULL"),
     {p for p in g.subjects(GEO.hasGeometry, None)})
for u, in sql("SELECT id_uuid FROM cau.region WHERE geography IS NOT NULL"):
    if not str(g.value(URIRef(f"{BASE}region/{u}/geometry"), GEO.asWKT) or "").startswith("MULTIPOLYGON"):
        errors.append(f"region {u}: no MULTIPOLYGON")
geoms = list(g.subjects(RDF.type, GEO.Geometry))
bad_wkt = [x for x in geoms if len(list(g.objects(x, GEO.asWKT))) != 1]
if bad_wkt:
    errors.append(f"{len(bad_wkt)} geometries without exactly one WKT")
no_geom = skipped("site", "no geometry")
if len(expected_sites) - len(with_geom) != len(no_geom):
    errors.append(f"sites without geometry: {len(expected_sites) - len(with_geom)}, skip report lists {len(no_geom)}")

# Name as reported and location certainty (knowledge-graph CONVENTIONS "Sites")
for u, rep, cert in sql("SELECT id_uuid, coalesce(nullif(btrim(site_as_reported), ''), ''), "
                        "coalesce(site_location_certainty, '') FROM cau.site "
                        "WHERE nullif(btrim(site_latin), '') IS NOT NULL"):
    s = URIRef(f"{BASE}site/{u}")
    names = [n for n in g.objects(s, CRM.P1_is_identified_by)
             if (n, CRM.P2_has_type, URIRef(BASE + "name_as_reported")) in g]
    got = [str(v) for n in names for v in g.objects(n, CRM.P190_has_symbolic_content)]
    if got != ([rep] if rep else []):
        errors.append(f"{s}: name as reported {got!r}, source {rep!r}")
    types = [str(t) for t in g.objects(URIRef(f"{s}/location"), CRM.P2_has_type)]
    if types != ([f"{BASE}location_{cert}"] if cert else []):
        errors.append(f"{s}/location: certainty {types!r}, source {cert!r}")
print("ok   names as reported and location certainty checked against the source")

# Native names: one extra label per site_native, with its language tag
native = sql("SELECT s.id_uuid, s.site_native_lang FROM cau.site s "
             "WHERE nullif(btrim(s.site_native), '') IS NOT NULL AND nullif(btrim(s.site_latin), '') IS NOT NULL")
for u, lang in native:
    s = URIRef(f"{BASE}site/{u}")
    if not any(isinstance(o, Literal) and o.language == lang for o in g.objects(s, RDFS.label)):
        errors.append(f"{s}: no @{lang} label")
print(f"ok   native-name labels checked: {len(native)}")

# Regions and site types
same("regions (E53_Place with label)", iris("region", "SELECT id_uuid FROM cau.region"),
     {s for s in g.subjects(RDF.type, CRM.E53_Place) if str(s).startswith(BASE + "region/")})
TYPOLOGY = ("SELECT id_uuid FROM cau.type UNION ALL SELECT id_uuid FROM cau.type_group "
            "UNION ALL SELECT id_uuid FROM cau.find_character")
local_e55 = {s for s in g.subjects(RDF.type, CRM.E55_Type) if str(s).startswith(BASE + "type/")}
same("site/feature types and typology (E55_Type)",
     iris("type", "SELECT id_uuid FROM cau.site_interpretation") | iris("type", TYPOLOGY)
     | iris("type", "SELECT id_uuid FROM cau.part WHERE part_id <> 0"), local_e55)
TYPOLOGY_IRI = URIRef(BASE + "typology")
same("typology concepts in :typology", iris("type", TYPOLOGY), set(g.subjects(SKOS.inScheme, TYPOLOGY_IRI)))
exp_broader = set()
for c, b in sql("SELECT t.id_uuid, coalesce(g.id_uuid, fc.id_uuid) FROM cau.type t LEFT JOIN cau.type_group g USING (type_group_id) "
                "JOIN cau.find_character fc ON fc.find_character_id = t.find_character_id "
                "UNION ALL SELECT g.id_uuid, coalesce(b.id_uuid, fc.id_uuid) FROM cau.type_group g "
                "LEFT JOIN cau.type_group b ON b.type_group_id = g.broader_type_group_id "
                "LEFT JOIN cau.find_character fc ON fc.find_character_id = g.find_character_id"):
    exp_broader.add((URIRef(f"{BASE}type/{c}"), URIRef(f"{BASE}type/{b}")))
same("typology skos:broader", exp_broader, set(g.subject_objects(SKOS.broader)))
same("typology top concepts (classes)", iris("type", "SELECT id_uuid FROM cau.find_character"),
     set(g.subjects(SKOS.topConceptOf, TYPOLOGY_IRI)))
for kind, pred in (("closeMatch", SKOS.closeMatch), ("broadMatch", SKOS.broadMatch)):
    exp = {(URIRef(f"{BASE}type/{u}"), URIRef(f"http://vocab.getty.edu/aat/{a}"))
           for u, a in sql(f"SELECT id_uuid, aat_id FROM cau.site_interpretation WHERE aat_match = '{kind}' "
                           f"UNION ALL SELECT id_uuid, aat_id FROM cau.type WHERE aat_match = '{kind}' "
                           f"UNION ALL SELECT id_uuid, aat_id FROM cau.type_group WHERE aat_match = '{kind}' "
                           f"UNION ALL SELECT id_uuid, aat_id FROM cau.find_character WHERE aat_match = '{kind}'")}
    same(f"type AAT {kind}", exp, set(g.subject_objects(pred)))

# Features: all, with labels; A2 exactly for those with finds; part of the site and the kurgan
CRMA = Namespace("http://www.cidoc-crm.org/extensions/crmarchaeo/")
same("features (E25)", iris("feature", "SELECT id_uuid FROM cau.feature"),
     set(g.subjects(RDF.type, CRM["E25_Human-Made_Feature"])))
same("features with finds (A2)", iris("feature", "SELECT f.id_uuid FROM cau.feature f WHERE EXISTS "
     "(SELECT 1 FROM cau.find x WHERE x.site_id = f.site_id AND x.feature_id = f.feature_id)"),
     set(g.subjects(RDF.type, CRMA.A2_Stratigraphic_Volume_Unit)))
for f in g.subjects(RDF.type, CRM["E25_Human-Made_Feature"]):
    if not any(isinstance(o, Literal) and o.language == "en" for o in g.objects(f, RDFS.label)):
        errors.append(f"{f}: no @en label")
same("feature → site", {(URIRef(f"{BASE}feature/{f}"), URIRef(f"{BASE}site/{s}")) for f, s in
     sql("SELECT f.id_uuid, s.id_uuid FROM cau.feature f JOIN cau.site s USING (site_id)")},
     {(a, b) for a, b in g.subject_objects(CRM.P46i_forms_part_of) if "/site/" in str(b)})
same("feature → kurgan", {(URIRef(f"{BASE}feature/{f}"), URIRef(f"{BASE}feature/{p}")) for f, p in
     sql("SELECT f.id_uuid, p.id_uuid FROM cau.feature f JOIN cau.feature p "
         "ON p.site_id = f.site_id AND p.feature_id = f.part_of_feature_id")},
     {(a, b) for a, b in g.subject_objects(CRM.P46i_forms_part_of) if "/feature/" in str(b)})

# Dating: features and site periods witness their phase only; the culture consists of its phases (ingest#17)
exp_dating = set()
for kind, q in (("feature", "SELECT f.id_uuid, z.id_uuid FROM cau.feature f JOIN cau.zt z USING (period_id)"),
                ("site", "SELECT s.id_uuid, z.id_uuid FROM cau.site_period p JOIN cau.site s USING (site_id) "
                         "JOIN cau.zt z USING (period_id)")):
    for u, z in sql(q):
        exp_dating.add((URIRef(f"{BASE}{kind}/{u}"), URIRef(f"{BASE}period/{z}")))
same("dating (P8i_witnessed → phase)", exp_dating, set(g.subject_objects(CRM.P8i_witnessed)))
phases = {(URIRef(f"{BASE}period/{z}"), URIRef(f"{BASE}culture/{c}")) for z, c in
          sql("SELECT z.id_uuid, c.id_uuid FROM cau.zt z JOIN cau.culture c USING (culture_id)")}
same("phase → culture (P9i)", phases, set(g.subject_objects(CRM.P9i_forms_part_of)) - {
     (a, b) for a, b in g.subject_objects(CRM.P9i_forms_part_of) if "/period/" not in str(a)})
same("culture → phase (P9)", {(c, z) for z, c in phases}, set(g.subject_objects(CRM.P9_consists_of)))
same("phase → chronology (skos:inScheme)", {(URIRef(f"{BASE}period/{z}"), URIRef(f"{BASE}chronology/{t}")) for z, t in
     sql("SELECT z.id_uuid, t.id_uuid FROM cau.zt z JOIN cau.zt_type t USING (zt_type_id)")},
     {(a, b) for a, b in g.subject_objects(SKOS.inScheme) if "/chronology/" in str(b)})
same("periods (zt, E4 with time-span)", iris("period", "SELECT id_uuid FROM cau.zt WHERE min IS NOT NULL AND max IS NOT NULL"),
     {s for s in g.subjects(RDF.type, CRM.E4_Period) if "/period/" in str(s)})
same("cultures (E4)", iris("culture", "SELECT id_uuid FROM cau.culture"),
     {s for s in g.subjects(RDF.type, CRM.E4_Period) if "/culture/" in str(s)})
for u, lo, hi in sql("SELECT id_uuid, trim_scale(min)::text, trim_scale(max)::text FROM cau.zt WHERE min IS NOT NULL"):
    ts = URIRef(f"{BASE}period/{u}/time_span")
    got = (str(g.value(ts, CRM.P79_beginning_is_qualified_by)), str(g.value(ts, CRM.P80_end_is_qualified_by)))
    if got != (f"-{lo}", f"-{hi}"):
        errors.append(f"{ts}: {got}, source {lo}/{hi} BC")

# Finds: all, labelled, typed (local type + AAT shortcut), in a feature or at the site's place,
# with the number as reported, the drawing number where it differs, and the remarks as a note
finds = iris("find", "SELECT id_uuid FROM cau.find")
parts = {URIRef(f"{BASE}find/{u}/{p}") for u, p in sql(
    "SELECT DISTINCT x.id_uuid, lower(replace(pt.part_en, ' ', '_')) FROM (SELECT site_id, find_id, part_id FROM cau.ca "
    "UNION SELECT site_id, find_id, part_id FROM cau.pb) a JOIN cau.find x USING (site_id, find_id) "
    "JOIN cau.part pt USING (part_id) WHERE a.part_id <> 0")}
same("finds and object parts (E22)", finds | parts, set(g.subjects(RDF.type, CRM["E22_Human-Made_Object"])))
same("material of analysed copper-base finds (P45)", iris("find", "SELECT DISTINCT x.id_uuid FROM cau.find x JOIN cau.ca c "
     "USING (site_id, find_id) WHERE c.main_id = 1"), set(g.subjects(CRM.P45_consists_of, URIRef("http://vocab.getty.edu/aat/300241441"))))
for x in finds:
    if not any(isinstance(o, Literal) and o.language == "en" for o in g.objects(x, RDFS.label)):
        errors.append(f"{x}: no @en label")
exp_types = {(URIRef(f"{BASE}find/{u}"), URIRef(f"{BASE}type/{t}")) for u, t in
             sql("SELECT x.id_uuid, t.id_uuid FROM cau.find x JOIN cau.type t USING (type_id)")}
same("find types (local only, knowledge-graph#28)", exp_types,
     {(a, b) for a, b in g.subject_objects(CRM.P2_has_type) if a in finds})
same("finds in a feature (AP21i)", {(URIRef(f"{BASE}find/{u}"), URIRef(f"{BASE}feature/{f}")) for u, f in
     sql("SELECT x.id_uuid, f.id_uuid FROM cau.find x JOIN cau.feature f ON f.site_id = x.site_id AND f.feature_id = x.feature_id")},
     set(g.subject_objects(CRMA.AP21i_is_contained_in)))
same("finds at the site's place (P53)", {(URIRef(f"{BASE}find/{u}"), URIRef(f"{BASE}site/{s}/location")) for u, s in
     sql("SELECT x.id_uuid, s.id_uuid FROM cau.find x JOIN cau.site s USING (site_id) WHERE x.feature_id IS NULL")},
     {(a, b) for a, b in g.subject_objects(CRM.P53_has_former_or_current_location) if a in finds})
OLD, DRAW = URIRef(BASE + "old_identifier"), URIRef(BASE + "drawing_number")
for u, old, drawing, note in [r + [""] * (4 - len(r)) for r in sql(
        "SELECT x.id_uuid, coalesce(nullif(btrim(x.find_old), ''), ''), "
        "CASE WHEN nullif(btrim(x.ref), '') NOT IN (coalesce(nullif(btrim(x.find_old), ''), ''), x.find_id::text) THEN btrim(x.ref) ELSE '' END, "
        "coalesce(nullif(btrim(x.remarks), ''), '') FROM cau.find x")]:
    f = URIRef(f"{BASE}find/{u}")
    ids = {(g.value(i, CRM.P2_has_type), str(g.value(i, CRM.P190_has_symbolic_content))) for i in g.objects(f, CRM.P1_is_identified_by)}
    exp = ({(OLD, old)} if old else set()) | ({(DRAW, drawing)} if drawing else set())
    if ids != exp:
        errors.append(f"{f}: identifiers {ids}, source {exp}")
    notes = [str(n) for n in g.objects(f, CRM.P3_has_note)]
    if notes != ([note] if note else []):
        errors.append(f"{f}: note {notes!r}, source {note!r}")
print("ok   find identifiers and notes checked against the source")

# Analyses (ingest#4, ingest#5, ingest#6, ingest#13; knowledge-graph#2, knowledge-graph#14, knowledge-graph#21)
AFX = Namespace("http://purl.allotrope.org/ontologies/property#")
AFR = Namespace("http://purl.allotrope.org/ontologies/result#")
QUDT = Namespace("http://qudt.org/schema/qudt#")
CRMS = Namespace("http://www.cidoc-crm.org/extensions/crmsci/")
analyses = iris("analysis", "SELECT id_uuid FROM cau.ca UNION ALL SELECT id_uuid FROM cau.pb")
same("analyses (E7)", analyses, set(g.subjects(RDF.type, CRM.E7_Activity)))
same("samples (S13), one per analysis", {URIRef(f"{a}/sample") for a in analyses}, set(g.subjects(RDF.type, CRMS.S13_Sample)))
same("analysis → sample (has input)", {(a, URIRef(f"{a}/sample")) for a in analyses}, set(g.subject_objects(AFX.AFX_0000399)))
same("analysis → lab", {(URIRef(f"{BASE}analysis/{a}"), URIRef(f"{BASE}lab/{l}")) for a, l in sql(
     "SELECT a.id_uuid, l.id_uuid FROM (SELECT id_uuid, lab_id FROM cau.ca UNION ALL SELECT id_uuid, lab_id FROM cau.pb) a "
     "JOIN cau.lab l USING (lab_id)")}, set(g.subject_objects(CRM.P14_carried_out_by)))
ELEMENTS = ["cu", "sn", "pb", "zn", "bi", "ag", "sb", "as", "fe", "ni", "co", "mn", "au", "p", "te", "se", "s"]
rows = sql("SELECT id_uuid, literature_id, main_id, " + ", ".join(f'coalesce("{e}"::text, \'-\')' for e in ELEMENTS) + " FROM cau.ca")
analysed = {(r[1], e) for r in rows for i, e in enumerate(ELEMENTS) if r[3 + i] != "-"}
exp_value, exp_nd = {}, set()
for r in rows:
    for i, e in enumerate(ELEMENTS):
        v = r[3 + i]
        if e == "cu" and r[2] == "1":
            continue                                  # all Cu of copper-base objects dropped (ingest#4)
        m = URIRef(f"{BASE}analysis/{r[0]}/{e}")
        if v != "-":
            exp_value[m] = v                          # as reported
        elif (r[1], e) in analysed:
            exp_nd.add(m)                             # not detected
measurements = set(g.subjects(RDF.type, AFR.AFR_0002099))
same("element measurements (mass fraction)", set(exp_value) | exp_nd, measurements)
same("measurements with a value", set(exp_value), set(g.subjects(QUDT.numericValue, None)) & measurements)
same("measurements not detected", exp_nd, set(g.subjects(CRM.P2_has_type, URIRef(BASE + "not_detected"))))
bad = [m for m, v in exp_value.items() if str(g.value(m, QUDT.numericValue)) != v]
if bad:
    errors.append(f"{len(bad)} values differ from the source, e.g. {bad[:2]}")
if any(str(m).endswith("/cu") for m in measurements):
    errors.append("Cu measurement of a copper-base object emitted")
RATIOS = [("pb206_pb204", "pb206_204"), ("pb207_pb204", "pb207_204"), ("pb208_pb204", "pb208_204"),
          ("pb207_pb206", "pb207_206"), ("pb208_pb206", "pb208_206"), ("pb204_pb206", "pb204_206")]
exp_ratios = {}
for r in sql("SELECT id_uuid, " + ", ".join(f"coalesce({c}::text, '-')" for _, c in RATIOS) + " FROM cau.pb"):
    for i, (name, _) in enumerate(RATIOS):
        if r[1 + i] != "-":
            exp_ratios[URIRef(f"{BASE}analysis/{r[0]}/{name}")] = r[1 + i]
same("lead isotope ratios (reported only)", set(exp_ratios), set(g.subjects(RDF.type, AFR.AFR_0002368)))
bad = [m for m, v in exp_ratios.items() if str(g.value(m, QUDT.numericValue)) != v]
if bad:
    errors.append(f"{len(bad)} ratios differ from the source, e.g. {bad[:2]}")

# Labs: their ROR id (owner, dump of 2026-11-16)
OWL = Namespace("http://www.w3.org/2002/07/owl#")
same("labs → ROR (owl:sameAs)", {(URIRef(f"{BASE}lab/{u}"), URIRef(f"https://ror.org/{r}")) for u, r in
     sql('SELECT id_uuid, ror_id FROM cau.lab WHERE ror_id IS NOT NULL')}, set(g.subject_objects(OWL.sameAs)))

for u, en, nat, lang in [r + [""] * (4 - len(r)) for r in sql("SELECT id_uuid, lab_en, coalesce(lab_native, ''), coalesce(lab_native_lang, '') FROM cau.lab")]:
    labels = {(str(o), o.language) for o in g.objects(URIRef(f"{BASE}lab/{u}"), RDFS.label)}
    if labels != {(en, "en")} | ({(nat, lang)} if nat else set()):
        errors.append(f"lab {u}: labels {labels}")
print("ok   lab labels (English + local name with its language) checked against the source")

# Literature (ingest#12): every publication of the database once, as a FaBiO record; finds and analyses cite it
FABIO = Namespace("http://purl.org/spar/fabio/")
DCT = Namespace("http://purl.org/dc/terms/")
pub_by_key = {str(o): s for s, o in g.subject_objects(DCT.identifier) if (s, RDF.type, CRM.E31_Document) in g}
keys = {r[0] for r in sql("SELECT zotero_key FROM cau.literature")}
if set(pub_by_key) != keys:
    errors.append(f"publications: {len(keys - set(pub_by_key))} missing, {len(set(pub_by_key) - keys)} unexpected")
else:
    print(f"ok   publications (FaBiO, one per literature row): {len(keys)}")
for kind, q in (("find", "SELECT x.id_uuid, l.zotero_key FROM cau.find x JOIN cau.literature l USING (literature_id)"),
                ("analysis", "SELECT a.id_uuid, l.zotero_key FROM (SELECT id_uuid, literature_id FROM cau.ca UNION ALL "
                             "SELECT id_uuid, literature_id FROM cau.pb) a JOIN cau.literature l USING (literature_id)")):
    exp = {(URIRef(f"{BASE}{kind}/{u}"), pub_by_key.get(k)) for u, k in sql(q)}
    got = {(a, b) for a, b in g.subject_objects(CRM.P70i_is_documented_in) if f"/{kind}/" in str(a) and str(a).count("/") == 5}
    same(f"{kind} → publication (P70i)", exp, got)
# Chronology systems name their source publication (dcterms:source, owner 2026-11-19)
same("chronology → publication (dcterms:source)",
     {(URIRef(f"{BASE}chronology/{u}"), pub_by_key.get(k)) for u, k in
      sql("SELECT t.id_uuid, l.zotero_key FROM cau.zt_type t JOIN cau.literature l USING (literature_id)")},
     {(a, b) for a, b in g.subject_objects(DCT.source) if "/chronology/" in str(a)})

if errors:
    print("\n".join("FAIL " + e for e in errors))
    sys.exit(1)
print(f"ok   {len(g)} triples")
