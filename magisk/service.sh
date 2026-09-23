#!/system/bin/sh
# late_start. Official module script. Do not also drop a copy in service.d.
MODDIR=${0%/*}
BASE=/data/adb/snap_daily
mkdir -p "$BASE/secrets" "$BASE/state" "$BASE/runs" "$BASE/crontabs"
cp -f "$MODDIR/snap.sh" "$BASE/snap.sh"
cp -f "$MODDIR/run.sh" "$BASE/run.sh"
cp -f "$MODDIR/watch.sh" "$BASE/watch.sh"
cp -f "$MODDIR/crontabs/root" "$BASE/crontabs/root"
chmod 755 "$BASE/snap.sh" "$BASE/run.sh" "$BASE/watch.sh"
chmod 700 "$BASE/secrets" "$BASE/crontabs"
chmod 600 "$BASE/crontabs/root"
if ! ps -A 2>/dev/null | grep -q '[c]rond'; then
  /system/xbin/crond -b -L "$BASE/crond.log" -c "$BASE/crontabs"
fi
