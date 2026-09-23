#!/usr/bin/env python3
"""Daily Snapchat: capture → Send To → 🔥 → Select All → Send → Telegram chat PNG."""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path
import fcntl
import shlex

SERIAL = os.environ.get("SNAP_SERIAL", "")
SHIMEJI = os.environ.get("SNAP_OVERLAY", "com.anbu.shimeji.desktoppet")
LOCAL = os.environ.get("SNAP_LOCAL") == "1"
TMP_DUMP = Path("/data/local/tmp/snap_uidump.xml" if LOCAL else "/tmp/snap_uidump.xml")
PIN_PATH = Path(os.environ.get("SNAP_PIN_FILE", "secrets/pin"))
ENV_PATH = Path(os.environ.get("SNAP_ENV", "secrets/env"))
CHATS_PATH = Path(os.environ.get("SNAP_CHATS", "secrets/chats"))
OUT_DIR = Path(os.environ.get("SNAP_RUNS", "runs"))
STATE = Path(os.environ.get("SNAP_STATE", "state"))
PENDING = STATE / "pending"
LAST_OK = STATE / "last_ok"
DUMP = "/sdcard/uidump.xml"
FIRE = "🔥"
IST = timezone(timedelta(hours=5, minutes=30))
RUN_STAMP = ""


def sh(*args, timeout=45):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def adb(*args, timeout=45):
    return sh("adb", "-s", SERIAL, *args, timeout=timeout)


def adb_sh(cmd, timeout=45):
    if LOCAL:
        return sh("sh", "-c", cmd, timeout=timeout)
    return adb("shell", cmd, timeout=timeout)


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def parse_nodes(xml_text: str):
    out = []
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return out
    for n in root.iter("node"):
        b = n.attrib.get("bounds") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b)
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        out.append(
            {
                "text": n.attrib.get("text") or "",
                "desc": n.attrib.get("content-desc") or "",
                "cx": (x1 + x2) // 2,
                "cy": (y1 + y2) // 2,
                "x1": x1,
                "y1": y1,
                "x2": x2,
                "y2": y2,
                "w": x2 - x1,
                "h": y2 - y1,
                "click": n.attrib.get("clickable") == "true",
            }
        )
    return out


def dump_ui():
    try:
        TMP_DUMP.unlink()
    except OSError:
        pass
    r = adb_sh(f"rm -f {DUMP}; uiautomator dump {DUMP}")
    blob = (r.stdout or "") + (r.stderr or "")
    if "dumped" not in blob.lower() and LOCAL:
        r = adb_sh(f"rm -f {DUMP}; su 2000 -c 'uiautomator dump {DUMP}'")
        blob = (r.stdout or "") + (r.stderr or "")
    if "dumped" not in blob.lower():
        return ""
    src = Path(DUMP)
    if LOCAL and src.exists():
        try:
            return src.read_text(errors="replace")
        except OSError:
            return ""
    pr = adb("pull", DUMP, str(TMP_DUMP))
    if pr.returncode != 0 or not TMP_DUMP.exists():
        return ""
    try:
        return TMP_DUMP.read_text(errors="replace")
    except OSError:
        return ""


def find(nodes, pred):
    for n in nodes:
        if pred(n):
            return n
    return None


def send_proved(blob: str) -> bool:
    return ("Snap Sent" in blob) or ("Delivered" in blob)


def should_queue(reason: str) -> bool:
    if reason.startswith("proof"):
        return False
    if reason.startswith("stuck"):
        return True
    return reason in {
        "no shutter",
        "no Send To",
        "no fire chip",
        "no Select All",
        "no Send",
        "lock",
        "adb connect",
    }


def compat_ok(nodes):
    titles = " ".join(x["text"] for x in nodes)
    if "Device not compatible" not in titles:
        return None
    return find(nodes, lambda x: x["text"] == "OK")


def is_lock_screen(xml: str, foc: str) -> bool:
    if "Lock screen" in (xml or ""):
        return True
    return "mDreamingLockscreen=true" in (foc or "")


def adb_text(text: str):
    adb_sh("input text " + shlex.quote(text.replace(" ", "%s")))


DISMISS_WORDS = {
    "not now",
    "skip",
    "no thanks",
    "maybe later",
    "close",
    "cancel",
    "got it",
    "later",
    "deny",
    "don't allow",
    "dont allow",
    "not interested",
    "dismiss",
}
NEVER_DISMISS = {
    "send",
    "send to",
    "camera capture",
    "select all",
    "select all button",
    "add",
    "post snap",
    "chat",
    "stories",
    "spotlight",
    "map",
    "camera",
    FIRE.lower(),
}


