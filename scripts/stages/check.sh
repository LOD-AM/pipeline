#!/usr/bin/env bash
# Stage check (planning#5), offline: the enriched graph against knowledge-graph's tools (term
# existence, CRM domain/range, SHACL) and against the database (test_materialize.py: every
# source row is converted or in the skip report). Any failure stops here: no release.
# Writes out/.build/checks.json only when every check passed (read by the package stage).
source "$(dirname "$0")/common.sh"
need "$BUILD/lod-am.ttl" enrich
db_up
rm -f "$BUILD/checks.json"
measure check_terms python3 "$KG/tools/check_terms.py" "$BUILD/lod-am.ttl"
# The local concepts (:name_as_reported, :location_area, :not_detected …) live in knowledge-graph
# One run (pySHACL takes several minutes on the full graph); warnings are counted, violations fail
if ! measure shacl python3 "$KG/tools/validate.py" "$BUILD/lod-am.ttl" "$KG/data/vocab" > "$BUILD/shacl.txt"; then
  grep -v '^warning:' "$BUILD/shacl.txt" | head -40; echo "FAIL: SHACL violations (out/.build/shacl.txt)" >&2; exit 1
fi
tail -1 "$BUILD/shacl.txt"
grep '^warning:' "$BUILD/shacl.txt" | sed -E -e 's/^warning: \S+ (\S*): /\1: /' -e 's/<[^>]*>/<…>/g' | sort | uniq -c | sort -rn > "$BUILD/shacl-warnings.txt" || true
head -8 "$BUILD/shacl-warnings.txt"
measure test_materialize python3 scripts/test_materialize.py "$BUILD/lod-am.ttl" "$BUILD/skip-report.csv" "$DBURL" | tee "$BUILD/test_materialize.txt"
python3 - "$BUILD" <<'PY'
import json, sys
from pathlib import Path
b = Path(sys.argv[1])
shacl = (b / "shacl.txt").read_text(encoding="utf-8").splitlines()
skips = (b / "skip-report.csv").read_text(encoding="utf-8").splitlines()[1:]
checks = {
    "terms": "passed",                                   # check_terms.py exits non-zero otherwise
    "shacl": {"violations": 0, "warnings": sum(1 for l in shacl if l.startswith("warning:")),
              "summary": shacl[-1] if shacl else ""},
    "test_materialize": "passed",
    "skipped_rows": len(skips),
}
(b / "checks.json").write_text(json.dumps(checks, indent=2) + "\n", encoding="utf-8")
PY
echo "check: all passed"
