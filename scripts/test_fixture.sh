#!/usr/bin/env bash
# A whole release in public CI, without private data: `make release` on the fixture of one released
# publication (tests/fixture/<key>/, built by scripts/make_fixture.py), in a scratch copy of this
# checkout, with the fixture's Zotero snapshot, offline. Checks:
#   1. the release holds exactly published/<key>.ttl and the manifest;
#   2. that file is the same graph as tests/fixture/<key>/expected.ttl (= the file the server released);
#   3. the full graph built from the fixture has no triple outside that file: the fixture holds
#      nothing that is not already public (pipeline CLAUDE.md, Confidentiality);
#   4. Jena's SHACL check (scripts/shacl.py, used by the stages) finds the same results as
#      knowledge-graph's pySHACL (tools/validate.py) on the fixture's full graph: the same severity,
#      focus node and path for every result, and the same triple count (messages may be worded differently).
# A converter change that changes the released file fails 2: update expected.ttl in the same PR and
# say which triples change and why. A schema round of the database: rebuild the fixture.
# Needs what `make release` needs (in the image: everything). Env: KEY (default hauptmann2002chemical).
# Usage: scripts/test_fixture.sh        (make test-fixture; in CI inside the image)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
KEY=${KEY:-hauptmann2002chemical}
FX=$ROOT/tests/fixture/$KEY
for f in dump.sql zotero.json zotero.version expected.ttl; do
  [ -s "$FX/$f" ] || { echo "FAIL: $FX/$f missing" >&2; exit 1; }
done
KG=$(realpath "${KG:-../knowledge-graph}"); export KG   # absolute: make runs in a scratch copy
export ONTOP_LIB=${ONTOP_LIB:-$ROOT/.cache/ontop/$(sha256sum mapping/pom.xml | cut -c1-16)}
export JENA_LIB=${JENA_LIB:-$ROOT/.cache/jena/$(sha256sum shacl/pom.xml | cut -c1-16)}
export LODAM_PG_PORT=${LODAM_PG_PORT:-5495}

T=$(mktemp -d)
cleanup() {
  [ -d "$T/pg/lodam-rdf-pg/data" ] && { if [ "$(id -u)" = 0 ]; then su postgres -s /bin/sh -c \
    "${PG_BIN:-/usr/lib/postgresql/16/bin}/pg_ctl -D '$T/pg/lodam-rdf-pg/data' -m fast stop"; else \
    "${PG_BIN:-/usr/lib/postgresql/16/bin}/pg_ctl" -D "$T/pg/lodam-rdf-pg/data" -m fast stop; fi; } > /dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
cp -r Makefile mapping shacl scripts "$T/"
mkdir -p "$T/.cache/zotero" "$T/pg"
[ "$(id -u)" = 0 ] && chmod 755 "$T" && chown postgres "$T/pg"
cp "$FX/zotero.json" "$T/.cache/zotero/group-6765723.json"
cp "$FX/zotero.version" "$T/.cache/zotero/group-6765723.version"

WORKDIR=$T/pg make -s -C "$T" release DUMP="$FX/dump.sql" > "$T/release.log" 2>&1 \
  || { tail -30 "$T/release.log"; echo "FAIL: make release on the fixture" >&2; exit 1; }
grep -E '^(package|publish):' "$T/release.log" || true
# FIXTURE_OUT=<dir>: keep the fixture's out/ there to look at a failure (never commit it)
[ -n "${FIXTURE_OUT:-}" ] && rm -rf "$FIXTURE_OUT" && cp -r "$T/out" "$FIXTURE_OUT"

# 1. the release holds only the publication and the manifest
got=$(cd "$T/out/release" && find . -type f | sort | tr '\n' ' ')
[ "$got" = "./manifest.json ./published/$KEY.ttl " ] \
  || { echo "FAIL 1: release holds: $got" >&2; exit 1; }
echo "ok   1 release holds published/$KEY.ttl and the manifest only"

# 2. the released file is the expected one
python3 scripts/compare_graphs.py "$FX/expected.ttl" "$T/out/release/published/$KEY.ttl" > "$T/compare.txt" \
  || { cat "$T/compare.txt"; echo "FAIL 2: published/$KEY.ttl differs from tests/fixture/$KEY/expected.ttl" >&2; exit 1; }
echo "ok   2 published/$KEY.ttl = tests/fixture/$KEY/expected.ttl"

# 3. nothing in the fixture beyond the released publication
python3 - "$T/out/internal/lod-am.ttl" "$T/out/release/published/$KEY.ttl" <<'PY'
import sys
from rdflib import Graph, Literal, XSD
full, pub = Graph(), Graph()
full.parse(sys.argv[1]); pub.parse(sys.argv[2])
# The same xsd:decimal can be written "4" (Ontop) or 4.0 (the export's serialiser): compare by value
norm = lambda o: ("decimal", o.toPython().normalize()) if isinstance(o, Literal) and o.datatype == XSD.decimal else o
key = lambda t: (t[0], t[1], norm(t[2]))
released = {key(t) for t in pub}
extra = [t for t in full if key(t) not in released]
if extra:
    for t in sorted(extra, key=str)[:20]:
        print("  extra:", *(x.n3() for x in t))
    sys.exit(f"FAIL 3: the fixture's full graph has {len(extra)} triple(s) that are not in the release")
print(f"ok   3 the fixture's full graph ({len(full)} triples) is all in the released file ({len(pub)} triples)")
PY

# 4. Jena and pySHACL agree
results() { grep -E '^(VIOLATION|warning):' "$1" | sed -E 's/^(\S+) (\S+) (\S*): .*/\1 \2 \3/' | sort; }
count() { tail -1 "$1" | grep -oE '[0-9]+ triples'; }
python3 scripts/shacl.py "$T/out/internal/lod-am.ttl" "$KG/data/vocab" > "$T/jena.txt" || true
python3 "$KG/tools/validate.py" "$T/out/internal/lod-am.ttl" "$KG/data/vocab" > "$T/pyshacl.txt" || true
if ! diff <(results "$T/pyshacl.txt") <(results "$T/jena.txt") > "$T/shacl.diff" \
   || [ "$(count "$T/pyshacl.txt")" != "$(count "$T/jena.txt")" ]; then
  head -20 "$T/shacl.diff"; tail -1 "$T/pyshacl.txt"; tail -1 "$T/jena.txt"
  echo "FAIL 4: Jena's SHACL results differ from pySHACL's" >&2; exit 1
fi
echo "ok   4 Jena's SHACL check = pySHACL's ($(tail -1 "$T/jena.txt" | sed 's/^SHACL: //'))"
