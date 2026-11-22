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
       replace(ST_AsText(s.geometry::geometry), 'POINT(', 'POINT (') AS wkt,   -- site.geometry (planning#27 round 5)
       -- name as reported (knowledge-graph CONVENTIONS "Sites"): an E41_Appellation
       CASE WHEN clean(s.site_as_reported) IS NOT NULL THEN iri('site', s.id_uuid) || '/name_as_reported' END AS name_iri,
       clean(s.site_as_reported)                       AS as_reported,
       -- location certainty: a type on the place; codes from cau.location_certainty (= the vocabulary terms)
       CASE WHEN s.site_location_certainty IS NOT NULL THEN 'https://lod-am.net/id/location_' || s.site_location_certainty END AS certainty_iri
FROM cau.site s
LEFT JOIN cau.context_type si USING (context_type_id)
LEFT JOIN cau.region r USING (region_id)
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
       CASE WHEN i.code = 'unspecified_context'
            THEN s.site_latin || ', unspecified context' || coalesce(', ' || clean(z.period_en), '')
            ELSE clean(f.feature_en) END AS label_en,
       CASE WHEN i.code = 'unspecified_context'
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
       -- material: base metal of the object (find.material_id, its AAT id in cau.material; ingest#13, planning#27)
       CASE WHEN m.aat_id IS NOT NULL THEN 'http://vocab.getty.edu/aat/' || m.aat_id END AS material_iri,
       pub.publication_iri
FROM cau.find x
LEFT JOIN cau.literature lit ON lit.literature_id = x.literature_id
LEFT JOIN lodam_lit.publication pub ON pub.zotero_key = lit.zotero_key
JOIN cau.site s USING (site_id)
JOIN cau.type t USING (type_id)
LEFT JOIN cau.feature f ON f.site_id = x.site_id AND f.feature_id = x.feature_id
LEFT JOIN cau.material m ON m.material_id = x.material_id
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

-- Object parts (blade, handle, rivet; code whole_object = no sub-part, ingest#5) ------------------
CREATE VIEW part_type AS
SELECT iri('type', p.id_uuid) AS type_iri, clean(p.part_en) AS label_en, clean(p.part_de) AS label_de
FROM cau.part p WHERE p.code IS DISTINCT FROM 'whole_object';

CREATE VIEW find_part AS
SELECT DISTINCT fv.find_iri, fv.find_iri || '/' || lower(replace(p.part_en, ' ', '_')) AS part_iri,
       fv.label_en || ', ' || p.part_en AS label_en, fv.label_de || ', ' || p.part_de AS label_de,
       iri('type', p.id_uuid) AS type_iri
FROM (SELECT site_id, find_id, part_id FROM cau.chemical_analysis UNION SELECT site_id, find_id, part_id FROM cau.lead_isotope_analysis) a
JOIN cau.part p USING (part_id)
JOIN cau.find x ON x.site_id = a.site_id AND x.find_id = a.find_id
JOIN lodam_rdf.find fv ON fv.find_iri = iri('find', x.id_uuid)
WHERE p.code IS DISTINCT FROM 'whole_object';

-- Analyses: one sampling, one sample and one analysis per chemical_analysis / lead_isotope_analysis row (repeat analyses are separate
-- samples, ingest#5). Method from cau.analysis_method (AFO class; chemical: assay, method mostly unknown;
-- lead isotopes: mass spectrometry, ingest#5). Identifier: analysis_no_reported (original lab number) or
-- the id (ingest#13). Remarks are a public note on the analysis (owner, 2026-11-22; planning#27).
CREATE VIEW analysis AS
SELECT iri('analysis', a.id_uuid) AS analysis_iri,
       iri('analysis', a.id_uuid) || '/sampling' AS sampling_iri,
       iri('analysis', a.id_uuid) || '/sample' AS sample_iri,
       CASE WHEN p.code = 'whole_object' THEN fv.find_iri ELSE fv.find_iri || '/' || lower(replace(p.part_en, ' ', '_')) END AS sampled_iri,
       a.kind,
       'http://purl.allotrope.org/ontologies/process#' || am.afo_id AS method_iri,
       coalesce(clean(a.ref), a.id::text) AS identifier,
       CASE a.kind WHEN 'ca' THEN 'Chemical analysis ' ELSE 'Lead isotope analysis ' END || coalesce(clean(a.ref), a.id::text) || ' of ' || fv.label_en AS label_en,
       CASE a.kind WHEN 'ca' THEN 'Chemische Analyse ' ELSE 'Bleiisotopenanalyse ' END || coalesce(clean(a.ref), a.id::text) || ' von ' || fv.label_de AS label_de,
       'Sample from ' || fv.label_en || CASE WHEN p.code = 'whole_object' THEN '' ELSE ', ' || p.part_en END
           || ' (' || coalesce(clean(a.ref), a.id::text) || ')' AS sample_label_en,
       'Probe von ' || fv.label_de || CASE WHEN p.code = 'whole_object' THEN '' ELSE ', ' || p.part_de END
           || ' (' || coalesce(clean(a.ref), a.id::text) || ')' AS sample_label_de,
       CASE WHEN l.id_uuid IS NOT NULL THEN iri('lab', l.id_uuid) END AS lab_iri,
       clean(a.remarks) AS note,
       pub.publication_iri
FROM (SELECT 'ca' AS kind, chemical_analysis_id AS id, site_id, find_id, part_id, lab_id, analysis_no_reported AS ref, literature_id, id_uuid,
             analysis_method_id, remarks FROM cau.chemical_analysis
      UNION ALL SELECT 'pb', lead_isotope_analysis_id, site_id, find_id, part_id, lab_id, analysis_no_reported, literature_id, id_uuid,
             analysis_method_id, remarks FROM cau.lead_isotope_analysis) a
JOIN cau.analysis_method am USING (analysis_method_id)
LEFT JOIN cau.literature lit ON lit.literature_id = a.literature_id
LEFT JOIN lodam_lit.publication pub ON pub.zotero_key = lit.zotero_key
JOIN cau.part p USING (part_id)
JOIN cau.find x ON x.site_id = a.site_id AND x.find_id = a.find_id
JOIN lodam_rdf.find fv ON fv.find_iri = iri('find', x.id_uuid)
LEFT JOIN cau.lab l USING (lab_id);

-- Element measurements (ingest#4): values as reported (incl. 0). An element the publication analysed
-- (cau.analysed_element) with a NULL value = not detected; an element not analysed: nothing (owner,
-- planning#27 round 3). All Cu of copper-base objects (find material code copper_base) dropped.
-- wt % = mass fraction. ChEBI ids from cau.element (knowledge-graph tools/chebi.tsv).
CREATE VIEW measurement AS
SELECT iri('analysis', c.id_uuid) AS analysis_iri,
       iri('analysis', c.id_uuid) || '/' || e.element_code AS measurement_iri,
       'http://purl.obolibrary.org/obo/' || e.chebi_id AS element_iri,
       v.v::text AS value,
       (v.v IS NULL) AS not_detected
FROM cau.chemical_analysis c
JOIN cau.find x ON x.site_id = c.site_id AND x.find_id = c.find_id
LEFT JOIN cau.material m ON m.material_id = x.material_id
CROSS JOIN LATERAL (VALUES   -- the element columns (one per element, as entered)
    ('cu', c.cu), ('sn', c.sn), ('pb', c.pb), ('zn', c.zn), ('bi', c.bi), ('ag', c.ag), ('sb', c.sb), ('as', c."as"),
    ('fe', c.fe), ('ni', c.ni), ('co', c.co), ('mn', c.mn), ('au', c.au), ('p', c.p), ('te', c.te), ('se', c.se), ('s', c.s)) AS v(el, v)
JOIN cau.element e ON e.element_code = v.el
JOIN cau.analysed_element ae ON ae.literature_id = c.literature_id AND ae.element_code = v.el
WHERE NOT (v.el = 'cu' AND m.code IS NOT DISTINCT FROM 'copper_base');

-- Lead isotope ratios (knowledge-graph#14): only ratios reported; nuclides (Wikidata) from cau.isotope_ratio ------
CREATE VIEW isotope_ratio AS
SELECT iri('analysis', b.id_uuid) AS analysis_iri,
       iri('analysis', b.id_uuid) || '/' || r.ratio_code AS ratio_iri,
       'http://www.wikidata.org/entity/' || r.numerator_wikidata AS numerator_iri,
       'http://www.wikidata.org/entity/' || r.denominator_wikidata AS denominator_iri,
       v.v::text AS value
FROM cau.lead_isotope_analysis b
CROSS JOIN LATERAL (VALUES   -- the ratio columns, as entered
    ('pb206_204', b.pb206_204), ('pb207_204', b.pb207_204), ('pb208_204', b.pb208_204),
    ('pb207_206', b.pb207_206), ('pb208_206', b.pb208_206), ('pb204_206', b.pb204_206)) AS v(col, v)
JOIN cau.isotope_ratio r ON r.column_name = v.col
WHERE v.v IS NOT NULL;

-- Skip report: every source row that is not converted, with the reason ---------------
CREATE VIEW skip AS
SELECT 'site' AS source_table, s.site_id::text AS source_key, 'no site_latin (no label)' AS reason
FROM cau.site s WHERE clean(s.site_latin) IS NULL
UNION ALL
SELECT 'site', s.site_id::text, 'no geometry'
FROM cau.site s
WHERE clean(s.site_latin) IS NOT NULL AND s.geometry IS NULL
UNION ALL
SELECT 'period', z.period_id::text, 'no min/max (no time-span)'
FROM cau.period z WHERE z.min IS NULL OR z.max IS NULL;
