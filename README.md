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
| `publish` | nothing | each released publication: `scripts/export_publication.py` (one parse of the full graph for all of them) (its finds and analyses and what they point to, with a privacy guard), checked again → `out/.build/published/` |
| `package` | nothing | → `out/release/` and `out/internal/`, each swapped in with one rename; the previous ones stay as `*.prev/` |

`make release` = materialize → enrich → check → publish → package; it runs offline. A failed stage
or check leaves `out/release/` and `out/internal/` as they were, and an empty result is never
packaged. A full run on ~330,000 triples takes about 40 minutes on the data LXC (2 cores; SHACL alone ~32 min,
on one core) and about 12 minutes on a faster machine.

**Which publications are released** is decided in the database: `cau.literature.released_on`
(a date; planning#27 round 3): set and not in the future = released, a future date schedules the
release (currently `hauptmann2002chemical`, released on 2026-11-17). The history is in ingest
`docs/decisions.md`.

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

**Scheduled runs** (nightly, only when something changed): [`deploy/README.md`](deploy/README.md).
Handing the release to the triplestore: planning#7.

## Memory
The checks hold the whole graph in memory (rdflib). Measured with 331,903 triples: SHACL peaks at
**~1.3 GB** (9 min), the term check, export and package at 0.6–0.8 GB, the throwaway Postgres ~0.2 GB.
The data LXC needs **3 GB RAM + 1 GB swap** today (with the live Postgres); too little shows as
`Killed` and exit code 137. Rule of thumb: ~4 GB of SHACL peak per million triples, growing with
the database, not with the number of released publications. Every release records the peak per
step in `out/internal/manifest.json` (`resources`), so the trend is visible run by run.

## Elsewhere (owner's machine, with a dump file)
```bash
make fetch                                   # needs Java 17+, Maven, PostgreSQL 16 + PostGIS, Python (docker/requirements.txt)
make release DUMP=../ingest/lod-am.sql KG=../knowledge-graph
make test-pipeline                           # package rules, no database needed
```
or with the image: `docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" -v /path/to/dump.sql:/dump.sql:ro lod-am-pipeline release DUMP=/dump.sql`.

## Schema rounds of the research database (planning#27)
The database is restructured in rounds (renames, constraints, explicit semantics, …). Each round is
a fix script in LOD-AM/ingest plus the matching change of `mapping/` here, and it must give **the same
graph**, except for the changes the round intends (listed per round in planning#27). How a round
shows that, with the dump before and after the round:
```bash
make release DUMP=../ingest/lod-am.sql KG=../knowledge-graph     # before the round (ingest main)
make baseline                                 # out/baseline/: full graph + manifest of "before"
# apply the round's fix script to the dump, change mapping/ to the new names
make release DUMP=<dump after the round> KG=../knowledge-graph
make compare                                  # "the same graph" (exit 0), or what changed (exit 1)
```
`make compare` (`scripts/compare_graphs.py`) groups removed and added triples by record kind and
predicate, with examples. Use the same Zotero snapshot (`.cache/zotero`) and `KG_COMMIT` for both
builds, so that only the round can make a difference. Baseline and report are private like all of
`out/`: never commit them. A PR gives the canonical sha256 of both graphs and the intended changes,
with single example triples at most.

## Public CI fixture (`tests/fixture/`)
Public CI has no data, so it runs a whole release on a **fixture**: the rows of one released
publication (`hauptmann2002chemical`) and the rows they point to, with that publication's Zotero items
and the file the server released (`expected.ttl`). `make test-fixture` (in CI inside the image, with
`--network none`) builds a release from it in a scratch copy and checks that
1. the release holds only that publication and the manifest,
2. the released file is the same graph as `expected.ttl`,
3. the full graph from the fixture has no triple that is not in the released file, so the fixture
   holds nothing that isn't public already.

A converter change that alters the released file fails 2: update `expected.ttl` in the same PR and
say which triples change and why. **After a schema round** (planning#27) the fixture's dump no longer
loads into the new views: rebuild it from the dump after the round, and check 3 again before committing:
```bash
make fetch-zotero
scripts/make_fixture.py ../ingest/lod-am.sql hauptmann2002chemical tests/fixture/hauptmann2002chemical
cp out/release/published/hauptmann2002chemical.ttl tests/fixture/hauptmann2002chemical/expected.ttl  # from a full run of the same dump
make test-fixture
```
Check 3 compares triples only. Columns the mapping doesn't turn into RDF still travel in the dump, so
look at the diff of `dump.sql` before committing it. Today these are internal uuids, codes, citation
strings, `released_on` and a feature's name as recorded.

## Files
- `scripts/compare_graphs.py`: two full graphs, same or what changed (schema rounds, planning#27)
- `Makefile`, `scripts/stages/`: the stages (`measure.py` records memory and time, `changed.py` decides whether
  a scheduled run needs a release); `scripts/`: Zotero, literature, source-row test, publication export
- `deploy/`: the scheduled run on the data LXC (`run.sh`, systemd units, `install.sh`, `test_deploy.sh`);
  `deploy/database/`: the research database's own Docker stack (compose file, daily dumps, migration steps)
- `mapping/`: SQL views + R2RML ([`mapping/README.md`](mapping/README.md)), `pom.xml` (Ontop)
- `Dockerfile`, `docker/`: the build image ([`docker/README.md`](docker/README.md))
- `tests/fixture/`, `scripts/make_fixture.py`, `scripts/test_fixture.sh`: the public CI fixture (above)
- `.github/workflows/ci.yml`: tests and image build, **without data** (the database never reaches GitHub)

## Licence
[MIT](LICENSE). The data the pipeline produces is not part of this repository; external ontologies
and vocabularies are subject to their own licences.
