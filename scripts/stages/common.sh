# shellcheck shell=bash disable=SC2034  # sourced by the stages, which use these variables
# Shared settings of the converter stages (planning#5); sourced, not run.
# Env: KG=../knowledge-graph (checkout with .cache/ from its `make fetch`), PG_BIN, WORKDIR=/tmp
set -euo pipefail
umask 077                   # snapshots and outputs are the database as a whole: owner-only files
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT=$PWD
KG=$(realpath "${KG:-../knowledge-graph}")
BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
WORK=$(realpath "${WORKDIR:-/tmp}")/lodam-rdf-pg
PORT=${LODAM_PG_PORT:-5498}   # scripts/test_fixture.sh uses another, so a test never meets a real run
DB=lodam_rdf
LIB=${ONTOP_LIB:-$ROOT/.cache/ontop/$(sha256sum mapping/pom.xml | cut -c1-16)}   # as in Makefile; the image sets ONTOP_LIB
BUILD=$ROOT/out/.build      # scratch: stages pass their results here; nothing here is a release
SNAP=$ROOT/out/snapshots    # database snapshots (private, stay on the server)
PSQL="psql -h $WORK -p $PORT -U postgres -v ON_ERROR_STOP=1 -q"
DBURL="postgresql://postgres@127.0.0.1:$PORT/$DB"
# measure <step> <command ...>: run a heavy step, record its peak memory and duration (out/.build/resources.jsonl)
measure() { local step=$1; shift; python3 "$ROOT/scripts/stages/measure.py" "$step" -- "$@"; }

# The libpq variables from .env (PGHOST, PGDATABASE, PGPASSWORD, ...) describe the live research
# database and are for the snapshot stage only. Every other stage talks to the throwaway cluster,
# where an inherited PGDATABASE or PGPASSWORD would point psql at the wrong database: drop them.
if [ "${LODAM_STAGE:-}" != snapshot ]; then
  unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE \
        PGSSLMODE PGOPTIONS PGAPPNAME PGTARGETSESSIONATTRS
fi

# Run a PostgreSQL server command as the postgres user when we are root
run() { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/sh -c "$*"; else sh -c "$*"; fi; }

need() { # file stage: fail unless an earlier stage left its output
  [ -s "$1" ] || { echo "FAIL: ${1#"$ROOT"/} missing; run \`make $2\` first" >&2; exit 1; }
}

db_up() { # the throwaway cluster of the materialize stage must still run
  run "$BIN/pg_ctl -D '$WORK/data' status" > /dev/null 2>&1 \
    || { echo "FAIL: build database not running; run \`make materialize\` first" >&2; exit 1; }
}
