#!/usr/bin/env bash
# Tests of scripts/export_publication.py on fictional triples; no database.
# Publication A documents a find; publication B documents an analysis of that find.
#   1. A exports its find without B's analysis, sampling event or sample (each release holds only
#      its own publication's analyses; before the fix this run stopped at the privacy guard)
#   2. B exports its analysis with its sampling event, sample and the sampled find
#   3. the privacy guard still stops an analysis of another publication that comes in by an
#      outgoing link
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL $1"; cat "$T/out" 2>/dev/null; exit 1; }
ID=https://lod-am.net/id
F=$ID/find/00000000-0000-4000-8000-000000000001
X=$ID/analysis/00000000-0000-4000-8000-000000000002
cat > "$T/g.ttl" <<TTL
@prefix crm: <http://www.cidoc-crm.org/cidoc-crm/> .
@prefix crmsci: <http://www.cidoc-crm.org/extensions/crmsci/> .
@prefix afx: <http://purl.allotrope.org/ontologies/property#> .
@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
<$ID/pub/A> dcterms:identifier "pubA" .
<$ID/pub/B> dcterms:identifier "pubB" .
<$F> rdfs:label "Find 1"@en ; crm:P70i_is_documented_in <$ID/pub/A> .
<$X> rdfs:label "Analysis 1"@en ; crm:P70i_is_documented_in <$ID/pub/B> ;
    afx:AFX_0000399 <$X/sample> .
<$X/sample> rdfs:label "Sample of analysis 1"@en .
<$X/sampling> crmsci:O3_sampled_from <$F> ; crmsci:O5_removed <$X/sample> .
TTL
exp() { python3 scripts/export_publication.py "$T/g.ttl" "$1" "$T/$1.ttl" > "$T/out" 2>&1; }

exp pubA || fail "1: export of A"
grep -q "find/00000000-0000-4000-8000-000000000001" "$T/pubA.ttl" || fail "1: find missing"
grep -q "analysis/" "$T/pubA.ttl" && fail "1: B's analysis or its sampling in A's export"
echo "ok 1 a find analysed in another publication comes without that analysis"

exp pubB || fail "2: export of B"
for x in "$X>" "$X/sample>" "$X/sampling>" "$F>"; do
  grep -qF "<$x" "$T/pubB.ttl" || fail "2: $x missing"
done
echo "ok 2 an analysis comes with its sampling event, sample and the sampled find"

printf '<%s> <http://www.cidoc-crm.org/cidoc-crm/P67_refers_to> <%s> .\n' "$F" "$X" >> "$T/g.ttl"
set +e; exp pubA; rc=$?; set -e
[ $rc != 0 ] && grep -q "is not documented in pubA" "$T/out" || fail "3: privacy guard (exit $rc)"
echo "ok 3 the privacy guard stops another publication's analysis"
