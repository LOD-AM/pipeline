# CLAUDE.md: LOD-AM pipeline

**Public repo, code only.** The data pipeline of LOD-AM (planning#3): live research database →
snapshot → Ontop → enrichment → checks → released publications. Overview, stages and server
setup: [README.md](README.md). Moved here from the private LOD-AM/ingest on 2026-11-21 (owner),
as a fresh start without ingest's history (that history contains the database dumps).

## Confidentiality (most important rule here)
- This repository is **public**. The research database as a whole is private until the owner
  releases it (ingest `CLAUDE.md`). Never commit a dump, a snapshot, generated RDF of the data,
  bulk extracts or reports of a real run (`out/` is gitignored). Single example rows are fine.
  The one exception is `tests/fixture/`: a released publication's rows only, built by
  `scripts/make_fixture.py` and proved public by `make test-fixture` (check 3); README "Public CI fixture".
- Public CI has **no data**: the database is LAN-only (planning#26) and never reaches GitHub. Real
  runs happen on the data LXC. Never add a self-hosted runner (pull requests could run code there).
- Only `out/release/` may leave the server, and it holds only released publications. Never put the
  full graph or figures about it (triple counts, skip or SHACL counts) into the release.
- Which publications are released is the owner's decision, recorded in the database
  (`cau.literature.released_on`, planning#27 round 3). Set or change it only on the owner's word.

## Checks
```bash
make test-pipeline                                   # package/publish rules, no database
make test-deploy                                     # deploy/run.sh control flow (stubbed docker/curl)
make test-fixture                                    # whole release on tests/fixture/ (needs `make fetch` outside the image)
bash -n scripts/*.sh scripts/stages/*.sh deploy/*.sh deploy/database/*.sh docker/entrypoint.sh
shellcheck -S warning scripts/*.sh scripts/stages/*.sh deploy/*.sh deploy/database/*.sh docker/entrypoint.sh
(cd deploy/database && cp .env.example .env && docker compose config -q; rm .env)   # database stack
bash scripts/check_shared_block.sh                   # shared block vs knowledge-graph
```
A full run needs a dump: `make fetch`, then `make release DUMP=<dump.sql> KG=../knowledge-graph`
(PostgreSQL 16 + PostGIS, Java 17+, Maven, Python from `docker/requirements.txt`). In a cloud
session the private dump is in a checkout of LOD-AM/ingest (`lod-am.sql`), if that repo is
attached: use it only locally, never copy anything from it into this repo (except through
`scripts/make_fixture.py`, see Confidentiality). There is no Docker daemon in
cloud sessions; CI builds the image. A converter change must keep the full graph's
`canonical_sha256` (`out/internal/manifest.json`) unchanged unless the change is meant to alter
the graph: say which triples change and why in the PR.

## Rules
- Modelling follows knowledge-graph `CONVENTIONS.md` and its shapes; never invent ontology terms
  (see knowledge-graph `CLAUDE.md` for lookups). What a column or value means is the owner's
  decision (ingest `docs/decisions.md`): ask, don't guess.
- Never overwrite a release or the internal output with empty or partial results; every source
  row is converted or in the skip report with its reason.
- Issue references: `ingest#<n>` (private), `planning#<n>` (private), `knowledge-graph#<n>`.
- Versions are pinned (base images by digest, Python with hashes, Ontop by BOM, knowledge-graph
  by `KG_COMMIT`). Dependabot proposes bumps; bump `KG_COMMIT` by hand, in its own PR.
- Licence: MIT (`LICENSE`, owner 2026-11-21), the same text as knowledge-graph's code licence.

## Where to resume (state 2026-11-22, evening)
- Moved from ingest (LOD-AM/ingest#47: stages, manifest, build image; verified there: image in CI
  gave the same graph as local runs, canonical sha256 `b82fc318…`, 331,903 triples). New here:
  `snapshot` and `publish` stages, release = released publications only, `out/internal/`.
- Data LXC (owner, 2026-11-22): read-only role, Docker, first complete run by hand: full graph
  `canonical_sha256` `b82fc318…`, 331,903 triples, identical to the ingest dump's graph. The first attempt was
  killed for lack of memory (exit 137 in the term check at 1 GB); the LXC now has 3 GB RAM + 1 GB swap. Scheduled run: `deploy/` (planning#6), installed by the owner with `deploy/install.sh`.
- Chain live since 2026-11-22 (planning#3): nightly run 03:17 → `deploy/run.sh` copies each release to
  `LODAM_PUBLISH_DIR` (/srv/lodam/release, world-readable) → webhook POST /lodam-release (bearer token,
  `{"manifest_sha256"}`) → the triplestore pulls with rsync over SSH (`rrsync -ro`, LOD-AM/triplestore
  `scripts/update_published.sh`), loads it and hands it to the website as a "Data release" PR. Exports use knowledge-graph's canonical prefixes (#14), so the same
  triples give the same file. A run with nothing new ends with `unchanged` (confirmed, planning#33).
- Alerts on failure (planning#34): `deploy/alert.sh` via `OnFailure=lodam-alert@%n` in `lodam-pipeline.service`
  (curl SMTP, `LODAM_ALERT_*` in `.env`; identical copy in LOD-AM/triplestore). Live and tested by the owner (2026-11-22).
- Database overhaul (planning#27): the views follow ingest's schema rounds; each round is checked with `make baseline` /
  `make compare` (README "Schema rounds"). Done: renames (round 1), constraints (2), explicit semantics (3: the release
  flag `cau.literature.released_on` is the only release switch; `analysed_element`, codes, reference tables; analysis
  remarks as `P3_has_note`, full graph `4289f5d3…`), site point as `site.geometry` (5). A view change lands together
  with the owner's run of the round's SQL (the nightly run pulls `main`).
- Round 4 (reported numbers only, 2026-11-25, on ingest's twenty-fifth dump): the views publish only
  `find_no_reported` / `analysis_no_reported`; `-` (the publication gives none) = no identifier, label without a
  number (`lodam_rdf.reported`); no internal id reaches the RDF. Full graph `9dce1017…` (the owner's corrections in
  the same dump: `3205a088…` with the old views). Fixture rebuilt. All rounds of planning#27 done once it is deployed.
  Since 2026-11-23 CI runs a whole release on the fixture (planning#36); rebuild it after every schema round.
- `main` protected (owner, 2026-11-26; required checks `test-pipeline`, `image`, `shared-block`), and
  `deploy/run.sh` takes a new `main` only once its check runs on GitHub passed (planning review
  2026-11-25, 5.2; `test_deploy.sh` 10–12).
- The research database runs the stack in `deploy/database/` since 2026-11-26 (owner; `postgis/postgis:16-3.6`,
  migrated from the frozen `kartoza/postgis:16-3.4`, i.e. 16.2): the next full graph had the same `canonical_sha256`
  `9dce1017…`. Its README has the migration as it worked (peer login for the dump, passwords re-set).
- SHACL with Jena 5.6.0 (`scripts/shacl.py`, jars from `shacl/pom.xml`; planning review 2026-11-25, section 6) instead of
  pySHACL, which took 34 of the 38 minutes of a run on the LXC and 1.3 GB: locally 13 s and 0.53 GB on the full graph (Java 17),
  the same results (graph `9dce1017…`, 0 violations, 2,097 warnings). `make test-fixture` check 4 compares both.
  Peak memory of a run is now `check_terms` (~0.8 GB). Jena 6 needs Java 21; the image stays on Java 17 for Ontop.

## LOD-AM project (shared block: keep identical in every repo)
Source of truth: knowledge-graph `CLAUDE.md`. Edit it there first, then copy it unchanged; CI (`scripts/check_shared_block.sh`) fails on drift.
LOD-AM = Linked Open Data for Ancient Metallurgy, a one-person research project (https://lod-am.net).
- `LOD-AM/knowledge-graph`: data model, vocabularies, converters, data. **Authority for all modelling rules** (`CONVENTIONS.md`).
- `LOD-AM/triplestore`: Apache Jena Fuseki (Docker) that serves the knowledge graph.
- `LOD-AM/ingest` (**private**): the owner's research database (dump), its checks and correction rounds; the database as a whole stays private until the owner says otherwise.
- `LOD-AM/pipeline`: the data pipeline, code only (database snapshot → R2RML/Ontop → enrichment → checks → released publications); runs on the data LXC, never with data on GitHub.
- `LOD-AM/website`: Eleventy site and blog, self-hosted.
- `LOD-AM/planning` (**private**): project management for all repos: one issue per task, state in labels (see its README).
- `LOD-AM/ontologies`, `vocabularies`, `converter`: **superseded** by knowledge-graph; don't edit.

Rules for every repo:
- Base IRI `https://lod-am.net/id/`; CIDOC CRM **7.1.3**. Don't restate modelling rules elsewhere; link to knowledge-graph `CONVENTIONS.md`.
- Work on a branch and open a PR to `main`; never push to `main`. Create issues, PRs or comments only when asked.
- Domain/modelling decisions belong to the owner: raise them as `LOD-AM/planning` issues (label `modelling`) instead of deciding silently.
- Never commit secrets (passwords, SMTP credentials, `.env`, `shiro.ini`).
- English for code, docs and commits. Keep commits small and explain *why*.
- Verify before you claim: run the repo's checks and report what you ran.
- Open work lives in `LOD-AM/planning` (issues with `status:`/`area:` labels; keep them true);
  PRs reference it (`Closes LOD-AM/planning#<n>`). Each CLAUDE.md's "Where to resume" keeps only
  repo-specific notes. The owner merges PRs; after a merge, start new work from the updated `main`.
