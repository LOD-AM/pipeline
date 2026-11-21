# Mapping: SQL views + R2RML (ingest#14)

The owner chose the "middle path": SQL views + R2RML, materialised with the Ontop CLI
(how the stages run: [`../README.md`](../README.md)). The modelling rules are knowledge-graph
[`CONVENTIONS.md`](https://github.com/LOD-AM/knowledge-graph/blob/main/CONVENTIONS.md); the owner's
data decisions the views implement are in the private LOD-AM/ingest (`docs/decisions.md`).

| File | Role |
|---|---|
| `views.sql` | Schema `lodam_rdf`, built in the throwaway database only: the owner's rules (ingest `docs/decisions.md`), IRIs (`/id/<kind>/<uuid>`, knowledge-graph#20), labels, and the `skip` view (every source row not converted, with the reason) |
| `lod-am.r2rml.ttl` | Which view column becomes which triple; patterns from knowledge-graph `CONVENTIONS.md` |
| `native-labels.r2rml.ttl.in` | One copy per language of `site_native` (R2RML has only a constant `rr:language`) |
| `../scripts/fetch_zotero.py` | Snapshot of the owner's public Zotero group with its library version (`.cache/zotero/`; `make fetch-zotero`) |
| `../scripts/literature.py` | From the snapshot, offline: the citation key → publication IRI table (`map`) and the FaBiO records (`records`) |
| `../scripts/stages/` | The stages behind `make` (below) and their test (`make test-pipeline`) |
| `pom.xml` | Fetches the Ontop CLI and the PostgreSQL JDBC driver from Maven Central into `.cache/ontop/<hash of pom.xml>/`, with Ontop's own dependency versions (its parent POM as BOM, so the jar set equals the official Ontop CLI's) |

## Coverage
| Step | Status |
|---|---|
| Sites, places, geometry, regions (with polygons), site types, name as reported, location certainty | done |
| Features (types, kurgans, notes), dating (`period_id`, `site_period`), phases with time-spans in their chronology system (which names its source publication, `dcterms:source`), cultures consisting of their phases | done |
| Typology (SKOS, broader, AAT matches); finds (local type, context, old identifier, drawing number, notes) | done |
| Materials (copper-base → AAT), object parts, labs | done |
| Literature: FaBiO from the public Zotero group (`scripts/literature.py`), links from finds and analyses | done |
| Samples, chemical analyses, measurements (not detected / not analysed / Cu rule) | done |
| Lead isotope analyses | done |

