--
-- PostgreSQL database dump
--


-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: cau; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA cau;


--
-- Name: check_analysed_element(); Type: FUNCTION; Schema: cau; Owner: -
--

CREATE FUNCTION cau.check_analysed_element() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE missing text;
BEGIN
  IF TG_TABLE_NAME = 'chemical_analysis' THEN
    SELECT string_agg(e.element_code, ', ' ORDER BY e.sort_order) INTO missing FROM cau.element e
    WHERE (to_jsonb(NEW) ->> e.element_code) IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM cau.analysed_element a WHERE a.literature_id = NEW.literature_id AND a.element_code = e.element_code);
    IF missing IS NOT NULL THEN
      RAISE EXCEPTION 'chemical_analysis %/%@%: % reported, but not in analysed_element for literature % (add the elements the publication analysed first)',
        NEW.chemical_analysis_id, NEW.part_id, NEW.site_id, missing, NEW.literature_id;
    END IF;
  ELSE                                       -- an element removed from a publication's list while values exist
    IF EXISTS (SELECT 1 FROM cau.chemical_analysis c WHERE c.literature_id = OLD.literature_id AND (to_jsonb(c) ->> OLD.element_code) IS NOT NULL) THEN
      RAISE EXCEPTION 'analysed_element %/%: analyses of this publication report %; remove the values first',
        OLD.literature_id, OLD.element_code, OLD.element_code;
    END IF;
  END IF;
  RETURN NULL;
END $$;


--
-- Name: check_context_type(); Type: FUNCTION; Schema: cau; Owner: -
--

CREATE FUNCTION cau.check_context_type() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_TABLE_NAME = 'context_type' THEN
    IF EXISTS (SELECT 1 FROM cau.site s WHERE s.context_type_id = NEW.context_type_id AND NEW.applies_to NOT IN ('site', 'both'))
       OR EXISTS (SELECT 1 FROM cau.feature f WHERE f.context_type_id = NEW.context_type_id AND NEW.applies_to NOT IN ('feature', 'both')) THEN
      RAISE EXCEPTION 'context_type % is used by a % but applies_to is %', NEW.context_type_id,
        CASE WHEN NEW.applies_to = 'feature' THEN 'site' ELSE 'feature' END, NEW.applies_to;
    END IF;
  ELSIF NEW.context_type_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cau.context_type t WHERE t.context_type_id = NEW.context_type_id
        AND t.applies_to IN (CASE TG_TABLE_NAME WHEN 'site' THEN 'site' ELSE 'feature' END, 'both')) THEN
    RAISE EXCEPTION '% %: context_type % is not a % type (context_type.applies_to)', TG_TABLE_NAME,
      -- to_jsonb: site rows have no feature_id, and PL/pgSQL would reject NEW.feature_id for them
      CASE TG_TABLE_NAME WHEN 'site' THEN NEW.site_id::text ELSE (to_jsonb(NEW) ->> 'feature_id') || '@' || NEW.site_id END,
      NEW.context_type_id, TG_TABLE_NAME;
  END IF;
  RETURN NULL;
END $$;


--
-- Name: check_find_dating(); Type: FUNCTION; Schema: cau; Owner: -
--

CREATE FUNCTION cau.check_find_dating() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE r record;
BEGIN
  IF TG_TABLE_NAME = 'find' THEN
    IF NEW.feature_id IS NULL AND NOT EXISTS (SELECT 1 FROM cau.site_period p WHERE p.site_id = NEW.site_id) THEN
      RAISE EXCEPTION 'find %@%: no feature, and site % has no site_period (a find is dated by its feature or its site)',
        NEW.find_id, NEW.site_id, NEW.site_id;
    END IF;
    IF NEW.feature_id IS NOT NULL AND EXISTS (SELECT 1 FROM cau.feature f WHERE f.site_id = NEW.site_id
          AND f.feature_id = NEW.feature_id AND f.period_id IS NULL) THEN
      RAISE EXCEPTION 'find %@%: feature %@% has no period (a feature with finds needs one)',
        NEW.find_id, NEW.site_id, NEW.feature_id, NEW.site_id;
    END IF;
  ELSIF TG_TABLE_NAME = 'feature' THEN       -- period removed from a feature that has finds
    IF NEW.period_id IS NULL AND EXISTS (SELECT 1 FROM cau.find x WHERE x.site_id = NEW.site_id AND x.feature_id = NEW.feature_id) THEN
      RAISE EXCEPTION 'feature %@%: has finds, so it needs a period', NEW.feature_id, NEW.site_id;
    END IF;
  ELSE                                       -- site_period deleted or moved: the site's finds without a feature
    SELECT x.find_id, x.site_id INTO r FROM cau.find x WHERE x.site_id = OLD.site_id AND x.feature_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM cau.site_period p WHERE p.site_id = OLD.site_id) LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'site_period %: site % has finds without a feature (e.g. find %@%), so it needs a site_period',
        OLD.site_period_id, OLD.site_id, r.find_id, r.site_id;
    END IF;
  END IF;
  RETURN NULL;
END $$;


--
-- Name: check_part_of_feature(); Type: FUNCTION; Schema: cau; Owner: -
--

CREATE FUNCTION cau.check_part_of_feature() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE kurgan integer := (SELECT context_type_id FROM cau.context_type WHERE code = 'kurgan');
BEGIN
  IF NEW.part_of_feature_id IS NOT NULL AND (NEW.part_of_feature_id = NEW.feature_id OR NOT EXISTS (
        SELECT 1 FROM cau.feature p WHERE p.site_id = NEW.site_id AND p.feature_id = NEW.part_of_feature_id
          AND p.context_type_id = kurgan AND p.part_of_feature_id IS NULL)) THEN
    RAISE EXCEPTION 'feature %@%: part_of_feature_id % is not a kurgan of the same site (context_type code kurgan, not part of another feature)',
      NEW.feature_id, NEW.site_id, NEW.part_of_feature_id;
  END IF;
  IF EXISTS (SELECT 1 FROM cau.feature c WHERE c.site_id = NEW.site_id AND c.part_of_feature_id = NEW.feature_id)
     AND (NEW.context_type_id IS DISTINCT FROM kurgan OR NEW.part_of_feature_id IS NOT NULL) THEN
    RAISE EXCEPTION 'feature %@%: other features are part of it, so it must stay a kurgan (context_type code kurgan) of its own',
      NEW.feature_id, NEW.site_id;
  END IF;
  RETURN NULL;
END $$;


--
-- Name: check_site_in_region(); Type: FUNCTION; Schema: cau; Owner: -
--

CREATE FUNCTION cau.check_site_in_region() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE s record;
BEGIN
  IF TG_TABLE_NAME = 'site' THEN
    IF NOT EXISTS (SELECT 1 FROM cau.region r WHERE r.region_id = NEW.region_id AND public.ST_Covers(r.geography, NEW.geometry)) THEN
      RAISE EXCEPTION 'site % (%): its point % is outside the polygon of region % (swapped longitude/latitude? or the region must grow)',
        NEW.site_id, NEW.site_latin, public.ST_AsText(NEW.geometry), NEW.region_id;
    END IF;
  ELSE                                                -- a region polygon changed: all its sites still inside
    SELECT site_id, site_latin INTO s FROM cau.site x WHERE x.region_id = NEW.region_id AND NOT public.ST_Covers(NEW.geography, x.geometry) LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'region %: site % (%) would be outside the new polygon', NEW.region_id, s.site_id, s.site_latin;
    END IF;
  END IF;
  RETURN NULL;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: analysed_element; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.analysed_element (
    literature_id integer NOT NULL,
    element_code text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL
);


--
-- Name: analysis_method; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.analysis_method (
    analysis_method_id integer NOT NULL,
    code text NOT NULL,
    label_en text NOT NULL,
    afo_id text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT analysis_method_afo_id_check CHECK ((afo_id ~ '^AFP_[0-9]{7}$'::text)),
    CONSTRAINT analysis_method_code_check CHECK ((code ~ '^[a-z][a-z0-9_]*$'::text)),
    CONSTRAINT analysis_method_label_en_check CHECK ((btrim(label_en) <> ''::text))
);


--
-- Name: chemical_analysis; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.chemical_analysis (
    chemical_analysis_id integer NOT NULL,
    part_id integer DEFAULT 0 NOT NULL,
    site_id integer NOT NULL,
    find_id integer NOT NULL,
    lab_id integer,
    literature_id integer NOT NULL,
    analysis_no_reported text,
    cu numeric,
    sn numeric,
    pb numeric,
    zn numeric,
    bi numeric,
    ag numeric,
    sb numeric,
    "as" numeric,
    fe numeric,
    ni numeric,
    co numeric,
    mn numeric,
    au numeric,
    p numeric,
    te numeric,
    se numeric,
    s numeric,
    remarks text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    analysis_method_id integer DEFAULT 1 NOT NULL
);


--
-- Name: chronology_system; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.chronology_system (
    chronology_system_id integer NOT NULL,
    chronology_system_de text NOT NULL,
    literature_id integer,
    chronology_system_en text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT chronology_system_chronology_system_de_check CHECK ((btrim(chronology_system_de) <> ''::text)),
    CONSTRAINT chronology_system_chronology_system_en_check CHECK ((btrim(chronology_system_en) <> ''::text))
);


--
-- Name: context_type; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.context_type (
    context_type_id integer NOT NULL,
    context_type_de text,
    context_type_en text,
    context_type_remarks text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    applies_to text DEFAULT 'site'::text NOT NULL,
    aat_id text,
    aat_match text,
    code text,
    CONSTRAINT context_type_aat_id_check CHECK ((aat_id ~ '^3[0-9]{8}$'::text)),
    CONSTRAINT context_type_aat_match_check CHECK ((aat_match = ANY (ARRAY['exactMatch'::text, 'closeMatch'::text, 'broadMatch'::text, 'narrowMatch'::text, 'relatedMatch'::text]))),
    CONSTRAINT context_type_applies_to_check CHECK ((applies_to = ANY (ARRAY['site'::text, 'feature'::text, 'both'::text]))),
    CONSTRAINT context_type_code_check CHECK ((code ~ '^[a-z][a-z0-9_]*$'::text))
);


--
-- Name: culture; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.culture (
    culture_id integer NOT NULL,
    culture_en text NOT NULL,
    culture_de text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT culture_culture_de_check CHECK ((btrim(culture_de) <> ''::text)),
    CONSTRAINT culture_culture_en_check CHECK ((btrim(culture_en) <> ''::text))
);


--
-- Name: element; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.element (
    element_code text NOT NULL,
    symbol text NOT NULL,
    chebi_id text NOT NULL,
    sort_order integer NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT element_chebi_id_check CHECK ((chebi_id ~ '^CHEBI_[0-9]+$'::text)),
    CONSTRAINT element_element_code_check CHECK ((element_code ~ '^[a-z]{1,2}$'::text))
);


