#!/usr/bin/env bash
# Dev cluster must never archive into prod's R2 backup path.
# Posture: the dev manifest declares NO spec.plugins block at all.
set -uo pipefail
DIR=clusters/talos/manifests/cnpg-cartarch-dev
[ -d "$DIR" ] || { echo "dev manifest dir absent, nothing to guard"; exit 0; }
fail=0
for f in "$DIR"/*.yaml; do
  clean=$(sed 's/#.*$//' "$f")
  if echo "$clean" | grep -q 'isWALArchiver: *true'; then
    echo "FAIL $f: isWALArchiver: true"; fail=1
  fi
  if echo "$clean" | grep -q '^[[:space:]]*plugins:'; then
    echo "FAIL $f: spec.plugins block present (dev must not declare an archiver plugin)"; fail=1
  fi
  if echo "$clean" | grep -q 'kind: *ScheduledBackup'; then
    echo "FAIL $f: ScheduledBackup in dev manifest dir"; fail=1
  fi
done
exit $fail
