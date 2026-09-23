#!/system/bin/sh
# Cron entry. Always sends the cycle log to Telegram. Does not print secrets.
set -u
BASE=/data/adb/snap_daily
mkdir -p "$BASE/runs" "$BASE/state"
LOG=$BASE/runs/last.log
export TZ=Asia/Kolkata
export PATH=/system/bin:/system/xbin
: > "$LOG"
/system/bin/sh "$BASE/snap.sh" >>"$LOG" 2>&1
code=$?
echo "exit $code" >>"$LOG"
if [ -f "$BASE/secrets/token" ] && [ -f "$BASE/secrets/chats" ]; then
  tok=$(cat "$BASE/secrets/token")
  cid=$(tr -d '\n' < "$BASE/secrets/chats")
  body=$(/system/bin/tail -n 25 "$LOG" 2>/dev/null || true)
  msg="snap daily log exit $code
$body"
  resp=$(/system/bin/curl -sS --max-time 30 \
    -d "chat_id=$cid" \
    --data-urlencode "text=$msg" \
    "https://api.telegram.org/bot${tok}/sendMessage" 2>/dev/null || true)
  if ! echo "$resp" | grep -q '"ok":true'; then
    if [ "$code" = 2 ]; then
      # offline: state/pending already records it, and the retry will report.
      # Do not spool one log per 5-minute retry.
      :
    else
      mkdir -p "$BASE/state/tgspool"
      printf '%s\n' "$msg" > "$BASE/state/tgspool/$(date -u +%Y%m%dT%H%M%SZ)-run.txt"
    fi
  fi
fi
exit "$code"
