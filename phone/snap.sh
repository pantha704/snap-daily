#!/system/bin/sh
# On-phone daily Snap. Root. No VPS. 05:00 IST via busybox crond.
# Back, then expected page, else reopen Snap. Pre-send miss queues. Post-send miss does not.
set -eu
BASE=/data/adb/snap_daily
STATE=$BASE/state
RUNS=$BASE/runs
DUMP=/sdcard/uidump.xml
NODES=$STATE/nodes.tsv
FIRE_MARK=FIRE
mkdir -p "$STATE" "$RUNS"
CLEARED=0
SNAP_PKG=com.snapchat.android

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

today() { TZ=Asia/Kolkata date +%Y%m%d; }

restore() {
  /system/bin/settings put system show_touches 0 >/dev/null 2>&1 || true
  if [ "$CLEARED" = 1 ] && [ -f "$BASE/secrets/pin" ]; then
    pin=$(cat "$BASE/secrets/pin")
    /system/bin/locksettings set-pin "$pin" >/dev/null 2>&1 || true
  fi
  /system/bin/svc power stayon false >/dev/null 2>&1 || true
}

dump_nodes() {
  src=$1
  /system/xbin/busybox awk '
    function attr(s, name,    p, n, t, q) {
      p = name "=\""
      n = index(s, p)
      if (n == 0) return ""
      t = substr(s, n + length(p))
      q = index(t, "\"")
      if (q == 0) return ""
      return substr(t, 1, q - 1)
    }
    function mark(s) {
      gsub(/&#128293;/, "FIRE", s)
      gsub(/🔥/, "FIRE", s)
      return s
    }
    BEGIN { RS = "<node " }
    NR > 1 {
      text = mark(attr($0, "text"))
      desc = mark(attr($0, "content-desc"))
      click = attr($0, "clickable")
      b = attr($0, "bounds")
      if (b == "") next
      gsub(/\]\[/, ",", b)
      gsub(/[^0-9,]/, "", b)
      n = split(b, a, ",")
      if (n < 4) next
      x1 = a[1] + 0; y1 = a[2] + 0; x2 = a[3] + 0; y2 = a[4] + 0
      cx = int((x1 + x2) / 2); cy = int((y1 + y2) / 2)
      w = x2 - x1; h = y2 - y1
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%s\n", text, desc, cx, cy, w, h, click
    }
  ' "$src" > "$NODES"
}

pick_dismiss() {
  compat=0
  if [ -f "$DUMP" ] && grep -q "Device not compatible" "$DUMP"; then
    compat=1
  fi
  /system/xbin/busybox awk -F '\t' -v compat="$compat" '
    BEGIN { best = ""; score = -1 }
    {
      text = tolower($1); desc = tolower($2)
      cx = $3 + 0; cy = $4 + 0; w = $5 + 0; h = $6 + 0; click = $7
      lab = (text != "" ? text : desc)
      if (lab == "send" || lab == "send to" || lab == "camera capture" || lab == "select all" || lab == "select all button" || lab == "add" || lab == "fire" || lab == "chat" || lab == "stories" || lab == "spotlight" || lab == "map" || lab == "camera" || lab == "post snap") next
      s = -1
      if (compat == 1 && text == "ok") s = 3000000 + cy
      else if (lab == "not now" || lab == "skip" || lab == "no thanks" || lab == "maybe later" || lab == "close" || lab == "cancel" || lab == "got it" || lab == "later" || lab == "deny" || lab == "don\047t allow" || lab == "dont allow" || lab == "not interested" || lab == "dismiss") s = 2000000 + cy
      else if (text == "" && desc == "" && click == "true" && w >= 400 && w <= 800 && h >= 70 && h <= 180 && cy >= 2000 && cy <= 2320) s = w
      if (s > score) { score = s; best = cx " " cy " " lab }
    }
    END { if (best != "") print best }
  ' "$NODES"
}

selftest() {
  tmp=$BASE/state/selftest.xml
  mkdir -p "$BASE/state"
  cat > "$tmp" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="Find Friends" resource-id="" class="android.widget.TextView" package="com.snapchat.android" content-desc="" checkable="false" checked="false" clickable="false" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[60,300][400,360]" drawing-order="0" hint=""/><node index="1" text="" resource-id="" class="android.widget.FrameLayout" package="com.snapchat.android" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[45,1675][1035,1831]" drawing-order="1" hint=""/><node index="2" text="" resource-id="" class="android.widget.Button" package="com.snapchat.android" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[293,2182][786,2305]" drawing-order="2" hint=""/></hierarchy>
XML
  DUMP=$tmp
  dump_nodes "$tmp"
  got=$(pick_dismiss || true)
  echo "sheet dismiss: $got"
  echo "$got" | grep -q "2243" || { echo "pill miss: $got"; exit 1; }
  echo "$got" | grep -q "1753" && { echo "friend row picked"; exit 1; }
  cat > "$tmp" <<'XML'
<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="Not now" resource-id="" class="android.widget.Button" package="com.snapchat.android" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[0,2060][200,2140]" drawing-order="0" hint=""/><node index="1" text="" resource-id="" class="android.widget.Button" package="com.snapchat.android" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="false" focused="false" scrollable="false" long-clickable="false" password="false" selected="false" bounds="[293,2182][786,2305]" drawing-order="1" hint=""/></hierarchy>
XML
  dump_nodes "$tmp"
  got=$(pick_dismiss || true)
  echo "labeled dismiss: $got"
  echo "$got" | grep -q "^100 2100" || { echo "label miss: $got"; exit 1; }
  rm -f "$tmp"
  echo "selftest ok"
  exit 0
}

[ "${SNAP_SELFTEST:-0}" = 1 ] && selftest

trap restore EXIT INT TERM

if [ -f "$STATE/last_ok" ] && [ "$(tr -d '\n' < "$STATE/last_ok")" = "$(today)" ] && [ "${SNAP_FORCE:-0}" != 1 ]; then
  log "already sent today IST"
  rm -f "$STATE/pending"
  exit 0
fi

if ! mkdir "$STATE/runlock" 2>/dev/null; then
  log "already running"
  exit 0
fi
trap 'rmdir "$STATE/runlock" 2>/dev/null || true; restore' EXIT INT TERM

stamp=$(date -u +%Y%m%dT%H%M%SZ)
log "cycle $stamp"

wake() {
  /system/bin/input keyevent 224
  /system/bin/svc power stayon true
  /system/bin/settings put system screen_off_timeout 180000
  /system/bin/cmd statusbar collapse || true
}

unlock_if_needed() {
  info=$(/system/bin/dumpsys window | /system/bin/grep -E 'mCurrentFocus|mDreamingLockscreen' | /system/bin/head -5 || true)
  xml=""
  if [ -f "$DUMP" ]; then xml=$(head -c 4000 "$DUMP" || true); fi
  locked=0
  echo "$info" | grep -q 'mDreamingLockscreen=true' && locked=1
  echo "$xml" | grep -q 'Lock screen' && locked=1
  if [ "$locked" = 0 ]; then
    log "unlocked"
    return 0
  fi
  [ -f "$BASE/secrets/pin" ] || { log "LOCKED and no PIN file"; return 1; }
  pin=$(cat "$BASE/secrets/pin")
  v=$(/system/bin/locksettings verify --old "$pin" 2>&1 || true)
  echo "$v" | grep -q "verified successfully" || { log "PIN verify failed"; return 1; }
  /system/bin/locksettings clear --old "$pin" >/dev/null 2>&1 || true
  CLEARED=1
  /system/bin/killall com.android.systemui >/dev/null 2>&1 || true
  sleep 2
  /system/bin/input keyevent 224
  sleep 1
  log "unlocked via PIN"
}

refresh() {
  rm -f "$DUMP"
  out=$(/system/bin/uiautomator dump "$DUMP" 2>&1 || true)
  echo "$out" | grep -q -i dumped || /system/bin/su 2000 -c "uiautomator dump $DUMP" >/dev/null 2>&1 || true
  [ -f "$DUMP" ] || return 1
  dump_nodes "$DUMP"
}

first_title() {
  /system/xbin/busybox awk -F '\t' '$1 != "" { print substr($1,1,40); exit }' "$NODES"
}

landmark_line() {
  name=$1
  case "$name" in
    shutter) /system/xbin/busybox awk -F '\t' '$2 == "Camera Capture" { print; exit }' "$NODES" ;;
    ready) /system/xbin/busybox awk -F '\t' '$2 == "Camera Capture" || $1 == "Send To" { print; exit }' "$NODES" ;;
    sendto) /system/xbin/busybox awk -F '\t' '$1 == "Send To" { print; exit }' "$NODES" ;;
    fire) /system/xbin/busybox awk -F '\t' '($1 == "FIRE" || $2 == "FIRE") && ($4 + 0) < 400 { print; exit }' "$NODES" ;;
    selectall) /system/xbin/busybox awk -F '\t' '$2 == "Select All Button" { print; exit }' "$NODES" ;;
    sendbtn) /system/xbin/busybox awk -F '\t' '$2 == "Send" && ($3 + 0) > 800 { print; exit }' "$NODES" ;;
  esac
}

