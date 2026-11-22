-- SQL views behind the R2RML mapping (mapping/lod-am.r2rml.ttl), issue ingest#14.
-- The owner's rules (docs/decisions.md) live here, so the mapping stays a plain
-- row-to-triples description. IRIs follow knowledge-graph CONVENTIONS.md (ingest#20):
-- https://lod-am.net/id/<kind>/<id_uuid>, helper nodes <record IRI>/<role>.
-- Needs PostgreSQL 16 with PostGIS (geometry as WKT). Safe to run more than once.
DROP SCHEMA IF EXISTS lodam_rdf CASCADE;
CREATE SCHEMA lodam_rdf;
SET search_path = lodam_rdf, cau, public;

-- Helpers -------------------------------------------------------------------
CREATE FUNCTION iri(kind text, u uuid) RETURNS text IMMUTABLE LANGUAGE sql
    AS $$ SELECT 'https://lod-am.net/id/' || kind || '/' || lower(u::text) $$;
-- Trimmed text, NULL when empty.
CREATE FUNCTION clean(t text) RETURNS text IMMUTABLE LANGUAGE sql
    AS $$ SELECT nullif(btrim(t), '') $$;

-- Sites, places, geometry ----------------------------------------------------
-- Label: site_latin @en (official name in Latin script); site_native with its own
-- language tag (separate view, one row per tag). A site without site_latin is a skip.
CREATE VIEW site AS
SELECT iri('site', s.id_uuid)                          AS site_iri,
       iri('site', s.id_uuid) || '/location'           AS place_iri,
       iri('site', s.id_uuid) || '/geometry'           AS geometry_iri,
       clean(s.site_latin)                             AS label_en,
       CASE WHEN si.id_uuid IS NOT NULL THEN iri('type', si.id_uuid) END AS type_iri,
       CASE WHEN r.id_uuid  IS NOT NULL THEN iri('region', r.id_uuid) END AS region_iri,
       replace(ST_AsText(g.geography::geometry), 'POINT(', 'POINT (') AS wkt,
       -- name as reported (knowledge-graph CONVENTIONS "Sites"): an E41_Appellation
       CASE WHEN clean(s.site_as_reported) IS NOT NULL THEN iri('site', s.id_uuid) || '/name_as_reported' END AS name_iri,
       clean(s.site_as_reported)                       AS as_reported,
       -- location certainty: a type on the place (uncertain / vicinity / area)
       CASE s.site_location_certainty
            WHEN 'uncertain' THEN 'https://lod-am.net/id/location_uncertain'
            WHEN 'vicinity'  THEN 'https://lod-am.net/id/location_vicinity'
            WHEN 'area'      THEN 'https://lod-am.net/id/location_area' END AS certainty_iri
FROM cau.site s
LEFT JOIN cau.context_type si USING (context_type_id)
LEFT JOIN cau.region r USING (region_id)
LEFT JOIN cau.geography g USING (geography_id)
WHERE clean(s.site_latin) IS NOT NULL;

CREATE VIEW site_native_label AS
SELECT iri('site', s.id_uuid) AS site_iri, clean(s.site_native) AS label, s.site_native_lang AS lang
FROM cau.site s
WHERE clean(s.site_latin) IS NOT NULL AND clean(s.site_native) IS NOT NULL;

-- R2RML has only a constant rr:language per term map: scripts/materialize.sh adds
-- one triples map per language present in this view (mapping/native-labels.r2rml.ttl.in).

-- Regions (places the site's place falls within) -------------------------------
CREATE VIEW region AS
SELECT iri('region', r.id_uuid) AS region_iri, clean(r.region_en) AS label_en, clean(r.region_de) AS label_de,
       iri('region', r.id_uuid) || '/geometry' AS geometry_iri,
       ST_AsText(r.geography::geometry) AS wkt   -- polygon around the region's sites (owner, 2026-11-16)
FROM cau.region r;

-- Site and feature types (context_type; applies_to site / feature / both) --------
-- AAT match: skos:closeMatch / skos:broadMatch as recorded in aat_match (ingest#8, knowledge-graph#7).
CREATE VIEW site_type AS
SELECT iri('type', i.id_uuid) AS type_iri,
       clean(i.context_type_en) AS label_en, clean(i.context_type_de) AS label_de,
       CASE WHEN i.aat_id IS NOT NULL THEN 'http://vocab.getty.edu/aat/' || i.aat_id END AS aat_iri,
       i.aat_match
FROM cau.context_type i;

-- Features ---------------------------------------------------------------------------
-- Label: feature_en @en, feature_de @de (normalised, ingest#8). "Unspecified context" features get
-- "<site>, unspecified context, <period>" (owner's proposal in ingest#8). A feature with finds is also a
-- CRMarchaeo A2 (CONVENTIONS); graves are part of their kurgan and of the site (both stated: no inference).
CREATE VIEW feature AS
SELECT iri('feature', f.id_uuid) AS feature_iri,
       iri('site', s.id_uuid)    AS site_iri,
       CASE WHEN f.context_type_id = 5
            THEN s.site_latin || ', unspecified context' || coalesce(', ' || clean(z.period_en), '')
            ELSE clean(f.feature_en) END AS label_en,
       CASE WHEN f.context_type_id = 5
            THEN s.site_latin || ', unbestimmter Kontext' || coalesce(', ' || clean(z.period_de), '')
            ELSE clean(f.feature_de) END AS label_de,
       iri('type', i.id_uuid)    AS type_iri,
       CASE WHEN p.id_uuid IS NOT NULL THEN iri('feature', p.id_uuid) END AS parent_iri,
       EXISTS (SELECT 1 FROM cau.find x WHERE x.site_id = f.site_id AND x.feature_id = f.feature_id) AS has_finds,
       clean(f.remarks)          AS note,
       CASE WHEN z.id_uuid IS NOT NULL THEN iri('period', z.id_uuid) END AS period_iri
FROM cau.feature f
JOIN cau.site s USING (site_id)
JOIN cau.context_type i ON i.context_type_id = f.context_type_id
LEFT JOIN cau.feature p ON p.site_id = f.site_id AND p.feature_id = f.part_of_feature_id
LEFT JOIN cau.period z ON z.period_id = f.period_id
WHERE clean(s.site_latin) IS NOT NULL;

-- Dating of sites without a feature for their finds (site_period, ingest#8) -------------------
CREATE VIEW site_period AS
SELECT iri('site', s.id_uuid) AS site_iri,
       iri('period', z.id_uuid) AS period_iri
FROM cau.site_period sp
JOIN cau.site s USING (site_id)
JOIN cau.period z USING (period_id)
WHERE clean(s.site_latin) IS NOT NULL;

-- Phases (period), cultures, chronology systems (chronology_system): local E4_Period until PeriodO (ingest#7, ingest#17) --
-- A culture consists of its phases; a phase is in its chronology system (one PeriodO collection
-- per source). period.min / period.max are conventional years BC (min >= max): begin "-<min>", end "-<max>".
CREATE VIEW period AS
SELECT iri('period', z.id_uuid) AS period_iri,
       iri('period', z.id_uuid) || '/time_span' AS time_span_iri,
       clean(z.period_en) AS label_en, clean(z.period_de) AS label_de,
       '-' || trim_scale(z.min)::text AS begin_year,
       '-' || trim_scale(z.max)::text   AS end_year,
       iri('culture', c.id_uuid) AS culture_iri,
       iri('chronology', t.id_uuid) AS chronology_iri
FROM cau.period z
JOIN cau.culture c ON c.culture_id = z.culture_id
JOIN cau.chronology_system t ON t.chronology_system_id = z.chronology_system_id
WHERE z.min IS NOT NULL AND z.max IS NOT NULL;

CREATE VIEW culture AS
SELECT iri('culture', c.id_uuid) AS culture_iri,
       clean(c.culture_en) AS label_en, clean(c.culture_de) AS label_de
FROM cau.culture c;

-- A chronology system names the publication it comes from (dcterms:source; owner 2026-11-19,
-- knowledge-graph CONVENTIONS "Local periods": as a PeriodO collection's source).
CREATE VIEW chronology AS
SELECT iri('chronology', t.id_uuid) AS chronology_iri,
       clean(t.chronology_system_en) AS label_en, clean(t.chronology_system_de) AS label_de,
       pub.publication_iri
FROM cau.chronology_system t
LEFT JOIN cau.literature lit ON lit.literature_id = t.literature_id
LEFT JOIN lodam_lit.publication pub ON pub.zotero_key = lit.zotero_key;

-- Typology (ingest#10): classes (find_class), groups (type_group), types; local SKOS concepts ---
-- skos:broader: type -> group or class; group -> broader group or class; classes are top concepts.
CREATE VIEW typology AS
SELECT iri('type', fc.id_uuid) AS concept_iri, clean(fc.find_class_en) AS label_en, clean(fc.find_class_de) AS label_de,
       NULL::text AS broader_iri, true AS is_top,
       CASE WHEN fc.aat_id IS NOT NULL THEN 'http://vocab.getty.edu/aat/' || fc.aat_id END AS aat_iri, fc.aat_match
FROM cau.find_class fc
UNION ALL
SELECT iri('type', g.id_uuid), clean(g.type_group_en), clean(g.type_group_de),
       coalesce(iri('type', b.id_uuid), iri('type', fc.id_uuid)), false,
       CASE WHEN g.aat_id IS NOT NULL THEN 'http://vocab.getty.edu/aat/' || g.aat_id END, g.aat_match
FROM cau.type_group g
LEFT JOIN cau.type_group b ON b.type_group_id = g.broader_type_group_id
LEFT JOIN cau.find_class fc ON fc.find_class_id = g.find_class_id
UNION ALL
SELECT iri('type', t.id_uuid), clean(t.type_en), clean(t.type_de),
       coalesce(iri('type', g.id_uuid), iri('type', fc.id_uuid)), false,
       CASE WHEN t.aat_id IS NOT NULL THEN 'http://vocab.getty.edu/aat/' || t.aat_id END, t.aat_match
FROM cau.type t
LEFT JOIN cau.type_group g ON g.type_group_id = t.type_group_id
JOIN cau.find_class fc ON fc.find_class_id = t.find_class_id;

-- Finds (ingest#10, ingest#13, ingest#19, knowledge-graph#28) ---------------------------------------------
-- Label: "<Type> (no. <find_no_reported>, <site>)", or "<Type> (<site>)" without an old identifier.
-- find_no_reported is an old identifier, only where present (owner, ingest#34). drawing_no_reported = drawing
-- number in the publication, dropped when it repeats find_no_reported or find_id (ingest#13). AAT only via the type's match.
-- Context: the feature (AP21i) or, without a feature, the site's place (P53, knowledge-graph#19).
CREATE VIEW find AS
SELECT iri('find', x.id_uuid) AS find_iri,
       upper(left(t.type_en, 1)) || substr(t.type_en, 2) || ' (' || coalesce('no. ' || n.old || ', ', '') || s.site_latin || ')' AS label_en,
       upper(left(t.type_de, 1)) || substr(t.type_de, 2) || ' (' || coalesce('Nr. ' || n.old || ', ', '') || s.site_latin || ')' AS label_de,
       iri('type', t.id_uuid) AS type_iri,
       CASE WHEN f.id_uuid IS NOT NULL THEN iri('feature', f.id_uuid) END AS feature_iri,
       CASE WHEN x.feature_id IS NULL THEN iri('site', s.id_uuid) || '/location' END AS place_iri,
       clean(x.remarks) AS note,
       CASE WHEN n.old IS NOT NULL THEN iri('find', x.id_uuid) || '/old_identifier' END AS old_iri,
       n.old,
       CASE WHEN n.drawing IS NOT NULL THEN iri('find', x.id_uuid) || '/drawing_number' END AS drawing_iri,
       n.drawing,
       -- material: base metal of the object (chemical_analysis.material_id, ingest#13); 1 = cu -> AAT <copper and copper alloy>
       CASE WHEN EXISTS (SELECT 1 FROM cau.chemical_analysis c WHERE c.site_id = x.site_id AND c.find_id = x.find_id AND c.material_id = 1)
            THEN 'http://vocab.getty.edu/aat/300241441' END AS material_iri,
       pub.publication_iri
FROM cau.find x
LEFT JOIN cau.literature lit ON lit.literature_id = x.literature_id
LEFT JOIN lodam_lit.publication pub ON pub.zotero_key = lit.zotero_key
JOIN cau.site s USING (site_id)
JOIN cau.type t USING (type_id)
LEFT JOIN cau.feature f ON f.site_id = x.site_id AND f.feature_id = x.feature_id
CROSS JOIN LATERAL (SELECT clean(x.find_no_reported) AS old,
       CASE WHEN clean(x.drawing_no_reported) IS NOT NULL AND clean(x.drawing_no_reported) <> coalesce(clean(x.find_no_reported), '') AND clean(x.drawing_no_reported) <> x.find_id::text
            THEN clean(x.drawing_no_reported) END AS drawing) n
WHERE clean(s.site_latin) IS NOT NULL;

-- Labs (ingest#5) with their ROR id (CONVENTIONS "Analytics": E74_Group, owl:sameAs ROR) ----------------------------
CREATE VIEW lab AS
SELECT iri('lab', l.id_uuid) AS lab_iri, clean(l.lab_en) AS label_en,
       clean(l.lab_native) AS label_native, l.lab_native_lang AS native_lang,   -- from ROR (owner, 2026-11-16)
       clean(l.ror_id) AS ror_id,                                        -- owner, dump of 2026-11-16
       CASE WHEN clean(l.ror_id) IS NOT NULL THEN 'https://ror.org/' || clean(l.ror_id) END AS ror_iri
FROM cau.lab l;

-- Object parts (part_id 1 blade, 2 handle, 3 rivet; 0 = the whole object, ingest#5) ------------------
CREATE VIEW part_type AS
SELECT iri('type', p.id_uuid) AS type_iri, clean(p.part_en) AS label_en, clean(p.part_de) AS label_de
FROM cau.part p WHERE p.part_id <> 0;

CREATE VIEW find_part AS
SELECT DISTINCT fv.find_iri, fv.find_iri || '/' || lower(replace(p.part_en, ' ', '_')) AS part_iri,
       fv.label_en || ', ' || p.part_en AS label_en, fv.label_de || ', ' || p.part_de AS label_de,
       iri('type', p.id_uuid) AS type_iri
FROM (SELECT site_id, find_id, part_id FROM cau.chemical_analysis UNION SELECT site_id, find_id, part_id FROM cau.lead_isotope_analysis) a
JOIN cau.part p USING (part_id)
JOIN cau.find x ON x.site_id = a.site_id AND x.find_id = a.find_id
JOIN lodam_rdf.find fv ON fv.find_iri = iri('find', x.id_uuid)
WHERE a.part_id <> 0;

-- Analyses: one sampling, one sample and one analysis per chemical_analysis / lead_isotope_analysis row (repeat analyses are separate
-- samples, ingest#5). Method mostly unknown for ca (interim: AFO assay); pb: mass spectrometry (ingest#5).
-- Identifier: analysis_no_reported (original lab number) or the id (ingest#13). remarks dropped (ingest#13).
CREATE VIEW analysis AS
SELECT iri('analysis', a.id_uuid) AS analysis_iri,
       iri('analysis', a.id_uuid) || '/sampling' AS sampling_iri,
       iri('analysis', a.id_uuid) || '/sample' AS sample_iri,
       CASE WHEN a.part_id = 0 THEN fv.find_iri ELSE fv.find_iri || '/' || lower(replace(p.part_en, ' ', '_')) END AS sampled_iri,
       a.kind,
       CASE a.kind WHEN 'ca' THEN 'http://purl.allotrope.org/ontologies/process#AFP_0002680'      -- assay
                   ELSE 'http://purl.allotrope.org/ontologies/process#AFP_0001427' END AS method_iri, -- mass spectrometry
       coalesce(clean(a.ref), a.id::text) AS identifier,
       CASE a.kind WHEN 'ca' THEN 'Chemical analysis ' ELSE 'Lead isotope analysis ' END || coalesce(clean(a.ref), a.id::text) || ' of ' || fv.label_en AS label_en,
       CASE a.kind WHEN 'ca' THEN 'Chemische Analyse ' ELSE 'Bleiisotopenanalyse ' END || coalesce(clean(a.ref), a.id::text) || ' von ' || fv.label_de AS label_de,
       'Sample from ' || fv.label_en || CASE WHEN a.part_id = 0 THEN '' ELSE ', ' || p.part_en END
           || ' (' || coalesce(clean(a.ref), a.id::text) || ')' AS sample_label_en,
       'Probe von ' || fv.label_de || CASE WHEN a.part_id = 0 THEN '' ELSE ', ' || p.part_de END
           || ' (' || coalesce(clean(a.ref), a.id::text) || ')' AS sample_label_de,
       CASE WHEN l.id_uuid IS NOT NULL THEN iri('lab', l.id_uuid) END AS lab_iri,
       pub.publication_iri
FROM (SELECT 'ca' AS kind, chemical_analysis_id AS id, site_id, find_id, part_id, lab_id, analysis_no_reported AS ref, literature_id, id_uuid FROM cau.chemical_analysis
      UNION ALL SELECT 'pb', lead_isotope_analysis_id, site_id, find_id, part_id, lab_id, analysis_no_reported, literature_id, id_uuid FROM cau.lead_isotope_analysis) a
LEFT JOIN cau.literature lit ON lit.literature_id = a.literature_id
LEFT JOIN lodam_lit.publication pub ON pub.zotero_key = lit.zotero_key
JOIN cau.part p USING (part_id)
JOIN cau.find x ON x.site_id = a.site_id AND x.find_id = a.find_id
JOIN lodam_rdf.find fv ON fv.find_iri = iri('find', x.id_uuid)
LEFT JOIN cau.lab l USING (lab_id);

-- Element measurements (ingest#4): values as reported (incl. 0); NULL = not detected, unless the element
-- is NULL in every analysis of the publication (= not analysed: nothing); all Cu of copper-base
-- objects (material_id 1) dropped. wt % = mass fraction. Elements: ChEBI ids from knowledge-graph tools/chebi.tsv.
CREATE VIEW measurement AS
SELECT iri('analysis', c.id_uuid) AS analysis_iri,
       iri('analysis', c.id_uuid) || '/' || e.el AS measurement_iri,
       e.chebi AS element_iri,
       e.v::text AS value,
       (e.v IS NULL) AS not_detected
FROM cau.chemical_analysis c
CROSS JOIN LATERAL (VALUES
    ('cu', 'http://purl.obolibrary.org/obo/CHEBI_28694', c.cu), ('sn', 'http://purl.obolibrary.org/obo/CHEBI_27007', c.sn),
    ('pb', 'http://purl.obolibrary.org/obo/CHEBI_25016', c.pb), ('zn', 'http://purl.obolibrary.org/obo/CHEBI_27363', c.zn),
    ('bi', 'http://purl.obolibrary.org/obo/CHEBI_33301', c.bi), ('ag', 'http://purl.obolibrary.org/obo/CHEBI_30512', c.ag),
    ('sb', 'http://purl.obolibrary.org/obo/CHEBI_30513', c.sb), ('as', 'http://purl.obolibrary.org/obo/CHEBI_27563', c."as"),
    ('fe', 'http://purl.obolibrary.org/obo/CHEBI_18248', c.fe), ('ni', 'http://purl.obolibrary.org/obo/CHEBI_28112', c.ni),
    ('co', 'http://purl.obolibrary.org/obo/CHEBI_27638', c.co), ('mn', 'http://purl.obolibrary.org/obo/CHEBI_18291', c.mn),
    ('au', 'http://purl.obolibrary.org/obo/CHEBI_29287', c.au), ('p',  'http://purl.obolibrary.org/obo/CHEBI_28659', c.p),
    ('te', 'http://purl.obolibrary.org/obo/CHEBI_30452', c.te), ('se', 'http://purl.obolibrary.org/obo/CHEBI_27568', c.se),
    ('s',  'http://purl.obolibrary.org/obo/CHEBI_26833', c.s)) AS e(el, chebi, v)
WHERE NOT (e.el = 'cu' AND c.material_id = 1)
  AND NOT (e.v IS NULL AND NOT EXISTS (
        SELECT 1 FROM cau.chemical_analysis c2 CROSS JOIN LATERAL (VALUES
            ('cu', c2.cu), ('sn', c2.sn), ('pb', c2.pb), ('zn', c2.zn), ('bi', c2.bi), ('ag', c2.ag), ('sb', c2.sb),
            ('as', c2."as"), ('fe', c2.fe), ('ni', c2.ni), ('co', c2.co), ('mn', c2.mn), ('au', c2.au), ('p', c2.p),
            ('te', c2.te), ('se', c2.se), ('s', c2.s)) AS e2(el, v)
        WHERE c2.literature_id = c.literature_id AND e2.el = e.el AND e2.v IS NOT NULL));

-- Lead isotope ratios (knowledge-graph#14): only ratios reported; nuclides as Wikidata items ------
CREATE VIEW isotope_ratio AS
SELECT iri('analysis', b.id_uuid) AS analysis_iri,
       iri('analysis', b.id_uuid) || '/' || r.name AS ratio_iri,
       'http://www.wikidata.org/entity/' || r.num AS numerator_iri,
       'http://www.wikidata.org/entity/' || r.den AS denominator_iri,
       r.v::text AS value
FROM cau.lead_isotope_analysis b
CROSS JOIN LATERAL (VALUES
    ('pb206_pb204', 'Q18883438', 'Q18883429', b.pb206_204), ('pb207_pb204', 'Q18883443', 'Q18883429', b.pb207_204),
    ('pb208_pb204', 'Q16670466', 'Q18883429', b.pb208_204), ('pb207_pb206', 'Q18883443', 'Q18883438', b.pb207_206),
    ('pb208_pb206', 'Q16670466', 'Q18883438', b.pb208_206), ('pb204_pb206', 'Q18883429', 'Q18883438', b.pb204_206)) AS r(name, num, den, v)
WHERE r.v IS NOT NULL;

-- Skip report: every source row that is not converted, with the reason ---------------
CREATE VIEW skip AS
SELECT 'site' AS source_table, s.site_id::text AS source_key, 'no site_latin (no label)' AS reason
FROM cau.site s WHERE clean(s.site_latin) IS NULL
UNION ALL
SELECT 'site', s.site_id::text, 'no geometry'
FROM cau.site s LEFT JOIN cau.geography g USING (geography_id)
WHERE clean(s.site_latin) IS NOT NULL AND g.geography IS NULL
UNION ALL
SELECT 'period', z.period_id::text, 'no min/max (no time-span)'
FROM cau.period z WHERE z.min IS NULL OR z.max IS NULL;
