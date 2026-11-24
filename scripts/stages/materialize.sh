#!/usr/bin/env bash
# Stage materialize (planning#5), offline:
#   dump → throwaway PostgreSQL 16 + PostGIS → views (mapping/views.sql)
#        → R2RML (mapping/lod-am.r2rml.ttl) → Ontop CLI → out/.build/ontop.ttl + skip-report.csv
# Needs `make fetch` (Ontop jars in .cache/ontop/<pom hash> or ONTOP_LIB, Zotero snapshot in .cache/zotero).
# The cluster keeps running for the check stage (test_materialize.py compares with the database).
# Usage: scripts/stages/materialize.sh [dump.sql]     (default: out/snapshots/latest.sql, `make snapshot`)
source "$(dirname "$0")/common.sh"
if [ -n "${1:-}" ]; then DUMP=$(realpath "$1")
elif [ -e "$SNAP/latest.sql" ]; then DUMP=$(realpath "$SNAP/latest.sql")   # the snapshot file itself
else echo "FAIL: no input: run \`make snapshot\` (live database) or pass DUMP=<dump.sql>" >&2; exit 1; fi
[ -s "$DUMP" ] || { echo "FAIL: $DUMP is empty or missing" >&2; exit 1; }
ls "$LIB"/ontop-cli-*.jar > /dev/null 2>&1 || { echo "FAIL: Ontop jars missing; run \`make fetch\`" >&2; exit 1; }
rm -rf "$BUILD"; mkdir -p "$BUILD"
echo "$DUMP" > "$BUILD/dump.path"     # for the manifest

# Throwaway cluster on 127.0.0.1 (JDBC needs TCP), trust auth, local only
mkdir -p "$WORK"; [ "$(id -u)" = 0 ] && chown postgres "$WORK"
[ -d "$WORK/data" ] || run "$BIN/initdb -D '$WORK/data' -A trust -U postgres" > /dev/null
if ! run "$BIN/pg_ctl -D '$WORK/data' status" > /dev/null 2>&1; then
  run "$BIN/pg_ctl -D '$WORK/data' -o \"-k '$WORK' -p $PORT -c listen_addresses=127.0.0.1\" -l '$WORK/log' -w start" > /dev/null
fi
$PSQL -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
$PSQL -d $DB -c "CREATE EXTENSION postgis"
$PSQL -d $DB -f "$DUMP" > /dev/null
# Citation key -> publication IRI, from the Zotero snapshot (ingest#12); the views link finds and analyses with it
python3 scripts/literature.py map "$BUILD" $PSQL -d $DB
$PSQL -d $DB -c "DROP SCHEMA IF EXISTS lodam_lit CASCADE" -c "CREATE SCHEMA lodam_lit" \
  -c "CREATE TABLE lodam_lit.publication (zotero_key text PRIMARY KEY, publication_iri text NOT NULL)" \
  -c "\\copy lodam_lit.publication FROM '$BUILD/publication.csv' CSV"
$PSQL -d $DB -f mapping/views.sql

# Mapping: the main file plus one native-label map per language present
cp mapping/lod-am.r2rml.ttl "$BUILD/mapping.ttl"
for lang in $($PSQL -d $DB -At -c "SELECT lang FROM lodam_rdf.site_native_label UNION SELECT native_lang FROM lodam_rdf.lab WHERE native_lang IS NOT NULL ORDER BY 1"); do
  [[ $lang =~ ^[a-z]{2}$ ]] || { echo "bad language code: $lang" >&2; exit 1; }
  sed "s/@LANG@/$lang/g" mapping/native-labels.r2rml.ttl.in >> "$BUILD/mapping.ttl"
done

cat > "$BUILD/ontop.properties" <<PROPS
jdbc.url=jdbc:postgresql://127.0.0.1:$PORT/$DB
jdbc.user=postgres
jdbc.password=
jdbc.driver=org.postgresql.Driver
PROPS
measure ontop java -cp "$LIB/*" it.unibz.inf.ontop.cli.Ontop materialize \
  -m "$BUILD/mapping.ttl" -p "$BUILD/ontop.properties" -f turtle -o "$BUILD/ontop.tmp.ttl" \
  > "$BUILD/ontop.log" 2>&1 || { tail -20 "$BUILD/ontop.log" >&2; echo "FAIL: Ontop" >&2; exit 1; }
grep -h "NR of TRIPLES" "$BUILD/ontop.log" || true
[ -s "$BUILD/ontop.tmp.ttl" ] || { echo "FAIL: Ontop wrote no output" >&2; exit 1; }

# Skip report (every source row not converted, with the reason)
$PSQL -d $DB -c "\copy (SELECT * FROM lodam_rdf.skip ORDER BY 1, 2) TO '$BUILD/skip-report.csv' CSV HEADER"
mv "$BUILD/ontop.tmp.ttl" "$BUILD/ontop.ttl"
echo "materialize: out/.build/ontop.ttl"
