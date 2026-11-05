#!/usr/bin/env bash
# Records the cue-driven flows. Each take relaunches the app fresh in demo mode, so takes match.
#   record_flows.sh <flow> <take> [dark|light]
#   flows: fitness-hero fitness-sync home-lights home-lock focus-start
# Gesture flows (fitness-scroll, fitness-sleep) are driven by hand around rec.sh start/stop.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
FLOW="$1"; TAKE="$2"; MODE="${3:-dark}"
NAME="$FLOW-$MODE-t$TAKE"
R="$D/rec.sh"; C="$D/cue.sh"
case "$FLOW" in
  fitness-hero)
    # Rings start empty and fill when the (delayed) data lands.
    xcrun simctl ui "${UDID:-DE4D0BA1-1D0F-4522-B175-AE044A8BCF8B}" appearance "$MODE"
    "$R" start "$NAME"
    EXTRA="-DemoFitnessDelay 4" WAIT=17 "$R" launch fitness "$MODE"
    "$R" stop ;;
  fitness-sync)
    "$R" launch fitness "$MODE"; "$R" start "$NAME"
    sleep 0.6; "$C" sync; sleep 3.6
    "$R" stop ;;
  home-lights)
    "$R" launch home "$MODE"; "$R" start "$NAME"
    sleep 2.0; "$C" light.toggle
    sleep 1.6; "$C" light.sheet
    sleep 1.2; "$C" light.bright
    sleep 2.0; "$C" light.close
    sleep 3.0
    "$R" stop ;;
  home-lock)
    "$R" launch home "$MODE"; "$R" start "$NAME"
    sleep 1.5; "$C" lock
    sleep 5.5
    "$R" stop ;;
  focus-start)
    "$R" launch focus "$MODE"; "$R" start "$NAME"
    sleep 0.8; "$C" focus; sleep 4.2
    "$R" stop ;;
  *) echo "unknown flow $FLOW" >&2; exit 1 ;;
esac
"$R" frames "$NAME" 10
