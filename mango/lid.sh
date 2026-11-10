#!/usr/bin/env bash
# Lid hook for Mango (switchbind in config.conf, and once at login): with the
# lid closed and an external screen connected, turn off the internal screen;
# otherwise turn it on. Linked to ~/.config/mango/lid.sh by home.nix.
INTERNAL=eDP-1

# While `remote-desktop attach` is active, all real screens stay off; detach
# runs this script again afterwards.
[ -f "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/remote-desktop/attached" ] && exit 0

external=0
for status in /sys/class/drm/card*-*/status; do
  [[ $status == *eDP* ]] && continue
  [[ $(<"$status") == connected ]] && external=1
done

if grep -q closed /proc/acpi/button/lid/*/state 2>/dev/null && ((external)); then
  mmsg dispatch disable_monitor,"$INTERNAL"
else
  mmsg dispatch enable_monitor,"$INTERNAL"
fi
