# input-block: blocks the notebook's physical keyboards, mice, touchpads and
# touchscreen while `remote-desktop attach` is active, so only the VNC viewer
# controls the session. Runs as root from remote-input-block.service
# (configuration.nix); never start it by hand.
#
# It grabs each device exclusively (EVIOCGRAB): Mango gets no events from it.
# The kernel releases a grab as soon as this program ends, for any reason
# (exit, crash, kill), so input can never stay blocked without it.
#
# Emergency override at the desk: hold Ctrl+Alt+Backspace for 3 seconds. The
# program then exits, and the service's stop hook locks the session and turns
# the screens back on (remote-desktop _hook).
#
# Not grabbed: the power and sleep buttons and the lid switch (logind needs
# them), and ydotool's virtual keyboard (not a physical device; `proofread`
# types with it). Devices plugged in later are grabbed within a second.
import select
import sys
import time

import evdev
from evdev import ecodes as e

HOLD_SECONDS = 3.0
RESCAN_SECONDS = 1.0
SKIP_NAMES = ("ydotoold",)
SYSTEM_KEYS = {e.KEY_POWER, e.KEY_SLEEP, e.KEY_SUSPEND, e.KEY_WAKEUP}
CTRL = {e.KEY_LEFTCTRL, e.KEY_RIGHTCTRL}
ALT = {e.KEY_LEFTALT, e.KEY_RIGHTALT}

devices = {}  # fd -> grabbed InputDevice
pressed = {}  # fd -> key codes held down on that device
skipped = set()  # paths looked at and left alone


def log(msg):
    print(msg, flush=True)


def wanted(dev):
    if any(name in dev.name for name in SKIP_NAMES):
        return False
    caps = dev.capabilities()
    if e.EV_REL in caps or e.EV_ABS in caps:
        return True  # mouse, touchpad, trackpoint, touchscreen
    return bool(set(caps.get(e.EV_KEY, [])) - SYSTEM_KEYS)  # keyboard, buttons


def scan():
    paths = set(evdev.list_devices())
    skipped.intersection_update(paths)  # an unplugged path may come back as a new device
    known = {dev.path for dev in devices.values()}
    for path in sorted(paths - known - skipped):
        try:
            dev = evdev.InputDevice(path)
        except OSError:
            continue
        if not wanted(dev):
            skipped.add(path)
            dev.close()
            continue
        try:
            dev.grab()
        except OSError as err:
            log(f"could not grab {path} ({dev.name}): {err}")
            skipped.add(path)
            dev.close()
            continue
        devices[dev.fd] = dev
        pressed[dev.fd] = set()
        log(f"grabbed {path}: {dev.name}")


def drop(fd):
    dev = devices.pop(fd)
    pressed.pop(fd, None)
    log(f"gone: {dev.path} ({dev.name})")
    try:
        dev.close()
    except OSError:
        pass


def combo_held():
    keys = set().union(*pressed.values()) if pressed else set()
    return bool(keys & CTRL) and bool(keys & ALT) and e.KEY_BACKSPACE in keys


def main():
    next_scan = 0.0
    held_since = None
    while True:
        now = time.monotonic()
        if now >= next_scan:
            scan()
            next_scan = now + RESCAN_SECONDS
        timeout = max(0.0, min(next_scan - now, 0.1 if held_since else RESCAN_SECONDS))
        ready, _, _ = select.select(list(devices), [], [], timeout)
        for fd in ready:
            try:
                events = list(devices[fd].read())
            except (OSError, KeyError):
                drop(fd)
                continue
            for ev in events:
                if ev.type != e.EV_KEY:
                    continue
                if ev.value == 1:
                    pressed[fd].add(ev.code)
                elif ev.value == 0:
                    pressed[fd].discard(ev.code)
        if combo_held():
            held_since = held_since or time.monotonic()
            if time.monotonic() - held_since >= HOLD_SECONDS:
                log("Ctrl+Alt+Backspace held at the desk: releasing all input")
                return 0
        else:
            held_since = None


if __name__ == "__main__":
    sys.exit(main())
