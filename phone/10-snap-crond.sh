#!/system/bin/sh
# Magisk late_start service.d script. Start one crond. Do not add a second copy.
if /system/bin/ps -A 2>/dev/null | /system/bin/grep -q '[c]rond'; then
  exit 0
fi
mkdir -p /data/adb/snap_daily/crontabs /data/adb/snap_daily/runs
/system/xbin/crond -b -L /data/adb/snap_daily/crond.log -c /data/adb/snap_daily/crontabs
