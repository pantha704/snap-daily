#!/system/bin/sh
# Example only. One supervisor. Do not run a second copy of this loop.
# Magisk late_start launches this. It must survive reboot without a laptop.
export PATH=/system/bin:/system/xbin:/product/bin:/data/adb/tailscale/bin
DIR=/data/adb/persist
LOG=$DIR/persist.log
PIDF=$DIR/run.pid
TS_DIR=/data/adb/tailscale
SOCK=$TS_DIR/tmp/tailscaled.sock

# A recycled PID is not "already running". The cmdline must be this script.
if [ -f "$PIDF" ]; then
  OP=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$OP" ] && [ -d "/proc/$OP" ]; then
    if tr '\0' ' ' < /proc/$OP/cmdline 2>/dev/null | grep -q persist/run.sh; then
      exit 0
    fi
  fi
fi
echo $$ > "$PIDF"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

wifi_up() { ip link show wlan0 2>/dev/null | grep -q "state UP"; }

ensure_wifi() {
  wifi_up && return 0
  svc wifi enable
  log wifi-enable
}

# Keep wireless ADB on 5555. Do not stop adbd. Stopping it drops the only remote path.
ensure_adbd() {
  cur=$(getprop persist.adb.tcp.port)
  [ "$cur" = "5555" ] || setprop persist.adb.tcp.port 5555
  cur=$(getprop service.adb.tcp.port)
  [ "$cur" = "5555" ] || setprop service.adb.tcp.port 5555
  [ "$(getprop init.svc.adbd)" = "running" ] || { start adbd; log adbd-start; }
}

# Userspace tailscaled. State file on disk means a reboot does not need a fresh login.
ensure_tsd() {
  pidof tailscaled >/dev/null 2>&1 && return 0
  mkdir -p "$TS_DIR/run" "$TS_DIR/tmp"
  "$TS_DIR/bin/tailscaled" -no-logs-no-support -tun=userspace-networking \
    -statedir="$TS_DIR/tmp" -state="$TS_DIR/tmp/tailscaled.state" \
    -socket="$SOCK" -port=41641 \
    > "$TS_DIR/run/tailscaled.log" 2>&1 &
  log tsd-start
}

log "boot-loop pid=$$"
while true; do
  ensure_wifi
  ensure_adbd
  ensure_tsd
  sleep 5
done
