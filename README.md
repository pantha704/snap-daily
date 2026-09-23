# snap-daily

Daily Snapchat camera send from a phone you own. One snap per local day. Default recipient is the fire chip beside All, then Select All, then Send. No caption unless you set one for that run.

Tested on a rooted OnePlus 7T (HD1901), Magisk, wireless ADB on port 5555, userspace Tailscale. Not tested on an unrooted phone. Not tested on other models.

This repository has no bot token, no lock PIN, no chat id, and no tailnet address. Those stay on the phone or the operator host. See [Security](#security).

## Root is required

Yes. A rooted phone is a requirement for this system, not an optional extra.

The job runs at 05:00 even if the screen is locked. Clearing the lock PIN and putting it back is `locksettings` through root. A normal ADB shell cannot clear a PIN that is already set. Without that step the taps hit the lock screen and the cycle fails.

The on-phone scheduler also lives under `/data/adb` and is started from Magisk `service.d`. That path is root-only.

Root does not log into Snapchat for you, and it does not remove Snapchat's own popups. The session must already exist. Popups are handled by the cycle script, described below.

An already-unlocked phone can be tapped over ADB without root. That is not a supported path here, because the morning run must still work when the phone is locked.

## Ground-up requirements

Phone

- A phone you own. Test device: rooted OnePlus 7T.
- Magisk. The test phone used a Magisk late-start service directory.
- Snapchat installed and already logged in. Package `com.snapchat.android`.
- Camera and microphone granted to Snapchat (`pm grant`).
- BusyBox `crond` and `awk` for the on-phone path (`/system/xbin` on the test phone).
- `/system/bin` tools: `sh`, `input`, `uiautomator`, `screencap`, `locksettings`, `svc`, `settings`, `cmd`, `am`, `pm`, `curl`, `dumpsys`.
- A lock PIN file, mode 600, only on the device. Required when the screen may be locked.
- Network at send time. Snapchat has to deliver the snap. Telegram has to take the log. The clock itself does not need network.
- No overlay sitting on the shutter. The test phone had a desktop-pet overlay. The script force-stops the package in `SNAP_OVERLAY` before capture. Default name is `com.anbu.shimeji.desktoppet`. Set the variable empty-safe by changing it if you do not have that app.

Operator host, only if you use path B

- Linux host with `python3`, `adb`, and a cron daemon.
- A route to the phone. On the test setup that route is Tailscale, then `adb connect <phone>:5555`.
- The phone must already be reviving Wi-Fi, ADB, and Tailscale by itself. Path B cannot heal a phone that is dark on the network.

Both paths

- A Telegram bot token in a file that is not in git. One chat id in another file. The cycle posts a photo and a text log there.
- Optional announce activity (`SNAP_ANNOUNCE=package/.Activity`). If set, it is shown before taps and must finish on its own. If unset, the cycle skips it.

Do not install Play Integrity, keybox, or attestation-spoof modules for this job. They are unrelated, and they are the wrong fix for a camera tap.

## Boot persistence

Path A can fire with no PC. Path B still needs the phone to come back after a reboot with Wi-Fi, ADB 5555, and Tailscale up. Both of those are the phone's job, not the VPS's.

Use one supervisor. On the test phone it is a 5-second loop started at Magisk late-start. Example: `phone/persist/run.sh`. Boot hook: `phone/persist/launch.sh`.

What the loop keeps alive

1. Wi-Fi. If `wlan0` is not UP, `svc wifi enable`. Do not add a second Wi-Fi watchdog. One loop is enough. Extra copies fight each other.
2. Wireless ADB on port 5555. Set `persist.adb.tcp.port` and `service.adb.tcp.port` to `5555`. If `adbd` is not running, start it. Do not stop `adbd`. Stopping it removes the only remote path.
3. Tailscale. Userspace `tailscaled`, state file on disk (`tailscaled.state`). A reboot must not require a new login. The daemon is started only if it is not already running. The Android Tailscale app UI does not reflect a userspace daemon, and stopping the app does not stop that daemon.

Revive across boots

- Primary hook: `/data/adb/service.d/00-persist.sh` runs the launcher at late-start.
- Backup hook: one Magisk module `service.sh` that execs the same launcher. Same script, not a second design.
- Do not add a third copy. Do not leave an executable backup inside `service.d`. Magisk runs every executable in that directory.
- Pidfile check must read `/proc/$PID/cmdline` and require `persist/run.sh`. After reboot Android reuses PIDs. A stale pidfile that points at some other process makes the supervisor exit and the phone stays off the tailnet.
- The snap cron has its own boot hook, `phone/10-snap-crond.sh`, installed as `/data/adb/service.d/10-snap-crond.sh`. It starts `crond` only if `crond` is absent. It is not a substitute for the Wi-Fi / ADB / Tailscale loop.

After a reboot, path B is usable only when all three are up: Wi-Fi associated, `adbd` listening on 5555, Tailscale running with the old state file. Probe the tailnet address first. If that is dark and you are on the same LAN, probe the LAN address. If the supervisor pidfile is stale, remove it and run the launcher again. Do not put those addresses in this repo.

## Two ways to run

Pick one. Running both sends two snaps.

### Path A — cron on the phone

This is the path that does not depend on a PC.

- Scripts: `phone/snap.sh`, `phone/run.sh`, `phone/watch.sh`
- Install under `/data/adb/snap_daily/`
- Crontab: `phone/crontabs/root`
- Schedule: `0 5 * * *` in `TZ=Asia/Kolkata` (05:00 IST). Watcher `*/5` runs only when `state/pending` exists and today is not already marked done.
- `run.sh` always sends the text log after the cycle. `snap.sh` sends the photo when it has one.
- Secrets on the phone, mode 600, not in this repo: `secrets/pin`, `secrets/token`, `secrets/chats`, optional `secrets/to`
- Start `crond` now and from the boot hook. A reboot is not required to turn the job on. The boot hook only brings `crond` back after a later reboot.

Idle cost on the test phone: `crond` about 748 KB RSS. The script tree is under 200 KB before screenshots. Each saved shot is about 0.5 MB. There is no cap in `runs/`.

### Path B — cron on a VPS, ADB into the phone

The host runs `vps/snap_daily.py`. The phone only receives ADB. This path needs the boot persistence above, or the morning job dies as "phone offline".

- Set `SNAP_SERIAL` to `<tailnet-or-lan-ip>:5555`. There is no default host in the script.
- Pin, bot token, and chat id come from the paths in `.env.example`.
- Cron the wrapper `vps/snap_daily.sh` at 05:00 in Asia/Kolkata. A UTC host uses `30 23 * * *`.
- Watcher `vps/snap_watch.sh` every 5 minutes. It exits immediately unless `state/pending` exists.
- `SNAP_DAILY_SELFTEST=1 python3 vps/snap_daily.py` checks the parser and the queue rules. It does not touch a phone.
- If path A is enabled, disable this cron. Do not leave both armed.

`SNAP_LOCAL=1` makes the Python script call shell commands directly instead of `adb`. That is how you would run the Python file on a phone that has Python. The tested on-phone runner is the shell script, because the test phone had no Python.

## What one cycle does

1. Take the lock. A second run exits. A busy lock is not a success.
2. If `state/last_ok` is already today's date in Asia/Kolkata, exit. One snap per day unless `SNAP_FORCE=1`.
3. Wake the panel (`KEYCODE_WAKEUP`, 224). Do not use power. Power toggles the screen off. `stayon` is turned off in the exit trap.
4. If the lock screen is up, verify the PIN, clear it, continue, and set the PIN again in the exit trap. If the phone was already unlocked, the PIN is not cleared.
5. Optional announce activity, then force-stop the overlay package and open Snapchat `MainActivity`.
6. Wait until the shutter (`content-desc` `Camera Capture`) or `Send To` is visible and not covered.
7. If still on the camera, tap the shutter. Wait for `Send To`. Never tap Chat. Never tap Post Snap. Never tap Memories in this cycle.
8. Recipient. See below.
9. Tap Send (`content-desc` `Send`, right side of the screen).
10. Screenshot. Reject a tiny black frame (under 80 KB) and try `screencap` again.
11. Proof is the text `Snap Sent` or `Delivered` in the UI dump. A Chat tab, the inbox, or a toast you did not capture is not proof.
12. Post the photo and, on path A, the text log.
13. On proof, write `state/last_ok` and delete `state/pending`. On a proof miss after the Send tap, do not queue a retry. A retry can double-send.

Exit codes from the shell runner: `0` done or skipped, `3` lock, `5` no shutter, `6` no Send To, `7` no fire chip or no named row, `8` no Select All, `9` no Send, `10` Send was tapped but proof text was missing.

## Recipient

Default is the fire group. The script looks for the fire chip near the top of the Send To sheet, taps it, taps Select All, then taps Send.

To send to one person instead, put that exact display name in `secrets/to` (path A) or `SNAP_TO` (path B), one line, no extra words. The script types it into search and taps the row below the search field. Delete the file, or leave it empty, to go back to the fire group. The scheduled default on the test phone is the fire group. A name is a switch, not a hard-coded person.

## Popups

Snapchat shows sheets that are not in any fixed list. Find Friends is one of them. Its dismiss control had no accessibility text.

A step is blocked when the next landmark is missing, a sheet covers that landmark, or the same UI is still there after two dumps.

Dismiss order

1. `OK` only when the title is `Device not compatible`.
2. A labeled dismiss word: Not now, Skip, No thanks, Maybe later, Close, Cancel, Got it, Later, Deny, Don't allow.
3. Otherwise the wide unlabeled footer pill. Width 400–800, height 70–180, vertical center 2000–2320 on a 1080x2400 screen. Do not tap the widest unlabeled node. Friend rows are wider and sit higher. Tapping one adds a person.

Never treat Send, Send To, the shutter, Select All, Add, or the nav bar as a dismiss control.

If two dumps look the same: press Back once. If the expected landmark is then visible and uncovered, continue. If not, reopen Snapchat. At most twice. If it is still stuck, fail with the on-screen title and queue a retry.

## Failsafe

Holds

- Pre-send miss writes `state/pending`. The 5-minute watcher reruns until today is marked done or the pending file is removed.
- One run at a time.
- PIN is restored on normal exit and on SIGTERM, and only if this run cleared it.
- A proof miss is not queued, so a doubtful Send is not repeated all morning.
- `stayon` is cleared on the way out.

Does not hold

- `kill -9` between PIN clear and PIN restore leaves the phone unlocked. SIGTERM is caught. SIGKILL is not.
- If Snapchat never shows `Snap Sent` or `Delivered`, that day is not marked done and is not retried. The next scheduled morning run is the next attempt.
- The watcher does nothing unless `state/pending` exists.
- Path B does nothing if the phone is off the network. That is why the boot loop exists.
- Compose screens often dump an empty accessibility tree. The screenshot is the real map. A black 15 KB PNG is a panel-off or secure-flag frame, not a successful shot.

## Security

Never commit

- The lock PIN
- `TELEGRAM_BOT_TOKEN` or any bot token
- The chat id file
- Tailnet addresses, LAN addresses, or ADB serials of a live phone
- `runs/`, screenshots, UI dumps, and `state/`

`.env.example` shows the variable names only. `.gitignore` ignores `secrets/`, `state/`, `runs/`, and `.env`.

The phone files that hold secrets must be mode 600 and owned by root. The cron log must not echo the PIN or the token. The scripts read those files and pass them to `locksettings` and `curl`. Do not `set -x` around that.

## Not in this scheduled cycle

A saved-Memory send is a different flow. It is not in the 05:00 job. Do not mix it into the shutter path.

If you build that flow separately: open Memories from the filmstrip left of the shutter, stay on Memories Home, never pick from Camera Roll or Add More. On the preview, a down chevron can sit anywhere on the right edge. Tap it, dump again, and do not send until that chevron is gone. There is no up-arrow fallback.

## License

MIT. See `LICENSE`. The test notes describe one rooted OnePlus 7T. They are not a promise that the same coordinates work on every phone.
