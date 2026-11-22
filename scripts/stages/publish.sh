#!/usr/bin/env bash
# Stage publish (planning#6), offline: one file per released publication, exported from the
# checked full graph and checked again (knowledge-graph terms + SHACL). Only these files go into
# the release; the full graph stays internal (owner, 2026-11-21).
#
# Which publications are released is the database's decision: cau.literature.released_on (a date,
# planning#27). Until that column exists, config/released-publications.txt stands in for it.
# Writes out/.build/published/<key>.ttl and published.json (read by the package stage).
source "$(dirname "$0")/common.sh"
need "$BUILD/checks.json" check
db_up
OUTDIR="$BUILD/published"
mkdir -p "$OUTDIR"; rm -f "$OUTDIR"/*.ttl "$OUTDIR"/*.shacl "$BUILD/published.json"

has_flag=$($PSQL -d $DB -At -c "SELECT count(*) FROM information_schema.columns
  WHERE table_schema = 'cau' AND table_name = 'literature' AND column_name = 'released_on'")
if [ "$has_flag" = 1 ]; then
  from=database
  keys=$($PSQL -d $DB -At -c "SELECT zotero_key FROM cau.literature
    WHERE released_on IS NOT NULL AND released_on <= current_date ORDER BY 1")
else
  from=config
  echo "note: cau.literature.released_on does not exist yet (planning#27): using config/released-publications.txt"
  keys=$(grep -vE '^[[:space:]]*(#|$)' config/released-publications.txt || true)
fi
[ -n "$keys" ] || { echo "FAIL: no publication is released ($from); nothing to publish" >&2; exit 1; }

for key in $keys; do
  [[ $key =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "FAIL: odd citation key: $key" >&2; exit 1; }
  measure "export $key" python3 scripts/export_publication.py "$BUILD/lod-am.ttl" "$key" "$OUTDIR/$key.tmp.ttl"
  measure "check_terms $key" python3 "$KG/tools/check_terms.py" "$OUTDIR/$key.tmp.ttl"
  if ! measure "shacl $key" python3 "$KG/tools/validate.py" "$OUTDIR/$key.tmp.ttl" "$KG/data/vocab" > "$OUTDIR/$key.shacl"; then
    grep -v '^warning:' "$OUTDIR/$key.shacl" | head -40; echo "FAIL: SHACL violations in $key" >&2; exit 1
  fi
  tail -1 "$OUTDIR/$key.shacl"
  mv "$OUTDIR/$key.tmp.ttl" "$OUTDIR/$key.ttl"
done

python3 - "$BUILD" "$from" $keys <<'PY'
import json, sys
from pathlib import Path
b, source, keys = Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
pubs = []
for k in keys:
    shacl = (b / "published" / f"{k}.shacl").read_text(encoding="utf-8").splitlines()
    pubs.append({"key": k, "file": f"published/{k}.ttl",
                 "shacl": {"violations": 0, "warnings": sum(1 for l in shacl if l.startswith("warning:"))}})
(b / "published.json").write_text(json.dumps({"selected_from": source, "publications": pubs}, indent=2) + "\n")
PY
echo "publish: $(echo $keys | wc -w) publication(s) from $from"
