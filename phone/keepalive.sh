#!/system/bin/sh
# keepalive: everything rooted on this phone is started by Magisk's boot stage
# (service.d + post-fs-data.d). When a restart does not run that stage, Android
# comes back on, apps work, and the phone is silently unreachable: no tailscaled,
# no adb 5555, no ssh, and nothing inside the phone can recover, because the only
# thing that would have started them never ran.
#
# crond is the exception: it has its own supervisor loop (see service.sh), so it
# is the one rooted daemon that survives on its own. This script rides that crond
# heartbeat and re-raises the rest of the chain every 5 minutes. It only writes
# to its log when it actually had to do something.
BASE=/data/adb/snap_daily
LOG=$BASE/keepalive.log
PERSIST=/data/adb/persist
TS=/data/adb/tailscale
SOCK=$TS/tmp/tailscaled.sock

log() { echo "$(TZ=Asia/Kolkata date '+%F %T') $*" >> "$LOG"; }

# rotate: keep the last ~8k
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 20000 ]; then
  tail -c 8000 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

sup_alive() {
  p=$(cat "$PERSIST/run.pid" 2>/dev/null)
  [ -n "$p" ] || return 1
  [ -d "/proc/$p" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'persist/run.sh'
}

# 1. the supervisor (it starts tailscaled, adb 5555, dropbear :8022, wifi)
if ! sup_alive; then
  if [ -f "$PERSIST/launch.sh" ]; then
    sh "$PERSIST/launch.sh" 2>/dev/null
    log "supervisor was not running -> relaunched"
    sleep 3
  else
    log "supervisor missing AND no launch.sh (cannot recover from here)"
  fi
fi

# 2. tailscaled, in case it died while the supervisor lived
if ! pidof tailscaled >/dev/null 2>&1; then
  if [ -x "$TS/bin/tailscaled" ]; then
    mkdir -p "$TS/run" "$TS/tmp"
    $TS/bin/tailscaled -no-logs-no-support -tun=userspace-networking \
      -statedir=$TS/tmp -state=$TS/tmp/tailscaled.state \
      -socket=$SOCK -port=41641 >> "$TS/run/tailscaled.log" 2>&1 &
    log "tailscaled was not running -> started"
    sleep 2
  fi
fi

# 3. the tunnel itself. userspace tailscaled can stay up with a dead tunnel
#    after a network reset, which looks healthy to pidof but not to the tailnet.
if pidof tailscaled >/dev/null 2>&1 && [ -x "$TS/bin/tailscale" ]; then
  st=$(timeout 10 "$TS/bin/tailscale" --socket="$SOCK" status 2>&1 | head -4)
  case "$st" in
    *"Logged out"*|*"failed to connect to local tailscaled"*|*"No such file"*|*"timed out"*)
      log "tunnel unhealthy ($(echo "$st" | head -1)) -> restarting tailscaled"
      kill $(pidof tailscaled) 2>/dev/null
      sleep 3
      ;;
  esac
fi

# 4. adb over tcp, the route used from the VPS
[ "$(getprop persist.adb.tcp.port)" = "5555" ] || { setprop persist.adb.tcp.port 5555; log "persist.adb.tcp.port set"; }
[ "$(getprop service.adb.tcp.port)" = "5555" ] || { setprop service.adb.tcp.port 5555; log "service.adb.tcp.port set"; }
[ "$(getprop init.svc.adbd)" = "running" ] || { start adbd 2>/dev/null; log "adbd was not running -> started"; }

# 5. wifi
ip link show wlan0 2>/dev/null | grep -q "state UP" || { svc wifi enable 2>/dev/null; log "wifi was down -> enabled"; }

exit 0
