#!/bin/sh
# Sandbox tests for the VPS watcher guards (path B). Runs anywhere with sh+python3.
set -eu
ROOT=$(dirname "$0")
T=$(mktemp -d)
mkdir -p "$T/state" "$T/vps"
cp "$ROOT/snap_watch.sh" "$T/vps/"
cat > "$T/vps/snap_daily.py" <<'PY'
import os, pathlib, datetime
s = pathlib.Path(os.environ.get("SNAP_STATE", "state"))
s.mkdir(parents=True, exist_ok=True)
(s / ("ran_" + datetime.datetime.now().strftime("%Y%m%d"))).touch()
(s / "python_ran").touch()
PY
TODAY=$(TZ=Asia/Kolkata date +%Y%m%d)
OLD=20200101
PASS=0; FAIL=0

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 (want $2 got $3)"; fi; }
reset() { rm -rf "$T/state"; mkdir -p "$T/state"; }
run() { SNAP_STATE="$T/state" SNAP_RUNS="$T/runs" SNAP_NOW_MIN="${1:-300}" sh "$T/vps/snap_watch.sh" >/dev/null 2>&1 || true; }
ran() { [ -f "$T/state/python_ran" ] && echo yes || echo no; }

reset; run 299;                                check t01_before_due_no_run no "$(ran)"
reset; run 300;                                check t02_due_fires yes "$(ran)"
reset; touch "$T/state/ran_$TODAY"; run 400;    check t03_attempted_no_double_fire no "$(ran)"
reset; printf '%s\n' "$TODAY" > "$T/state/last_ok"; touch "$T/state/pending"; run 400
check t04_done_today_no_run no "$(ran)"
check t04_pending_cleared gone "$([ -f $T/state/pending ] && echo present || echo gone)"
reset; touch "$T/state/sent_$TODAY"; touch "$T/state/pending"; run 340
check t05_sent_today_no_second_snap no "$(ran)"
check t05_pending_cleared gone "$([ -f $T/state/pending ] && echo present || echo gone)"
reset; touch "$T/state/pending"; run 330;       check t06_pending_retries yes "$(ran)"
check t06_tries_counted 1 "$(cat $T/state/tries_$TODAY 2>/dev/null || echo 0)"
reset; touch "$T/state/pending"; echo 3 > "$T/state/tries_$TODAY"; run 340
check t07_cap_stops_run no "$(ran)"
check t07_gaveup_marker yes "$([ -f $T/state/gaveup_$TODAY ] && echo yes || echo no)"
reset; touch "$T/state/pending"; run 700
check t08_past_window_no_run no "$(ran)"
check t08_pending_cleared gone "$([ -f $T/state/pending ] && echo present || echo gone)"

rm -rf "$T"
echo "--- pass=$PASS fail=$FAIL ---"
[ "$FAIL" = 0 ] || exit 1
