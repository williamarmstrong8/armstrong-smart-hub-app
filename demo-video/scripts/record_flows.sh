#!/usr/bin/env bash
# Records the cue-driven flows. Each take relaunches the app fresh in demo mode, so takes match.
#   record_flows.sh <flow> <take> [dark|light]
#   flows: fitness-hero fitness-sync home-lights home-lock focus-start
#          tab-tour fitness-scroll2 fitness-pages fitness-workout home-scroll finance-tour calendar-tour focus-tour
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
  tab-tour)
    "$R" launch home "$MODE"; "$R" start "$NAME"
    for t in finance calendar fitness focus home; do sleep 0.9; "$C" tab $t; done
    sleep 1.5
    "$R" stop ;;
  fitness-scroll2)
    "$R" launch fitness "$MODE"; "$R" start "$NAME"
    sleep 1.0; "$C" scroll 1500 6
    sleep 7.5
    "$R" stop ;;
  fitness-pages)
    "$R" launch fitness "$MODE"; "$R" start "$NAME"
    sleep 1.0; "$C" nav sleep; sleep 2.0; "$C" scroll 520 1.6; sleep 2.2; "$C" back
    sleep 1.4; "$C" nav heart; sleep 2.0; "$C" scroll 600 1.6; sleep 2.2; "$C" back
    sleep 1.4; "$C" nav training; sleep 2.0; "$C" scroll 560 1.6; sleep 2.2; "$C" back
    sleep 1.5
    "$R" stop ;;
  fitness-workout)
    "$R" launch fitness "$MODE"; "$R" start "$NAME"
    sleep 1.0; "$C" nav workout; sleep 2.4; "$C" scroll 760 2.0; sleep 2.6; "$C" back
    sleep 1.4; "$C" workout.start; sleep 2.6; "$C" workout.set; sleep 1.4; "$C" workout.set; sleep 3.0; "$C" workout.end
    sleep 1.5
    "$R" stop ;;
  home-scroll)
    "$R" launch home "$MODE"; "$R" start "$NAME"
    sleep 1.0; "$C" scroll 640 3.0; sleep 4.5
    "$R" stop ;;
  finance-tour)
    "$R" launch finance "$MODE"; "$R" start "$NAME"
    sleep 1.5; "$C" tag; sleep 1.8; "$C" tag; sleep 1.8; "$C" tag.other; sleep 2.0; "$C" tag.pick Groceries
    sleep 1.6; "$C" scroll 720 2.4; sleep 3.2; "$C" nav transactions; sleep 2.2; "$C" scroll 900 2.6; sleep 3.4
    "$R" stop ;;
  calendar-tour)
    "$R" launch calendar "$MODE"; "$R" start "$NAME"
    sleep 1.8; "$C" scroll 640 2.6; sleep 3.4; "$C" scroll 1280 2.2; sleep 3.2
    "$R" stop ;;
  focus-tour)
    "$R" launch focus "$MODE"; "$R" start "$NAME"
    sleep 1.0; "$C" focus; sleep 4.2; "$C" scroll 520 1.8; sleep 2.6; "$C" nav activity; sleep 3.0; "$C" back
    sleep 1.2; "$C" scroll top 1.2; sleep 2.0; "$C" focus; sleep 4.0
    "$R" stop ;;
  focus-start)
    "$R" launch focus "$MODE"; "$R" start "$NAME"
    sleep 0.8; "$C" focus; sleep 4.2
    "$R" stop ;;
  *) echo "unknown flow $FLOW" >&2; exit 1 ;;
esac
"$R" frames "$NAME" 10
