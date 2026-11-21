#!/usr/bin/env bash
# Stage enrich (planning#5), offline: adds what does not come from the database to the Ontop
# output. Today: the literature records from the Zotero snapshot (FaBiO; ingest#12). Later enrichments
# (PeriodO, Pleiades) go here too; every one of them runs before the checks (planning#3).
# Writes out/.build/lod-am.ttl (the graph the check stage validates).
source "$(dirname "$0")/common.sh"
need "$BUILD/ontop.ttl" materialize
db_up
rm -f "$BUILD/lod-am.ttl"
python3 scripts/literature.py records "$BUILD" $PSQL -d $DB
cat "$BUILD/ontop.ttl" "$BUILD/literature.ttl" > "$BUILD/lod-am.tmp.ttl"   # Turtle allows @prefix lines anywhere
mv "$BUILD/lod-am.tmp.ttl" "$BUILD/lod-am.ttl"
echo "enrich: out/.build/lod-am.ttl"
