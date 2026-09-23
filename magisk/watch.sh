#!/system/bin/sh
# Every 5 min. Quiet unless a pre-send miss is queued and today is not done.
set -u
BASE=/data/adb/snap_daily
STATE=$BASE/state
export TZ=Asia/Kolkata
today=$(date +%Y%m%d)
if [ -f "$STATE/last_ok" ] && [ "$(tr -d '\n' < "$STATE/last_ok")" = "$today" ]; then
  rm -f "$STATE/pending"
  exit 0
fi
[ -f "$STATE/pending" ] || exit 0
exec /system/bin/sh "$BASE/run.sh"
