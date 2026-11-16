# remote-desktop: work on the notebook from home, over VNC.
#
#   remote-desktop attach [WIDTHxHEIGHT] [SCALE]   take over the office session
#   remote-desktop detach                          give it back (locks it)
#   remote-desktop start [WIDTHxHEIGHT]            a separate desktop (fallback)
#   remote-desktop stop                            end the separate desktop
#   remote-desktop resize WIDTHxHEIGHT             change the size; windows stay
#   remote-desktop status                          what is running?
#
# Run it over SSH. Both modes serve VNC on port 5901 (localhost only).
# Connect from home (after the work VPN):
#   ssh -L 5901:localhost:5901 <user>@<notebook>      then: remote-desktop attach
#   VNC viewer -> localhost:5901
#
# attach: like RDP. Needs you logged in at the office (leave it locked). Adds a
# virtual screen to that Mango session, turns off the real screens (their
# windows move to the virtual one), blocks the physical keyboard, mouse and
# touchpad, and shares only the virtual screen. Everything is undone, with the
# session locked, by `detach`, by Ctrl+Alt+Backspace held 3 s at the desk, by
# 5 minutes without a VNC viewer, after 12 hours, or if any part of it dies.
# Nothing survives a reboot. See remote-desktop-attach-plan.md.
#
# start: a second, headless Mango with its own windows, for when nobody is
# logged in at the notebook (e.g. after a reboot). Windows already open in the
# office session don't show up there.
set -euo pipefail

PORT=5901
MANGO_SETTINGS="$HOME/.config/mango/settings.conf"
LID_SCRIPT="$HOME/.config/mango/lid.sh"
DIR="${XDG_RUNTIME_DIR:?is not set. Log in through SSH or a normal session.}/remote-desktop"

# start: the separate headless desktop
UNIT=remote-desktop
OUTPUT=HEADLESS-1 # the screen the headless backend creates by itself

# attach: the office session
VOUT=REMOTE-1                         # the virtual screen added to the office session
ATTACH_UNIT=remote-desktop-attach     # user unit: wayvnc + the watcher
NOCTALIA_UNIT=noctalia-office         # user unit: Noctalia, if it had to be restarted
BLOCK_UNIT=remote-input-block.service # system unit: blocks physical input (configuration.nix)
STATE="$DIR/attached"                 # exists while attached; lid.sh checks it
OUTPUTS_FILE="$DIR/attached-outputs"  # the real screens to turn back on: "name x y" per line
LOCK="$DIR/attach.lock"
VNC_SOCK="$DIR/wayvncctl-attach"
IDLE_DETACH=300 # seconds without a VNC viewer before detaching by itself

die() {
  echo "remote-desktop: $*" >&2
  exit 1
}

