#!/bin/bash
# Brightness key handler — targets the right display automatically.
#
#   brightness-key.sh hold-start up|down [builtin]  # key down: step now, repeat while held
#   brightness-key.sh hold-stop                     # key up: stop repeating
#
# Target: external if connected, else built-in; "builtin" forces built-in.
# Karabiner's shell_command doesn't auto-repeat on key hold, so we run our
# own repeat loop between key-down and key-up.

BD=/opt/homebrew/bin/betterdisplaycli
EXTERNAL="U27G4XM"
TAP_STEP="0.05"     # single tap = one clear notch
FINE_STEP="0.015"   # hold-repeat uses fine steps at high rate = smooth ramp
FLAG=/tmp/.brightness-hold
REPEAT_DELAY=0.2    # before repeat kicks in
REPEAT_EVERY=0.03   # ~33 fine steps/s ≈ 0.5 brightness/s, visually continuous
MAX_STEPS=250       # runaway guard if key-up event is ever lost (~7.5s)

case "$1" in
  hold-stop)
    rm -f "$FLAG"
    exit 0
    ;;
  hold-start)
    if [ "$3" = "builtin" ]; then
      sel="-namelike=built"
    elif [ "$($BD get -name=$EXTERNAL -connected 2>/dev/null)" = "on" ]; then
      sel="-name=$EXTERNAL"
    else
      sel="-namelike=built"
    fi
    if [ "$2" = "up" ]; then sign="+"; else sign="-"; fi

    echo $$ > "$FLAG"   # newer press takes over; older loop sees pid mismatch and exits
    $BD set "$sel" -brightness="${sign}${TAP_STEP}" -offset
    sleep "$REPEAT_DELAY"
    i=0
    while [ "$(cat "$FLAG" 2>/dev/null)" = "$$" ] && [ "$i" -lt "$MAX_STEPS" ]; do
      $BD set "$sel" -brightness="${sign}${FINE_STEP}" -offset
      sleep "$REPEAT_EVERY"
      i=$((i + 1))
    done
    ;;
esac
