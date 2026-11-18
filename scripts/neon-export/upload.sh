#!/usr/bin/env bash
# Copies the export to the Pi's data folder: the phone's import, and the Pi's own
# app list and watch faces (only where the Pi doesn't have its own yet).
set -euo pipefail
cd "$(dirname "$0")"
DATA='~/armstrong-hub/data'
ssh pi "mkdir -p $DATA/watch-faces"
scp -q out/import.json "pi:armstrong-hub/data/import.json"
ssh pi "test -e $DATA/dev.json" || scp -q out/pi/dev.json pi:armstrong-hub/data/dev.json
ssh pi "test -e $DATA/watch-faces.json" || { scp -q out/pi/watch-faces.json pi:armstrong-hub/data/; scp -q out/pi/watch-faces/*.prg pi:armstrong-hub/data/watch-faces/ 2>/dev/null || true; }
ssh pi "chmod -R go-rwx ~/armstrong-hub/data"
echo "Copied. Open the app on the phone to import the history."
