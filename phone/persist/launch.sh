#!/system/bin/sh
# Boot hook. Copy to /data/adb/service.d/00-persist.sh
# and to the Magisk module service.sh. Same launcher. Not a third loop.
/system/bin/nohup /system/bin/setsid /system/bin/sh /data/adb/persist/run.sh </dev/null >/dev/null 2>&1 &
