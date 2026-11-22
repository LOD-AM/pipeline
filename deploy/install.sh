#!/usr/bin/env bash
# Install (or update) the scheduled pipeline run on the data LXC (planning#6).
# Usage: sudo deploy/install.sh          (from the pipeline checkout; run again after changes to deploy/)
# Writes /etc/systemd/system/lodam-pipeline.{service,timer} and lodam-alert@.service (mails the owner
# when a run fails, planning#34) with this checkout's path and enables the timer. Nothing else on the machine is changed. Undo: sudo deploy/install.sh --remove
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$PWD
UNITS=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
if [ "${1:-}" = --remove ]; then
  systemctl disable --now lodam-pipeline.timer 2>/dev/null || true
  rm -f "$UNITS/lodam-pipeline.service" "$UNITS/lodam-pipeline.timer" "$UNITS/lodam-alert@.service"
  systemctl daemon-reload
  echo "removed lodam-pipeline.service, .timer and lodam-alert@.service (the checkout, its out/ and the image stay)"
  exit 0
fi
[[ $DIR != *[[:space:]]* ]] || { echo "FAIL: the checkout path must not contain spaces: $DIR" >&2; exit 1; }
[ -f .env ] || { echo "FAIL: .env missing (cp .env.example .env, chmod 600 .env, fill in)" >&2; exit 1; }
for cmd in docker git curl flock setpriv getent; do
  command -v "$cmd" > /dev/null || { echo "FAIL: $cmd not installed" >&2; exit 1; }
done
if grep -q '^LODAM_PUBLISH_DIR=.' .env && ! command -v rsync > /dev/null; then
  echo "FAIL: LODAM_PUBLISH_DIR is set, but rsync is not installed (apt install rsync)" >&2; exit 1
fi
grep -q '^LODAM_ALERT_EMAIL_TO=.' .env \
  || echo "note: LODAM_ALERT_EMAIL_TO is not set in .env; failed runs are not mailed (deploy/README.md, Alerts)"
sed "s|@DIR@|$DIR|g" deploy/lodam-pipeline.service > "$UNITS/lodam-pipeline.service"
sed "s|@DIR@|$DIR|g" deploy/lodam-alert@.service > "$UNITS/lodam-alert@.service"
cp deploy/lodam-pipeline.timer "$UNITS/lodam-pipeline.timer"
systemctl daemon-reload
systemctl enable --now lodam-pipeline.timer
systemctl list-timers lodam-pipeline.timer --no-pager
echo "installed. Run now: sudo systemctl start --no-block lodam-pipeline; log: sudo journalctl -u lodam-pipeline -f"