tap_line() {
  line=$1
  cx=$(printf '%s' "$line" | /system/xbin/busybox awk -F '\t' '{print $3}')
  cy=$(printf '%s' "$line" | /system/xbin/busybox awk -F '\t' '{print $4}')
  [ -n "$cx" ] && [ -n "$cy" ] || return 1
  /system/bin/input tap "$cx" "$cy"
}

queue_reason() {
  r=$1
  case "$r" in
  stuck:*|no\ *) return 0 ;;
  esac
  return 1
}

shot() {
  dest=$1
  /system/bin/input keyevent 224
  /system/bin/screencap -p "$dest" || true
  sz=0
  [ -f "$dest" ] && sz=$(stat -c %s "$dest" 2>/dev/null || echo 0)
  if [ "$sz" -lt 80000 ]; then
    /system/bin/screencap -p /sdcard/snap_proof.png || true
    cp /sdcard/snap_proof.png "$dest" 2>/dev/null || true
  fi
}

tg_photo() {
  cap=$1
  png=$2
  [ -f "$BASE/secrets/token" ] && [ -f "$BASE/secrets/chats" ] || { log "no telegram secrets"; return 1; }
  tok=$(cat "$BASE/secrets/token")
  cid=$(tr -d '\n' < "$BASE/secrets/chats")
  resp=$(/system/bin/curl -sS --max-time 60 \
    -F "chat_id=$cid" \
    -F "caption=$cap" \
    -F "photo=@$png" \
    "https://api.telegram.org/bot${tok}/sendPhoto" || true)
  echo "$resp" | grep -q '"ok":true' && log "telegram photo ok" || log "telegram photo fail"
}

