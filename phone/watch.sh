#!/system/bin/sh
# Every 5 min. Silent unless the day's snap is due or a pre-send miss is queued.
#
# WHY THE DAILY DECISION LIVES HERE: busybox crond on this device matches the
# crontab schedule in UTC and ignores TZ in its own environment. Measured on
# 2026-09-24 with TZ=Asia/Kolkata in the daemon env: "* 5 * * *" fired during
# UTC hour 5 while "* 10 * * *" stayed silent during IST hour 10 — so a
# "0 5 * * *" entry means 05:00 UTC, i.e. 10:30 IST, which is how the snap went
# out 5.5 hours late. A 5-minute heartbeat is timezone-proof (every 5 minutes is
# every 5 minutes in any zone), so the crontab provides only that and the IST
# comparison below decides when the day is due.
#
# RETRY GUARDS (why they exist): a queued miss used to re-run every 5 minutes
# with no cap, no battery check and no window. On 2026-09-29 that turned a
# single failure into ~100 wake-ups of a phone that was down to 8% battery,
# plus one Telegram photo per attempt. A retry now needs all of: attempts left
# under SNAP_MAX_TRIES, time still inside SNAP_RETRY_WINDOW after the due time,
# and battery above SNAP_MIN_BATTERY.
set -u
BASE=${SNAP_BASE:-/data/adb/snap_daily}
STATE=$BASE/state
RUNSH=$BASE/run.sh
DUE_MIN=${SNAP_DUE_MIN:-300}           # 05:00 IST, minutes past midnight
MAX_TRIES=${SNAP_MAX_TRIES:-3}         # attempts per IST day, first try included
WINDOW=${SNAP_RETRY_WINDOW:-60}        # attempts stay inside 05:00-06:00 IST
MIN_BAT=${SNAP_MIN_BATTERY:-15}        # below this, do not wake the phone at all
CURL=${SNAP_CURL:-/system/bin/curl}
DUMPSYS=${SNAP_DUMPSYS:-/system/bin/dumpsys}
LOCKSET=${SNAP_LOCKSETTINGS:-/system/bin/locksettings}
export TZ=Asia/Kolkata
mkdir -p "$STATE"

