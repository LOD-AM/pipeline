# CLAUDE.md: LOD-AM pipeline

**Public repo, code only.** The data pipeline of LOD-AM (planning#3): live research database →
snapshot → Ontop → enrichment → checks → released publications. Overview, stages and server
setup: [README.md](README.md). Moved here from the private LOD-AM/ingest on 2026-11-21 (owner),
as a fresh start without ingest's history (that history contains the database dumps).

## Confidentiality (most important rule here)
- This repository is **public**. The research database as a whole is private until the owner
  releases it (ingest `CLAUDE.md`). Never commit a dump, a snapshot, generated RDF of the data,
  bulk extracts or reports of a real run (`out/` is gitignored). Single example rows are fine.
- Public CI has **no data**: the database is LAN-only (planning#26) and never reaches GitHub. Real
  runs happen on the data LXC. Never add a self-hosted runner (pull requests could run code there).
- Only `out/release/` may leave the server, and it holds only released publications. Never put the
  full graph or figures about it (triple counts, skip or SHACL counts) into the release.
- Which publications are released is the owner's decision, recorded in the database
  (`cau.literature.released_on`, planning#27; until then `config/released-publications.txt`).
  Change that file only on the owner's word.

## Checks
```bash
make test-pipeline                                   # package/publish rules, no database
make test-deploy                                     # deploy/run.sh control flow (stubbed docker/curl)
bash -n scripts/stages/*.sh deploy/*.sh docker/entrypoint.sh
shellcheck -S warning scripts/stages/*.sh deploy/*.sh docker/entrypoint.sh
bash scripts/check_shared_block.sh                   # shared block vs knowledge-graph
```
A full run needs a dump: `make fetch`, then `make release DUMP=<dump.sql> KG=../knowledge-graph`
(PostgreSQL 16 + PostGIS, Java 17+, Maven, Python from `docker/requirements.txt`). In a cloud
session the private dump is in a checkout of LOD-AM/ingest (`lod-am.sql`), if that repo is
attached: use it only locally, never copy anything from it into this repo. There is no Docker daemon in
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
  `scripts/update_published.sh`), loads it and hands it to the website as a "Data release" PR. Peak memory
  1.27 GB (SHACL), a run takes ~40 min. Exports use knowledge-graph's canonical prefixes (#14), so the same
  triples give the same file. Still to confirm (planning#33): a run with nothing new ends with `unchanged`.
- Next: the release flag in the database (planning#27 round 3), alerts on failure (planning#34), a public
  fixture (from the released `hauptmann2002chemical`) so CI can run a whole release without private data.

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