fail() {
  msg=$1
  code=$2
  log "$msg"
  d=$RUNS/fail_$stamp
  mkdir -p "$d"
  printf '%s\n' "$msg" > "$d/reason.txt"
  cp "$DUMP" "$d/ui.xml" 2>/dev/null || true
  shot "$d/screen.png"
  if queue_reason "$msg"; then
    printf '%s %s\n' "$(today)" "$msg" > "$STATE/pending"
    log "queued"
  fi
  if [ -f "$d/screen.png" ]; then
    tg_photo "snap daily FAIL: $msg" "$d/screen.png"
  fi
  exit "$code"
}

wait_landmark() {
  name=$1
  tries=$2
  reopens=0
  prev=""
  stuck=0
  i=0
  while [ "$i" -lt "$tries" ]; do
    refresh || true
    info=$(/system/bin/dumpsys window | /system/bin/grep mDreamingLockscreen || true)
    echo "$info" | grep -q 'mDreamingLockscreen=true' && wake
    dis=$(pick_dismiss || true)
    if [ -n "$dis" ]; then
      set -- $dis
      log "blocker dismiss: ${3:-sheet-button}"
      /system/bin/input tap "$1" "$2"
      sleep 0.9
      stuck=0
      prev=""
      i=$((i + 1))
      continue
    fi
    line=$(landmark_line "$name" || true)
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    sig=$(/system/xbin/busybox awk -F '\t' 'NF { print $1 "|" $2 "|" $4 }' "$NODES" | /system/bin/head -40 | tr '\n' ';')
    if [ "$sig" = "$prev" ]; then stuck=$((stuck + 1)); else stuck=0; fi
    prev=$sig
    if [ "$stuck" -ge 2 ]; then
      log "stuck — back once"
      /system/bin/input keyevent 4
      sleep 0.6
      refresh || true
      dis=$(pick_dismiss || true)
      line=$(landmark_line "$name" || true)
      if [ -z "$dis" ] && [ -n "$line" ]; then
        log "back landed on expected page"
        printf '%s\n' "$line"
        return 0
      fi
      if [ "$reopens" -lt 2 ]; then
        reopens=$((reopens + 1))
        log "not expected page — reopen snap"
        /system/bin/am force-stop com.anbu.shimeji.desktoppet >/dev/null 2>&1 || true
        /system/bin/am start -n "$SNAP_PKG/com.snap.mushroom.MainActivity" >/dev/null 2>&1 || true
        sleep 2
      fi
      stuck=0
      prev=""
    fi
    sleep 0.7
    i=$((i + 1))
  done
  return 1
}

