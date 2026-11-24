#!/usr/bin/env bash
# Stage snapshot (planning#3): a consistent copy of the live research database (schema cau).
# pg_dump reads in one transaction, so a database edited during the run still gives a consistent
# copy. The connection comes from the standard libpq variables (PGHOST, PGPORT, PGDATABASE, PGUSER,
# PGPASSWORD; see .env.example) and must use a read-only role: the pipeline never writes to the
# research database.
#
# Writes out/snapshots/<UTC time>.sql and .json (sha256, time, server version) and points
# out/snapshots/latest.sql at it. A snapshot identical to the latest one is not kept again.
# The snapshots are the database as a whole: private, they stay on the server (never in a repo).
# shellcheck disable=SC2034  # read by common.sh
LODAM_STAGE=snapshot                 # keep the PG* variables (common.sh drops them elsewhere)
source "$(dirname "$0")/common.sh"
: "${PGHOST:?set PGHOST etc. (see .env.example)}" "${PGDATABASE:?set PGDATABASE}" "${PGUSER:?set PGUSER}"
mkdir -p "$SNAP"
ts=$(date -u +%Y%m%dT%H%M%SZ)
tmp="$SNAP/.$ts.sql.tmp"
pg_dump --schema=cau --no-owner --no-privileges --file="$tmp"
# pg_dump >= 16.10 writes \restrict lines with a random key: drop them, so the same database gives
# the same file (they only guard restores of untrusted dumps; this one comes from our database)
sed -i -E '/^\\(un)?restrict /d' "$tmp"
grep -q '^CREATE TABLE cau\.' "$tmp" || { echo "FAIL: snapshot has no cau tables; not kept" >&2; rm -f "$tmp"; exit 1; }
sha=$(sha256sum "$tmp" | cut -d' ' -f1)
if [ -e "$SNAP/latest.sql" ] && [ "$(sha256sum "$SNAP/latest.sql" | cut -d' ' -f1)" = "$sha" ]; then
  rm -f "$tmp"
  echo "snapshot: database unchanged since $(basename "$(readlink "$SNAP/latest.sql")")"
  exit 0
fi
server=$(psql -At -c "SHOW server_version")
mv "$tmp" "$SNAP/$ts.sql"
printf '{"kind": "snapshot", "file": "%s", "sha256": "%s", "taken_at": "%s", "server_version": "%s", "pg_dump": "%s"}\n' \
  "$ts.sql" "$sha" "$(date -u -d "${ts:0:8} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%Y-%m-%dT%H:%M:%SZ)" "$server" \
  "$(pg_dump --version | awk '{print $3}')" > "$SNAP/$ts.json"
ln -sfn "$ts.sql" "$SNAP/latest.sql"
echo "snapshot: out/snapshots/$ts.sql ($(grep -cE '^(COPY|INSERT INTO) ' "$SNAP/$ts.sql") data blocks)"
