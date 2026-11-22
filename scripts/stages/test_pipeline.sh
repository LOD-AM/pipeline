#!/usr/bin/env bash
# Tests of the package stage (planning#5, #6), without database or network, in a scratch copy:
#   1. no checks.json (a check failed or did not run) → no release, out/release/ untouched;
#   2. checks passed → out/release/ holds only the released publications + manifest, never the full
#      graph; out/internal/ holds the full graph; the previous ones are kept as *.prev/;
#   3. the same graph in another triple order → the same canonical hash;
#   4. RELEASE_STRICT=1 refuses untraceable inputs (no git, a dump file that is not a snapshot);
#   5. a snapshot that does not match its .json → no release;
#   6. no released publication → no release;
#   7. the live database's PG* variables reach only the snapshot stage;
#   8. measure.py records peak memory and duration and passes the exit code on (also when killed).
set -euo pipefail
cd "$(dirname "$0")/../.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/stages" "$T/mapping" "$T/.cache/zotero" "$T/out/release" "$T/out/.build/published" "$T/snap"
cp scripts/stages/package.py "$T/scripts/stages/"
cp mapping/pom.xml "$T/mapping/"
echo 59 > "$T/.cache/zotero/group-6765723.version"
echo "old release" > "$T/out/release/marker"
B=$T/out/.build
printf '%s\n' '@prefix ex: <https://example.invalid/> .' 'ex:a ex:p ex:b .' 'ex:b ex:p "x" .' 'ex:c ex:p ex:a .' > "$B/lod-am.ttl"
printf '%s\n' '@prefix ex: <https://example.invalid/> .' 'ex:a ex:p ex:b .' > "$B/published/pub1.ttl"
echo '{"selected_from": "database", "publications": [{"key": "pub1", "file": "published/pub1.ttl", "shacl": {"violations": 0, "warnings": 0}}]}' > "$B/published.json"
echo "-- dump" > "$T/snap/20260101T000000Z.sql"; echo "$T/snap/20260101T000000Z.sql" > "$B/dump.path"
echo "source_table,source_key,reason" > "$B/skip-report.csv"
echo "Conforms: True" > "$B/shacl.txt"; : > "$B/shacl-warnings.txt"; echo "ok   3 triples" > "$B/test_materialize.txt"
printf '%s\n' '{"step": "ontop", "seconds": 60.0, "peak_rss_mb": 900}' '{"step": "shacl", "seconds": 500.0, "peak_rss_mb": 1300}' > "$B/resources.jsonl"
pkg() { KG="$T/nokg" python3 "$T/scripts/stages/package.py"; }
CHECKS='{"terms": "passed", "shacl": {"violations": 0, "warnings": 0, "summary": ""}, "test_materialize": "passed", "skipped_rows": 0}'

if pkg > "$T/log" 2>&1; then echo "FAIL 1: packaged without checks.json"; exit 1; fi
grep -q "old release" "$T/out/release/marker" && [ ! -e "$T/out/release/manifest.json" ] \
  || { echo "FAIL 1: out/release/ changed"; exit 1; }
echo "ok   1 no passed check → no release, old release untouched"

echo "$CHECKS" > "$B/checks.json"
pkg > "$T/log"
python3 - "$T/out" <<'PY'
import json, sys
from pathlib import Path
out = Path(sys.argv[1])
rel, intl = out / "release", out / "internal"
files = sorted(str(p.relative_to(rel)) for p in rel.rglob("*") if p.is_file())
assert files == ["manifest.json", "published/pub1.ttl"], files          # never the full graph
m = json.loads((rel / "manifest.json").read_text())
assert "graph" not in m and "skipped_rows" not in json.dumps(m) and "resources" not in m, m   # no figures of the full database
assert m["publications"]["files"][0]["triples"] == 1 and m["zotero"]["library_version"] == 59
assert m["pipeline"]["ontop"] and m["pipeline"]["ontop"][0].isdigit(), m["pipeline"]   # property resolved
assert m["source"]["kind"] == "file" and m["source"]["file"] == "20260101T000000Z.sql"
mi = json.loads((intl / "manifest.json").read_text())
assert mi["graph"]["triples"] == 3 and (intl / "lod-am.ttl").exists() and (intl / "shacl-report.txt").exists()
r = mi["resources"]
assert r["peak_rss_mb"] == 1300 and r["peak_step"] == "shacl" and r["seconds"] == 560, r
assert [s["step"] for s in r["steps"]] == ["ontop", "shacl", "package"], r
assert (out / "release.prev" / "marker").read_text().strip() == "old release"
open(sys.argv[1] + "/canon1", "w").write(mi["graph"]["canonical_sha256"])
PY
echo "ok   2 checks passed → release = released publications + manifest only; full graph internal; previous kept"

