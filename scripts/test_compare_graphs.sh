#!/usr/bin/env bash
# Tests of scripts/compare_graphs.py (planning#27, round 0) on fictional triples; no database.
#   1. the same triples in another order and syntax: "the same graph", exit 0
#   2. blank nodes with other labels: the same graph
#   3. a changed value: exit 1, removed and added grouped by record kind and predicate
#   4. a file that does not parse: exit 2
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $1"; cat "$T/out" 2>/dev/null; exit 1; }
cmp_() { python3 scripts/compare_graphs.py "$@" > "$T/out" 2>&1; }
cat > "$T/a.ttl" <<'TTL'
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
<https://lod-am.net/id/site/00000000-0000-4000-8000-000000000001> rdfs:label "Testsite"@en .
<https://lod-am.net/id/find/00000000-0000-4000-8000-000000000002> rdfs:label "Find 1"@en ;
    rdfs:comment "fictional" .
TTL
cat > "$T/b.nt" <<'NT'
<https://lod-am.net/id/find/00000000-0000-4000-8000-000000000002> <http://www.w3.org/2000/01/rdf-schema#comment> "fictional" .
<https://lod-am.net/id/find/00000000-0000-4000-8000-000000000002> <http://www.w3.org/2000/01/rdf-schema#label> "Find 1"@en .
<https://lod-am.net/id/site/00000000-0000-4000-8000-000000000001> <http://www.w3.org/2000/01/rdf-schema#label> "Testsite"@en .
NT
cmp_ "$T/a.ttl" "$T/b.nt" && grep -q "the same graph" "$T/out" || fail "1: same triples"
echo "ok 1 same triples, other order and syntax"

printf '_:x <urn:x:p> "1" .\n' > "$T/c.nt"; printf '_:y <urn:x:p> "1" .\n' > "$T/d.nt"
cmp_ "$T/c.nt" "$T/d.nt" || fail "2: blank nodes"
echo "ok 2 blank nodes compared canonically"

sed 's/"Find 1"/"Find 2"/' "$T/b.nt" > "$T/e.nt"
cmp_ "$T/b.nt" "$T/e.nt" && fail "3: a change must exit 1"
[ $? = 1 ] || fail "3: exit code"
grep -q "DIFFERENT: 1 removed, 1 added" "$T/out" || fail "3: counts"
grep -qE '^ +1  find  <http://www.w3.org/2000/01/rdf-schema#label>$' "$T/out" || fail "3: grouping"
grep -q '"Find 2"@en' "$T/out" || fail "3: example"
echo "ok 3 a changed value: removed/added by kind and predicate, with examples"

echo "not rdf <" > "$T/bad.ttl"
set +e; cmp_ "$T/a.ttl" "$T/bad.ttl"; rc=$?; set -e
[ $rc = 2 ] && grep -q "cannot parse" "$T/out" || fail "4: parse error (exit $rc)"
echo "ok 4 parse error: exit 2"
echo "all compare_graphs tests passed"
