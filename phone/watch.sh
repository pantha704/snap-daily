#!/system/bin/sh
# Every 5 min. Quiet unless a pre-send miss is queued and today is not done.
set -u
BASE=/data/adb/snap_daily
STATE=$BASE/state
export TZ=Asia/Kolkata
today=$(date +%Y%m%d)

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
if [ -f "$STATE/last_ok" ] && [ "$(tr -d '\n' < "$STATE/last_ok")" = "$today" ]; then
  rm -f "$STATE/pending"
  exit 0
fi
[ -f "$STATE/pending" ] || exit 0
exec /system/bin/sh "$BASE/run.sh"
