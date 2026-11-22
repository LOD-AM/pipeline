# LOD-AM data pipeline

Turns the LOD-AM research database into checked Linked Open Data
([LOD-AM/planning#3](https://github.com/LOD-AM/planning/issues/3), private):

```
live PostgreSQL (data LXC, LAN only)
  → snapshot   pg_dump through a read-only role
  → materialize  throwaway PostgreSQL 16 + PostGIS → SQL views → R2RML → Ontop
  → enrich     literature from the public Zotero group (later PeriodO, Pleiades)
  → check      knowledge-graph term check, SHACL, every source row converted or skipped with a reason
  → publish    one checked file per released publication
  → package    out/release/ (released publications + manifest), out/internal/ (full graph, private)
  → triplestore pulls the release (planning#7) → website rebuild
```

**This repository holds code only, no data.** The research database as a whole is private until
the owner releases it. It never leaves the data LXC, and neither do the snapshots, the full graph or
its reports. Only `out/release/` may leave the server, and it holds only the publications the owner
has released. Everything that knows about the data's meaning lives elsewhere: modelling rules in
[LOD-AM/knowledge-graph](https://github.com/LOD-AM/knowledge-graph) (`CONVENTIONS.md`, shapes),
the owner's data decisions and correction rounds in the private LOD-AM/ingest.

## Stages
| Stage | Needs | Input → output |
|---|---|---|
| `fetch` | internet | Zotero group 6765723 → `.cache/zotero/` (+ library version); Ontop CLI + JDBC (Maven Central) → `.cache/ontop/<hash of pom.xml>/`; CRM/AFO/FaBiO → knowledge-graph `.cache/` (all built into the image) |
| `snapshot` | the database | live database, schema `cau` → `out/snapshots/<UTC time>.sql` + `.json` (sha256, time, server version), `latest.sql` points to it; an unchanged database is not stored twice |
| `materialize` | nothing | snapshot (or `DUMP=<file>`) → throwaway PostgreSQL 16 + PostGIS (127.0.0.1:5498) → `mapping/views.sql` → R2RML → Ontop → `out/.build/ontop.ttl`, skip report |
| `enrich` | nothing | + FaBiO records of the cited literature from the Zotero snapshot → `out/.build/lod-am.ttl` |
| `check` | nothing | knowledge-graph `tools/check_terms.py` + `tools/validate.py` (SHACL), `scripts/test_materialize.py` → `checks.json` only if all pass |
| `publish` | nothing | each released publication: `scripts/export_publication.py` (its finds and analyses and what they point to, with a privacy guard), checked again → `out/.build/published/` |
| `package` | nothing | → `out/release/` and `out/internal/`, each swapped in with one rename; the previous ones stay as `*.prev/` |

`make release` = materialize → enrich → check → publish → package; it runs offline. A failed stage
or check leaves `out/release/` and `out/internal/` as they were, and an empty result is never
packaged. A full run takes about 12 minutes, almost all of it SHACL on ~330,000 triples.

**Which publications are released** is decided in the database: `cau.literature.released_on`
(a date; planning#27). Until that column exists, `config/released-publications.txt` stands in for
it (currently `hauptmann2002chemical`, already on lod-am.net).

**manifest.json** (`out/release/`) traces every file to its inputs: the snapshot (sha256, time),
the pipeline commit and image, the knowledge-graph commit, the Zotero library version, and per
publication its triples and hashes (`canonical_sha256` = sha256 of the sorted N-Triples, the same
for the same graph). `out/internal/manifest.json` adds the full graph's counts and hashes.
`RELEASE_STRICT=1` refuses a release from uncommitted code or an untraceable source.

## On the data LXC (owner)
Once, as the owner, in the research database (the password goes only into `.env`):
```sql
CREATE ROLE lodam_pipeline LOGIN PASSWORD 'change-me';
GRANT CONNECT ON DATABASE <database> TO lodam_pipeline;
GRANT USAGE ON SCHEMA cau TO lodam_pipeline;
GRANT SELECT ON ALL TABLES IN SCHEMA cau TO lodam_pipeline;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA cau TO lodam_pipeline;   -- pg_dump reads sequence values
ALTER DEFAULT PRIVILEGES IN SCHEMA cau GRANT SELECT ON TABLES TO lodam_pipeline;
ALTER DEFAULT PRIVILEGES IN SCHEMA cau GRANT SELECT ON SEQUENCES TO lodam_pipeline;
```
Run the grants **in the research database itself** (pgAdmin: right-click that database → Query
Tool; `SELECT current_database();` shows where you are). `CREATE ROLE` works from any database, so
the role shows up even when the grants went elsewhere, and `pg_dump` then fails with
`permission denied for schema cau`. Check (all three `true`):
```sql
SELECT has_schema_privilege('lodam_pipeline', 'cau', 'USAGE'),
       has_table_privilege('lodam_pipeline', 'cau.site', 'SELECT'),
       has_table_privilege('lodam_pipeline', 'cau.site', 'UPDATE') = false;
```
**After re-importing a dump** that drops and recreates schema `cau` (the correction rounds of
planning#27), the grants are gone: run the `GRANT` and `ALTER DEFAULT PRIVILEGES` lines again.

Then:
```bash
git clone https://github.com/LOD-AM/pipeline ~/pipeline && cd ~/pipeline
cp .env.example .env && chmod 600 .env      # fill in database name and password
docker build -t lod-am-pipeline .
docker run --rm --network host --user "$(id -u):$(id -g)" --env-file .env -v "$PWD:/work" \
  lod-am-pipeline fetch snapshot release
```
`RELEASE_STRICT=1` (`-e RELEASE_STRICT=1`) is for scheduled runs. `out/snapshots/` grows by one file
per changed database; delete old snapshots by hand when they are no longer needed for tracing.
Scheduling, and handing the release to the triplestore, follow in planning#6 and #7.

## Elsewhere (owner's machine, with a dump file)
```bash
make fetch                                   # needs Java 17+, Maven, PostgreSQL 16 + PostGIS, Python (docker/requirements.txt)
make release DUMP=../ingest/lod-am.sql KG=../knowledge-graph
make test-pipeline                           # package rules, no database needed
```
or with the image: `docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -v /path/to/dump.sql:/dump.sql:ro lod-am-pipeline release DUMP=/dump.sql`.

## Files
- `Makefile`, `scripts/stages/`: the stages; `scripts/`: Zotero, literature, source-row test, publication export
- `mapping/`: SQL views + R2RML ([`mapping/README.md`](mapping/README.md)), `pom.xml` (Ontop)
- `config/released-publications.txt`: stand-in for the database's release flag
- `Dockerfile`, `docker/`: the build image ([`docker/README.md`](docker/README.md))
- `.github/workflows/ci.yml`: tests and image build, **without data** (the database never reaches GitHub)

## Licence
[MIT](LICENSE). The data the pipeline produces is not part of this repository; external ontologies
and vocabularies are subject to their own licences.
