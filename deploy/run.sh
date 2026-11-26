#!/usr/bin/env bash
# Scheduled pipeline run on the data LXC (planning#6), started by lodam-pipeline.service (as root,
# for Docker). Every file in the checkout is written as the checkout's owner, never as root.
#   1. code:   fast-forward the checkout to origin/main (only the owner merges there; main is
#              protected), but only to a commit whose check runs on GitHub passed; refuse
#              local changes, so that a release always matches a commit
#   2. image:  rebuild lod-am-pipeline only when Dockerfile, docker/ or mapping/pom.xml changed
#   3. fetch snapshot changed: Zotero, the live database (read-only role, PG* from .env), and
#              the decision whether anything changed since the live release (out/run-decision.txt)
#   4. release (only if something changed, or with --force), with RELEASE_STRICT=1 and
#              --network none: the conversion provably runs offline
#   5. hand over: copy out/release/ to LODAM_PUBLISH_DIR (from .env, optional; world-readable, only
#              released data), then POST to LODAM_RELEASE_WEBHOOK (optional) that a release is
#              there; the triplestore fetches it from there itself (planning#7)
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
# The check runs of a commit on GitHub: "passed N", "failed N", "running", "none" or "unreadable".
# Read with grep (no python3 or jq on the host): every check run has exactly one "status" and one
# "conclusion"; nothing else in the response has these keys.
checks_of() {
  local json n open bad
  json=$(curl -sS --fail --max-time 30 -H "Accept: application/vnd.github+json" \
    "${LODAM_GITHUB_API:-https://api.github.com}/repos/${LODAM_PIPELINE_REPO:-LOD-AM/pipeline}/commits/$1/check-runs?per_page=100") \
    || { echo unreadable; return 0; }
  n=$(grep -o '"status": *"[a-z_]*"' <<< "$json" | wc -l || true)
  open=$(grep -o '"status": *"[a-z_]*"' <<< "$json" | grep -vc '"completed"' || true)
  bad=$(grep -oE '"conclusion": *("[a-z_]*"|null)' <<< "$json" | grep -vcE '"(success|neutral|skipped)"' || true)
  if [ "$n" = 0 ]; then echo none; elif [ "$open" != 0 ]; then echo running
  elif [ "$bad" != 0 ]; then echo "failed $bad"; else echo "passed $n"; fi
}

exec 9> "${LODAM_LOCK:-/run/lodam-pipeline.lock}"
flock -n 9 || { log "another run is still in progress; nothing to do"; exit 0; }
[ -f .env ] || { log "FAIL: .env missing (see .env.example)"; exit 1; }

# 1. code
[ "$(as_owner git rev-parse --abbrev-ref HEAD)" = main ] || { log "FAIL: checkout is not on main"; exit 1; }
[ -z "$(as_owner git status --porcelain --untracked-files=no)" ] \
  || { log "FAIL: checkout has local changes; commit or discard them first"; exit 1; }
as_owner git fetch -q origin main
# New code only once its checks on GitHub passed (planning review 2026-11-25, 5.2; the same gate as
# the triplestore's update_kg.sh). Failed checks: the run stops and the owner gets the failure mail.
# Checks not finished, none yet, or GitHub not readable: tonight's run uses the code it already has.
cur=$(as_owner git rev-parse HEAD); new=$(as_owner git rev-parse origin/main)
if [ "$new" != "$cur" ]; then
  case $(checks_of "$new") in
    passed*) as_owner git merge -q --ff-only origin/main ;;
    failed*) log "FAIL: main ${new:0:7} is not used, its checks on GitHub failed; the code stays at ${cur:0:7}"; exit 1 ;;
    *) log "main ${new:0:7}: checks on GitHub not finished or not readable; this run uses ${cur:0:7}" ;;
  esac
fi
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
# Copy out/release/ to LODAM_PUBLISH_DIR (world-readable, released data only), where the triplestore
# fetches it (planning#7): out/ itself is owner-only. Returns 1 if not configured or already current.
publish() {
  local pub; pub=$(envval LODAM_PUBLISH_DIR)
  [ -n "$pub" ] && [ -f out/release/manifest.json ] || return 1
  cmp -s out/release/manifest.json "$pub/manifest.json" 2>/dev/null && return 1
  install -d -m 755 "$pub"
  rsync -rt --delete --delay-updates --chmod=D755,F644 out/release/ "$pub/"
  log "copied out/release/ to $pub for the triplestore"
}
# Tell the triplestore (planning#7) that a release is ready; it fetches and checks it itself
signal() {
  local url token sha
  url=$(envval LODAM_RELEASE_WEBHOOK)
  if [ -z "$url" ]; then log "no LODAM_RELEASE_WEBHOOK in .env: not signalling the triplestore (planning#7)"; return 0; fi
  token=$(envval LODAM_RELEASE_WEBHOOK_TOKEN)
  sha=$(sha256sum out/release/manifest.json | cut -d' ' -f1)
  curl -fsS --max-time 30 -X POST -H "Content-Type: application/json" ${token:+-H "Authorization: Bearer $token"} \
    --data "{\"manifest_sha256\": \"$sha\"}" "$url" > /dev/null \
    || { log "FAIL: release ready, but the webhook did not answer; the triplestore's daily check picks it up"; return 1; }
  log "signalled $url"
}

if [ "${decision%%:*}" = unchanged ] && [ "$FORCE" != --force ]; then
  log "$decision; no new release"
  if publish; then signal; fi            # e.g. LODAM_PUBLISH_DIR newly set: hand over the live release
  exit 0
fi
log "$decision"

# 4. release, offline
docker run --rm --network none --user "$IDS" -e RELEASE_STRICT=1 -v "$DIR:/work" "$IMAGE" release
sha=$(sha256sum out/release/manifest.json | cut -d' ' -f1)
log "new release: out/release/ (manifest sha256 $sha); peak memory and time per step: out/internal/manifest.json"

# 5. hand over and signal
publish || true
signal