usage() {
  sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

is_running() { systemctl --user is-active --quiet "$UNIT"; }

is_attached() { [ -f "$STATE" ]; }

listening() { [ -n "$(ss -Hltn "sport = :$PORT" 2>/dev/null)" ]; }

valid_size() { [[ "$1" =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]] || die "the size must look like 1920x1080."; }

valid_scale() { [[ "$1" =~ ^[1-9](\.[0-9]+)?$ ]] || die "the scale must look like 1 or 1.5."; }

# Keyboard layout from the Mango settings, as wayvnc wants it: layout[-variant]
keymap() {
  local layout variant
  layout="$(sed -n -E '/^xkb_rules_layout=/{s/^xkb_rules_layout=([^[:space:]]*).*/\1/p;q}' "$MANGO_SETTINGS")"
  variant="$(sed -n -E '/^xkb_rules_variant=/{s/^xkb_rules_variant=([^[:space:]]*).*/\1/p;q}' "$MANGO_SETTINGS")"
  printf '%s%s' "${layout:-us}" "${variant:+-$variant}"
}

# ================================================================== start/stop
# The Wayland display of the running headless desktop (e.g. wayland-1), read
# from the environment of its wayvnc. Not from Mango itself: it may still
# carry the office session's WAYLAND_DISPLAY from systemd.
session_display() {
  local cg pid d
  cg="$(systemctl --user show -p ControlGroup --value "$UNIT")"
  [ -n "$cg" ] || return 1
  for pid in $(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null); do
    [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = wayvnc ] || continue
    d="$({ tr '\0' '\n' <"/proc/$pid/environ"; } 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p' || true)"
    if [ -n "$d" ]; then
      echo "$d"
      return
    fi
  done
  return 1
}

# Sets the size of the virtual screen in the headless desktop. Open windows
# stay; wayvnc sends the new size to the viewer.
set_size() {
  local display
  display="$(session_display)" || die "can't find the remote desktop's Wayland display."
  WAYLAND_DISPLAY="$display" wlr-randr --output "$OUTPUT" --custom-mode "$1" ||
    die "couldn't set the size to $1."
}

start() {
  local size="${1:-1920x1080}" config session
  valid_size "$size"
  [ -r "$MANGO_SETTINGS" ] || die "no Mango settings at $MANGO_SETTINGS."
  is_attached && die "attached to the office session. End that first: remote-desktop detach"
  if is_running; then
    if listening; then
      if [ -n "${1:-}" ]; then
        set_size "$size"
        echo "Resized to $size."
      fi
      echo "Already running. Connect the VNC viewer to localhost:$PORT (through the SSH tunnel)."
      return
    fi
    echo "Running, but without VNC (an earlier start went wrong). Restarting it."
    systemctl --user stop "$UNIT"
  fi

  config="$DIR/mango.conf"
  session="$DIR/session.sh"
  mkdir -p "$DIR"

  # Mango runs this once it's up, inside the new session (WAYLAND_DISPLAY
  # points at it). Mango 0.18 needs wayvnc-screencopy (see configuration.nix).
  # -S: its own control socket. The default one belongs to the wayvnc of the
  # office session, and a second wayvnc refuses to start while that one runs.
  cat >"$session" <<EOF
#!/bin/sh
# Generated by remote-desktop.
noctalia &
sleep 1
exec wayvnc-screencopy -S $DIR/wayvncctl -o $OUTPUT -k $(keymap) 127.0.0.1 $PORT
EOF
  chmod +x "$session"

  # Your normal Mango settings (not config.conf, whose autostart is for the
  # office session), plus the size of the virtual screen.
  cat >"$config" <<EOF
# Generated by remote-desktop: your Mango settings plus a virtual screen.
source=$MANGO_SETTINGS
monitor_rule=name:^$OUTPUT\$,width:${size%x*},height:${size#*x},refresh:60
exec_once=$session
EOF

  # A systemd user service: it survives a dropped SSH connection, and stopping
  # it closes everything started inside it. bash -l loads the normal login
  # environment (PATH, the session variables from the NixOS config).
  # Without a screen, software rendering can't get buffers from the GPU device
  # (gbm_bo_create: Permission denied), so LIBGL_ALWAYS_SOFTWARE, a VM
  # workaround for the office session, is switched off here.
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  systemd-run --user --quiet --unit="$UNIT" \
    --description="Remote desktop (headless Mango)" \
    --setenv=WLR_BACKENDS=headless \
    --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
    bash -lc "unset LIBGL_ALWAYS_SOFTWARE WAYLAND_DISPLAY DISPLAY; exec mango -c '$config'"

  echo "Starting a $size desktop..."
  for _ in $(seq 1 30); do
    if listening; then
      # Mango doesn't apply the monitor_rule above to the virtual screen, so
      # set the size now that the desktop is up.
      set_size "$size"
      echo "Ready. Connect the VNC viewer to localhost:$PORT (through the SSH tunnel)."
      echo "End it with: remote-desktop stop"
      return
    fi
    is_running || break
    sleep 1
  done
  echo "It didn't come up. The last log lines:" >&2
  journalctl --user -u "$UNIT" -n 40 --no-pager >&2 || true
  exit 1
}

stop() {
  if ! is_running; then
    if is_attached; then
      echo "The separate desktop isn't running; you're attached to the office session. End that with: remote-desktop detach"
    else
      echo "Not running."
    fi
    return
  fi
  systemctl --user stop "$UNIT"
  echo "Stopped."
}

# ================================================================ attach/detach
# Runs a command against the office session (saved in $STATE while attached).
att() { WAYLAND_DISPLAY="$ATT_WAYLAND" MANGO_INSTANCE_SIGNATURE="$ATT_MANGO" "$@"; }

# Finds the office Mango session: its IPC socket (ATT_MANGO) and its Wayland
# display (ATT_WAYLAND, read from a program it started, e.g. Noctalia). Over
# SSH neither is in the environment.
find_office_session() {
  local sock pid env d
  for sock in "$XDG_RUNTIME_DIR"/mango-*.sock; do
    [ -S "$sock" ] || continue
    MANGO_INSTANCE_SIGNATURE="$sock" mmsg get version >/dev/null 2>&1 || continue
    for pid in $(pgrep -u "$(id -u)"); do
      env="$(tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ")" || continue
      grep -qxF "MANGO_INSTANCE_SIGNATURE=$sock" <<<"$env" || continue
      d="$(sed -n 's/^WAYLAND_DISPLAY=//p' <<<"$env")"
      if [ -n "$d" ]; then
        ATT_MANGO="$sock"
        ATT_WAYLAND="${d%%$'\n'*}"
        return 0
      fi
    done
  done
  return 1
}

# The real screens in use, as "name x y" per line: those that are on, and
# those the idle timer (Noctalia) put to sleep. wlr-randr shows a sleeping
# screen as off too, but Mango keeps its windows and its place, so it has a
# size here. A screen turned off with disable_monitor (lid closed, or by
# hand) has size 0 and stays off.
screens_in_use() {
  att mmsg get all-monitors |
    jq -r --arg v "$VOUT" '.monitors[] | select(.name != $v and .width > 0) | "\(.name) \(.x) \(.y)"'
}

# The real screens that are on now (everything but the virtual one).
real_screens_on() {
  att wlr-randr --json | jq -r --arg v "$VOUT" '.[] | select(.enabled and .name != $v) | .name'
}

viewer_count() {
  wayvncctl -S "$VNC_SOCK" -j client-list 2>/dev/null | jq 'length' 2>/dev/null || echo 0
}

# Is a Noctalia running in the office session? Checked by process, not by
# its socket: a busy Noctalia may not answer for a few seconds.
office_noctalia_running() {
  local pid
  # The Nix wrapper runs .noctalia-wrapped; the kernel keeps 15 characters.
  for pid in $(pgrep -u "$(id -u)" '^(noctalia|\.noctalia-wrapp)$'); do
    tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" | grep -qxF "WAYLAND_DISPLAY=$ATT_WAYLAND" && return 0
  done
  return 1
}

# Starts Noctalia in the office session again if it's gone. Without it, a
# locked session shows only gray and can't be unlocked, not even at the desk
# (Mango stays locked when the lock screen dies). Returns once it answers.
ensure_office_noctalia() {
  if ! office_noctalia_running; then
    echo "Noctalia is gone from the office session; starting it again."
    systemctl --user reset-failed "$NOCTALIA_UNIT" 2>/dev/null || true
    # bash -l: the normal login environment. DISPLAY comes from the systemd
    # user environment and may belong to the separate desktop.
    systemd-run --user --quiet --unit="$NOCTALIA_UNIT" \
      --description="Noctalia for the office session (restarted by remote-desktop)" \
      --setenv=WAYLAND_DISPLAY="$ATT_WAYLAND" --setenv=MANGO_INSTANCE_SIGNATURE="$ATT_MANGO" \
      --setenv=XDG_CURRENT_DESKTOP=mango:wlroots --setenv=XDG_SESSION_DESKTOP=mango \
      --setenv=XDG_SESSION_TYPE=wayland \
      bash -lc 'unset DISPLAY; exec noctalia' || return 1
  fi
  for _ in $(seq 1 20); do
    att noctalia msg config-get shell >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

# Tells the office Noctalia the screens are on (dpms-on): it wakes every
# screen it knows and forgets an earlier "off". After an idle screen-off,
# Noctalia puts all screens to sleep again whenever a screen appears
# (onOutputAdded in its compositor_platform.cpp): the new virtual screen, or
# a real one that detach turns back on. And Mango turns a sleeping screen
# fully off at the next screen change (a VNC viewer's resize, wlr-randr).
# That dropped the viewer and left the office screens dark. While attached,
# _idle-screens never says "off", so Noctalia's state stays "on".
wake_office_screens() {
  att noctalia msg dpms-on >/dev/null 2>&1 || return 1
  sleep 1
}

# Noctalia's idle step "screen-off" (noctalia/config.toml) runs this, with
# off after the timeout and on at the next input. Noctalia's own screen_off
# would turn every screen on at the next input: while attached, the first
# VNC input turned the office screens on, the watcher turned them off, and
# back and forth until Noctalia stalled and Mango dropped it, lock screen
# and all. While attached this does nothing: the real screens stay off and
# the virtual one stays on.
idle_screens() {
  case "${1:-}" in
    off | on) ;;
    *) die "usage: remote-desktop _idle-screens off|on" ;;
  esac
  is_attached && return 0
  noctalia msg "dpms-$1"
}

