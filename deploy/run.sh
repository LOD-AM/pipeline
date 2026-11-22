#!/usr/bin/env bash
# Scheduled pipeline run on the data LXC (planning#6), started by lodam-pipeline.service (as root,
# for Docker). Every file in the checkout is written as the checkout's owner, never as root.
#   1. code:   fast-forward the checkout to origin/main (only the owner merges there); refuse
#              local changes, so that a release always matches a commit
#   2. image:  rebuild lod-am-pipeline only when Dockerfile, docker/ or mapping/pom.xml changed
#   3. fetch snapshot changed: Zotero, the live database (read-only role, PG* from .env), and
#              the decision whether anything changed since the live release (out/run-decision.txt)
#   4. release (only if something changed, or with --force), with RELEASE_STRICT=1 and
#              --network none: the conversion provably runs offline
#   5. signal: POST to LODAM_RELEASE_WEBHOOK (from .env, optional) that a new release is there;
#              the triplestore then fetches out/release/ itself (planning#7)
# A failing step stops the run with a non-zero exit (systemctl shows the unit as failed); the
# live release in out/release/ is only ever replaced by a fully checked one.
# Usage: deploy/run.sh [--force]     logs: journalctl -u lodam-pipeline
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$PWD
IMAGE=${LODAM_IMAGE:-lod-am-pipeline}
FORCE=${1:-}
log() { echo "pipeline-run: $*"; }
OWNER=$(stat -c %U "$DIR")
IDS="$(stat -c %u "$DIR"):$(stat -c %g "$DIR")"
OWNER_HOME=$(getent passwd "$OWNER" | cut -d: -f6)
# setpriv, not runuser: same user, groups and HOME, but no PAM session (two journal lines per call)
as_owner() {
  if [ "$(id -u)" = 0 ] && [ "$OWNER" != root ]; then
    setpriv --reuid="$OWNER" --regid="$(stat -c %g "$DIR")" --init-groups env HOME="$OWNER_HOME" "$@"
  else "$@"; fi
}
# Values from .env without executing it (it holds the database password)
envval() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

exec 9> "${LODAM_LOCK:-/run/lodam-pipeline.lock}"
flock -n 9 || { log "another run is still in progress; nothing to do"; exit 0; }
[ -f .env ] || { log "FAIL: .env missing (see .env.example)"; exit 1; }

# 1. code
[ "$(as_owner git rev-parse --abbrev-ref HEAD)" = main ] || { log "FAIL: checkout is not on main"; exit 1; }
[ -z "$(as_owner git status --porcelain --untracked-files=no)" ] \
  || { log "FAIL: checkout has local changes; commit or discard them first"; exit 1; }
as_owner git fetch -q origin main
as_owner git merge -q --ff-only origin/main
log "code at $(as_owner git rev-parse --short HEAD)"

# 2. image
inputs=$(cat Dockerfile .dockerignore docker/* mapping/pom.xml | sha256sum | cut -c1-16)
have=$(docker image inspect -f '{{ index .Config.Labels "net.lod-am.inputs" }}' "$IMAGE" 2>/dev/null || true)
if [ "$have" != "$inputs" ]; then
  log "building $IMAGE (inputs $inputs)"
  docker build -q --label "net.lod-am.inputs=$inputs" \
    --build-arg "PIPELINE_IMAGE=$IMAGE:$(as_owner git rev-parse --short HEAD)" -t "$IMAGE" . > /dev/null
fi

# 3. snapshot and decision. Only the PG* lines of .env go into the container.
envf=$(mktemp); trap 'rm -f "$envf"' EXIT
grep -E '^PG[A-Z]+=' .env > "$envf" || true
docker run --rm --network host --user "$IDS" --env-file "$envf" -v "$DIR:/work" "$IMAGE" fetch snapshot changed
decision=$(cat out/run-decision.txt)
if [ "${decision%%:*}" = unchanged ] && [ "$FORCE" != --force ]; then
  log "$decision; no new release"
  exit 0
fi
log "$decision"

# 4. release, offline
docker run --rm --network none --user "$IDS" -e RELEASE_STRICT=1 -v "$DIR:/work" "$IMAGE" release
sha=$(sha256sum out/release/manifest.json | cut -d' ' -f1)
log "new release: out/release/ (manifest sha256 $sha); peak memory and time per step: out/internal/manifest.json"

# 5. signal
url=$(envval LODAM_RELEASE_WEBHOOK)
if [ -z "$url" ]; then
  log "no LODAM_RELEASE_WEBHOOK in .env: not signalling the triplestore (planning#7)"
  exit 0
fi
token=$(envval LODAM_RELEASE_WEBHOOK_TOKEN)
curl -fsS --max-time 30 -X POST -H "Content-Type: application/json" ${token:+-H "Authorization: Bearer $token"} \
  --data "{\"manifest_sha256\": \"$sha\"}" "$url" > /dev/null \
  || { log "FAIL: release built, but the webhook did not answer; the triplestore picks it up on the next signal"; exit 1; }
log "signalled $url"
