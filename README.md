# snap-daily

Camera snap, 1 / day, 05:00 Asia/Kolkata. Tested: rooted OnePlus 7T (HD1901) + Magisk.

No token, no PIN, no chat id, no tailnet IP in this repo.

## Package

Magisk module lives in its own repo: **https://github.com/pantha704/snap-daily-magisk** (flashable zip in its Releases). This repo = the cycle scripts, both run paths, and the boot-persist loop.

LSPosed / Zygisk / vector: possible, wrong. Those hooks run inside Snapchat. This job taps from outside (`input` + `uiautomator`). In-app hook breaks on Snapchat updates & can flag the account. ⊥ ship that.

Module ≠ Wi-Fi / ADB / Tailscale loop. That loop stays a separate supervisor. Two Wi-Fi loops fight.

## What the module installs

Separate repo: https://github.com/pantha704/snap-daily-magisk

- `snap.sh` `run.sh` `watch.sh` → `/data/adb/snap_daily/`
- crontab → `/data/adb/snap_daily/crontabs/root`
- `service.sh` starts `crond` at late_start if `crond` absent

Does not install:

- PIN, bot token, chat id (you add those)
- Wi-Fi watchdog, `adbd` :5555, `tailscaled`
- LSPosed hook
- Snapchat

Fallback `/data/adb/service.d/10-snap-crond.sh` is optional and first-install only. Proven order: flash the module, reboot, confirm `crond` is up, then delete the fallback. Both starters check `pidof crond` first and `snap.sh` holds `state/runlock`, so two `crond` cannot double-send. ⊥ delete the fallback first — a reboot then leaves no `crond` and no snap.

## Root

! Root. `locksettings` clear/set PIN needs it. `/data/adb` needs it. Unrooted ADB tap ⊥ supported. 05:00 must work on a locked screen.

Root ⊥ log you into Snapchat. Session must already exist.

## Fire group

! Before first run, in Snapchat:

1. Create a group.
2. Name / emoji = `🔥`.
3. Add the people who should get the daily snap.

Default send → Send To → `🔥` chip beside All → Select All → Send.

That group = the recipient list. Change members in Snapchat. No code change.

One person instead: `secrets/to` or `SNAP_TO` = exact display name, one line. Delete file → back to `🔥` group.

## Requirements

Phone ! 

- rooted, Magisk. Tested OnePlus 7T only.
- Snapchat `com.snapchat.android`, already logged in.
- `pm grant` CAMERA + RECORD_AUDIO.
- BusyBox `crond` + `awk` (`/system/xbin` on test phone).
- `/system/bin`: `sh` `input` `uiautomator` `screencap` `locksettings` `svc` `settings` `cmd` `am` `pm` `curl` `dumpsys`.
- `secrets/pin` mode 600, on device only, if screen may be locked.
- network at send time. Clock itself needs no network.
- no overlay on shutter. `SNAP_OVERLAY` default `com.anbu.shimeji.desktoppet`. Force-stop before capture.

Path B host ! only if VPS drives the phone:

- `python3` `adb` cron
- route to phone. Test setup = Tailscale, then `adb connect <phone>:5555`
- phone must already revive Wi-Fi + ADB + Tailscale. VPS cannot heal a dark phone.

Both:

- Telegram token + one chat id, files not in git.
- `SNAP_ANNOUNCE=package/.Activity` ? optional. Unset → skip.

⊥ Play Integrity / keybox / attestation-spoof modules. Wrong fix for a camera tap.

## Boot persist (path B, and remote heal)

One loop. Example `phone/persist/run.sh`. Boot hook `phone/persist/launch.sh`.

Every 5s:

1. `wlan0` not UP → `svc wifi enable`. ⊥ second Wi-Fi watchdog.
2. `adbd` on port `5555`. Set `persist.adb.tcp.port` + `service.adb.tcp.port`. Start `adbd` if down. ⊥ stop `adbd`.
3. userspace `tailscaled`. State file on disk → reboot ⊥ new login. Start only if absent.

Revive across boots:

- `/data/adb/service.d/00-persist.sh` = primary launcher
- one Magisk module `service.sh` = same launcher, backup
- ⊥ third copy. ⊥ extra executable backup in `service.d` (Magisk runs every executable there)
- pidfile counts only if `/proc/$PID/cmdline` contains `persist/run.sh`. Recycled PID → supervisor exits → phone dark on tailnet.

After reboot, path B works only when Wi-Fi up + `adbd` :5555 + `tailscaled` on old state file. Probe tailnet first, LAN second. Stale pidfile → delete it, run launcher. ⊥ put live addresses in this repo.

Snap cron boot = module `service.sh`. Not a substitute for the persist loop.

## Two run paths

Pick one. Both armed → two snaps.

### A — phone cron

No PC.

- scripts `phone/snap.sh` `phone/run.sh` `phone/watch.sh`
- live dir `/data/adb/snap_daily/`
- crontab = `*/5` heartbeat only. ⊥ cron hour: busybox crond matches in **UTC** & ignores its own `TZ` (`* 5 * * *` fired in UTC hr 5, `* 10 * * *` silent in IST hr 10) → `0 5 * * *` = 10:30 IST. `watch.sh` decides: spool flush → done today? clear + exit → `pending`? run → IST ≥ `DUE_MIN` (300) & no `state/ran_<date>`? run. `snap.sh` writes `ran_<date>` at cycle start (⊥ on dry/selftest) so a proof-miss ⊥ loop.
- `run.sh` → text log after every cycle. Photo when one exists.
- secrets mode 600: `pin` `token` `chats` optional `to`
- reboot ⊥ required to turn the job on. Boot hook only brings `crond` back later.

