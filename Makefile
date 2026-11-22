# LOD-AM data pipeline (planning#3): research database → Ontop → enrichment → checks → release.
#   make fetch      network: Zotero snapshot, Ontop + JDBC jars, knowledge-graph ontologies
#   make snapshot   the live database (read-only role, PG* variables) → out/snapshots/latest.sql
#   make release    offline: materialize → enrich → check → publish → package
#                   → out/release/ (released publications + manifest) and out/internal/ (full graph)
# Each stage can also be run alone (in this order) to debug it; its input is the previous stage's
# output in out/.build/. Only `package` touches out/release/ and out/internal/, and only after every
# check passed. Everything in out/ except out/release/ is private: the database as a whole.
# Env: DUMP (default: out/snapshots/latest.sql), KG=../knowledge-graph, ONTOP_LIB, PG_BIN, WORKDIR=/tmp,
#      RELEASE_STRICT=1 (server runs). The build image (Dockerfile) sets KG, ONTOP_LIB and PG_BIN.
DUMP ?=
KG ?= ../knowledge-graph
PY ?= python3
# Ontop jars per mapping/pom.xml version: a changed pom fetches into a new directory, so a stale
# jar set is never used (old directories can be deleted by hand)
ONTOP_LIB ?= $(CURDIR)/.cache/ontop/$(shell sha256sum mapping/pom.xml | cut -c1-16)
export KG ONTOP_LIB

.PHONY: release fetch fetch-zotero fetch-ontop fetch-kg snapshot changed materialize enrich check publish package baseline compare test-pipeline test-deploy clean

release: materialize enrich check publish package

fetch: fetch-zotero fetch-ontop fetch-kg

fetch-zotero:        ## owner's public Zotero group → .cache/zotero (+ library version)
	$(PY) scripts/fetch_zotero.py

fetch-ontop:         ## Ontop CLI + PostgreSQL JDBC driver (Maven Central) → .cache/ontop/<pom hash> (in the image: built in)
	@if ls $(ONTOP_LIB)/ontop-cli-*.jar > /dev/null 2>&1; then echo "cached: Ontop jars"; \
	else mvn -q -f mapping/pom.xml dependency:copy-dependencies -DoutputDirectory=$(ONTOP_LIB); fi

fetch-kg:            ## ontologies the knowledge-graph checks need → $(KG)/.cache
	bash $(KG)/tools/fetch_ontologies.sh

snapshot:            ## live research database (read-only) → out/snapshots/<time>.sql, latest.sql
	bash scripts/stages/snapshot.sh

changed:             ## inputs changed since the live release? → out/run-decision.txt (deploy/run.sh)
	$(PY) scripts/stages/changed.py

materialize:         ## dump → Postgres → views → R2RML → Ontop (out/.build/ontop.ttl, skip report)
	bash scripts/stages/materialize.sh $(DUMP)

enrich:              ## + literature records from the Zotero snapshot (out/.build/lod-am.ttl)
	bash scripts/stages/enrich.sh

check:               ## terms, SHACL, source rows vs. output (out/.build/checks.json)
	bash scripts/stages/check.sh

publish:             ## one checked file per released publication (out/.build/published/)
	bash scripts/stages/publish.sh

package:             ## → out/release/ + out/internal/ (previous: *.prev/)
	$(PY) scripts/stages/package.py

# Schema rounds of the research database (planning#27): every round must give the same graph except
# for its intended changes. `make baseline` keeps the current full graph; after the round's release,
# `make compare` lists what changed. Both stay in out/ (private, never committed).
BASELINE ?= out/baseline
baseline:            ## keep out/internal/ (full graph + manifest) as $(BASELINE)/ for `make compare`
	@test -f out/internal/lod-am.ttl || { echo "FAIL: no out/internal/lod-am.ttl; run make release first"; exit 1; }
	rm -rf $(BASELINE) && mkdir -p $(BASELINE) && cp out/internal/lod-am.ttl out/internal/manifest.json $(BASELINE)/
	@$(PY) -c "import json,sys; g=json.load(open(sys.argv[1]))['graph']; print('baseline:', g['triples'], 'triples, canonical sha256', g['canonical_sha256'])" $(BASELINE)/manifest.json

compare:             ## $(BASELINE)/lod-am.ttl vs. out/internal/lod-am.ttl: same graph, or what changed (exit 1)
	$(PY) scripts/compare_graphs.py $(BASELINE)/lod-am.ttl out/internal/lod-am.ttl

test-pipeline:       ## package/publish rules: a failed check never replaces a release (no database)
	bash scripts/stages/test_pipeline.sh
	bash scripts/test_compare_graphs.sh

test-deploy:         ## deploy/run.sh control flow with stubbed docker and curl (no server needed)
	bash deploy/test_deploy.sh
	bash deploy/test_alert.sh

clean:               ## remove the scratch directory (never a release or a snapshot)
	rm -rf out/.build