set_attached_size() {
  local args=(--output "$VOUT" --custom-mode "$1")
  [ -n "${2:-}" ] && args+=(--scale "$2")
  att wlr-randr "${args[@]}"
}

# If attaching fails halfway, undo what was done. Holds $LOCK already.
undo_and_die() {
  echo "remote-desktop: $*" >&2
  echo "Undoing the attach..." >&2
  detach_locked >&2
  exit 1
}

attach() {
  local size="${1:-1920x1080}" scale="${2:-1}" screens outputs o
  valid_size "$size"
  valid_scale "$scale"
  [ -r "$MANGO_SETTINGS" ] || die "no Mango settings at $MANGO_SETTINGS."
  mkdir -p "$DIR"

  if is_attached; then
    # shellcheck source=/dev/null
    . "$STATE"
    if [ -n "${1:-}" ]; then
      set_attached_size "$size" "${2:-}" || die "couldn't set the size to $size."
      echo "Resized to $size."
    fi
    status
    return
  fi
  is_running && die "the separate desktop (remote-desktop start) is running. End it first: remote-desktop stop"
  listening && die "port $PORT is already in use."
  find_office_session ||
    die "no Mango session found. Is anyone logged in at the notebook? If not, use: remote-desktop start"

  exec 9>"$LOCK"
  flock -w 30 9 || die "another attach or detach is still running."

  # The screens show the lock screen for a moment, then go off below.
  ensure_office_noctalia || die "Noctalia doesn't answer in the office session."
  echo "Waking the office screens..."
  wake_office_screens || die "couldn't wake the office screens through Noctalia."

  # Sleeping screens count too: disable_monitor below really turns them off
  # (their windows move to the virtual screen), and detach turns them on.
  screens="$(screens_in_use)" || die "couldn't read the screens of the office session."
  [ -n "$screens" ] || die "the office session has no screen in use."
  outputs="$(cut -d' ' -f1 <<<"$screens")"
  printf 'ATT_MANGO=%q\nATT_WAYLAND=%q\n' "$ATT_MANGO" "$ATT_WAYLAND" >"$STATE"
  # With their positions: Mango places a screen that comes back wherever
  # there's room, so detach puts each one back where it was.
  printf '%s\n' "$screens" >"$OUTPUTS_FILE"

  echo "Adding a $size virtual screen to the office session..."
  att mmsg dispatch "create_virtual_output,$VOUT" >/dev/null || undo_and_die "couldn't create the virtual screen."
  for _ in $(seq 1 20); do
    att wlr-randr --json | jq -e --arg v "$VOUT" 'any(.[]; .name == $v)' >/dev/null && break
    sleep 0.25
  done
  set_attached_size "$size" "$scale" || undo_and_die "couldn't set the virtual screen to $size."

  echo "Blocking the physical keyboard, mouse and touchpad..."
  systemctl start "$BLOCK_UNIT" || undo_and_die "couldn't start $BLOCK_UNIT."
  sleep 1
  systemctl is-active --quiet "$BLOCK_UNIT" ||
    undo_and_die "$BLOCK_UNIT stopped right away. Log: journalctl -u $BLOCK_UNIT"

  echo "Turning off the real screens: $(tr '\n' ' ' <<<"$outputs")"
  for o in $outputs; do
    att mmsg dispatch "disable_monitor,$o" >/dev/null || undo_and_die "couldn't turn off $o."
  done

  # wayvnc and the watcher in a user unit: they survive a dropped SSH
  # connection. --setenv=NAME passes the value from here (PATH has jq etc.).
  systemctl --user reset-failed "$ATTACH_UNIT" 2>/dev/null || true
  systemd-run --user --quiet --unit="$ATTACH_UNIT" \
    --description="Remote desktop (attached to the office session)" \
    --setenv=PATH --setenv=HOME --setenv=XDG_RUNTIME_DIR \
    bash "$(readlink -f "$0")" _watch || undo_and_die "couldn't start $ATTACH_UNIT."

  for _ in $(seq 1 15); do
    if listening; then
      echo "Ready. Connect the VNC viewer to localhost:$PORT (through the SSH tunnel)."
      echo "Without a viewer for $((IDLE_DETACH / 60)) minutes it detaches by itself."
      echo "End it with: remote-desktop detach"
      return
    fi
    sleep 1
  done
  journalctl --user -u "$ATTACH_UNIT" -n 20 --no-pager >&2 || true
  undo_and_die "VNC didn't come up."
}

