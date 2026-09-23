#!/bin/sh
set -eu
ROOT=$(dirname "$0")
export SNAP_STATE=${SNAP_STATE:-$ROOT/../state}
export SNAP_RUNS=${SNAP_RUNS:-$ROOT/../runs}
STATE=$SNAP_STATE
TODAY=$(TZ=Asia/Kolkata date +%Y%m%d)
if [ -f "$STATE/last_ok" ] && [ "$(tr -d "\\n" < "$STATE/last_ok")" = "$TODAY" ]; then rm -f "$STATE/pending"; exit 0; fi
[ -f "$STATE/pending" ] || exit 0
exec python3 "$ROOT/snap_daily.py"
