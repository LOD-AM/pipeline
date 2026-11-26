# Converter build image (planning#4)

One image that runs the pipeline's `make` stages ([`../README.md`](../README.md)) identically on the
data LXC (the real runs), on the owner's machine and in CI (`.github/workflows/ci.yml`, without data).

```bash
docker build -t lod-am-pipeline .
docker run --rm --network host --user "$(id -u):$(id -g)" --env-file .env -v "$PWD:/work" \
  lod-am-pipeline fetch snapshot release
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" lod-am-pipeline test-pipeline   # any make target
```
Run it from the pipeline checkout. The output lands in `out/` of the checkout and belongs to your user.
`fetch` needs the internet (Zotero only; everything else is built into the image), `snapshot` the
database (`--network host` reaches Postgres on the same LXC), `release` neither.

## What is in it, and what is not
| Part | Version | Pinned by |
|---|---|---|
| PostgreSQL 16 + PostGIS 3.6 (Debian trixie) | `postgis/postgis:16-3.6` | digest in `Dockerfile` (Dependabot) |
| Java 17 (Temurin JRE) | `17.0.20.1_1` | digest in `Dockerfile` (Dependabot) |
| Ontop CLI, PostgreSQL JDBC | 5.5.0, 42.7.4 | `mapping/pom.xml` (Dependabot), fetched at build time |
| Apache Jena command-line tools (SHACL validation) | 5.6.0 (6 needs Java 21) | `shacl/pom.xml` (Dependabot), fetched at build time |
| Python 3.13 (Debian), rdflib, pyshacl + dependencies | 7.6.0, 0.40.2 | `docker/requirements.txt` with hashes (Dependabot) |
| knowledge-graph tools, shapes, vocabularies + ontology files | commit `KG_COMMIT` | `Dockerfile` (bump by hand, in its own PR) |

**No data:** the build context is only `docker/`, `mapping/pom.xml` and `shacl/pom.xml` (`.dockerignore`). Snapshots,
the Zotero snapshot and `out/` stay in the mounted checkout, so the image can be published without
exposing the database.

## Notes
- The image refuses to run as root. With `--user` it runs as any uid; PostgreSQL's `initdb` gets a
  passwd entry for an unknown uid through nss_wrapper (`docker/entrypoint.sh`).
- `PIPELINE_IMAGE` (build arg) goes into `manifest.json`; CI sets it to the commit.
- A knowledge-graph bump can bring new shapes that reject data. Change `KG_COMMIT` in its own PR and
  run a release on the data LXC to see the check results.
- A Dependabot bump of PostGIS, Ontop or rdflib must leave the full graph's `canonical_sha256`
  (`out/internal/manifest.json`) unchanged on the data LXC, unless the PR says why the graph changes.
