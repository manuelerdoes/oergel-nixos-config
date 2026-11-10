#!/usr/bin/env bash
# Turns the notebook panel off while the lid is closed and an external
# monitor is connected, and back on otherwise. Run by Umbriel on lid
# open/close and once at startup (see [events] and autostart in config.toml).
INTERNAL=eDP-1

external=0
for status in /sys/class/drm/card*-*/status; do
  [[ $status == *eDP* ]] && continue
  [[ $(<"$status") == connected ]] && external=1
done

if grep -q closed /proc/acpi/button/lid/*/state 2>/dev/null && ((external)); then
  umbriel msg output-disable "$INTERNAL"
else
  umbriel msg output-enable "$INTERNAL"
fi
