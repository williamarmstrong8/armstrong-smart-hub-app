#!/usr/bin/env bash
# Fires a film cue in the running demo app: cue.sh <name> [args…], e.g. cue.sh tab finance, cue.sh scroll 900 3, cue.sh nav sleep
U="${UDID:-DE4D0BA1-1D0F-4522-B175-AE044A8BCF8B}"
DIR="$(xcrun simctl get_app_container "$U" com.paularmstrong.ArmstrongSmartHubApp data)/Documents"
mkdir -p "$DIR"
echo "$* $(date +%s%N)" > "$DIR/demo-cue"
