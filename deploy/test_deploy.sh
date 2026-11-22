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
  image) cat "$T/label" 2>/dev/null; exit 0 ;;
  build) for a in "$@"; do [[ $a == net.lod-am.inputs=* ]] && echo "${a#*=}" > "$T/label"; done; exit 0 ;;
  run)
    args=" $* "
    while [ $# -gt 0 ]; do [ "$1" = --env-file ] && { echo "--- env-file:"; cat "$2"; } >> "$T/docker.log"; shift; done
    if [[ $args == *" changed "* ]]; then mkdir -p out; echo "$DECISION" > out/run-decision.txt; fi
    if [[ $args == *" release "* ]]; then
      [ "${FAIL_RELEASE:-}" = 1 ] && exit 2
      mkdir -p out/release out/internal; echo "{\"run\": \"$RANDOM\"}" > out/release/manifest.json
      echo '{"resources": {"peak_rss_mb": 1300, "peak_step": "shacl", "seconds": 700}}' > out/internal/manifest.json
    fi ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$T/curl.log"
EOF
cat > "$T/bin/setpriv" <<'EOF'
#!/usr/bin/env bash
# stub: drop setpriv's options and run the command as is (the test does not run as root anyway)
while [[ ${1:-} == --* ]]; do shift; done; exec "$@"
EOF
chmod +x "$T/bin/"*
export T PATH="$T/bin:$PATH" LODAM_LOCK="$T/lock"
run() { (cd "$W" && bash deploy/run.sh "$@") > "$T/out.log" 2>&1; }
calls() { grep -c "$1" "$T/$2" 2>/dev/null || true; }
reset() { : > "$T/docker.log"; : > "$T/curl.log"; }
fail() { echo "FAIL $1"; cat "$T/out.log"; exit 1; }

reset; DECISION="changed: no release yet" run || fail "1: run failed"
[ "$(calls 'docker build' docker.log)" = 1 ] && [ "$(calls ' release$' docker.log)" = 1 ] && [ "$(calls 'manifest_sha256' curl.log)" = 1 ] \
  || fail "1: expected one build, one release, one signal"
grep -q 'docker run --rm --network none .* release$' "$T/docker.log" || fail "1: release container is not offline"
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
  || fail "7: new commit on origin/main not fast-forwarded, or image not rebuilt for a changed Dockerfile"
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
