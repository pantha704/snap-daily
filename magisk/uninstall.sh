#!/system/bin/sh
# Magisk remove. Stops the job files this module copied. Leaves secrets.
BASE=/data/adb/snap_daily
rm -f "$BASE/snap.sh" "$BASE/run.sh" "$BASE/watch.sh" "$BASE/crontabs/root"
# crond may serve other crontabs. Do not kill it here.
