#!/usr/bin/env bash
# Restarts Noctalia in the current session (Super+Ctrl+Shift+R). Helps when
# the bar draws wrong, e.g. after a remote-desktop session, without logging
# out. Only the Noctalia of this session (same WAYLAND_DISPLAY) is touched:
# the remote-desktop session runs a Noctalia of its own.
#
# Don't run it while the screen is locked: the lock screen is part of
# Noctalia, and Mango stays locked (gray) when it goes away.

: "${WAYLAND_DISPLAY:?WAYLAND_DISPLAY is not set}"

ours() {
  local pid
  # The Nix wrapper runs .noctalia-wrapped; the kernel keeps 15 characters.
  for pid in $(pgrep -u "$(id -u)" '^(noctalia|\.noctalia-wrapp)$'); do
    tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" |
      grep -qxF "WAYLAND_DISPLAY=$WAYLAND_DISPLAY" && echo "$pid"
  done
}

pids=$(ours)
if [ -n "$pids" ]; then
  kill $pids 2>/dev/null
  for _ in $(seq 1 30); do
    [ -z "$(ours)" ] && break
    sleep 0.1
  done
  pids=$(ours)
  [ -n "$pids" ] && kill -9 $pids 2>/dev/null
fi

# Left over if remote-desktop had restarted it as a systemd unit.
systemctl --user reset-failed noctalia-office 2>/dev/null || true

exec noctalia
