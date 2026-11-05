#!/usr/bin/env bash
# Simulator recording helper for the launch film.
#   rec.sh launch <tab> [dark|light]   relaunch the app in demo mode on a tab and wait until it has drawn
#                                      (EXTRA="-DemoFitnessDelay 4" passes more launch arguments)
#   rec.sh start <clip-name>           start recording demo-video/raw/<clip-name>.mp4 (H.264)
#   rec.sh stop                        stop the recording cleanly (SIGINT so the file is finalized)
#   rec.sh frames <clip-name> [n]      pull n evenly spaced frames to demo-video/raw/frames/<clip-name>/ for review
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
U="${UDID:-DE4D0BA1-1D0F-4522-B175-AE044A8BCF8B}"
RAW="$ROOT/demo-video/raw"
PIDFILE="$RAW/.rec.pid"
mkdir -p "$RAW"

case "${1:-}" in
  launch)
    xcrun simctl ui "$U" appearance "${3:-dark}"
    xcrun simctl status_bar "$U" override --time 9:41 --batteryState charged --batteryLevel 100 \
      --cellularBars 4 --wifiBars 3 --operatorName "" --dataNetwork wifi
    xcrun simctl launch --terminate-running-process "$U" com.paularmstrong.ArmstrongSmartHubApp \
      -DemoMode YES -DemoTab "$2" ${EXTRA:-} >/dev/null
    sleep "${WAIT:-13}"
    ;;
  start)
    xcrun simctl io "$U" recordVideo --codec=h264 --force "$RAW/$2.mp4" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep "${LEAD:-2}"   # recordVideo takes a moment to start; this is also the lead-in still
    ;;
  stop)
    sleep 0.8   # tail still for trimming
    kill -INT "$(cat "$PIDFILE")" 2>/dev/null || true
    while kill -0 "$(cat "$PIDFILE")" 2>/dev/null; do sleep 0.2; done
    rm -f "$PIDFILE"
    ;;
  frames)
    n="${3:-8}"
    f="$RAW/$2.mp4"
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
    out="$RAW/frames/$2"; rm -rf "$out"; mkdir -p "$out"
    ffmpeg -loglevel error -y -i "$f" -vf "fps=$n/$dur,scale=300:-1,tile=${n}x1" -frames:v 1 "$out/strip.png"
    echo "$f: ${dur}s → $out/strip.png"
    ;;
  *) echo "usage: rec.sh launch|start|stop|frames" >&2; exit 1 ;;
esac