def overlay_dismiss(nodes):
    """Return a node to tap when a sheet/dialog is covering the next step.

    Name list first (Not now, Skip, OK on the Play dialog). If the label is
    missing from the accessibility tree — Find Friends' Maybe Later is — tap
    the wide unlabeled pill at the bottom of the sheet. Never tap Send,
    shutter, Add, or the nav bar.
    """
    ok = compat_ok(nodes)
    if ok:
        return ok
    labeled = []
    for node in nodes:
        lab = (node.get("text") or node.get("desc") or "").strip().lower()
        if not lab or lab in NEVER_DISMISS:
            continue
        if lab in DISMISS_WORDS:
            labeled.append(node)
    if labeled:
        labeled.sort(key=lambda n: n["cy"], reverse=True)
        return labeled[0]
    pills = []
    for node in nodes:
        if (node.get("text") or node.get("desc") or "").strip():
            continue
        if not node.get("click"):
            continue
        w = node.get("w") or 0
        h = node.get("h") or 0
        if w >= 400 and w <= 800 and 70 <= h <= 180 and 2000 <= node.get("cy", 0) <= 2320:
            pills.append(node)
    if not pills:
        return None
    pills.sort(key=lambda n: n["w"], reverse=True)
    return pills[0]


def tap_node(n):
    adb_sh(f"input tap {int(n['cx'])} {int(n['cy'])}")


def focus():
    return adb_sh("dumpsys window | grep -E 'mCurrentFocus|mDreamingLockscreen'").stdout


def load_pin():
    return PIN_PATH.read_text().strip() if PIN_PATH.exists() else ""