printf '%s\n' '@prefix ex: <https://example.invalid/> .' 'ex:c ex:p ex:a .' 'ex:b ex:p "x" .' 'ex:a ex:p ex:b .' > "$B/lod-am.ttl"
pkg > "$T/log"
c2=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['graph']['canonical_sha256'])" "$T/out/internal/manifest.json")
[ "$c2" = "$(cat "$T/out/canon1")" ] || { echo "FAIL 3: canonical hash depends on triple order"; exit 1; }
echo "ok   3 same graph, other order → same canonical hash"

before=$(sha256sum "$T/out/release/manifest.json")
if RELEASE_STRICT=1 pkg > "$T/log" 2>&1; then echo "FAIL 4: strict release from untraceable inputs"; exit 1; fi
grep -q "RELEASE_STRICT" "$T/log" && [ "$before" = "$(sha256sum "$T/out/release/manifest.json")" ] \
  || { echo "FAIL 4: wrong refusal or release changed"; cat "$T/log"; exit 1; }
echo "ok   4 RELEASE_STRICT=1 refuses untraceable inputs, release untouched"

echo '{"kind": "snapshot", "file": "20260101T000000Z.sql", "sha256": "0000"}' > "$T/snap/20260101T000000Z.json"
if pkg > "$T/log" 2>&1; then echo "FAIL 5: packaged a snapshot that does not match its .json"; exit 1; fi
grep -q "does not match" "$T/log" || { echo "FAIL 5: wrong refusal"; cat "$T/log"; exit 1; }
rm -f "$T/snap/20260101T000000Z.json"
echo "ok   5 snapshot not matching its metadata → no release"

echo '{"selected_from": "database", "publications": []}' > "$B/published.json"
if pkg > "$T/log" 2>&1; then echo "FAIL 6: packaged without a released publication"; exit 1; fi
[ "$before" = "$(sha256sum "$T/out/release/manifest.json")" ] || { echo "FAIL 6: release changed"; exit 1; }
echo "ok   6 no released publication → no release"

# 7. The live database's PG* variables (.env) reach only the snapshot stage
out=$(PGDATABASE=lodam PGPASSWORD=x bash -c 'source scripts/stages/common.sh; echo "${PGDATABASE:-unset} ${PGPASSWORD:-unset}"')
[ "$out" = "unset unset" ] || { echo "FAIL 7: PG* variables leak into the build stages ($out)"; exit 1; }
out=$(PGDATABASE=lodam bash -c 'LODAM_STAGE=snapshot; source scripts/stages/common.sh; echo "${PGDATABASE:-unset}"')
[ "$out" = "lodam" ] || { echo "FAIL 7: snapshot stage lost PGDATABASE ($out)"; exit 1; }
echo "ok   7 PG* variables only in the snapshot stage"

# 8. measure.py: exit code passed on, a kill shows as 128 + signal, every run recorded
M=scripts/stages/measure.py; export LODAM_RESOURCES=$T/resources.jsonl; R=$LODAM_RESOURCES; before=0
python3 "$M" t-ok -- python3 -c "b = bytearray(50 * 1024 * 1024)" 2>/dev/null
set +e; python3 "$M" t-fail -- sh -c 'exit 3' 2>/dev/null; c1=$?; python3 "$M" t-kill -- sh -c 'kill -9 $$' 2>/dev/null; c2=$?; set -e
[ "$c1" = 3 ] && [ "$c2" = 137 ] || { echo "FAIL 8: exit codes $c1 $c2 (want 3 137)"; exit 1; }
python3 - "$R" "$before" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])][int(sys.argv[2]):]
assert [r["step"] for r in rows] == ["t-ok", "t-fail", "t-kill"], rows
assert rows[0]["peak_rss_mb"] >= 50 and rows[1]["exit_code"] == 3 and rows[2]["exit_code"] == -9, rows
PY
echo "ok   8 measure.py: peak memory recorded, exit codes passed on"
