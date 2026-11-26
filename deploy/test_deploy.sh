#!/usr/bin/env bash
# Control-flow tests of deploy/run.sh (planning#6), with docker, curl and setpriv stubbed; no server,
# database or Docker daemon needed. The checkout is a temporary clone with its own "origin".
#   1. first run: image built, snapshot + decision, offline release, webhook signalled
#   2. nothing changed: no rebuild, no release, no signal
#   3. --force: release and signal although nothing changed
#   4. local changes in the checkout: refused before Docker runs
#   5. failing release: non-zero exit, no signal
#   6. no webhook configured: release, no signal, exit 0
#   7. only the PG* lines of .env reach the container (never the webhook token); the release
#      container has no network; a new commit on origin/main is fast-forwarded
#   8. LODAM_PUBLISH_DIR gets each new release, world-readable, before the signal
#   9. an unchanged run refreshes an outdated publish dir (and signals), leaves a current one alone
#  10. a new commit on origin/main whose checks failed: not used, non-zero exit, nothing runs
#  11. checks still running, or GitHub not readable: tonight's run uses the code it has
#  12. the checks' answer is read in GitHub's compact form too
#  13. containers left by an earlier, interrupted run (label net.lod-am.run=pipeline) are removed first
#  14. a run stopped with TERM removes its own container and exits non-zero at once
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=$PWD
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/work" 2>/dev/null
W=$T/work
mkdir -p "$W/deploy" "$W/docker" "$W/mapping"
cp "$SRC/deploy/run.sh" "$W/deploy/"; cp "$SRC/Dockerfile" "$SRC/.dockerignore" "$W/"
cp "$SRC/docker/"* "$W/docker/"; cp "$SRC/mapping/pom.xml" "$W/mapping/"
printf '%s\n' 'out/' '.env' > "$W/.gitignore"
git -C "$W" add -A; git -C "$W" -c user.name=t -c user.email=t@example.invalid commit -qm init; git -C "$W" -c push.negotiate=false push -q origin main
printf '%s\n' 'PGHOST=127.0.0.1' 'PGDATABASE=change-me' 'PGPASSWORD=change-me' \
  'LODAM_RELEASE_WEBHOOK=http://triplestore.example.invalid:9000/hooks/lodam' 'LODAM_RELEASE_WEBHOOK_TOKEN=secret-token' > "$W/.env"

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
# stub: records calls; simulates image labels, the decision and the release
echo "docker $*" >> "$T/docker.log"
case $1 in
  ps) printf '%s\n' ${LEFTOVERS:-}; exit 0 ;;
  image) cat "$T/label" 2>/dev/null; exit 0 ;;
  build) for a in "$@"; do [[ $a == net.lod-am.inputs=* ]] && echo "${a#*=}" > "$T/label"; done; exit 0 ;;
  run)
    args=" $* "
    while [ $# -gt 0 ]; do [ "$1" = --env-file ] && { echo "--- env-file:"; cat "$2"; } >> "$T/docker.log"; shift; done
    if [[ $args == *" changed "* ]]; then mkdir -p out; echo "$DECISION" > out/run-decision.txt; fi
    if [[ $args == *" release "* ]]; then
      [ "${FAIL_RELEASE:-}" = 1 ] && exit 2
      [ "${SLOW_RELEASE:-}" = 1 ] && { echo $$ > "$T/release.pid"; sleep 30; }
      mkdir -p out/release out/internal; echo "{\"run\": \"$RANDOM\"}" > out/release/manifest.json
      echo '{"resources": {"peak_rss_mb": 1300, "peak_step": "shacl", "seconds": 700}}' > out/internal/manifest.json
    fi ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# stub: the check runs of a commit on GitHub come from $CHECKS (a file; exit $CHECKS_EXIT),
# every other call is the webhook
if [[ "$*" == *check-runs* ]]; then
  echo "curl $*" >> "$T/checks.log"; [ "${CHECKS_EXIT:-0}" = 0 ] || exit "$CHECKS_EXIT"
  cat "${CHECKS:-$T/checks-passed.json}"; exit 0
fi
echo "curl $*" >> "$T/curl.log"
EOF
# Check-run answers in GitHub's format (abridged): the app and output objects have no status/conclusion
run_json() { # status conclusion name
  printf '    {\n      "id": %s,\n      "name": "%s",\n      "status": "%s",\n      "conclusion": %s,\n' "$RANDOM" "$3" "$1" "$2"
  printf '      "output": { "title": null, "summary": null, "annotations_count": 0 },\n'
  printf '      "app": { "slug": "github-actions", "owner": { "login": "github" }, "events": [] },\n'
  printf '      "check_suite": { "id": 1 }, "pull_requests": []\n    }'
}
checks_file() { # file run...   each run as status:conclusion:name
  local f=$1; shift; local first=1
  { printf '{\n  "total_count": %s,\n  "check_runs": [\n' "$#"
    for r in "$@"; do IFS=: read -r st co nm <<< "$r"; [ $first = 1 ] || printf ',\n'; first=0
      run_json "$st" "$co" "$nm"; done
    printf '\n  ]\n}\n'; } > "$f"
}
checks_file "$T/checks-passed.json" 'completed:"success":test-pipeline' 'completed:"success":image' 'completed:"skipped":shared-block'
checks_file "$T/checks-failed.json" 'completed:"success":test-pipeline' 'completed:"failure":image' 'completed:"success":shared-block'
checks_file "$T/checks-running.json" 'completed:"success":test-pipeline' 'in_progress:null:image'
cat > "$T/bin/setpriv" <<'EOF'
#!/usr/bin/env bash
# stub: drop setpriv's options and run the command as is (the test does not run as root anyway)
while [[ ${1:-} == --* ]]; do shift; done; exec "$@"
EOF
chmod +x "$T/bin/"*
export T PATH="$T/bin:$PATH" LODAM_LOCK="$T/lock"
run() { (cd "$W" && bash deploy/run.sh "$@") > "$T/out.log" 2>&1; }
calls() { grep -c "$1" "$T/$2" 2>/dev/null || true; }
reset() { : > "$T/docker.log"; : > "$T/curl.log"; : > "$T/checks.log"; }
fail() { echo "FAIL $1"; cat "$T/out.log"; exit 1; }

reset; DECISION="changed: no release yet" run || fail "1: run failed"
[ "$(calls 'docker build' docker.log)" = 1 ] && [ "$(calls ' release$' docker.log)" = 1 ] && [ "$(calls 'manifest_sha256' curl.log)" = 1 ] \
  || fail "1: expected one build, one release, one signal"
grep -q 'docker run --rm --name lodam-pipeline-release --label net.lod-am.run=pipeline --network none .* release$' "$T/docker.log" \
  || fail "1: release container is not offline, or has no fixed name and label"
echo "ok   1 first run: image built, offline release, webhook signalled"

reset; DECISION="unchanged: snapshot abc, pipeline def" run || fail "2: run failed"
[ "$(calls 'docker build' docker.log)" = 0 ] && [ "$(calls ' release$' docker.log)" = 0 ] && [ "$(calls curl curl.log)" = 0 ] \
  || fail "2: unchanged inputs must not rebuild, release or signal"
grep -q "no new release" "$T/out.log" || fail "2: no 'no new release' in the log"
echo "ok   2 nothing changed: no rebuild, no release, no signal"

reset; DECISION="unchanged: snapshot abc, pipeline def" run --force || fail "3: run failed"
[ "$(calls ' release$' docker.log)" = 1 ] && [ "$(calls 'manifest_sha256' curl.log)" = 1 ] || fail "3: --force must release and signal"
echo "ok   3 --force: release and signal"

echo "# local edit" >> "$W/Dockerfile"; reset
if DECISION="changed: x" run; then fail "4: ran with local changes"; fi
[ "$(calls 'docker run' docker.log)" = 0 ] && grep -q "local changes" "$T/out.log" || fail "4: expected refusal before docker"
git -C "$W" checkout -q Dockerfile
echo "ok   4 local changes: refused before Docker runs"

reset
if FAIL_RELEASE=1 DECISION="changed: x" run; then fail "5: a failing release exited 0"; fi
[ "$(calls curl curl.log)" = 0 ] || fail "5: signalled after a failed release"
echo "ok   5 failing release: non-zero exit, no signal"

sed -i '/^LODAM_RELEASE_WEBHOOK/d' "$W/.env"; reset; DECISION="changed: x" run || fail "6: run failed"
[ "$(calls ' release$' docker.log)" = 1 ] && [ "$(calls curl curl.log)" = 0 ] || fail "6: expected release without signal"
echo "ok   6 no webhook configured: release, no signal"

echo 'LODAM_RELEASE_WEBHOOK_TOKEN=secret-token' >> "$W/.env"; reset; DECISION="changed: x" run || fail "7: run failed"
grep -q "PGPASSWORD=change-me" "$T/docker.log" && ! grep -q "secret-token\|LODAM_RELEASE" "$T/docker.log" \
  || fail "7: the container must get the PG* lines and nothing else from .env"
git clone -q "$T/origin.git" "$T/other" 2>/dev/null; echo "# new" >> "$T/other/Dockerfile"
git -C "$T/other" -c user.name=t -c user.email=t@example.invalid commit -qam new; git -C "$T/other" -c push.negotiate=false push -q origin main
reset; DECISION="unchanged: x" run || fail "7: run failed"
[ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$T/other" rev-parse HEAD)" ] && [ "$(calls 'docker build' docker.log)" = 1 ] \
  && [ "$(calls "commits/$(git -C "$T/other" rev-parse HEAD)/check-runs" checks.log)" = 1 ] \
  || fail "7: new commit on origin/main (checks passed) not fast-forwarded, or image not rebuilt for a changed Dockerfile"
echo "ok   7 only PG* reach the container; origin/main fast-forwarded; image rebuilt when its inputs change"

# 8. LODAM_PUBLISH_DIR: a new release is copied there (world-readable) and then signalled
echo "LODAM_PUBLISH_DIR=$T/pub" >> "$W/.env"; echo 'LODAM_RELEASE_WEBHOOK=http://triplestore.example.invalid:9300/lodam-release' >> "$W/.env"
reset; DECISION="changed: x" run || fail "8: run failed"
cmp -s "$W/out/release/manifest.json" "$T/pub/manifest.json" && [ "$(stat -c %a "$T/pub/manifest.json")" = 644 ] \
  && [ "$(stat -c %a "$T/pub")" = 755 ] && [ "$(calls 'manifest_sha256' curl.log)" = 1 ] || fail "8: release not copied world-readable, or not signalled"
echo "ok   8 new release copied to LODAM_PUBLISH_DIR (755/644), then signalled"

# 9. unchanged: an outdated publish dir gets the live release (and a signal), a current one nothing
echo '{"old": true}' > "$T/pub/manifest.json"; reset; DECISION="unchanged: x" run || fail "9: run failed"
cmp -s "$W/out/release/manifest.json" "$T/pub/manifest.json" && [ "$(calls 'manifest_sha256' curl.log)" = 1 ] \
  && [ "$(calls ' release$' docker.log)" = 0 ] || fail "9: outdated publish dir not refreshed"
reset; DECISION="unchanged: x" run || fail "9: run failed"
[ "$(calls curl curl.log)" = 0 ] || fail "9: signalled although the publish dir was current"
echo "ok   9 unchanged: outdated publish dir refreshed and signalled; current one left alone"

# 10.-12. new code only once its checks on GitHub passed (planning review 2026-11-25, 5.2)
newcommit() { echo "# $1" >> "$T/other/docker/README.md"; git -C "$T/other" -c user.name=t -c user.email=t@example.invalid commit -qam "$1"
  git -C "$T/other" -c push.negotiate=false push -q origin main; }
here() { git -C "$W" rev-parse HEAD; }
before=$(here); newcommit failed; reset
if CHECKS="$T/checks-failed.json" DECISION="changed: x" run; then fail "10: ran a main whose checks failed"; fi
[ "$(here)" = "$before" ] && [ "$(calls 'docker run' docker.log)" = 0 ] && grep -q "checks on GitHub failed" "$T/out.log" \
  || fail "10: main with failed checks was used, or Docker ran"
echo "ok  10 checks failed: main not used, non-zero exit, nothing runs"

reset; CHECKS="$T/checks-running.json" DECISION="unchanged: x" run || fail "11: run failed while checks were running"
[ "$(here)" = "$before" ] && [ "$(calls 'docker run' docker.log)" -ge 1 ] && grep -q "not finished or not readable" "$T/out.log" \
  || fail "11: checks running: expected the run on the old code"
reset; CHECKS_EXIT=22 DECISION="unchanged: x" run || fail "11: run failed while GitHub was not readable"
[ "$(here)" = "$before" ] && [ "$(calls 'docker run' docker.log)" -ge 1 ] || fail "11: GitHub not readable: expected the run on the old code"
echo "ok  11 checks running or GitHub not readable: the run uses the code it has"

tr -d ' \n' < "$T/checks-passed.json" > "$T/checks-compact.json"
reset; CHECKS="$T/checks-compact.json" DECISION="unchanged: x" run || fail "12: run failed"
[ "$(here)" = "$(git -C "$T/other" rev-parse HEAD)" ] || fail "12: compact JSON with passed checks: main not fast-forwarded"
echo "ok  12 GitHub's compact JSON: passed checks, main fast-forwarded"

# 13.-14. no containers left behind (planning review 2026-11-25; two ran for days until 2026-11-26)
reset; LEFTOVERS="abc123 def456" DECISION="unchanged: x" run || fail "13: run failed"
grep -q "docker ps -aq --filter label=net.lod-am.run=pipeline" "$T/docker.log" && grep -q "docker rm -f abc123 def456" "$T/docker.log" \
  && grep -q "removing 2 container(s) left by an earlier" "$T/out.log" || fail "13: leftover containers not removed"
echo "ok  13 leftover containers of an interrupted run are removed first"

reset; rm -f "$T/release.pid"
(cd "$W" && SLOW_RELEASE=1 DECISION="changed: x" exec bash deploy/run.sh) > "$T/out.log" 2>&1 & runpid=$!
for _ in $(seq 50); do [ -s "$T/release.pid" ] && break; sleep 0.1; done
[ -s "$T/release.pid" ] || fail "14: the release never started"
kill -TERM "$runpid"; start=$SECONDS; rc=0; wait "$runpid" || rc=$?
kill "$(cat "$T/release.pid")" 2>/dev/null || true
[ "$rc" != 0 ] && [ $((SECONDS - start)) -lt 10 ] && grep -q "docker rm -f lodam-pipeline-release" "$T/docker.log" \
  && [ "$(calls 'manifest_sha256' curl.log)" = 0 ] || fail "14: TERM did not remove the release container, or the run went on (rc $rc)"
echo "ok  14 TERM during the release: its container is removed, non-zero exit, no signal"
