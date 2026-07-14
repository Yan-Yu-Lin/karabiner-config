#!/bin/bash
# Toggle JankyBorders fade animation (150ms ↔ off). Applies live to the running
# borders-fade instance and persists via a state file that the AeroSpace
# after-startup-command launch line reads at login.

STATE="$HOME/.config/borders-fade-duration"
current=$(cat "$STATE" 2>/dev/null || echo 150)

if [ "$current" = "0" ]; then
  next=150; mode=fade-on
else
  next=0; mode=fade-off
fi

printf '%s' "$next" > "$STATE"
/opt/homebrew/bin/borders-fade fade_duration="$next"

echo "show $mode" > /tmp/karabiner-hud.fifo &