# Gives the session back: locks it first, so whoever sits at the desk sees
# only the lock screen. Holds $LOCK already. Each step goes on even if an
# earlier one failed: the screens and the input must come back.
detach_locked() {
  local o
  if ! is_attached; then
    echo "Not attached."
    return 0
  fi
  # shellcheck source=/dev/null
  . "$STATE"

  echo "Locking the session..."
  ensure_office_noctalia || echo "warning: Noctalia doesn't answer in the office session." >&2
  att noctalia msg session lock >/dev/null 2>&1 || echo "warning: couldn't lock the session." >&2
  sleep 1

  if [ -n "${IN_WATCH:-}" ]; then
    if [ -n "${WAYVNC_PID:-}" ]; then kill "$WAYVNC_PID" 2>/dev/null || true; fi
  else
    systemctl --user stop "$ATTACH_UNIT" 2>/dev/null || true
  fi

  echo "Turning the real screens back on..."
  local x y saved=() positions=()
  # Noctalia first, or it puts each screen that comes back to sleep again.
  wake_office_screens || echo "warning: couldn't tell Noctalia the screens are on." >&2
  while read -r o x y; do
    [ -n "$o" ] || continue
    saved+=("$o")
    att mmsg dispatch "enable_monitor,$o" >/dev/null 2>&1 || echo "warning: couldn't turn on $o." >&2
    [ -n "$y" ] && positions+=(--output "$o" --pos "$x,$y")
  done <"$OUTPUTS_FILE"
  # Removes all virtual screens; REMOTE-1 is the only one. Mango puts each
  # window back on the screen it came from.
  att mmsg dispatch destroy_all_virtual_output >/dev/null 2>&1 || true
  # The screens back in their old order, all in one change so they never
  # overlap on the way. (A screen plugged in while attached has no saved
  # position; Mango places it.)
  if ((${#positions[@]})); then
    att wlr-randr "${positions[@]}" || echo "warning: couldn't put the screens back in their old positions." >&2
  fi

  rm -f "$STATE" "$OUTPUTS_FILE"
  # Now that $STATE is gone, the lid script decides about the internal screen.
  if [ -x "$LID_SCRIPT" ]; then
    att "$LID_SCRIPT" >/dev/null 2>&1 || true
  fi
  systemctl stop --no-block "$BLOCK_UNIT" 2>/dev/null || true

  # Check: at least one screen must be on, or nobody at the desk sees the
  # lock screen. Try once more if not.
  sleep 1
  if [ -z "$(real_screens_on 2>/dev/null)" ]; then
    echo "warning: no screen came on; trying again." >&2
    wake_office_screens || true
    for o in "${saved[@]}"; do
      att mmsg dispatch "enable_monitor,$o" >/dev/null 2>&1 || true
    done
    sleep 1
    if [ -z "$(real_screens_on 2>/dev/null)" ]; then
      echo "warning: the notebook's screens are still off. Wake them with: WAYLAND_DISPLAY=$ATT_WAYLAND noctalia msg dpms-on" >&2
      return 0
    fi
  fi
  echo "Detached. The session is locked and the notebook's screens are on again."
}

detach() {
  mkdir -p "$DIR"
  exec 9>"$LOCK"
  flock -w 30 9 || die "another attach or detach is still running."
  detach_locked
}

# Called by the stop hook of $BLOCK_UNIT (as this user): the input block
# ended (emergency combination at the desk, 12 h limit, crash, kill), so
# detach unless a detach is already under way.
hook() {
  mkdir -p "$DIR"
  exec 9>"$LOCK"
  flock -n 9 || exit 0
  is_attached || exit 0
  echo "The input block ended: detaching."
  detach_locked
}

# Inside $ATTACH_UNIT: runs wayvnc on the virtual screen and watches.
# Detaches when there was no VNC viewer for $IDLE_DETACH seconds, when the
# input block or Mango is gone, or when this watcher dies. Turns off any real
# screen that comes on (plugged in, lid, config reload).
watch_attached() {
  local last_viewer now o
  set +e
  is_attached || exit 0
  # shellcheck source=/dev/null
  . "$STATE"
  IN_WATCH=1

  auto_detach() {
    trap - EXIT
    exec 9>"$LOCK"
    flock -n 9 || exit 0
    echo "Detaching: $1"
    detach_locked
    exit 0
  }
  trap 'exit 0' TERM INT
  trap 'auto_detach "the watcher ended"' EXIT

  start_wayvnc() {
    rm -f "$VNC_SOCK"
    WAYLAND_DISPLAY="$ATT_WAYLAND" wayvnc-screencopy -S "$VNC_SOCK" -o "$VOUT" -k "$(keymap)" 127.0.0.1 "$PORT" &
    WAYVNC_PID=$!
  }
  start_wayvnc

  # Each change of the screens prints a line here, so a new screen is turned
  # off at once, not only at the next 5-second check.
  coproc MONITORS { att mmsg watch all-monitors; }

  last_viewer=$(date +%s)
  while :; do
    if [ -n "${MONITORS_PID:-}" ] && kill -0 "$MONITORS_PID" 2>/dev/null; then
      read -r -t 5 -u "${MONITORS[0]}" _ || sleep 1
    else
      sleep 5
    fi
    is_attached || { trap - EXIT; exit 0; }

    att mmsg get version >/dev/null 2>&1 || auto_detach "the Mango session is gone"
    systemctl is-active --quiet "$BLOCK_UNIT" || auto_detach "the input block ended"

    # Without Noctalia the session is stuck on gray. Start it again and lock:
    # the lock screen comes back on the virtual screen, so you can go on.
    if ! office_noctalia_running; then
      if ensure_office_noctalia; then
        att noctalia msg session lock >/dev/null 2>&1 || echo "warning: couldn't lock the session."
      else
        auto_detach "Noctalia ended and didn't come back"
      fi
    fi

    # The virtual screen must stay on; wayvnc shows nothing without it.
    case "$(att wlr-randr --json 2>/dev/null | jq -r --arg v "$VOUT" \
      'map(select(.name == $v)) | if length == 0 then "gone" elif .[0].enabled then "on" else "off" end')" in
      gone) auto_detach "the virtual screen is gone" ;;
      off)
        echo "The virtual screen went off; turning it on again."
        att mmsg dispatch "enable_monitor,$VOUT" >/dev/null
        ;;
    esac

    for o in $(real_screens_on 2>/dev/null); do
      echo "Turning off $o, which came on."
      att mmsg dispatch "disable_monitor,$o" >/dev/null
      grep -q "^$o\( \|\$\)" "$OUTPUTS_FILE" || echo "$o" >>"$OUTPUTS_FILE"
    done

    if ! kill -0 "$WAYVNC_PID" 2>/dev/null; then
      echo "wayvnc ended; starting it again."
      start_wayvnc
    fi

    now=$(date +%s)
    if [ "$(viewer_count)" -gt 0 ]; then
      last_viewer=$now
    elif ((now - last_viewer >= IDLE_DETACH)); then
      auto_detach "no VNC viewer for $((IDLE_DETACH / 60)) minutes"
    fi
  done
}

# ====================================================================== both
resize() {
  [ -n "${1:-}" ] || die "give the size, e.g.: remote-desktop resize 1470x956"
  valid_size "$1"
  if is_attached; then
    # shellcheck source=/dev/null
    . "$STATE"
    set_attached_size "$1" || die "couldn't set the size to $1."
  else
    is_running || die "not running. Start it with: remote-desktop attach $1"
    set_size "$1"
  fi
  echo "Resized to $1. If the viewer doesn't follow, reconnect it."
}

status() {
  if is_attached; then
    if listening; then
      echo "Attached to the office session. VNC on localhost:$PORT (through the SSH tunnel), $(viewer_count) viewer(s) connected."
    else
      echo "Attached to the office session, but VNC isn't listening on port $PORT. Log: journalctl --user -u $ATTACH_UNIT"
    fi
    systemctl is-active --quiet "$BLOCK_UNIT" && echo "The physical keyboard, mouse and touchpad are blocked."
  elif is_running; then
    if listening; then
      echo "The separate desktop is running. VNC on localhost:$PORT (through the SSH tunnel)."
    else
      echo "The separate desktop is running, but VNC isn't listening on port $PORT. Log: journalctl --user -u $UNIT"
    fi
  else
    echo "Not running. Start with: remote-desktop attach [WIDTHxHEIGHT] [SCALE]"
    echo "(or, if nobody is logged in at the notebook: remote-desktop start [WIDTHxHEIGHT])"
  fi
}

case "${1:-}" in
  attach) attach "${2:-}" "${3:-}" ;;
  detach) detach ;;
  start) start "${2:-}" ;;
  stop) stop ;;
  resize) resize "${2:-}" ;;
  status) status ;;
  _watch) watch_attached ;;
  _hook) hook ;;
  _idle-screens) idle_screens "${2:-}" ;;
  -h | --help | help) usage 0 ;;
  *) usage 1 ;;
esac
