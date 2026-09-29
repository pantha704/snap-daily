#!/bin/sh
set -eu
ROOT=$(dirname "$0")
export SNAP_STATE=${SNAP_STATE:-$ROOT/../state}
export SNAP_RUNS=${SNAP_RUNS:-$ROOT/../runs}
STATE=$SNAP_STATE
TODAY=$(TZ=Asia/Kolkata date +%Y%m%d)
DUE_MIN=${SNAP_DUE_MIN:-300}      # 05:00 IST, minutes past midnight
MAX_TRIES=${SNAP_MAX_TRIES:-3}    # attempts per IST day, first try included
WINDOW=${SNAP_RETRY_WINDOW:-60}   # attempts stay inside 05:00-06:00 IST
MIN_BAT=${SNAP_MIN_BATTERY:-15}   # below this, never wake the phone
H=$(TZ=Asia/Kolkata date +%H); case "$H" in 0*) H=${H#0} ;; esac; [ -n "$H" ] || H=0
M=$(TZ=Asia/Kolkata date +%M); case "$M" in 0*) M=${M#0} ;; esac; [ -n "$M" ] || M=0
NOW_MIN=$((H * 60 + M))
NOW_MIN=${SNAP_NOW_MIN:-$NOW_MIN}   # overridable so the guards can be tested
if [ -f "$STATE/last_ok" ] && [ "$(tr -d "\\n" < "$STATE/last_ok")" = "$TODAY" ]; then rm -f "$STATE/pending"; exit 0; fi
# a snap already went out today, proof text or not: never send a second one
if [ -f "$STATE/sent_$TODAY" ]; then rm -f "$STATE/pending"; exit 0; fi

# battery floor: never drive a phone that is nearly flat; keep the day open
if [ -n "${SNAP_SERIAL:-}" ] && [ "${SNAP_SKIP_BATTERY_CHECK:-0}" != 1 ]; then
  LVL=$(adb -s "$SNAP_SERIAL" shell dumpsys battery 2>/dev/null | awk -F': ' '/^  level:/ {print $2; exit}' || true)
  case "$LVL" in ''|*[!0-9]*) LVL=100 ;; esac
  if [ "$LVL" -lt "$MIN_BAT" ]; then
    echo "snap watch: skipped, battery ${LVL}% below ${MIN_BAT}%" >&2
    exit 0
  fi
fi

if [ -f "$STATE/pending" ]; then
  TRIES=$(cat "$STATE/tries_$TODAY" 2>/dev/null || echo 0)
  case "$TRIES" in ''|*[!0-9]*) TRIES=0 ;; esac
  if [ "$TRIES" -ge "$MAX_TRIES" ]; then
    rm -f "$STATE/pending"; : > "$STATE/gaveup_$TODAY"; exit 0
  fi
  if [ "$NOW_MIN" -gt "$((DUE_MIN + WINDOW))" ]; then
    rm -f "$STATE/pending"; : > "$STATE/gaveup_$TODAY"; exit 0
  fi
  echo $((TRIES + 1)) > "$STATE/tries_$TODAY"
  exec python3 "$ROOT/snap_daily.py"
fi

# first attempt of the day: inside the 05:00 IST window, once per IST day
if [ "$NOW_MIN" -ge "$DUE_MIN" ] && [ "$NOW_MIN" -le "$((DUE_MIN + WINDOW))" ] && [ ! -f "$STATE/ran_$TODAY" ]; then
  echo 1 > "$STATE/tries_$TODAY"
  exec python3 "$ROOT/snap_daily.py"
fi
exit 0
