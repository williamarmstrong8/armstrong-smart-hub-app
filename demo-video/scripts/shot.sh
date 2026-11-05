#!/usr/bin/env bash
# shot.sh <out.png> [width] : screenshot the demo simulator, scaled for review
U="${UDID:-DE4D0BA1-1D0F-4522-B175-AE044A8BCF8B}"
xcrun simctl io "$U" screenshot "$1.full.png" >/dev/null 2>&1 && sips -Z "${2:-700}" "$1.full.png" --out "$1" >/dev/null && rm "$1.full.png"
