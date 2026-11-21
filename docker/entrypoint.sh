#!/usr/bin/env bash
# Entry point of the pipeline image (planning#4): runs make targets of the mounted pipeline
# checkout, e.g. `fetch release`, `release`, `check`, `test-pipeline`.
# Runs as any non-root user: with `--user $(id -u):$(id -g)` the files written to the mounted
# checkout belong to the caller. PostgreSQL's initdb needs a passwd entry for the current uid, so
# an unknown uid gets one through nss_wrapper (as in the official postgres image).
set -euo pipefail
if [ "$(id -u)" = 0 ]; then
  echo "FAIL: run the pipeline image as a non-root user (--user \"\$(id -u):\$(id -g)\")" >&2; exit 1
fi
[ -f /work/Makefile ] && [ -f /work/mapping/lod-am.r2rml.ttl ] \
  || { echo "FAIL: mount the pipeline checkout at /work (-v \"\$PWD:/work\")" >&2; exit 1; }
if ! getent passwd "$(id -u)" > /dev/null; then
  wrapper=$(ls /usr/lib/*/libnss_wrapper.so 2>/dev/null | head -1)
  [ -n "$wrapper" ] || { echo "FAIL: uid $(id -u) unknown and no nss_wrapper" >&2; exit 1; }
  NSS_WRAPPER_PASSWD=$(mktemp); NSS_WRAPPER_GROUP=$(mktemp)
  cat /etc/passwd > "$NSS_WRAPPER_PASSWD"
  echo "lodam-build:x:$(id -u):$(id -g):LOD-AM pipeline:/tmp:/bin/bash" >> "$NSS_WRAPPER_PASSWD"
  cat /etc/group > "$NSS_WRAPPER_GROUP"
  getent group "$(id -g)" > /dev/null || echo "lodam-build:x:$(id -g):" >> "$NSS_WRAPPER_GROUP"
  export LD_PRELOAD=$wrapper NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP HOME=/tmp
fi
exec make -C /work "${@:-release}"
