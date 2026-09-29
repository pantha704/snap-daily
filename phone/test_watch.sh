#!/system/bin/sh
# Integration tests for watch.sh decision logic, run on the phone in a sandbox.
# Each case builds a state dir, runs watch.sh with a stubbed clock/battery/tools,
# and asserts what it did. Usage: sh test_watch.sh /path/to/watch.sh
set -u
WHICH=${1:-/data/adb/snap_daily/watch.sh}
T=/data/local/tmp/watchtest
PASS=0
FAIL=0

setup() {
  rm -rf "$T"
  mkdir -p "$T/base/state" "$T/bin" "$T/base/runs"
  # stub run.sh records that it was executed
  printf '#!/system/bin/sh\necho invoked >> %s/invoked.log\n' "$T" > "$T/base/run.sh"
  chmod 755 "$T/base/run.sh"
  : > "$T/invoked.log"
  # stub battery: level comes from $T/battery
  echo 80 > "$T/battery"
  printf '#!/system/bin/sh\nif [ "$1" = battery ]; then echo "  level: $(cat %s/battery)"; fi\n' "$T" > "$T/bin/dumpsys"
  # stub curl: record every call
  printf '#!/system/bin/sh\necho call >> %s/curl.log\necho "{\\"ok\\":true}"\n' "$T" > "$T/bin/curl"
  # stub locksettings: verify fails unless $T/lock_ok exists
  printf '#!/system/bin/sh\necho "$@" >> %s/lock.log\nif [ "$1" = verify ]; then [ -f %s/lock_ok ] && exit 0 || exit 1; fi\nexit 0\n' "$T" "$T" > "$T/bin/locksettings"
  chmod 755 "$T/bin/dumpsys" "$T/bin/curl" "$T/bin/locksettings"
  : > "$T/curl.log"; : > "$T/lock.log"
  # telegram secrets so the notify path is reachable
  mkdir -p "$T/base/secrets"
  echo tok > "$T/base/secrets/token"
  echo 123 > "$T/base/secrets/chats"
  echo 4321 > "$T/base/secrets/pin"
}

run_case() {
  # $1 now_min, $2 battery
  env -i PATH=/system/bin:/system/xbin:$T/bin \
    SNAP_BASE=$T/base SNAP_NOW_MIN=$1 SNAP_BATTERY=$2 \
    SNAP_DUMPSYS=$T/bin/dumpsys SNAP_CURL=$T/bin/curl \
    SNAP_LOCKSETTINGS=$T/bin/locksettings \
    /system/bin/sh "$WHICH" >/dev/null 2>&1
  echo $?
}

runs() { wc -l < "$T/invoked.log" 2>/dev/null | tr -d ' '; }
curls() { wc -l < "$T/curl.log" 2>/dev/null | tr -d ' '; }

check() { # $1 name, $2 expected, $3 actual
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "PASS $1"
  else FAIL=$((FAIL + 1)); echo "FAIL $1 (want $2 got $3)"; fi
}

TODAY=$(TZ=Asia/Kolkata date +%Y%m%d)
OLD=20200101

echo "--- testing: $WHICH ---"

# t01 nothing due yet
setup
rc=$(run_case 299 80)
check t01_before_due_no_run 0 "$(runs)"

# t02 due, first attempt
setup
rc=$(run_case 300 80)
check t02_due_fires_once 1 "$(runs)"

# t03 already attempted today, nothing pending
setup
: > "$T/base/state/ran_$TODAY"
rc=$(run_case 400 80)
check t03_attempted_no_double_fire 0 "$(runs)"

# t04 day already done
setup
printf '%s\n' "$TODAY" > "$T/base/state/last_ok"
printf '%s stuck: X\n' "$TODAY" > "$T/base/state/pending"
rc=$(run_case 400 80)
check t04_done_today_no_run 0 "$(runs)"
check t04_pending_cleared gone "$([ -f $T/base/state/pending ] && echo present || echo gone)"

# t05 queued miss retries
setup
printf '%s stuck: X\n' "$TODAY" > "$T/base/state/pending"
rc=$(run_case 330 80)
check t05_pending_retries 1 "$(runs)"
check t05_tries_counted 1 "$(cat $T/base/state/tries_$TODAY 2>/dev/null || echo 0)"

# t06 retry cap reached
setup
printf '%s stuck: X\n' "$TODAY" > "$T/base/state/pending"
echo 3 > "$T/base/state/tries_$TODAY"
rc=$(run_case 340 80)
check t06_cap_stops_run 0 "$(runs)"
check t06_pending_cleared gone "$([ -f $T/base/state/pending ] && echo present || echo gone)"
check t06_gaveup_marker yes "$([ -f $T/base/state/gaveup_$TODAY ] && echo yes || echo no)"

# t07 retry after the window closed
setup
printf '%s stuck: X\n' "$TODAY" > "$T/base/state/pending"
rc=$(run_case 700 80)
check t07_past_window_no_run 0 "$(runs)"
check t07_pending_cleared gone "$([ -f $T/base/state/pending ] && echo present || echo gone)"

# t08 low battery never wakes the phone
setup
printf '%s stuck: X\n' "$TODAY" > "$T/base/state/pending"
rc=$(run_case 330 8)
check t08_low_battery_no_run 0 "$(runs)"
check t08_pending_kept present "$([ -f $T/base/state/pending ] && echo present || echo gone)"

# t09 low battery on the daily fire too
setup
rc=$(run_case 300 9)
check t09_low_battery_skips_daily 0 "$(runs)"

# t10 stale markers pruned
setup
: > "$T/base/state/ran_$OLD"
rc=$(run_case 100 80)
check t10_stale_ran_pruned gone "$([ -f $T/base/state/ran_$OLD ] && echo present || echo gone)"

# t11 a run killed mid-cycle (marker left behind) gets the phone relocked
setup
: > "$T/base/state/pin_cleared"
rc=$(run_case 100 80)
check t11_pin_healed 1 "$(grep -c 'set-pin' "$T/lock.log" | tr -d ' ')"
check t11_marker_cleared gone "$([ -f $T/base/state/pin_cleared ] && echo present || echo gone)"

# t11b a phone the owner deliberately left without a lock is NOT relocked
setup
rc=$(run_case 100 80)
check t11b_no_uninvited_relock 0 "$(grep -c 'set-pin' "$T/lock.log" | tr -d ' ')"

# t12 no repeat telegram spam
setup
rc=$(run_case 330 8)
rc=$(run_case 335 8)
rc=$(run_case 340 8)
check t12_one_notice_max 1 "$(curls)"

# t13 a snap already went out today: never send a second one, even unproven
setup
: > "$T/base/state/sent_$TODAY"
printf '%s stuck: X\n' "$TODAY" > "$T/base/state/pending"
rc=$(run_case 340 80)
check t13_sent_today_no_second_snap 0 "$(runs)"
check t13_pending_cleared gone "$([ -f $T/base/state/pending ] && echo present || echo gone)"

# t14 yesterday's sent marker is cleaned up
setup
: > "$T/base/state/sent_$OLD"
rc=$(run_case 100 80)
check t14_old_sent_pruned gone "$([ -f $T/base/state/sent_$OLD ] && echo present || echo gone)"

echo "--- pass=$PASS fail=$FAIL ---"
[ "$FAIL" = 0 ] || exit 1