--
-- Name: feature; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.feature (
    feature_id integer NOT NULL,
    site_id integer NOT NULL,
    feature_as_recorded text,
    remarks text,
    period_id integer,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    context_type_id integer NOT NULL,
    feature_de text NOT NULL,
    feature_en text NOT NULL,
    part_of_feature_id integer,
    CONSTRAINT feature_feature_de_check CHECK ((btrim(feature_de) <> ''::text)),
    CONSTRAINT feature_feature_en_check CHECK ((btrim(feature_en) <> ''::text))
);


--
-- Name: find; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.find (
    find_id integer NOT NULL,
    site_id integer NOT NULL,
    feature_id integer,
    type_id integer NOT NULL,
    remarks text,
    literature_id integer NOT NULL,
    drawing_no_reported text,
    find_no_reported text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    material_id integer
);


--
-- Name: find_class; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.find_class (
    find_class_id integer NOT NULL,
    find_class_de text,
    find_class_en text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    aat_id text,
    aat_match text,
    code text,
    CONSTRAINT find_class_aat_id_check CHECK ((aat_id ~ '^3[0-9]{8}$'::text)),
    CONSTRAINT find_class_aat_match_check CHECK ((aat_match = ANY (ARRAY['exactMatch'::text, 'closeMatch'::text, 'broadMatch'::text, 'narrowMatch'::text, 'relatedMatch'::text]))),
    CONSTRAINT find_class_code_check CHECK ((code ~ '^[a-z][a-z0-9_]*$'::text))
);


--
-- Name: isotope_ratio; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.isotope_ratio (
    ratio_code text NOT NULL,
    column_name text NOT NULL,
    numerator_wikidata text NOT NULL,
    denominator_wikidata text NOT NULL,
    sort_order integer NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT isotope_ratio_denominator_wikidata_check CHECK ((denominator_wikidata ~ '^Q[0-9]+$'::text)),
    CONSTRAINT isotope_ratio_numerator_wikidata_check CHECK ((numerator_wikidata ~ '^Q[0-9]+$'::text)),
    CONSTRAINT isotope_ratio_ratio_code_check CHECK ((ratio_code ~ '^pb[0-9]{3}_pb[0-9]{3}$'::text))
);


--
-- Name: lab; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.lab (
    lab_id integer NOT NULL,
    lab_en text NOT NULL,
    lab_remarks text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    ror_id text NOT NULL,
    lab_native text,
    lab_native_lang text,
    CONSTRAINT lab_lab_en_check CHECK ((btrim(lab_en) <> ''::text)),
    CONSTRAINT lab_lab_native_lang_check CHECK ((lab_native_lang ~ '^[a-z]{2}$'::text)),
    CONSTRAINT lab_native_pair_check CHECK (((lab_native IS NULL) = (lab_native_lang IS NULL))),
    CONSTRAINT lab_ror_id_check CHECK ((ror_id ~ '^0[a-hj-km-np-tv-z0-9]{6}[0-9]{2}$'::text))
);


--
-- Name: lead_isotope_analysis; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.lead_isotope_analysis (
    lead_isotope_analysis_id integer NOT NULL,
    find_id integer NOT NULL,
    site_id integer NOT NULL,
    part_id integer DEFAULT 0 NOT NULL,
    lab_id integer,
    literature_id integer NOT NULL,
    analysis_no_reported text,
    pb206_204 numeric,
    pb207_204 numeric,
    pb208_204 numeric,
    pb207_206 numeric,
    pb208_206 numeric,
    remarks text,
    pb204_206 numeric,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    analysis_method_id integer DEFAULT 2 NOT NULL
);


--
-- Name: literature; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.literature (
    literature_id integer NOT NULL,
    citation text,
    literature_remarks text,
    zotero_key text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    released_on date,
    CONSTRAINT literature_zotero_key_check CHECK ((btrim(zotero_key) <> ''::text))
);


--
-- Name: location_certainty; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.location_certainty (
    code text NOT NULL,
    label_en text NOT NULL,
    label_de text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT location_certainty_code_check CHECK ((code ~ '^[a-z]+$'::text))
);


--
-- Name: material; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.material (
    material_id integer NOT NULL,
    material text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    code text,
    aat_id text,
    CONSTRAINT material_aat_id_check CHECK ((aat_id ~ '^3[0-9]{8}$'::text)),
    CONSTRAINT material_code_check CHECK ((code ~ '^[a-z][a-z0-9_]*$'::text))
);


--
-- Name: part; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.part (
    part_id integer NOT NULL,
    part_de text,
    part_en text,
    remarks text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    code text,
    CONSTRAINT part_code_check CHECK ((code ~ '^[a-z][a-z0-9_]*$'::text))
);


--
-- Name: period; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.period (
    period_de text NOT NULL,
    period_en text NOT NULL,
    chronology_system_id integer NOT NULL,
    min numeric NOT NULL,
    max numeric NOT NULL,
    period_id integer NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    culture_id integer NOT NULL,
    CONSTRAINT period_min_max_check CHECK ((min >= max)),
    CONSTRAINT period_period_de_check CHECK ((btrim(period_de) <> ''::text)),
    CONSTRAINT period_period_en_check CHECK ((btrim(period_en) <> ''::text))
);


--
-- Name: region; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.region (
    region_id integer NOT NULL,
    region_de text NOT NULL,
    region_en text NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    geography public.geography NOT NULL,
    CONSTRAINT region_region_de_check CHECK ((btrim(region_de) <> ''::text)),
    CONSTRAINT region_region_en_check CHECK ((btrim(region_en) <> ''::text))
);


--
-- Name: site; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.site (
    site_id integer NOT NULL,
    site_native text,
    context_type_id integer,
    region_id integer NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    site_latin text NOT NULL,
    site_location_certainty text,
    site_native_lang text,
    site_as_reported text NOT NULL,
    geometry public.geography(Point,4326) NOT NULL,
    CONSTRAINT site_context_type_id_check CHECK ((context_type_id <> 0)),
    CONSTRAINT site_native_pair_check CHECK (((site_native IS NULL) = (site_native_lang IS NULL))),
    CONSTRAINT site_site_as_reported_check CHECK ((btrim(site_as_reported) <> ''::text)),
    CONSTRAINT site_site_latin_check CHECK (((site_latin <> ''::text) AND (site_latin = btrim(site_latin)))),
    CONSTRAINT site_site_native_check CHECK ((site_native = btrim(site_native))),
    CONSTRAINT site_site_native_lang_check CHECK ((site_native_lang ~ '^[a-z]{2}$'::text))
);


--
-- Name: COLUMN site.site_latin; Type: COMMENT; Schema: cau; Owner: -
--

COMMENT ON COLUMN cau.site.site_latin IS 'International (English) site name; Cyrillic in BGN/PCGN. Proposed 2026-11-14, to be reviewed by the owner.';


--
-- Name: COLUMN site.site_location_certainty; Type: COMMENT; Schema: cau; Owner: -
--

COMMENT ON COLUMN cau.site.site_location_certainty IS 'uncertain = name marked with ? in the source; vicinity = near the named place; area = only an area is known; NULL = no restriction known.';


--
-- Name: site_period; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.site_period (
    site_period_id integer NOT NULL,
    site_id integer NOT NULL,
    period_id integer NOT NULL,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL
);


--
-- Name: type; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.type (
    type_id integer NOT NULL,
    type_de text,
    type_en text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    find_class_id integer NOT NULL,
    type_group_id integer,
    aat_id text,
    aat_match text,
    code text,
    CONSTRAINT type_aat_id_check CHECK ((aat_id ~ '^3[0-9]{8}$'::text)),
    CONSTRAINT type_aat_match_check CHECK ((aat_match = ANY (ARRAY['exactMatch'::text, 'closeMatch'::text, 'broadMatch'::text, 'narrowMatch'::text, 'relatedMatch'::text]))),
    CONSTRAINT type_code_check CHECK ((code ~ '^[a-z][a-z0-9_]*$'::text))
);


--
-- Name: type_group; Type: TABLE; Schema: cau; Owner: -
--

CREATE TABLE cau.type_group (
    type_group_id integer NOT NULL,
    type_group_de text NOT NULL,
    type_group_en text NOT NULL,
    find_class_id integer,
    broader_type_group_id integer,
    aat_id text,
    aat_match text,
    id_uuid uuid DEFAULT gen_random_uuid() NOT NULL,
    CONSTRAINT type_group_aat_id_check CHECK ((aat_id ~ '^3[0-9]{8}$'::text)),
    CONSTRAINT type_group_aat_match_check CHECK ((aat_match = ANY (ARRAY['exactMatch'::text, 'closeMatch'::text, 'broadMatch'::text, 'narrowMatch'::text, 'relatedMatch'::text]))),
    CONSTRAINT type_group_one_parent_check CHECK (((find_class_id IS NULL) <> (broader_type_group_id IS NULL)))
);


--
-- Data for Name: analysed_element; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'ag', '31ef8207-e02e-b927-cb99-483388ae5894');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'as', '746199a2-c02a-fb5f-6520-a8dd257d9b55');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'au', '438f2f18-abca-e45b-68db-d40c3b94e7b9');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'bi', '36440d4f-8a21-5858-054f-2391948fad30');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'co', '8084a7e6-3166-c2b5-d733-104a358a8ffa');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'cu', '8f65850d-ae2c-e40d-c8e0-e1a11fb5964c');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'fe', 'fc063fdd-834b-4d12-bde4-92400658754d');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'ni', 'e6f508f1-3d0c-66a4-742e-b3b75a0473af');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'p', '0ce509d1-bc0e-33f0-ec5a-7dc95d1de8ee');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'pb', '21f534f7-4c55-02fa-ab29-3100a9ff7d8b');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'sb', '5f09dd58-2770-884b-1fcc-b95a8c2ad875');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'se', '2ccceb16-cf6c-2d91-4da6-69ac2e8c4018');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'sn', '75a131b6-a8a7-11ab-0c0c-558c07e33276');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'te', '21b61d3a-584d-5b98-957d-b4e8438bfb5e');
INSERT INTO cau.analysed_element (literature_id, element_code, id_uuid) VALUES (41, 'zn', '77bed753-c5de-c5e0-18f6-bb5a3df89598');


--
-- Data for Name: analysis_method; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.analysis_method (analysis_method_id, code, label_en, afo_id, id_uuid) VALUES (1, 'assay', 'assay (method not reported)', 'AFP_0002680', 'f95543fe-d333-cb80-bb02-d42a8a2bf4e1');
INSERT INTO cau.analysis_method (analysis_method_id, code, label_en, afo_id, id_uuid) VALUES (2, 'mass_spectrometry', 'mass spectrometry', 'AFP_0001427', '3271a474-c5e7-8ef6-14dc-4f4f88d37d92');


