#!/bin/bash
# Cycle the "delay until key repeat" between presets: 500ms → 250ms → 180ms → 500ms…
# - hidutil sets the LIVE value (instant, everywhere, no app restart)
# - defaults write persists it across logout/reboot (units: ticks of 15ms)
# - HUD flashes the new speed (auto-hides)

current=$(hidutil property --get HIDInitialKeyRepeat | tr -dc '0-9')

case "$current" in
  500000000) next=250000000; ticks=17; mode=repeat-250 ;;
  250000000) next=180000000; ticks=12; mode=repeat-180 ;;
  *)         next=500000000; ticks=33; mode=repeat-500 ;;
esac

hidutil property --set "{\"HIDInitialKeyRepeat\":$next}" >/dev/null
defaults write -g InitialKeyRepeat -int "$ticks"

echo "show $mode" > /tmp/karabiner-hud.fifo &