Idle on test phone: `crond` ~748 KB RSS. Tree < 200 KB before shots. Shot ~0.5 MB. `runs/` has no cap.

### B — VPS cron, ADB into phone

`vps/snap_daily.py`. Phone only receives ADB. Needs the boot loop above.

- `SNAP_SERIAL=<ip>:5555`. No default host.
- pin / token / chat id from `.env.example` paths.
- cron `vps/snap_daily.sh` at 05:00 Asia/Kolkata. UTC host: `30 23 * * *`.
- `vps/snap_watch.sh` every 5 min. Exits unless `state/pending`.
- `SNAP_DAILY_SELFTEST=1 python3 vps/snap_daily.py` → parser + queue rules. No phone.
- path A on → this cron off.

`SNAP_LOCAL=1` = Python calls shell, no `adb`. Tested on-phone runner = shell. Test phone had no Python.

## Cycle

Dry run first: `SNAP_DRY=1 sh /data/adb/snap_daily/run.sh`. It stops before Send and writes no `last_ok` / `pending`. Safe on a real phone.

1. Lock. Second run exits. Busy lock ≠ success.
2. `state/last_ok` = today Asia/Kolkata → exit. `SNAP_FORCE=1` overrides.
3. Wake = keyevent `224`. ⊥ power key (toggles screen off). `stayon` cleared on exit.
4. Locked → verify PIN, clear, run, `set-pin` in exit trap. Already unlocked → PIN not cleared.
5. Optional announce. Force-stop overlay. Open `com.snapchat.android` `MainActivity`.
6. Wait for `Camera Capture` or `Send To`, uncovered.
7. Still on camera → tap shutter. Wait `Send To`. ⊥ Chat. ⊥ Post Snap. ⊥ Memories.
8. Recipient = `🔥` group, or `secrets/to`.
9. Tap `Send`, right side (`cx` > 800).
10. Screenshot. Reject PNG < 80 KB (black / secure frame). Retry `screencap`.
11. Proof = text `Snap Sent` or `Delivered`. Chat tab, inbox, missed toast ⊥ proof.
12. Photo + path A text log.
13. Proof → write `last_ok`, delete `pending`. Proof miss after Send tap → ⊥ queue. Retry can double-send.

Exit: `0` done/skip, `3` lock, `5` no shutter, `6` no Send To, `7` no fire chip / no named row, `8` no Select All, `9` no Send, `10` Send tapped, proof text missing.

## Popups

Sheet with no name still blocks. Find Friends dismiss had no accessibility text.

Blocked = next landmark missing | sheet covers it | same UI twice.

Dismiss order:

1. `OK` only if title = `Device not compatible`.
2. Word: Not now, Skip, No thanks, Maybe later, Close, Cancel, Got it, Later, Deny, Don't allow.
3. Else wide unlabeled footer pill. Width 400–800, height 70–180, cy 2000–2320 on 1080x2400. ⊥ widest node. Friend rows ~990 px & higher. Tap one → adds a person.

⊥ dismiss via Send, Send To, shutter, Select All, Add, nav bar.

Two identical dumps in a row with a blocker on screen → Back, then check the page again. Back only fires when a blocker is actually there: a named dismiss word, the Play-services title, or an unnamed wide button (width ≥ 350, height ≥ 100) in the lower band (cy ≥ 1600). An idle screen with no blocker is waited on, not backed out of. Max **4** Backs. If the page is still wrong after 4, Snapchat is force-stopped and reopened (max **2** restarts), then the step fails with the on-screen title and queues. After every Back the landmark is re-checked, so a Back that lands correctly continues the run immediately.

## Failsafe

Holds: pre-send miss → `state/pending` + 5 min watcher. One run. PIN restore on normal exit & SIGTERM, only if this run cleared it. Proof miss ⊥ queued. `stayon` off on exit.

Offline: ! nothing but snap delivery & Telegram needs net. Clock, unlock, taps, screenshots = local. No net at 05:00 → ⊥ taps, `state/pending` = `offline`, exit `2`, watcher retries every 5 min → snap goes when net returns, same day. One deduped `queued: phone offline` notice spooled. Undeliverable Telegram → `state/tgspool/` (max 20, oldest dropped), flushed by watcher. Exit `2` ⊥ spool a log per retry. `SNAP_ONLINE_HOSTS` = probe hosts; `SNAP_SKIP_ONLINE_CHECK=1` skips probe.

⊥ hold: `kill -9` between PIN clear & restore → phone stays unlocked. No `Snap Sent` / `Delivered` → day not marked, not retried, next 05:00 is next try. Watcher idle unless `pending` exists. Path B idle if phone off network. Empty Compose dump → trust screenshot, not the XML.

## Security

⊥ commit: PIN, bot token, chat id, live tailnet/LAN/ADB serial, `runs/`, shots, UI dumps, `state/`.

`.gitignore` ignores `secrets/` `state/` `runs/` `.env`.

Phone secret files mode 600, root. ⊥ `set -x` around PIN / token.

## Not this cycle

Saved-Memory send ≠ 05:00 job. ⊥ mix into shutter path.

If built separate: filmstrip left of shutter → Memories Home only. ⊥ Camera Roll. ⊥ Add More. Down chevron can sit anywhere on the right edge. Tap, dump again, ⊥ Send until chevron gone. ⊥ up-arrow fallback.

## License

MIT. `LICENSE`. Notes = one rooted OnePlus 7T. ⊥ promise same coordinates on every phone.