today=$(date +%Y%m%d)
h=$(date +%H); case "$h" in 0*) h=${h#0} ;; esac; [ -n "$h" ] || h=0
m=$(date +%M); case "$m" in 0*) m=${m#0} ;; esac; [ -n "$m" ] || m=0
now_min=$((h * 60 + m))
now_min=${SNAP_NOW_MIN:-$now_min}

tg() { # $1 = tag (deduped per IST day), $2 = message text
  tag=$1; msg=$2
  [ -f "$BASE/secrets/token" ] && [ -f "$BASE/secrets/chats" ] || return 0
  [ -f "$STATE/notified_${today}_$tag" ] && return 0
  : > "$STATE/notified_${today}_$tag"
  tok=$(cat "$BASE/secrets/token")
  cid=$(tr -d '\n' < "$BASE/secrets/chats")
  if ! $CURL -sS --max-time 30 -d "chat_id=$cid" \
    --data-urlencode "text=$msg" \
    "https://api.telegram.org/bot${tok}/sendMessage" 2>/dev/null | grep -q '"ok":true'; then
    spool_text "$msg"
  fi
}

spool_text() {
  mkdir -p "$STATE/tgspool"
  msg=$1
  for f in "$STATE/tgspool"/*.txt; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$msg" ] && return 0
  done
  printf '%s\n' "$msg" > "$STATE/tgspool/$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
}

battery() {
  if [ -n "${SNAP_BATTERY:-}" ]; then echo "$SNAP_BATTERY"; return 0; fi
  lvl=$($DUMPSYS battery 2>/dev/null | awk -F': ' '/^  level:/ {print $2; exit}' || true)
  case "$lvl" in ''|*[!0-9]*) echo 100 ;; *) echo "$lvl" ;; esac
}

# A run that was killed between clearing the PIN and restoring it leaves the
# phone with no lock at all. It drops this marker before clearing, so if the
# marker is still here the device needs relocking.
pin_heal() {
  [ -f "$STATE/pin_cleared" ] || return 0
  [ -f "$BASE/secrets/pin" ] || return 0
  pin=$(cat "$BASE/secrets/pin")
  if $LOCKSET verify --old "$pin" >/dev/null 2>&1; then
    rm -f "$STATE/pin_cleared"
    return 0
  fi
  if $LOCKSET set-pin "$pin" >/dev/null 2>&1; then
    rm -f "$STATE/pin_cleared"
    tg pinheal "snap daily: phone was left UNLOCKED by a killed run — PIN restored"
  else
    tg pinheal_fail "snap daily: phone is UNLOCKED and the PIN could not be restored"
  fi
}

# 1. flush anything Telegram would not take earlier (offline, DNS, timeout)
if [ -f "$BASE/secrets/token" ] && [ -f "$BASE/secrets/chats" ]; then
  tok=$(cat "$BASE/secrets/token")
  cid=$(tr -d '\n' < "$BASE/secrets/chats")
  if [ -d "$STATE/tgspool" ]; then
    for f in "$STATE/tgspool"/*.txt; do
      [ -f "$f" ] || continue
      if $CURL -sS --max-time 30 -d "chat_id=$cid" \
        --data-urlencode "text@$f" \
        "https://api.telegram.org/bot${tok}/sendMessage" 2>/dev/null | grep -q '"ok":true'; then
        rm -f "$f"
      fi
    done
  fi
fi

pin_heal

# 2. housekeeping: keep only today's attempt marker, drop old day files
for f in "$STATE"/ran_*; do
  [ -f "$f" ] || continue
  [ "$f" = "$STATE/ran_$today" ] || rm -f "$f"
done
for f in "$STATE"/tries_* "$STATE"/gaveup_* "$STATE"/notified_* "$STATE"/sent_*; do
  [ -f "$f" ] || continue
  case "$f" in *"_$today") ;; *"_${today}_"*) ;; *) rm -f "$f" ;; esac
done

# 3. the IST day is already done
if [ -f "$STATE/last_ok" ] && [ "$(tr -d '\n' < "$STATE/last_ok")" = "$today" ]; then
  rm -f "$STATE/pending"
  exit 0
fi

# 3b. a snap already went out today even if its proof text never showed up:
# close the day instead of retrying, so no second snap can be sent
if [ -f "$STATE/sent_$today" ]; then
  rm -f "$STATE/pending"
  exit 0
fi

# 4. battery floor: never wake a dying phone, and do not count it as an attempt
lvl=$(battery)
if [ "$lvl" -lt "$MIN_BAT" ]; then
  if [ -f "$STATE/pending" ] || { [ "$now_min" -ge "$DUE_MIN" ] && [ ! -f "$STATE/ran_$today" ]; }; then
    tg lowbat "snap daily: skipped, battery ${lvl}% (below ${MIN_BAT}%) — will try when charged"
  fi
  exit 0
fi

# 5. a queued pre-send miss retries, but only within the cap and the window
if [ -f "$STATE/pending" ]; then
  tries=$(cat "$STATE/tries_$today" 2>/dev/null || echo 0)
  case "$tries" in ''|*[!0-9]*) tries=0 ;; esac
  if [ "$tries" -ge "$MAX_TRIES" ]; then
    rm -f "$STATE/pending"
    : > "$STATE/gaveup_$today"
    tg gaveup "snap daily: giving up for today after $tries attempts"
    exit 0
  fi
  if [ "$now_min" -gt "$((DUE_MIN + WINDOW))" ]; then
    rm -f "$STATE/pending"
    : > "$STATE/gaveup_$today"
    tg window "snap daily: retry window closed ($((DUE_MIN + WINDOW)) min IST) — no snap today"
    exit 0
  fi
  echo $((tries + 1)) > "$STATE/tries_$today"
  exec /system/bin/sh "$RUNSH"
fi

# 6. first attempt of the day: at or after 05:00 IST, and inside the window.
# It is a 05:00 IST snap, so a morning that was missed (phone off, flat, locked
# away) stays missed instead of firing at some random later hour.
if [ "$now_min" -ge "$DUE_MIN" ] && [ "$now_min" -le "$((DUE_MIN + WINDOW))" ] && [ ! -f "$STATE/ran_$today" ]; then
  echo 1 > "$STATE/tries_$today"
  exec /system/bin/sh "$RUNSH"
fi
if [ "$now_min" -gt "$((DUE_MIN + WINDOW))" ] && [ ! -f "$STATE/ran_$today" ] && [ ! -f "$STATE/sent_$today" ]; then
  tg missed "snap daily: the 05:00 IST window passed with no snap today"
fi
exit 0