--
-- Data for Name: chemical_analysis; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (84, 0, 1005, 84, NULL, 41, NULL, 93, NULL, NULL, 0.001, NULL, 0.001, 0.0029, 4.93, 0.012, 0.0012, 0.00007, NULL, 0.00003, NULL, NULL, 0.0009, NULL, NULL, '9064f3e1-3e18-48ba-a9f0-13be09d7ecb4', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (88, 0, 1005, 88, NULL, 41, NULL, 95, NULL, NULL, 0.0011, NULL, 0.0034, 0.0016, 4.05, 0.0837, 0.0025, 0.00008, NULL, 0.000009, NULL, NULL, 0.00006, NULL, NULL, '0a4d21ee-092d-449e-8d93-b7c3431ca348', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (89, 0, 1005, 89, NULL, 41, NULL, 96, NULL, NULL, 0.0022, NULL, 0.0031, 0.0047, 3.77, 0.0035, 0.001, 0.00004, NULL, 0.000019, NULL, NULL, 0.00035, NULL, NULL, '3607d552-14c6-46a5-832e-b711a3171b21', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (810, 0, 1005, 810, NULL, 41, NULL, 95, NULL, NULL, 0.00011, NULL, 0.036, 0.0016, 6.08, 0.0135, 0.042, 0.00004, NULL, 0.00119, NULL, NULL, 0.0013, NULL, NULL, 'ac884993-dea4-456d-bc32-acf092423084', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (818, 0, 1005, 818, NULL, 41, NULL, 96, NULL, NULL, 0.0018, NULL, 0.0013, 0.0023, 3.53, 0.0054, 0.0018, 0.00003, NULL, 0.000017, NULL, NULL, 0.00029, NULL, NULL, '8a82c6de-5b63-4493-835b-090f81609161', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (821, 0, 1005, 821, NULL, 41, NULL, 98, NULL, NULL, 0.0025, NULL, 0.0008, 0.0044, 2.57, 0.01, 0.0014, 0.00004, NULL, 0.000017, NULL, NULL, 0.00046, NULL, NULL, '9fe3ecbf-d19d-4ccf-8ddc-695d7e175d38', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (828, 0, 1005, 828, NULL, 41, NULL, 96, NULL, NULL, 0.0021, NULL, 0.0035, 0.0008, 4.31, 0.009, 0.0009, 0.00003, NULL, 0.000012, NULL, NULL, 0.00006, NULL, NULL, '593362f2-0a71-46f2-aed8-febe346669bd', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (831, 0, 1005, 831, NULL, 41, NULL, 95, NULL, NULL, 0.0019, NULL, 0.0008, 0.0007, 4.05, 0.008, 0.0022, 0.00009, NULL, 0.000012, NULL, NULL, 0.00011, NULL, NULL, '0f01d87e-d13e-4dd5-82ef-71bab4835c7f', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (139, 0, 1005, 970139, NULL, 41, NULL, 95, 0.0001, 0.023, 0.008, 0.0001, 0.004, 0.024, 0.003, 0.0001, 0.047, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'dea90f1b-1443-4a76-96f5-c94cf0750d7c', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (140, 0, 1005, 970140, NULL, 41, NULL, 93, 0.019, 0.043, 0.022, 0.019, 0.108, 0.005, 0.054, 0.508, 0.75, 0.003, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'eb33ba0b-bf44-417b-a1e0-3406650e2a6e', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (141, 0, 1005, 970141, NULL, 41, NULL, 82, 0.0001, 0.001, 0.0001, 0.0001, 0.009, 0.097, 0.45, 0.021, 0.32, 0.0001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'f9f93bb7-e008-4e4b-ba90-6ee4d104d70e', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (142, 0, 1005, 970142, NULL, 41, NULL, 67, 0.0001, 0.001, 0.026, 0.0001, 0.002, 0.003, 0.61, 0.012, 1.64, 0.004, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '64db9ce9-4b5a-45ec-bc3e-ea1edcb64645', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (143, 0, 1005, 970143, NULL, 41, NULL, 97, 0.0001, 0.06, 0.0001, 0.035, 0.001, 0.13, 0.69, 0.04, 0.76, 0.59, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '7f47077c-d11b-4434-a6d5-aa7bd6527478', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (144, 0, 1005, 970144, NULL, 41, NULL, 91, 0.008, 0.001, 0.005, 0.0001, 0.395, 0.123, 0.88, 0.138, 0.92, 0.002, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '53054c18-2928-42c3-b289-0bf8ea7e3f34', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (145, 0, 1005, 970145, NULL, 41, NULL, 91, 0.008, 0.004, 0.009, 0.011, 0.352, 0.024, 1, 0.451, 1.09, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'b69c92e2-9373-485d-9bfd-e0717c21f15a', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (146, 0, 1005, 970146, NULL, 41, NULL, 91, 0.0001, 0.48, 0.009, 0.036, 0.03, 0.26, 1.07, 0.007, 1.1, 0.003, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '13f4e579-2605-4ac7-bd0d-1cc53acbbb49', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (147, 0, 1005, 970147, NULL, 41, NULL, 95, 0.0001, 0.91, 0.002, 0.072, 0.021, 0.51, 1.08, 0.007, 0.56, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '918dd4ef-2e36-4054-a770-f064d1b079c8', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (148, 0, 1005, 970148, NULL, 41, NULL, 88, 0.0001, 1.63, 0.006, 0.056, 0.037, 0.62, 1.1, 0.027, 0.83, 0.051, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '463dab0d-aeb8-4bed-a159-eb57ca6526d0', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (149, 0, 1005, 970149, NULL, 41, NULL, 96, 0.001, 0.03, 0.001, 0.008, 0.31, 0.0762, 1.15, 0.005, 1.69, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '059aa4a8-4e34-478d-a2ca-457a39a55326', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (150, 0, 1005, 970150, NULL, 41, NULL, 95, 0.0001, 0.0001, 0.006, 0.0001, 0.01, 0.065, 1.31, 0.006, 1.21, 0.004, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'a9d7be1a-a05a-4cd1-bd03-f3f453801a47', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (151, 0, 1005, 970151, NULL, 41, NULL, 73, 0.008, 0.068, 0.006, 0.009, 0.469, 0.04, 1.43, 0.099, 1.97, 0.01, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '8c6b5935-1ff7-45a1-8e85-6c5629f6b2ce', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (152, 0, 1005, 970152, NULL, 41, NULL, 97, 0.001, 0.009, 0.001, 0.005, 0.26, 0.057, 1.46, 0.28, 1.07, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'a920794b-40b3-4c5e-b835-ebc454864f0d', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (153, 0, 1005, 970153, NULL, 41, NULL, 67, 0.0001, 0.0001, 0.012, 0.0001, 0.002, 0.069, 1.64, 0.0001, 2.2, 0.003, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '758a1d49-0eca-4696-a041-8e088d92480d', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (154, 0, 1005, 970154, NULL, 41, NULL, 98, 0.008, 0.017, 0.001, 0.0001, 0.081, 0.01, 1.65, 0.435, 1.36, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '22a0edd5-47ac-44cf-98e7-7bf358b830e3', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (155, 0, 1005, 970155, NULL, 41, NULL, 96, 0.001, 0.011, 0.001, 0.006, 0.18, 0.016, 2.12, 0.42, 2, 0.002, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'd7925926-8c7b-40e8-8561-3f86b26f76ba', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (156, 0, 1005, 970156, NULL, 41, NULL, 91, 0.08, 0.028, 0.004, 0.032, 0.411, 0.109, 2.15, 1.289, 1.76, 0.01, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'd21a044e-73bd-4fb8-bd6b-7daf8a3bc437', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (157, 0, 1005, 970157, NULL, 41, NULL, 96, 0.001, 0.29, 0.001, 0.2, 0.081, 0.01, 2.17, 0.04, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'b04f558b-1e56-48b2-9d5b-a69ccb983a4e', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (158, 0, 1005, 970158, NULL, 41, NULL, 94, 0.001, 0.001, 0.001, 0.007, 0.015, 0.009, 2.17, 0.015, 2.91, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '21078063-5607-4648-a917-2286ed7333bb', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (159, 0, 1005, 970159, NULL, 41, NULL, 98, 0.001, 0.021, 0.003, 0.019, 0.043, 0.008, 2.18, 0.018, 0.01, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '9fa29900-74b4-432a-a46c-ff27988d0449', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (160, 0, 1005, 970160, NULL, 41, NULL, 84, 0.001, 0.511, 0.014, 0.02, 0.001, 0.01, 2.24, 0.259, 0.03, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '582ac3de-325f-40d2-a202-2e67685e2b33', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (161, 0, 1005, 970161, NULL, 41, NULL, 95, 0.001, 0.001, 0.001, 0.007, 0.007, 0.002, 2.25, 0.83, 1.98, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '03a924e6-44ad-47e8-aa09-10ab3821cdaf', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (162, 0, 1005, 970162, NULL, 41, NULL, 93, 0.001, 0.003, 0.014, 0.007, 0.23, 0.012, 2.42, 0.97, 2.51, 0.007, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '64c24c93-aca3-4754-9d43-52375bc62db1', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (163, 0, 1005, 970163, NULL, 41, NULL, 97, 0.001, 0.001, 0.001, 0.005, 0.001, 0.006, 2.43, 0.004, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'aee5c0e1-e564-4921-b3cd-ba4fc4b8ad29', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (164, 0, 1005, 970164, NULL, 41, NULL, 97, 0.001, 0.001, 0.001, 0.005, 0.001, 0.007, 2.59, 0.006, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'aba832e5-b6f6-4f04-9da5-8ff7beccf611', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (165, 0, 1005, 970165, NULL, 41, NULL, 91, 0.0001, 0.069, 0.005, 0.0001, 0.07, 0.116, 2.61, 0.61, 0.87, 0.053, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '01de3d13-6299-473f-9cb1-aee0b7e8abe8', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (166, 0, 1005, 970166, NULL, 41, NULL, 99, 0.0001, 0.0001, 0.002, 0.0001, 0.026, 0.023, 2.65, 0.02, 4, 0.006, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '90b01161-b48e-49f1-9dfc-45f04baa4fc1', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (167, 0, 1005, 970167, NULL, 41, NULL, 93, 0.017, 0.021, 0.005, 0.0001, 0.113, 0.036, 2.68, 0.01, 0.01, 0.008, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '2c658f12-ea03-4ec1-9545-7297d846f04f', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (168, 0, 1005, 970168, NULL, 41, NULL, 97, 0.001, 0.001, 0.001, 0.007, 0.001, 0.007, 2.86, 0.008, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '20c1801a-5046-4e61-ba56-a637e9f3807d', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (169, 0, 1005, 970169, NULL, 41, NULL, 68, 0.0001, 0.27, 0.015, 0.0001, 0.18, 0.07, 2.87, 0.08, 1, 0.0001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'bb8ac61b-1508-44c0-90c3-da80275f97e0', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (170, 0, 1005, 970170, NULL, 41, NULL, 98, 0.001, 0.001, 0.001, 0.005, 0.001, 0.007, 2.92, 0.004, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'fd422b8a-f9f4-4487-a703-722dfc948f0d', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (171, 0, 1005, 970171, NULL, 41, NULL, 96, 0.001, 0.019, 0.001, 0.006, 0.001, 0.004, 3, 0.22, 0.03, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'fad1e5eb-9989-41a4-9c3d-6f99be03bbf7', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (172, 0, 1005, 970172, NULL, 41, NULL, 97, 0.001, 0.001, 0.003, 0.008, 0.001, 0.008, 3.06, 0.008, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '1f6dccd8-80be-474c-a8d6-7f684419cbf0', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (173, 0, 1005, 970173, NULL, 41, NULL, 97, 0.001, 0.001, 0.001, 0.008, 0.002, 0.007, 3.11, 0.008, 0.002, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'b8efcd0c-c3d6-4ffc-afd4-ec1576e87d17', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (174, 0, 1005, 970174, NULL, 41, NULL, 96, 0.001, 0.001, 0.001, 0.007, 0.001, 0.007, 3.15, 0.008, 0.002, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '6e5b383b-432d-4ce6-9df5-e7406b25db13', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (175, 0, 1005, 970175, NULL, 41, NULL, 96, 0.001, 0.005, 0.001, 0.007, 0.27, 0.007, 3.18, 0.25, 0.53, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'cc2985cd-cb3c-46c1-9858-126ce3cb2d59', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (176, 0, 1005, 970176, NULL, 41, NULL, 97, 0.001, 0.001, 0.001, 0.008, 0.002, 0.006, 3.24, 0.004, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '91c18514-41f2-4466-b256-85a96077ea2e', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (177, 0, 1005, 970177, NULL, 41, NULL, 95, 0.008, 0.016, 0.007, 0.008, 0.041, 0.01, 3.25, 0.01, 1.86, 0.003, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, 'b53e78e1-c79b-4502-96ed-115c4f54ac64', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (178, 0, 1005, 970178, NULL, 41, NULL, 88, 0.003, 0.021, 0.003, 0.0001, 0.016, 0.01, 3.8, 0.002, 0.009, 0.002, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '667c6f40-57b7-46ec-85c2-c003b7ad3a4b', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (179, 0, 1005, 970179, NULL, 41, NULL, 96, 0.001, 0.001, 0.001, 0.008, 0.001, 0.007, 3.99, 0.004, 0.003, 0.001, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '32d5f0b3-e8e4-422b-92cc-4f06983a2b78', 1);
INSERT INTO cau.chemical_analysis (chemical_analysis_id, part_id, site_id, find_id, lab_id, literature_id, analysis_no_reported, cu, sn, pb, zn, bi, ag, sb, "as", fe, ni, co, mn, au, p, te, se, s, remarks, id_uuid, analysis_method_id) VALUES (180, 0, 1005, 970180, NULL, 41, NULL, 76, 0.001, 0.445, 0.001, 0.05, 0.4, 2.741, 8.66, 4.606, 0.17, 0.006, NULL, 0.0001, 0.0001, 0.0001, 0.0001, NULL, NULL, '8c130027-1522-4d19-991b-d3905690b8b1', 1);


--
-- Data for Name: chronology_system; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.chronology_system (chronology_system_id, chronology_system_de, literature_id, chronology_system_en, id_uuid) VALUES (15, 'Arslantepe Stufen', 90, 'Arslantepe periods', 'bffcc2eb-7e52-46f8-86cd-2f552b07a4d1');
INSERT INTO cau.chronology_system (chronology_system_id, chronology_system_de, literature_id, chronology_system_en, id_uuid) VALUES (11, 'Tepe Gawra Stufen', 91, 'Tepe Gawra periods', '83070ad2-1af8-4fb0-8952-669a2fc670d4');


--
-- Data for Name: context_type; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.context_type (context_type_id, context_type_de, context_type_en, context_type_remarks, id_uuid, applies_to, aat_id, aat_match, code) VALUES (7, 'Grab', 'grave', NULL, '3f8ffd6b-d47c-1613-f4a9-213326a3abb2', 'feature', '300005907', 'closeMatch', NULL);
INSERT INTO cau.context_type (context_type_id, context_type_de, context_type_en, context_type_remarks, id_uuid, applies_to, aat_id, aat_match, code) VALUES (4, 'Hort', 'hoard', NULL, '24a624fc-7cb3-4a3a-8bc0-407a3fa89816', 'both', '300195474', 'closeMatch', NULL);
INSERT INTO cau.context_type (context_type_id, context_type_de, context_type_en, context_type_remarks, id_uuid, applies_to, aat_id, aat_match, code) VALUES (3, 'Siedlung', 'settlement', NULL, '19d849fb-d725-45e5-8449-0080e31537b9', 'both', '300444153', 'closeMatch', NULL);
INSERT INTO cau.context_type (context_type_id, context_type_de, context_type_en, context_type_remarks, id_uuid, applies_to, aat_id, aat_match, code) VALUES (5, 'unbestimmter Kontext', 'unspecified context', NULL, '053ddd47-0b52-1f63-e9f1-e011e0b1ed34', 'feature', NULL, NULL, 'unspecified_context');


--
-- Data for Name: culture; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.culture (culture_id, culture_en, culture_de, id_uuid) VALUES (30, 'Northern Mesopotamian Late Chalcolithic', 'Nordmesopotamisches Spätchalkolithikum', '44259120-5d4e-4525-b354-c325cfbc2d87');
INSERT INTO cau.culture (culture_id, culture_en, culture_de, id_uuid) VALUES (31, 'Northern Mesopotamian Early Bronze Age', 'Nordmesopotamische Frühbronzezeit', '8b9eb484-3821-415f-8847-d15ba11c9a73');


--
-- Data for Name: element; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('cu', 'Cu', 'CHEBI_28694', 1, 'c91cb8fd-a8f7-1522-65a7-46521d87c26f');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('sn', 'Sn', 'CHEBI_27007', 2, 'f6c6b0ac-1744-d89e-32a9-24f167dd4022');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('pb', 'Pb', 'CHEBI_25016', 3, '119dd7f7-3420-5ae4-df60-103b1e7ec2a8');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('zn', 'Zn', 'CHEBI_27363', 4, 'a71ef004-73da-89bb-28a4-933b0db9d905');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('bi', 'Bi', 'CHEBI_33301', 5, 'dd3f674f-6801-ff98-8c95-01f4a9e08cfa');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('ag', 'Ag', 'CHEBI_30512', 6, '3fe656bb-5b64-3d5e-c4b3-9ccb26249023');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('sb', 'Sb', 'CHEBI_30513', 7, 'b3f15fdd-5c3a-0331-0e0d-8f0a8ce24ed3');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('as', 'As', 'CHEBI_27563', 8, 'c5b39523-ac79-30e2-d325-7025703713a5');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('fe', 'Fe', 'CHEBI_18248', 9, 'a9e3a852-ea3e-af91-8300-1be675041b11');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('ni', 'Ni', 'CHEBI_28112', 10, '504748ac-3661-5d4c-c6ec-a3395de4233e');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('co', 'Co', 'CHEBI_27638', 11, 'de1a3306-5042-3e1c-0e04-4e7698eea03e');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('au', 'Au', 'CHEBI_29287', 13, '90dfccbe-4553-4078-ac11-33e9d3a5d28b');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('p', 'P', 'CHEBI_28659', 14, '7f93877b-d052-38e1-ff63-8a06169cca8e');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('te', 'Te', 'CHEBI_30452', 15, 'b9ab00d4-254b-3825-5a46-0dd82b9aa0fc');
INSERT INTO cau.element (element_code, symbol, chebi_id, sort_order, id_uuid) VALUES ('se', 'Se', 'CHEBI_27568', 16, '40db68d9-8076-d5b5-dd98-db009ff2a0fc');


--
-- Data for Name: feature; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (1, 1005, 'royal tomb', NULL, 61, '230027af-11bd-4fce-ac4d-39cd542cf78d', 7, 'Königsgrab', 'Royal Tomb', NULL);
INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (3, 1005, 'Palaca Hoard', NULL, 68, '252b75ad-286f-4a5d-9b39-b340730e0869', 4, 'Palasthort', 'Palace Hoard', NULL);
INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (610, 1005, 'unspecified context', NULL, 68, '4cfba3b0-27bd-4ee4-9ab5-f47bb4ff7293', 5, 'unbestimmter Kontext', 'Unspecified context', NULL);
INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (621, 1005, 'unspecified context', NULL, 61, 'f179e4ce-3415-48da-a3f4-bd56efc9b077', 5, 'unbestimmter Kontext', 'Unspecified context', NULL);
INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (622, 1005, 'unspecified context', NULL, 53, 'c912cee1-3c27-4d7d-8ea3-6f9d8d9b38cc', 5, 'unbestimmter Kontext', 'Unspecified context', NULL);
INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (630, 1005, 'unspecified context', NULL, 38, 'cc7b7373-132e-4537-9ea3-44d030355466', 5, 'unbestimmter Kontext', 'Unspecified context', NULL);
INSERT INTO cau.feature (feature_id, site_id, feature_as_recorded, remarks, period_id, id_uuid, context_type_id, feature_de, feature_en, part_of_feature_id) VALUES (700, 1005, 'unspecified context', NULL, 87, '6880a16a-b65f-4bcf-9278-c622c27b7ab4', 5, 'unbestimmter Kontext', 'Unspecified context', NULL);


--
-- Data for Name: find; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (53, 1005, 1, 405, NULL, 41, NULL, 'ARSL 53', '07126867-320f-45f2-8a0a-9c37b895c8c4', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (40, 1005, 1, 405, NULL, 41, NULL, 'ARSL 40', '2146411b-904b-4a6d-850a-37ba56afc3dd', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (23, 1005, 1, 817, 'vier Spiralen', 41, NULL, 'ARSL 23', '73dff4ab-d352-49de-ad79-5e6d231f6328', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (46, 1005, 1, 401, 'Spiralring', 41, NULL, 'ARSL 46', 'b480309f-8ed7-430c-9854-3cc5464c42a9', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (63, 1005, 1, 401, 'Spiralring', 41, NULL, 'ARSL 63', '945fffcc-2fb1-4771-a7ce-9a75907c2436', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (55, 1005, 1, 401, NULL, 41, NULL, 'ARSL 55', '5d15f780-60f5-4570-8e76-d2da8c844ac2', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (17, 1005, 1, 901, NULL, 41, NULL, 'ARSL 17', '050ce3a1-85fb-4de5-a0a0-c728b167cc59', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (64, 1005, 1, 405, NULL, 41, NULL, 'ARSL 64', 'd35bbe82-a847-44ed-aece-9957ce1ebab7', NULL);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970159, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 26', '8a233981-1517-4471-8d20-9873949802bd', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (828, 1005, 3, 220, NULL, 41, NULL, 'TR-8/28', '83a82b77-02b5-4aac-b2f3-8903d97cd0cf', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970153, 1005, 621, 712, 'Fragment', 41, NULL, 'TR-8/210', '086c2bb1-7a77-41f9-892b-e0e19d4675ca', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970172, 1005, 1, 201, 'Dolch', 41, NULL, 'ARSL 65', '3c50f5be-4029-4911-af95-6bb65442d6df', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970151, 1005, 1, 601, 'Nadel', 41, NULL, 'ARSL 6', 'c6951c76-eca7-4144-ad1b-9a9a118c9b8b', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970156, 1005, 1, 806, 'Pfriem', 41, NULL, 'ARSL 22', 'f1aea236-08ac-450d-8371-6cfd45b8b85e', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970162, 1005, 1, 137, 'Tuellenmeissel', 41, NULL, 'ARSL 13', '7f57d6c3-09f3-415d-a71a-4aae8197bd43', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970139, 1005, 622, 712, 'Fragment', 41, NULL, 'TR-8/208', '20b00c14-a069-491c-a365-24f24f7830da', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970157, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 33', 'e8f3e3eb-a100-4450-a410-80b74e8a52e6', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970146, 1005, 700, 712, 'Fragment', 41, NULL, 'TR-8/206', 'd9e03dff-726a-4f0d-acca-c5be7344ee4c', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (831, 1005, 3, 301, NULL, 41, NULL, 'TR-8/31', '3d0fee13-7129-4469-9cab-413bdfa7bbeb', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970142, 1005, 621, 712, 'Fragment', 41, NULL, 'TR-8/211', '7167119b-0418-4e16-adc7-d05d480606a2', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970163, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 29', 'b759279f-093a-46c7-8d81-1191e4ce736f', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970168, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 32', '4f084b2e-4334-4b9a-8f3f-7ec73aef1be1', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970176, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 31B', '30871380-ff3b-494f-9984-70c2c3baf857', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970180, 1005, 1, 907, 'Becher', 41, NULL, 'ARSL 58', 'a87dd84a-d19c-46b3-b221-386aad1bec78', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970149, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 28', '8519e91a-5f32-48f1-b27c-7b10743c2557', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970166, 1005, 610, 712, 'Fragment', 41, NULL, 'TR-8/116', '326e500d-26d8-4c4d-b210-464dfb44d55a', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970145, 1005, 1, 601, 'Nadel', 41, NULL, 'ARSL 5', '2886e1d4-430e-494c-b479-40799115f84b', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970169, 1005, 621, 712, 'Fragment', 41, NULL, 'TR-8/203', '4f5d221f-a707-450b-8dab-d08160b8628a', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970154, 1005, 1, 134, 'Meissel', 41, NULL, 'ARSL 24', 'e251d69f-dead-42e7-bd65-8268b6d42849', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (84, 1005, 3, 220, NULL, 41, NULL, 'TR-8/4', 'b824e657-6bcd-4b21-b220-a9da9858f007', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970141, 1005, 610, 712, 'Fragment', 41, NULL, 'TR-8/201', 'e91cbfd1-17b1-4162-8af2-049ff228ec1b', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (821, 1005, 3, 301, NULL, 41, NULL, 'TR-8/21', '0a447a3a-1e9e-4115-b521-f8aee1e528a7', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (818, 1005, 3, 301, NULL, 41, NULL, 'TR-8/18', '92131cbc-ddfc-4407-94ac-8cac4f613a89', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970165, 1005, 630, 712, 'Fragment', 41, NULL, 'TR-8/207', '794dd9e6-6c26-492e-b53a-4cbcf7a3ef11', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970178, 1005, 1, 220, 'Schwert', 41, NULL, 'ARSL 35', '4be2d50c-70bf-4593-b5ee-e2a635137ba2', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970144, 1005, 1, 905, 'Schale', 41, NULL, 'ARSL 47', 'd1bd0c5c-67c7-42f7-b388-331a1c85f26b', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970170, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 30', '546eb25e-31f3-4958-b3c0-772509509d86', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (88, 1005, 3, 220, NULL, 41, NULL, 'TR-8/8', '1857ac0e-7e16-4004-a300-8f16bbdcb615', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970173, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 31A', 'd22a482b-a2a2-4d44-b025-3c005e1e8d5f', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970143, 1005, 610, 712, 'Fragment', 41, NULL, 'TR-8/204', '5f8210e6-4f71-4877-904d-606af3917318', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970175, 1005, 1, 122, 'Axt', 41, NULL, 'ARSL 21', '6ec60c33-6dc1-484f-b578-43f0aed89dde', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970161, 1005, 1, 122, 'Axt', 41, NULL, 'ARSL 19', '386ff65e-38b4-4e1c-ac38-963e244ab245', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970171, 1005, 1, 122, 'Axt', 41, NULL, 'ARSL 12', 'a4874ab7-97be-4315-b2da-aeeaadb38b15', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970179, 1005, 1, 201, 'Dolch', 41, NULL, 'ARSL 18', '6ecabf90-1ecd-49f0-a366-379a356ae2c0', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970155, 1005, 1, 122, 'Axt', 41, NULL, 'ARSL 20', '4e7e0f9d-8f79-4b99-986a-25777d0afbb1', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970164, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 27', 'c7f0df3e-fa13-4040-9cf5-c93ba8edb117', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970167, 1005, 1, 301, 'Lanze', 41, NULL, 'ARSL 34', '3ea27ec7-1e3c-4c54-9a4b-acee8c61e249', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970148, 1005, 610, 712, 'Fragment', 41, NULL, 'TR-8/202', '538473f9-b52f-41cc-b363-91e32045696d', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970150, 1005, 610, 712, 'Fragment', 41, NULL, 'TR-8/205', '4ac34d32-6bfa-4bd1-8a4a-ec421ab335e1', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970177, 1005, 1, 201, 'Messer', 41, NULL, 'ARSL 16', '6b9acc5d-b501-4e6a-9bff-e63c8da5145a', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970158, 1005, 1, 806, 'Pfriem', 41, NULL, 'ARSL 14', '8617989c-e99b-4e81-8b57-e707b8dc85c5', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (810, 1005, 3, 507, 'vier Spiralen', 41, NULL, 'TR-8/10', '036079bd-3f71-459e-b9ff-8a0d76189921', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (89, 1005, 3, 301, NULL, 41, NULL, 'TR-8/9', '89e70a5b-b125-4125-be33-6e423915c675', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970140, 1005, 1, 601, 'Nadel', 41, NULL, 'ARSL 2', '3d0ebeb1-ab09-42ee-a975-f65638719cea', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970174, 1005, 1, 220, 'Schwert', 41, NULL, 'ARSL 15', 'd463ac30-f668-4260-8e26-ccb03ea7a982', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970152, 1005, 1, 134, 'Meissel', 41, NULL, 'ARSL 25', '846cb931-4676-4aa7-8bf1-13eaceac0b7b', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970147, 1005, 610, 712, 'Fragment', 41, NULL, 'TR-8/200', '452deab4-8ea1-47d1-8b9f-c505f4fe702c', 1);
INSERT INTO cau.find (find_id, site_id, feature_id, type_id, remarks, literature_id, drawing_no_reported, find_no_reported, id_uuid, material_id) VALUES (970160, 1005, 1, 601, 'Nadel', 41, NULL, 'ARSL 3', 'c7e94195-8fb6-4530-8790-18fc20649057', 1);


--
-- Data for Name: find_class; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (7, 'Barren und Gussreste', 'ingots and casting waste', 'b007a011-5b1d-4f6b-a57d-9d17b8c53dfd', NULL, NULL, NULL);
INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (1, 'Trachtbestandteile', 'elements of dress and jewellery', 'c1a00170-1b71-487a-b6e1-61b389eabe29', '300209273', 'broadMatch', NULL);
INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (2, 'Äxte und Beile', 'axes and adzes', 'b220f040-d41b-47ee-a2f4-80283fd6b9d4', '300024662', 'broadMatch', NULL);
INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (3, 'Dolche und andere Klingen', 'daggers and other blades', '26a9cabc-46b3-41eb-b61b-eb2351736d90', '300036973', 'broadMatch', NULL);
INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (4, 'Pfrieme, Meißel und andere Geräte', 'awls, chisels and other tools', '4c196761-59b7-4876-9473-e1c831020983', '300024841', 'broadMatch', NULL);
INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (5, 'Lanzen und andere Spitzen', 'spearheads and other points', '4343f447-9ceb-4727-8bf7-ba1b16d5001a', '300037204', 'broadMatch', NULL);
INSERT INTO cau.find_class (find_class_id, find_class_de, find_class_en, id_uuid, aat_id, aat_match, code) VALUES (6, 'Gefäße', 'vessels', 'aa79dce1-8a75-4498-9cba-87ede12cee6b', '300193015', 'closeMatch', NULL);


--
-- Data for Name: isotope_ratio; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.isotope_ratio (ratio_code, column_name, numerator_wikidata, denominator_wikidata, sort_order, id_uuid) VALUES ('pb206_pb204', 'pb206_204', 'Q18883438', 'Q18883429', 1, '50b7bbae-7dc4-8088-28de-50daab853934');
INSERT INTO cau.isotope_ratio (ratio_code, column_name, numerator_wikidata, denominator_wikidata, sort_order, id_uuid) VALUES ('pb207_pb204', 'pb207_204', 'Q18883443', 'Q18883429', 2, 'e348f2f9-2663-af28-a722-9645eab46183');
INSERT INTO cau.isotope_ratio (ratio_code, column_name, numerator_wikidata, denominator_wikidata, sort_order, id_uuid) VALUES ('pb208_pb204', 'pb208_204', 'Q16670466', 'Q18883429', 3, '2bc2a594-aa55-413d-65b3-1435e36d1aec');
INSERT INTO cau.isotope_ratio (ratio_code, column_name, numerator_wikidata, denominator_wikidata, sort_order, id_uuid) VALUES ('pb207_pb206', 'pb207_206', 'Q18883443', 'Q18883438', 4, '61c46e3f-2b96-3178-4fd0-7e411bd3d401');
INSERT INTO cau.isotope_ratio (ratio_code, column_name, numerator_wikidata, denominator_wikidata, sort_order, id_uuid) VALUES ('pb208_pb206', 'pb208_206', 'Q16670466', 'Q18883438', 5, '2c98202f-e91c-400d-1613-2c3da61781e0');
INSERT INTO cau.isotope_ratio (ratio_code, column_name, numerator_wikidata, denominator_wikidata, sort_order, id_uuid) VALUES ('pb204_pb206', 'pb204_206', 'Q18883429', 'Q18883438', 6, '46e7bd78-725e-594b-636c-34e0173d87a9');


--
-- Data for Name: lab; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.lab (lab_id, lab_en, lab_remarks, id_uuid, ror_id, lab_native, lab_native_lang) VALUES (2, 'German Mining Museum Bochum', NULL, '74524672-34d8-47bd-a09b-08dc6557b079', '03k7cjr94', 'Deutsches Bergbau-Museum Bochum', 'de');


--
-- Data for Name: lead_isotope_analysis; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (1, 970171, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8309, 2.0716, NULL, 0.05295, 'c4d2ef3c-e1f2-4435-8144-ae198e8ea956', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (2, 970162, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.831, 2.0657, NULL, 0.05307, '95f1920b-e408-4a83-9e17-020025b66c0a', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (3, 970158, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.831, 2.0647, NULL, 0.05321, '6bd907f1-5182-4a61-a8d5-9cbaf9a104a2', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (4, 970174, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8385, 2.0767, NULL, 0.05352, '7a3f9cad-a60e-498b-8031-9de2f0845bdc', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (5, 970177, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.833, 2.0688, NULL, 0.05308, '38c1eb32-da90-4583-a6c2-22a3b3eab1df', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (6, 17, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8315, 2.0648, NULL, 0.05311, '6ed3e529-7e81-40ed-be87-52d49ac48542', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (7, 970179, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8374, 2.0743, NULL, 0.05347, 'e343cdfa-0ade-4b80-9a30-94dc9a1ae4d7', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (8, 970161, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8308, 2.0713, NULL, 0.05291, '373499d0-1deb-4efa-ad1d-7a836235017a', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (9, 970155, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8307, 2.0654, NULL, 0.05304, '646b2514-a0b3-4f5d-b1c2-006179290796', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (10, 970175, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8347, 2.0722, NULL, 0.05329, '36047110-6bf3-4ce3-9a8b-3bea6d860ee3', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (11, 23, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8309, 2.0694, NULL, 0.05295, '445d98ae-762d-4643-9a12-e6e63805e6cb', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (12, 970149, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.83, 2.0627, NULL, 0.05306, '4b4b9455-2618-4610-9f6b-a6eb1d84f5c6', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (13, 970163, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8455, 2.0865, NULL, 0.05426, '91dd1767-55c9-4ab7-89a4-9c8ec961afe2', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (14, 970173, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.841, 2.0798, NULL, 0.05382, '6bf46093-d970-404e-800e-af3b28b1af12', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (15, 970176, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8413, 2.0815, NULL, 0.05376, '324245c9-da2b-419f-aa22-f6ccdd865cf2', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (16, 970167, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8448, 2.0865, NULL, 0.05426, 'a26247f3-3198-4434-88e4-7110cf75e9f9', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (17, 40, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8299, 2.068, NULL, 0.05293, '18ffe50c-2e68-4a24-b8bd-7eb154500a8b', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (18, 46, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.83, 2.0674, NULL, 0.05301, 'f05c2fb3-da4a-4cec-8901-72f31287dbc8', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (19, 53, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8313, 2.0701, NULL, 0.05296, '0ad0b513-bda9-46c0-b4a4-1e0de577d3b4', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (20, 55, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8307, 2.0692, NULL, 0.05293, 'e63aae6f-26fc-43eb-8ed9-eff30f217c8c', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (21, 63, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.83, 2.0683, NULL, 0.05291, '7c66fb2f-5ff1-49e3-9fbd-61e1a214b7cd', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (22, 64, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8304, 2.0691, NULL, 0.05295, 'af6ab4fd-22d7-4745-ad1f-09232d43306f', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (23, 970172, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8443, 2.0856, NULL, 0.05407, '63ea8da2-0012-4465-be8f-082e732e2c25', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (24, 818, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8444, 2.0852, NULL, 0.05407, '70a5e5a8-15db-4f0d-8fa5-bbf33af51c94', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (25, 828, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8664, 2.1104, NULL, 0.05562, '73346c59-7fbd-43a6-a8d4-a6dcf8b1f2b5', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (26, 831, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.843, 2.0816, NULL, 0.054, 'adaa570f-e786-4b88-b905-5f5fe4fef47b', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (27, 84, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8461, 2.0879, NULL, 0.05421, '267b046f-0dd4-425c-97c5-c8ad66d9da9a', 2);
INSERT INTO cau.lead_isotope_analysis (lead_isotope_analysis_id, find_id, site_id, part_id, lab_id, literature_id, analysis_no_reported, pb206_204, pb207_204, pb208_204, pb207_206, pb208_206, remarks, pb204_206, id_uuid, analysis_method_id) VALUES (28, 89, 1005, 0, 2, 41, NULL, NULL, NULL, NULL, 0.8432, 2.083, NULL, 0.05396, '0af8087b-d6d0-42f3-b5c4-e682fd1f38e4', 2);


--
-- Data for Name: literature; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.literature (literature_id, citation, literature_remarks, zotero_key, id_uuid, released_on) VALUES (90, 'Vignola et al 2019', NULL, 'vignola2019changes', 'b7336a24-915a-4eed-be86-2bdaf31867b2', NULL);
INSERT INTO cau.literature (literature_id, citation, literature_remarks, zotero_key, id_uuid, released_on) VALUES (91, 'Rothman Peasnall 2002', NULL, 'rothman2002tepe', '34a00ea9-6ce2-4ddd-870c-8f3490a391e4', NULL);
INSERT INTO cau.literature (literature_id, citation, literature_remarks, zotero_key, id_uuid, released_on) VALUES (41, 'Hauptmann/Schmitt-Strecker/Bergmann/Palmieri 2002', NULL, 'hauptmann2002chemical', 'acded39b-b1c9-4a8f-a468-2559a43bd62d', '2026-11-17');


--
-- Data for Name: location_certainty; Type: TABLE DATA; Schema: cau; Owner: -
--



--
-- Data for Name: material; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.material (material_id, material, id_uuid, code, aat_id) VALUES (1, 'cu', '782ddcc0-da10-48c3-a4ea-d2dfd70448f4', 'copper_base', '300241441');


--
-- Data for Name: part; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.part (part_id, part_de, part_en, remarks, id_uuid, code) VALUES (0, 'keine Unterteilung', 'no sub-parts', NULL, 'eec8c9d2-31aa-4bd4-bbd2-3dff59c5cf56', 'whole_object');


--
-- Data for Name: period; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Arslantepe VIC', 'Arslantepe VIC', 15, 2750, 2500, 38, 'da6081e3-c22c-43dc-99cf-9a2b834fca3f', 31);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Arslantepe VIB2', 'Arslantepe VIB2', 15, 2900, 2750, 53, '7d79372b-75ec-4c49-a8f7-0806fccd4b43', 31);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Arslantepe VIB1', 'Arslantepe VIB1', 15, 3000, 2900, 61, '561b5ede-c714-41f7-afc2-e7aa41cf175f', 31);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Tepe Gawra 7', 'Tepe Gawra 7', 11, 3050, 2400, 63, '28287aff-a17e-4bf6-8f13-75ddb84a299a', 31);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Arslantepe VIA', 'Arslantepe VIA', 15, 3350, 3000, 68, '55526f31-ccc5-4c09-806f-c528a2d6f49e', 30);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Tepe Gawra 8', 'Tepe Gawra 8', 11, 3750, 3600, 82, '0445fe50-49b2-433d-949b-5062a371994f', 30);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Tepe Gawra 9', 'Tepe Gawra 9', 11, 3850, 3750, 85, '2a0eaaff-18d3-4aef-9f59-3a3431d28319', 30);
INSERT INTO cau.period (period_de, period_en, chronology_system_id, min, max, period_id, id_uuid, culture_id) VALUES ('Arslantepe VII', 'Arslantepe VII', 15, 3900, 3350, 87, 'b67708d0-02a7-4428-9d68-664111a537aa', 30);


--
-- Data for Name: region; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.region (region_id, region_de, region_en, id_uuid, geography) VALUES (4, 'Nordmesopotamien', 'Northern Mesopotamia', 'f82ca066-6f79-4f46-b1dd-737f7a550470', '0106000020E6100000010000000103000000010000003C00000053C8FAB899FD4140023938ECEF9641404EF2CD5000F14140184E79352894414043687856F6E341408E6013E857934140FAD94AE3EDD641401C8B293286944140399F321159CA41401AFD85D0A8974140C9EBC345A6BE4140084D5361A49C4140AAA9A8933CB4414005FB8F454DA3414076663D4B78AB4140B503C60B69AB41404275D658011A4140B6B05E54964A42400F2400D4D21241406D6DB2A3065442408AE37F53F90D41405B3E582C5F5E4240B3744EF4A30B414068B713D93F694240A4FC26BCEA0B4140421F704843744240970CDB67CD0E41407F2D2876027F4240BAE49217331441404FE25E8118894240599891E8EA1B4140E5AE196C26924240E569B782AD25414014CEB3AED6994240F82D8A941F3141400100EA79E09F4240B342B62BD53D4140B041EE830AA4424076ADCFCA554B41405F96D2402DA6424018BF11E62B6541406B93BCE332A842407620269683294240EDA6404636BF42409CA9E8B988FF424030D3CA1C595943406FF5FD64410B4340F3A18A8CFF5F4340CEF9885D781843409F5349CAB164434004274EA1A7264340060BCC1B40674340E6A201D83E354340BD15A68C90674340F5AE835EA9434340F0897002A06543403878E28654514340CEBC5A5A82614340983EE0BBB55D4340B60D238F615B43407C9F2C579BA24440F6881B65528D4240ABB3726672A34540F953B1A84D7B4240C96DFD6ADDB04540ED056AF432794240E467459E97BD4540B06C08EA1F754240EBB7797E2BC94540673BAF693A6F4240B78BCDC02ED345402125D61AB9674240D23A283646DB454002563358E15E4240847D6F0629E145401BAF639404554240D470FE25A3E445401B7439547D4A42403EFC68F496E54540A6D7B8DEAB3F42408486D1FEFDE34540D28D20C4F23442405DA6F7E9E8DF4540ABDA175DB32A4240CD8833907ED94540D01684614A21424031D09265FAD04540F439F2B30C1942401E70489735A5444036469CB8431E414093731B854F9B4440E22284E31F174140E6E33A3AEC8F4440BD82995CB2114140D5F9A7E374834440A38C20172D0E41406F2F54335C7644400A549778B00C4140AE33B76F1A694440FCB0773B4A0D4140A77DF159295C4440937B92F4F40F41403126C10600504440668CC23E98144140B090F8C60E454440D011538C091B4140BE1FCA3CBB3B4440B462F8980D234140D388F3BB5C344440B1189D725A2C4140CFCB5713392F444047D2880A9A3641408201680CA4D14340E30E68A22D2D4240F8FD55ADEF2143405163F6878B2142400D7C5C2954094240C1A495AA969B414053C8FAB899FD4140023938ECEF964140');


--
-- Data for Name: site; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.site (site_id, site_native, context_type_id, region_id, id_uuid, site_latin, site_location_certainty, site_native_lang, site_as_reported, geometry) VALUES (1005, NULL, 3, 4, 'fc9ee3ea-41b1-4c3d-a174-d553b81bd6d8', 'Arslantepe', NULL, NULL, 'Arslantepe', '0101000020E6100000D42B6519E2304340F54A5986382E4340');


--
-- Data for Name: site_period; Type: TABLE DATA; Schema: cau; Owner: -
--



--
-- Data for Name: type; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (122, 'Schaftlochaxt, einschneidig', 'single-bladed shaft-hole axe', 'a9bd30fe-194a-49f6-9494-18ac4fbb674a', 2, NULL, '300024664', 'broadMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (134, 'Flachmeißel, Keil', 'flat chisel, wedge', 'abab9506-c910-482e-b645-c7877b86ab14', 4, NULL, '300024665', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (137, 'Tüllenmeißel', 'socketed chisel', 'f57ba98b-5d3f-4626-94dd-d7a1ab654627', 4, NULL, '300024665', 'broadMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (201, 'Flachdolch oder Dolch, unbestimmt', 'flat dagger or dagger, unspecified', '6e7f3e75-af89-42aa-8afa-aa0c403d81ca', 3, 5, '300037058', 'broadMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (220, 'Schwert, unbestimmt', 'sword, unspecified', '20fba788-5ca7-4cd7-80dc-7f43234a2fa7', 3, 2, '300037048', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (301, 'Lanzenspitze, unbestimmt', 'spearhead, unspecified', 'a1540470-f7ef-43ed-842b-874d8a0556ea', 5, NULL, '300037118', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (401, 'Ring, unbestimmt', 'ring, unspecified', 'de245a9a-46f7-4cca-b6f6-d80927db6961', 1, NULL, '300263678', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (405, 'Armring, unbestimmt', 'bracelet, unspecified', '8b8d073b-974e-48bb-b198-1590a2ccffc1', 1, NULL, '300045991', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (507, 'Anhänger, unbestimmt', 'pendant, unspecified', '03c7bcb1-e358-4672-a3df-1c11cc31d0a8', 1, NULL, '300046002', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (601, 'Nadel, Sonderform, Form unbestimmt', 'pin, special or unspecified form', '562f7ec7-48d8-4348-98ac-059f95ee65df', 1, NULL, '300046006', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (712, 'Gussrückstand, Gusszapfen, Schlacke', 'casting residue, sprue, slag', '5efa1ccc-f09a-4dad-a2e9-23d264f15050', 7, NULL, '300011790', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (806, 'Pfriem', 'awl', '35d292b4-169a-4847-8ac5-428c9ca72ac5', 4, NULL, '300024663', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (817, 'Majkop-Gabel', 'Maykop fork', 'a574e70a-4899-4cd0-9abc-2685cd8782ed', 1, NULL, '300393163', 'broadMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (901, 'Gefäß, unbestimmt', 'vessel, unspecified', '9acd3f63-ce57-44e2-ad29-0825bee76196', 6, NULL, '300193015', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (905, 'Schale', 'bowl', 'c772c3aa-6d20-4f22-8cc7-715bbadce301', 6, NULL, '300203596', 'closeMatch', NULL);
INSERT INTO cau.type (type_id, type_de, type_en, id_uuid, find_class_id, type_group_id, aat_id, aat_match, code) VALUES (907, 'Becher', 'beaker', '54771f81-da93-4aca-abe0-15d2b917b767', 6, NULL, '300043198', 'closeMatch', NULL);


--
-- Data for Name: type_group; Type: TABLE DATA; Schema: cau; Owner: -
--

INSERT INTO cau.type_group (type_group_id, type_group_de, type_group_en, find_class_id, broader_type_group_id, aat_id, aat_match, id_uuid) VALUES (1, 'Dolche', 'daggers', 3, NULL, '300037058', 'closeMatch', '8e23cf21-b1ec-f7c1-f531-f2fdeaf4fb1b');
INSERT INTO cau.type_group (type_group_id, type_group_de, type_group_en, find_class_id, broader_type_group_id, aat_id, aat_match, id_uuid) VALUES (2, 'Schwerter', 'swords', 3, NULL, '300037048', 'closeMatch', 'e07c341a-51fe-9d96-191b-353f287af14b');
INSERT INTO cau.type_group (type_group_id, type_group_de, type_group_en, find_class_id, broader_type_group_id, aat_id, aat_match, id_uuid) VALUES (5, 'Dolchklingen oder Dolche mit organischem Griff', 'dagger blades or daggers with organic handle', NULL, 1, '300037058', 'broadMatch', '7f997a47-1bb1-b180-935f-d2a455b92065');


--
-- Name: analysed_element analysed_element_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysed_element
    ADD CONSTRAINT analysed_element_id_uuid_key UNIQUE (id_uuid);


--
-- Name: analysed_element analysed_element_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysed_element
    ADD CONSTRAINT analysed_element_pkey PRIMARY KEY (literature_id, element_code);


--
-- Name: analysis_method analysis_method_code_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysis_method
    ADD CONSTRAINT analysis_method_code_key UNIQUE (code);


--
-- Name: analysis_method analysis_method_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysis_method
    ADD CONSTRAINT analysis_method_id_uuid_key UNIQUE (id_uuid);


--
-- Name: analysis_method analysis_method_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysis_method
    ADD CONSTRAINT analysis_method_pkey PRIMARY KEY (analysis_method_id);


--
-- Name: chemical_analysis chemical_analysis_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_id_uuid_key UNIQUE (id_uuid);


--
-- Name: chemical_analysis chemical_analysis_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_pkey PRIMARY KEY (chemical_analysis_id, part_id, site_id);


--
-- Name: chronology_system chronology_system_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chronology_system
    ADD CONSTRAINT chronology_system_id_uuid_key UNIQUE (id_uuid);


--
-- Name: chronology_system chronology_system_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chronology_system
    ADD CONSTRAINT chronology_system_pkey PRIMARY KEY (chronology_system_id);


--
-- Name: context_type context_type_code_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.context_type
    ADD CONSTRAINT context_type_code_key UNIQUE (code);


--
-- Name: context_type context_type_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.context_type
    ADD CONSTRAINT context_type_id_uuid_key UNIQUE (id_uuid);


--
-- Name: context_type context_type_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.context_type
    ADD CONSTRAINT context_type_pkey PRIMARY KEY (context_type_id);


--
-- Name: culture culture_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.culture
    ADD CONSTRAINT culture_id_uuid_key UNIQUE (id_uuid);


--
-- Name: culture culture_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.culture
    ADD CONSTRAINT culture_pkey PRIMARY KEY (culture_id);


--
-- Name: element element_chebi_id_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.element
    ADD CONSTRAINT element_chebi_id_key UNIQUE (chebi_id);


--
-- Name: element element_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.element
    ADD CONSTRAINT element_id_uuid_key UNIQUE (id_uuid);


--
-- Name: element element_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.element
    ADD CONSTRAINT element_pkey PRIMARY KEY (element_code);


--
-- Name: element element_sort_order_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.element
    ADD CONSTRAINT element_sort_order_key UNIQUE (sort_order);


--
-- Name: element element_symbol_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.element
    ADD CONSTRAINT element_symbol_key UNIQUE (symbol);


--
-- Name: feature feature_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.feature
    ADD CONSTRAINT feature_id_uuid_key UNIQUE (id_uuid);


--
-- Name: feature feature_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.feature
    ADD CONSTRAINT feature_pkey PRIMARY KEY (feature_id, site_id);


--
-- Name: find_class find_class_code_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find_class
    ADD CONSTRAINT find_class_code_key UNIQUE (code);


--
-- Name: find_class find_class_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find_class
    ADD CONSTRAINT find_class_id_uuid_key UNIQUE (id_uuid);


--
-- Name: find_class find_class_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find_class
    ADD CONSTRAINT find_class_pkey PRIMARY KEY (find_class_id);


--
-- Name: find find_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_id_uuid_key UNIQUE (id_uuid);


--
-- Name: find find_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_pkey PRIMARY KEY (find_id, site_id);


--
-- Name: isotope_ratio isotope_ratio_column_name_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.isotope_ratio
    ADD CONSTRAINT isotope_ratio_column_name_key UNIQUE (column_name);


--
-- Name: isotope_ratio isotope_ratio_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.isotope_ratio
    ADD CONSTRAINT isotope_ratio_id_uuid_key UNIQUE (id_uuid);


--
-- Name: isotope_ratio isotope_ratio_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.isotope_ratio
    ADD CONSTRAINT isotope_ratio_pkey PRIMARY KEY (ratio_code);


--
-- Name: isotope_ratio isotope_ratio_sort_order_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.isotope_ratio
    ADD CONSTRAINT isotope_ratio_sort_order_key UNIQUE (sort_order);


--
-- Name: lab lab_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lab
    ADD CONSTRAINT lab_id_uuid_key UNIQUE (id_uuid);


--
-- Name: lab lab_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lab
    ADD CONSTRAINT lab_pkey PRIMARY KEY (lab_id);


--
-- Name: lead_isotope_analysis lead_isotope_analysis_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_id_uuid_key UNIQUE (id_uuid);


--
-- Name: lead_isotope_analysis lead_isotope_analysis_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_pkey PRIMARY KEY (lead_isotope_analysis_id, site_id);


--
-- Name: literature literature_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.literature
    ADD CONSTRAINT literature_id_uuid_key UNIQUE (id_uuid);


--
-- Name: literature literature_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.literature
    ADD CONSTRAINT literature_pkey PRIMARY KEY (literature_id);


--
-- Name: literature literature_zotero_key_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.literature
    ADD CONSTRAINT literature_zotero_key_key UNIQUE (zotero_key);


--
-- Name: location_certainty location_certainty_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.location_certainty
    ADD CONSTRAINT location_certainty_id_uuid_key UNIQUE (id_uuid);


--
-- Name: location_certainty location_certainty_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.location_certainty
    ADD CONSTRAINT location_certainty_pkey PRIMARY KEY (code);


--
-- Name: material material_code_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.material
    ADD CONSTRAINT material_code_key UNIQUE (code);


--
-- Name: material material_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.material
    ADD CONSTRAINT material_id_uuid_key UNIQUE (id_uuid);


--
-- Name: material material_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.material
    ADD CONSTRAINT material_pkey PRIMARY KEY (material_id);


--
-- Name: part part_code_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.part
    ADD CONSTRAINT part_code_key UNIQUE (code);


--
-- Name: part part_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.part
    ADD CONSTRAINT part_id_uuid_key UNIQUE (id_uuid);


--
-- Name: part part_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.part
    ADD CONSTRAINT part_pkey PRIMARY KEY (part_id);


--
-- Name: period period_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.period
    ADD CONSTRAINT period_id_uuid_key UNIQUE (id_uuid);


--
-- Name: period period_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.period
    ADD CONSTRAINT period_pkey PRIMARY KEY (period_id);


--
-- Name: region region_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.region
    ADD CONSTRAINT region_id_uuid_key UNIQUE (id_uuid);


--
-- Name: region region_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.region
    ADD CONSTRAINT region_pkey PRIMARY KEY (region_id);


--
-- Name: site site_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site
    ADD CONSTRAINT site_id_uuid_key UNIQUE (id_uuid);


--
-- Name: site_period site_period_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site_period
    ADD CONSTRAINT site_period_id_uuid_key UNIQUE (id_uuid);


--
-- Name: site_period site_period_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site_period
    ADD CONSTRAINT site_period_pkey PRIMARY KEY (site_period_id);


--
-- Name: site_period site_period_site_id_period_id_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site_period
    ADD CONSTRAINT site_period_site_id_period_id_key UNIQUE (site_id, period_id);


--
-- Name: site site_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site
    ADD CONSTRAINT site_pkey PRIMARY KEY (site_id);


--
-- Name: type type_code_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type
    ADD CONSTRAINT type_code_key UNIQUE (code);


--
-- Name: type_group type_group_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type_group
    ADD CONSTRAINT type_group_id_uuid_key UNIQUE (id_uuid);


--
-- Name: type_group type_group_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type_group
    ADD CONSTRAINT type_group_pkey PRIMARY KEY (type_group_id);


--
-- Name: type type_id_uuid_key; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type
    ADD CONSTRAINT type_id_uuid_key UNIQUE (id_uuid);


--
-- Name: type type_pkey; Type: CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type
    ADD CONSTRAINT type_pkey PRIMARY KEY (type_id);


--
-- Name: analysed_element analysed_element_delete_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER analysed_element_delete_trigger AFTER DELETE OR UPDATE ON cau.analysed_element DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_analysed_element();


--
-- Name: chemical_analysis chemical_analysis_analysed_element_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER chemical_analysis_analysed_element_trigger AFTER INSERT OR UPDATE ON cau.chemical_analysis DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_analysed_element();


--
-- Name: context_type context_type_applies_to_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER context_type_applies_to_trigger AFTER UPDATE OF applies_to ON cau.context_type DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_context_type();


--
-- Name: feature feature_context_type_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER feature_context_type_trigger AFTER INSERT OR UPDATE OF context_type_id ON cau.feature DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_context_type();


--
-- Name: feature feature_part_of_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER feature_part_of_trigger AFTER INSERT OR UPDATE OF part_of_feature_id, context_type_id ON cau.feature DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_part_of_feature();


--
-- Name: feature feature_period_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER feature_period_trigger AFTER INSERT OR UPDATE OF period_id ON cau.feature DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_find_dating();


--
-- Name: find find_dating_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER find_dating_trigger AFTER INSERT OR UPDATE OF feature_id, site_id ON cau.find DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_find_dating();


--
-- Name: region region_covers_sites_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER region_covers_sites_trigger AFTER UPDATE OF geography ON cau.region DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_site_in_region();


--
-- Name: site site_context_type_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER site_context_type_trigger AFTER INSERT OR UPDATE OF context_type_id ON cau.site DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_context_type();


--
-- Name: site site_in_region_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER site_in_region_trigger AFTER INSERT OR UPDATE OF geometry, region_id ON cau.site DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_site_in_region();


--
-- Name: site_period site_period_dating_trigger; Type: TRIGGER; Schema: cau; Owner: -
--

CREATE CONSTRAINT TRIGGER site_period_dating_trigger AFTER DELETE OR UPDATE OF site_id ON cau.site_period DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION cau.check_find_dating();


--
-- Name: analysed_element analysed_element_element_code_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysed_element
    ADD CONSTRAINT analysed_element_element_code_fkey FOREIGN KEY (element_code) REFERENCES cau.element(element_code) DEFERRABLE;


--
-- Name: analysed_element analysed_element_literature_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.analysed_element
    ADD CONSTRAINT analysed_element_literature_id_fkey FOREIGN KEY (literature_id) REFERENCES cau.literature(literature_id) DEFERRABLE;


--
-- Name: chemical_analysis chemical_analysis_analysis_method_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_analysis_method_id_fkey FOREIGN KEY (analysis_method_id) REFERENCES cau.analysis_method(analysis_method_id) DEFERRABLE;


--
-- Name: chemical_analysis chemical_analysis_find_id_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_find_id_site_id_fkey FOREIGN KEY (find_id, site_id) REFERENCES cau.find(find_id, site_id) DEFERRABLE;


--
-- Name: chemical_analysis chemical_analysis_lab_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_lab_id_fkey FOREIGN KEY (lab_id) REFERENCES cau.lab(lab_id) DEFERRABLE;


--
-- Name: chemical_analysis chemical_analysis_literature_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_literature_id_fkey FOREIGN KEY (literature_id) REFERENCES cau.literature(literature_id) DEFERRABLE;


--
-- Name: chemical_analysis chemical_analysis_part_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chemical_analysis
    ADD CONSTRAINT chemical_analysis_part_id_fkey FOREIGN KEY (part_id) REFERENCES cau.part(part_id) DEFERRABLE;


--
-- Name: chronology_system chronology_system_literature_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.chronology_system
    ADD CONSTRAINT chronology_system_literature_id_fkey FOREIGN KEY (literature_id) REFERENCES cau.literature(literature_id) DEFERRABLE;


--
-- Name: feature feature_context_type_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.feature
    ADD CONSTRAINT feature_context_type_id_fkey FOREIGN KEY (context_type_id) REFERENCES cau.context_type(context_type_id) DEFERRABLE;


--
-- Name: feature feature_part_of_feature_id_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.feature
    ADD CONSTRAINT feature_part_of_feature_id_site_id_fkey FOREIGN KEY (part_of_feature_id, site_id) REFERENCES cau.feature(feature_id, site_id) DEFERRABLE;


--
-- Name: feature feature_period_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.feature
    ADD CONSTRAINT feature_period_id_fkey FOREIGN KEY (period_id) REFERENCES cau.period(period_id) DEFERRABLE;


--
-- Name: feature feature_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.feature
    ADD CONSTRAINT feature_site_id_fkey FOREIGN KEY (site_id) REFERENCES cau.site(site_id) DEFERRABLE;


--
-- Name: find find_feature_id_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_feature_id_site_id_fkey FOREIGN KEY (feature_id, site_id) REFERENCES cau.feature(feature_id, site_id) DEFERRABLE;


--
-- Name: find find_literature_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_literature_id_fkey FOREIGN KEY (literature_id) REFERENCES cau.literature(literature_id) DEFERRABLE;


--
-- Name: find find_material_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_material_id_fkey FOREIGN KEY (material_id) REFERENCES cau.material(material_id) DEFERRABLE;


--
-- Name: find find_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_site_id_fkey FOREIGN KEY (site_id) REFERENCES cau.site(site_id) DEFERRABLE;


--
-- Name: find find_type_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.find
    ADD CONSTRAINT find_type_id_fkey FOREIGN KEY (type_id) REFERENCES cau.type(type_id) DEFERRABLE;


--
-- Name: lead_isotope_analysis lead_isotope_analysis_analysis_method_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_analysis_method_id_fkey FOREIGN KEY (analysis_method_id) REFERENCES cau.analysis_method(analysis_method_id) DEFERRABLE;


--
-- Name: lead_isotope_analysis lead_isotope_analysis_find_id_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_find_id_site_id_fkey FOREIGN KEY (find_id, site_id) REFERENCES cau.find(find_id, site_id) DEFERRABLE;


--
-- Name: lead_isotope_analysis lead_isotope_analysis_lab_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_lab_id_fkey FOREIGN KEY (lab_id) REFERENCES cau.lab(lab_id) DEFERRABLE;


--
-- Name: lead_isotope_analysis lead_isotope_analysis_literature_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_literature_id_fkey FOREIGN KEY (literature_id) REFERENCES cau.literature(literature_id) DEFERRABLE;


--
-- Name: lead_isotope_analysis lead_isotope_analysis_part_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.lead_isotope_analysis
    ADD CONSTRAINT lead_isotope_analysis_part_id_fkey FOREIGN KEY (part_id) REFERENCES cau.part(part_id) DEFERRABLE;


--
-- Name: period period_chronology_system_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.period
    ADD CONSTRAINT period_chronology_system_id_fkey FOREIGN KEY (chronology_system_id) REFERENCES cau.chronology_system(chronology_system_id) DEFERRABLE;


--
-- Name: period period_culture_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.period
    ADD CONSTRAINT period_culture_id_fkey FOREIGN KEY (culture_id) REFERENCES cau.culture(culture_id) DEFERRABLE;


--
-- Name: site site_context_type_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site
    ADD CONSTRAINT site_context_type_id_fkey FOREIGN KEY (context_type_id) REFERENCES cau.context_type(context_type_id) DEFERRABLE;


--
-- Name: site_period site_period_period_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site_period
    ADD CONSTRAINT site_period_period_id_fkey FOREIGN KEY (period_id) REFERENCES cau.period(period_id) DEFERRABLE;


--
-- Name: site_period site_period_site_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site_period
    ADD CONSTRAINT site_period_site_id_fkey FOREIGN KEY (site_id) REFERENCES cau.site(site_id) DEFERRABLE;


--
-- Name: site site_region_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site
    ADD CONSTRAINT site_region_id_fkey FOREIGN KEY (region_id) REFERENCES cau.region(region_id) DEFERRABLE;


--
-- Name: site site_site_location_certainty_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.site
    ADD CONSTRAINT site_site_location_certainty_fkey FOREIGN KEY (site_location_certainty) REFERENCES cau.location_certainty(code) DEFERRABLE;


--
-- Name: type type_find_class_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type
    ADD CONSTRAINT type_find_class_id_fkey FOREIGN KEY (find_class_id) REFERENCES cau.find_class(find_class_id) DEFERRABLE;


--
-- Name: type_group type_group_broader_type_group_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type_group
    ADD CONSTRAINT type_group_broader_type_group_id_fkey FOREIGN KEY (broader_type_group_id) REFERENCES cau.type_group(type_group_id) DEFERRABLE;


--
-- Name: type_group type_group_find_class_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type_group
    ADD CONSTRAINT type_group_find_class_id_fkey FOREIGN KEY (find_class_id) REFERENCES cau.find_class(find_class_id) DEFERRABLE;


--
-- Name: type type_type_group_id_fkey; Type: FK CONSTRAINT; Schema: cau; Owner: -
--

ALTER TABLE ONLY cau.type
    ADD CONSTRAINT type_type_group_id_fkey FOREIGN KEY (type_group_id) REFERENCES cau.type_group(type_group_id) DEFERRABLE;


--
-- PostgreSQL database dump complete
--


