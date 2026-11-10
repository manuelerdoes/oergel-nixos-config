# Remote desktop: attach to the office session

Plan from 2026-11-04, to build next week at the office.

## Goal

Work from home in the real office Mango session, like RDP: the same windows, the physical screens dark and the physical keyboard and mouse blocked. Build it next week at the office; until every test passes, the current `remote-desktop start` stays the way in.

The current headless desktop is a second, separate Mango. Windows can't move between Wayland compositors, and single-instance apps (Zen, Chromium, Thunderbird, Nextcloud, VS Code) hand a new launch to the copy already running in the office session, so their windows open on the office screens.

## How attach and detach work

`remote-desktop attach [WIDTHxHEIGHT]`, run over SSH:

1. Save which window sits on which screen and tag (`mmsg get all-clients`).
2. Add a virtual screen to the running office session (`mmsg dispatch create_virtual_output`) and set its size to the home monitor's, e.g. `attach 3440x1440`.
3. Start the input block (system service, see Safety nets).
4. Turn off the laptop panel and the external monitors (`disable_monitor`). Mango moves their windows onto the virtual screen.
5. Start wayvnc on the virtual screen only, port 5901, own control socket, through the SSH tunnel.

`remote-desktop detach`, the auto-detach or the emergency combination undo it in this order: lock the session (Noctalia), stop wayvnc, turn the real screens back on, put every window back on its saved screen, remove the virtual screen, release the input block.

**Screen size.** The virtual screen takes whatever size you give it, so one big home screen gets one big desktop, not two office-sized halves. `remote-desktop resize WIDTHxHEIGHT` changes it while attached, as it does today. On a 4K screen, a scale (e.g. 1.5) keeps text readable; `attach` takes it as an option.

**What it looks like.** Windows from both office screens land on the one virtual screen, keeping their tags, so tag 1 of each office screen shows together on tag 1. Detach puts them back on their own screens.

- [ ] Check: does Mango keep each window's tag when its screen is turned off?
- [ ] Check: which `mmsg` call moves a window back to a given screen on detach?
- [ ] Check: can wayvnc follow the viewer window's size by itself, or only through `resize`?

## Safety nets

The computer must never end up unreachable both remotely and at the desk. Each net works on its own:

| Situation | What happens |
| --- | --- |
| Someone at the desk holds **Ctrl+Alt+Backspace for 3 s** | Lock first, then real screens on, VNC ended, input back. Like a physical login kicking out RDP: the desk sees the lock screen and needs the password. |
| A USB keyboard or mouse is plugged in while attached | It's grabbed too, and the emergency combination works on it. |
| A monitor is plugged in while attached | A watcher turns it off again. The emergency combination turns everything back on. |
| Lid opened or closed while attached | `lid.sh` checks the attach state and leaves the screens off. |
| No VNC viewer connected for 5 min (tunnel, VPN or home PC died) | Automatic detach: lock, screens on, input back. |
| Attached for 12 h | The input block stops itself; same as detach. |
| The blocking program crashes, is killed, or Mango crashes | The kernel releases the input devices at once. |
| Reboot or power cut | Nothing is enabled at boot and the state lives in `/run`, so the computer starts exactly as today. |
| Everything else fails | SSH from any machine on the VPN, `remote-desktop detach`. At the desk: the power button (held about 4 s forces it off). |

The power button and the lid switch are never blocked, only keyboards, touchpads and mice.

## Implementation

All in `oergel-nixos-config`, one commit per step so each can be rolled back on its own.

1. **Input-block service** (`configuration.nix`): a small program run as a root systemd service, started on demand, never at boot. It grabs every keyboard, touchpad and mouse exclusively (EVIOCGRAB), also ones plugged in later, watches them for the emergency combination, and exits after 12 h. Your user may start and stop only this unit (polkit rule), so you don't need the `input` group.
2. **Emergency action:** when the combination fires, the service locks the session and calls `remote-desktop detach` as your user, then exits.
3. **`scripts/remote-desktop.sh`:** add `attach` and `detach`; `resize` works for both modes; `start`, `stop` and `status` stay as they are (fallback). The state file lives in `$XDG_RUNTIME_DIR/remote-desktop/`.
4. **Watcher**, started by `attach`: auto-detach after 5 min without a VNC client (`wayvncctl client-list`), turns off newly plugged monitors (`mmsg watch all-monitors`).
5. **`mango/lid.sh`:** do nothing while attached.
6. **README:** a short "Remote desktop" update covering attach, detach, the emergency combination and the fallback.

Prerequisite for attach: you're logged in at the office and the session is locked. After a reboot, use `remote-desktop start`.

## Tests at the office

Use attach from home only after every box is ticked. Keep a second machine with SSH open for all tests.

- [ ] Try `create_virtual_output` alone: note the screen name, set a size, capture it with wayvnc, remove it.
- [ ] `attach` locally without VNC: screens go dark, keyboard and touchpad do nothing.
- [ ] Hold Ctrl+Alt+Backspace 3 s: lock screen appears; after unlocking, both screens and all windows are back where they were.
- [ ] `attach`, then kill the input service from SSH: input returns immediately.
- [ ] Connect VNC from a second device: windows already open in the office session are there and usable; `resize` to the home screen size works.
- [ ] Disconnect the viewer and wait 5 min: auto-detach, session locked.
- [ ] While attached: close and open the lid, plug in a monitor, plug in a USB keyboard (the combination works on it).
- [ ] `detach` over SSH: same result as the combination.
- [ ] Reboot: nothing is blocked; `remote-desktop start` (fallback) still works.

## Open question

- Should detach put windows back on their original office screens, or leave them all on one?