def load_bot_token():
    if not ENV_PATH.exists():
        return ""
    for line in ENV_PATH.read_text().splitlines():
        if line.startswith("TELEGRAM_BOT_TOKEN="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def connect():
    if LOCAL:
        return True
    if not SERIAL:
        log("SNAP_SERIAL is unset")
        return False
    sh("adb", "connect", SERIAL, timeout=15)
    for _ in range(8):
        r = sh("adb", "devices", timeout=10)
        if SERIAL in r.stdout and "device" in r.stdout.split(SERIAL, 1)[-1].split("\n", 1)[0]:
            return True
        time.sleep(2)
        sh("adb", "connect", SERIAL, timeout=15)
    return False


def wake():
    adb_sh("input keyevent 224")
    adb_sh("svc power stayon true")
    adb_sh("settings put system screen_off_timeout 180000")
    adb_sh("cmd statusbar collapse")


def unlock_if_needed(pin: str) -> tuple[bool, bool]:
    info = focus()
    xml = dump_ui()
    locked = "Lock screen" in xml or "mDreamingLockscreen=true" in info
    if not locked:
        adb_sh("cmd statusbar collapse")
        log("unlocked")
        return True, False
    if not pin:
        log("LOCKED and no PIN file")
        return False, False
    v = adb_sh("su 0 -c " + shlex.quote(f"locksettings verify --old {pin}"))
    if "verified successfully" not in (v.stdout + v.stderr):
        log("PIN verify failed")
        return False, False
    adb_sh("su 0 -c " + shlex.quote(f"locksettings clear --old {pin}"))
    adb_sh("su 0 -c 'killall com.android.systemui'")
    time.sleep(2)
    adb_sh("input keyevent 224")
    time.sleep(1)
    adb_sh("cmd statusbar collapse")
    log("unlocked via PIN")
    return True, True


def restore_pin(pin: str):
    if pin:
        adb_sh("su 0 -c " + shlex.quote(f"locksettings set-pin {pin}"))
    adb_sh("svc power stayon false")


def dismiss_compat(nodes):
    n = compat_ok(nodes)
    if not n:
        return False
    tap_node(n)
    time.sleep(0.8)
    log("dismissed Device not compatible")
    return True


def ensure_snap():
    adb_sh(f"am force-stop {SHIMEJI}")
    adb_sh("pm grant com.snapchat.android android.permission.CAMERA")
    adb_sh("pm grant com.snapchat.android android.permission.RECORD_AUDIO")
    adb_sh("am start -n com.snapchat.android/com.snap.mushroom.MainActivity")
    time.sleep(2)


DISMISS_ONLY = {
    "not now", "skip", "no thanks", "maybe later", "close", "cancel",
    "got it", "later", "deny", "not interested", "dismiss",
}


def blocker_present(nodes) -> bool:
    """True when a sheet or dialog is covering the screen.

    A named dismiss word, the Play-services title, or an unnamed wide button in
    the lower band. Used only to decide whether pressing Back is warranted.
    """
    if compat_ok(nodes):
        return True
    for n in nodes:
        lab = (n.get("text") or n.get("desc") or "").strip().lower()
        if lab in DISMISS_ONLY:
            return True
        if lab:
            continue
        if not n.get("click"):
            continue
        if (n.get("w") or 0) >= 350 and (n.get("h") or 0) >= 100 and (n.get("cy") or 0) >= 1600:
            return True
    return False


def restart_snap():
    """Four Backs did not reach the next page. Close Snapchat and open it again."""
    adb_sh("am force-stop com.snapchat.android")
    time.sleep(1)
    ensure_snap()


def wait_nodes(pred, tries=12, delay=0.7):
    last = []
    prev = None
    stuck = 0
    backs = 0
    restarts = 0
    for _ in range(tries):
        xml = dump_ui()
        nodes = parse_nodes(xml)
        last = nodes
        if is_lock_screen(xml, ""):
            adb_sh("input keyevent 224")
            adb_sh("cmd statusbar collapse")
        blocker = overlay_dismiss(nodes)
        if blocker:
            lab = (blocker.get("text") or blocker.get("desc") or "sheet-button")[:40]
            log(f"blocker dismiss: {lab}")
            tap_node(blocker)
            time.sleep(0.9)
            continue
        if pred(nodes):
            return nodes
        sig = tuple((n["text"], n["desc"], n["cy"]) for n in nodes if n["text"] or n["desc"])
        stuck = stuck + 1 if sig == prev else 0
        prev = sig
        if stuck >= 2:
            if not blocker_present(nodes):
                log("idle, no blocker — keep waiting")
                stuck = 0
                prev = None
                time.sleep(delay)
                continue
            stuck = 0
            prev = None
            if backs < 4:
                backs += 1
                log(f"back {backs}/4")
                adb_sh("input keyevent 4")
                time.sleep(0.7)
                nodes = parse_nodes(dump_ui())
                last = nodes
                if pred(nodes) and not overlay_dismiss(nodes):
                    log("back landed on expected page")
                    return nodes
                continue
            if restarts < 2:
                restarts += 1
                backs = 0
                log("4 backs without the next page — restart snap")
                restart_snap()
                continue
            log("4 backs and a restart without the next page — giving up")
            return last
        time.sleep(delay)
    return last

def announce_start(wait_s=12):
    """Tiny dialog APK: 3.2.1 + OK. Auto-finishes; cron does not hang."""
    comp = os.environ.get("SNAP_ANNOUNCE", "").strip()
    if not comp:
        log("announce skipped")
        return
    adb_sh("am start -n " + comp)
    deadline = time.time() + wait_s
    while time.time() < deadline:
        foc = focus()
        if comp.split("/")[0] not in foc:
            break
        time.sleep(0.4)
    log("announce done")


def ist_today():
    return datetime.now(IST).strftime("%Y%m%d")


def mark_pending(reason: str):
    STATE.mkdir(parents=True, exist_ok=True)
    PENDING.write_text(f"{ist_today()} {reason}\n")


def mark_ok():
    STATE.mkdir(parents=True, exist_ok=True)
    LAST_OK.write_text(ist_today() + "\n")
    if PENDING.exists():
        PENDING.unlink()


def already_ok_today():
    return LAST_OK.exists() and LAST_OK.read_text().strip() == ist_today()


def capture_png(dest: Path) -> bool:
    """Reject the 15KB black frame exec-out returns when the panel is off or secure."""
    adb_sh("input keyevent 224")
    try:
        r = subprocess.run(
            ["adb", "-s", SERIAL, "exec-out", "screencap", "-p"],
            capture_output=True,
            timeout=25,
        )
        if r.stdout.startswith(b"\x89PNG") and len(r.stdout) > 80000:
            dest.write_bytes(r.stdout)
            return True
    except Exception:
        pass
    adb_sh("su -c 'screencap -p /sdcard/snap_proof.png'")
    adb("pull", "/sdcard/snap_proof.png", str(dest))
    return dest.exists() and dest.stat().st_size > 80000


def save_debug(msg: str) -> Path | None:
    d = OUT_DIR / f"fail_{RUN_STAMP or ist_today()}"
    d.mkdir(parents=True, exist_ok=True)
    (d / "reason.txt").write_text(msg + "\n")
    try:
        (d / "focus.txt").write_text(focus())
    except Exception as e:
        (d / "focus.txt").write_text(str(e))
    try:
        (d / "ui.xml").write_text(dump_ui())
    except Exception as e:
        (d / "ui.xml").write_text(str(e))
    png = d / "screen.png"
    if capture_png(png):
        return png
    return png if png.exists() else None


def fail(msg, code):
    log(msg)
    if should_queue(msg):
        mark_pending(msg)
    png = save_debug(msg)
    cap = f"snap daily FAIL: {msg}"
    if png:
        send_telegram(png, cap)
    else:
        send_telegram_text(cap)
    return code


def send_telegram_text(text: str) -> None:
    token = load_bot_token()
    if not token or not CHATS_PATH.exists():
        return
    for cid in [c.strip() for c in CHATS_PATH.read_text().splitlines() if c.strip()]:
        sh(
            "curl", "-sS", "-X", "POST",
            f"https://api.telegram.org/bot{token}/sendMessage",
            "-d", f"chat_id={cid}",
            "--data-urlencode", f"text={text[:1500]}",
            timeout=30,
        )


def send_telegram(photo: Path, caption: str) -> bool:
    token = load_bot_token()
    if not token or not photo.exists():
        log("telegram skip")
        return False
    ok = True
    for cid in [c.strip() for c in CHATS_PATH.read_text().splitlines() if c.strip()]:
        r = sh(
            "curl", "-sS",
            "-F", f"chat_id={cid}",
            "-F", f"caption={caption[:900]}",
            "-F", f"photo=@{photo}",
            f"https://api.telegram.org/bot{token}/sendPhoto",
            timeout=60,
        )
        if '"ok":true' in r.stdout.replace(" ", ""):
            log(f"telegram ok {cid}")
        else:
            log(f"telegram fail {cid} {r.stdout[:180]}")
            ok = False
    return ok


def run():
    global RUN_STAMP
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    STATE.mkdir(parents=True, exist_ok=True)
    lockf = open(STATE / "lock", "w")
    try:
        fcntl.flock(lockf.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("already running")
        return 0
    RUN_STAMP = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    stamp = RUN_STAMP
    if already_ok_today() and not os.environ.get("SNAP_FORCE"):
        log("already sent today IST")
        if PENDING.exists():
            PENDING.unlink()
        return 0
    pin = load_pin()
    cleared = False
    connected = False
    try:
        if not connect():
            mark_pending("adb connect")
            send_telegram_text("snap daily queued: phone offline")
            log("adb connect — queued")
            return 2
        connected = True
        wake()
        ok, cleared = unlock_if_needed(pin)
        if not ok:
            return fail("lock", 3)
        adb_sh("settings put system show_touches 1")
        announce_start()

        ensure_snap()
        nodes = wait_nodes(
            lambda ns: find(ns, lambda n: n["desc"] == "Camera Capture")
            or find(ns, lambda n: n["text"] == "Send To")
        )
        send_to = find(nodes, lambda n: n["text"] == "Send To")
        if not send_to:
            capn = find(nodes, lambda n: n["desc"] == "Camera Capture")
            if not capn:
                title = next((n["text"] for n in nodes if n["text"]), "")
                return fail(("stuck: " + title[:40]) if title else "no shutter", 5)
            tap_node(capn)
            nodes = wait_nodes(lambda ns: find(ns, lambda n: n["text"] == "Send To"), tries=15)
            send_to = find(nodes, lambda n: n["text"] == "Send To")
        loc = find(nodes, lambda n: n["text"] == "Don't Allow")
        if loc:
            tap_node(loc)
            time.sleep(0.5)
        if not send_to:
            return fail("no Send To", 6)
        caption = os.environ.get("SNAP_CAPTION", "").strip()
        if caption:
            adb_sh("input tap 540 1100")
            time.sleep(0.6)
            adb_text(caption)
            time.sleep(0.4)
            adb_sh("input keyevent KEYCODE_BACK")
            time.sleep(0.6)
            nodes = wait_nodes(lambda ns: find(ns, lambda n: n["text"] == "Send To"), tries=6)
            send_to = find(nodes, lambda n: n["text"] == "Send To") or send_to
        tap_node(send_to)
        to = os.environ.get("SNAP_TO", "").strip()
        if to:
            time.sleep(1)
            adb_sh("input tap 540 140")
            time.sleep(0.4)
            adb_text(to)
            time.sleep(1.2)
            nodes = wait_nodes(
                lambda ns: find(ns, lambda n: n["text"] == to and n["cy"] > 300),
                tries=10,
            )
            row = find(nodes, lambda n: n["text"] == to and n["cy"] > 300)
            if not row:
                return fail("no " + to, 7)
            tap_node(row)
            time.sleep(0.8)
        else:
            nodes = wait_nodes(lambda ns: find(ns, lambda n: n["desc"] == FIRE or n["text"] == FIRE), tries=10)
            fire = find(nodes, lambda n: n["desc"] == FIRE or (n["text"] == FIRE and n["cy"] < 400))
            if not fire:
                return fail("no fire chip", 7)
            tap_node(fire)
            time.sleep(0.8)
            nodes = wait_nodes(lambda ns: find(ns, lambda n: n["desc"] == "Select All Button"), tries=12)
            sel = find(nodes, lambda n: n["desc"] == "Select All Button")
            if not sel:
                return fail("no Select All", 8)
            tap_node(sel)
            time.sleep(0.8)
        nodes = wait_nodes(lambda ns: find(ns, lambda n: n["desc"] == "Send"), tries=12)
        snd = find(nodes, lambda n: n["desc"] == "Send" and n["cx"] > 800) or find(
            nodes, lambda n: n["desc"] == "Send"
        )
        if not snd:
            return fail("no Send", 9)
        tap_node(snd)
        time.sleep(2.5)
        nodes = parse_nodes(dump_ui())
        # Nav-bar Chat (bottom) is not the sent-snap thread. Tapping it opens the inbox and kills proof.
        chat = find(nodes, lambda n: n["desc"] == "Chat" and n["cy"] < 2000)
        if chat and not send_proved(" ".join(n["text"] for n in nodes)):
            tap_node(chat)
            time.sleep(1.2)
            nodes = parse_nodes(dump_ui())
        png = OUT_DIR / f"chat_{stamp}.png"
        capture_png(png)
        proof = " ".join(n["text"] + n["desc"] for n in nodes)
        ok_ui = send_proved(proof)
        send_telegram(png, f"snap daily {stamp} {'OK' if ok_ui else 'CHECK'}")
        log(f"done ui_ok={ok_ui} png={png}")
        if not ok_ui:
            log(f"proof missing {stamp} — not queued (send may already have gone out)")
            return 10
        mark_ok()
        return 0
    finally:
        if connected:
            adb_sh("settings put system show_touches 0")
            if pin and cleared:
                restore_pin(pin)
            else:
                adb_sh("svc power stayon false")


def _selftest():
    xml = '<?xml version="1.0"?><hierarchy><node text="Send To" content-desc="" bounds="[801,2230][905,2277]"/><node text="" content-desc="🔥" bounds="[163,238][204,283]"/></hierarchy>'
    ns = parse_nodes(xml)
    assert find(ns, lambda n: n["text"] == "Send To")
    assert find(ns, lambda n: n["desc"] == FIRE)
    # Chat button exists before send. It is not proof.
    assert send_proved("Snap Sent")
    assert send_proved("Delivered to the recipient")
    assert not send_proved("Chat")
    assert not send_proved("")
    # Pre-send misses must queue. Post-send proof miss must not (would double-send).
    assert should_queue("no shutter")
    assert should_queue("no Send To")
    assert should_queue("lock")
    assert not should_queue("proof 20260923T000000Z")
    compat = parse_nodes(
        '<hierarchy><node text="Device not compatible" bounds="[1,1][2,2]"/>'
        '<node text="OK" bounds="[836,1302][987,1430]"/></hierarchy>'
    )
    assert compat_ok(compat)["text"] == "OK"
    assert is_lock_screen('<node content-desc="Lock screen" bounds="[0,0][1,1]"/>', "mDreamingLockscreen=false")
    assert not is_lock_screen("<hierarchy/>", "mCurrentFocus=MainActivity mDreamingLockscreen=false")
    sheet = [
        {"text": "Camera Capture", "desc": "", "cx": 539, "cy": 1978, "w": 265, "h": 265, "click": True},
        {"text": "Add", "desc": "", "cx": 937, "cy": 816, "w": 63, "h": 42, "click": True},
        {"text": "", "desc": "", "cx": 540, "cy": 1753, "w": 990, "h": 156, "click": True},
        {"text": "", "desc": "", "cx": 539, "cy": 2243, "w": 493, "h": 123, "click": True},
    ]
    hit = overlay_dismiss(sheet)
    assert hit and hit["cy"] == 2243, hit
    assert overlay_dismiss([{"text": "Not now", "desc": "", "cx": 200, "cy": 400, "w": 80, "h": 40, "click": True}])["text"] == "Not now"
    assert overlay_dismiss([{"text": "Send", "desc": "", "cx": 900, "cy": 2200, "w": 500, "h": 120, "click": True}]) is None
    print("selftest ok")


if __name__ == "__main__":
    if os.environ.get("SNAP_DAILY_SELFTEST"):
        _selftest()
        sys.exit(0)
    sys.exit(run())
