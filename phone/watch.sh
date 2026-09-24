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
set -u
BASE=/data/adb/snap_daily
STATE=$BASE/state
DUE_MIN=${SNAP_DUE_MIN:-300}   # 05:00 IST, minutes past midnight
export TZ=Asia/Kolkata

# 1. flush anything Telegram would not take earlier (offline, DNS, timeout)
if [ -f "$BASE/secrets/token" ] && [ -f "$BASE/secrets/chats" ]; then
  tok=$(cat "$BASE/secrets/token")
  cid=$(tr -d '\n' < "$BASE/secrets/chats")
  if [ -d "$STATE/tgspool" ]; then
    for f in "$STATE/tgspool"/*.txt; do
      [ -f "$f" ] || continue
      if /system/bin/curl -sS --max-time 30 -d "chat_id=$cid" \
        --data-urlencode "text@$f" \
        "https://api.telegram.org/bot${tok}/sendMessage" 2>/dev/null | grep -q '"ok":true'; then
        rm -f "$f"
      fi
    done
  fi
fi

today=$(date +%Y%m%d)
now_min=$(date +%-H)
now_min=$((now_min * 60 + $(date +%-M)))
now_min=${SNAP_NOW_MIN:-$now_min}

# 2. the IST day is already done
if [ -f "$STATE/last_ok" ] && [ "$(tr -d '\n' < "$STATE/last_ok")" = "$today" ]; then
  rm -f "$STATE/pending"
  exit 0
fi

# 3. a queued pre-send miss always retries
if [ -f "$STATE/pending" ]; then
  exec /system/bin/sh "$BASE/run.sh"
fi

# 4. first attempt of the day: at or after 05:00 IST, once per IST day
for f in "$STATE"/ran_*; do
  [ -f "$f" ] || continue
  [ "$f" = "$STATE/ran_$today" ] || rm -f "$f"
done
if [ "$now_min" -ge "$DUE_MIN" ] && [ ! -f "$STATE/ran_$today" ]; then
  exec /system/bin/sh "$BASE/run.sh"
fi
exit 0