ensure_snap() {
  /system/bin/am force-stop com.anbu.shimeji.desktoppet >/dev/null 2>&1 || true
  /system/bin/pm grant "$SNAP_PKG" android.permission.CAMERA >/dev/null 2>&1 || true
  /system/bin/pm grant "$SNAP_PKG" android.permission.RECORD_AUDIO >/dev/null 2>&1 || true
  /system/bin/am start -n "$SNAP_PKG/com.snap.mushroom.MainActivity" >/dev/null 2>&1 || true
  sleep 2
}

wake
refresh || true
unlock_if_needed || fail "lock" 3
/system/bin/settings put system show_touches 1
ann=${SNAP_ANNOUNCE:-}
if [ -n "$ann" ]; then
  /system/bin/am start -n "$ann" >/dev/null 2>&1 || true
  w=0
  while [ "$w" -lt 24 ]; do
    foc=$(/system/bin/dumpsys window | /system/bin/grep mCurrentFocus || true)
    echo "$foc" | grep -q "${ann%%/*}" || break
    sleep 0.5
    w=$((w + 1))
  done
fi
log "announce done"
ensure_snap

line=$(wait_landmark ready 12 || true)
if [ -z "$line" ]; then
  title=$(first_title || true)
  if [ -n "$title" ]; then fail "stuck: $title" 5; else fail "no shutter" 5; fi
fi
sendline=$(landmark_line sendto || true)
if [ -z "$sendline" ]; then
  tap_line "$line"
  sendline=$(wait_landmark sendto 15 || true)
fi
[ -n "$sendline" ] || fail "no Send To" 6
tap_line "$sendline"

TO=""
if [ -f "$BASE/secrets/to" ]; then
  TO=$(tr -d '\r\n' < "$BASE/secrets/to")
fi
if [ -n "$TO" ]; then
  log "recipient $TO"
  /system/bin/input tap 540 140
  sleep 0.4
  /system/bin/input text "$(printf '%s' "$TO" | /system/bin/sed 's/ /%s/g')"
  sleep 1.2
  row=""
  n=0
  while [ "$n" -lt 8 ]; do
    refresh || true
    row=$(/system/xbin/busybox awk -F '\t' -v name="$TO" '$1 == name && ($4 + 0) > 300 { print; exit }' "$NODES")
    [ -n "$row" ] && break
    sleep 0.6
    n=$((n + 1))
  done
  [ -n "$row" ] || fail "no $TO" 7
  tap_line "$row"
  sleep 0.8
else
  log "recipient fire-select-all"
  fire=$(wait_landmark fire 10 || true)
  [ -n "$fire" ] || fail "no fire chip" 7
  tap_line "$fire"
  sleep 0.8
  sel=$(wait_landmark selectall 8 || true)
  [ -n "$sel" ] || fail "no Select All" 8
  tap_line "$sel"
  sleep 0.8
fi
snd=$(wait_landmark sendbtn 8 || true)
[ -n "$snd" ] || fail "no Send" 9
if [ "${SNAP_DRY:-0}" = 1 ]; then
  log "dry run — stopping before Send"
  png=$RUNS/dry_$stamp.png
  shot "$png"
  tg_photo "snap daily DRY $stamp — reached Send, nothing sent" "$png"
  /system/bin/am force-stop "$SNAP_PKG" >/dev/null 2>&1 || true
  log "dry run done"
  exit 0
fi
tap_line "$snd"
sleep 2.5
refresh || true
png=$RUNS/chat_$stamp.png
shot "$png"
proof=$(tr '\n' ' ' < "$NODES" || true)
if echo "$proof" | grep -q -e 'Snap Sent' -e 'Delivered'; then
  printf '%s\n' "$(today)" > "$STATE/last_ok"
  rm -f "$STATE/pending"
  tg_photo "snap daily $stamp OK" "$png"
  log "done ui_ok=1"
  exit 0
fi
tg_photo "snap daily $stamp CHECK" "$png"
log "done ui_ok=0 proof missing — not queued"
exit 10
