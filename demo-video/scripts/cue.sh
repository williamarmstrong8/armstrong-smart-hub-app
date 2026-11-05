#!/usr/bin/env bash
# Fires a film cue in the running demo app: cue.sh sync | light.toggle | light.sheet | light.bright | light.close | lock | focus
U="${UDID:-DE4D0BA1-1D0F-4522-B175-AE044A8BCF8B}"
DIR="$(xcrun simctl get_app_container "$U" com.paularmstrong.ArmstrongSmartHubApp data)/Documents"
mkdir -p "$DIR"
echo "$1 $(date +%s%N)" > "$DIR/demo-cue"
