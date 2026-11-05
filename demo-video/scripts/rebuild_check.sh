#!/usr/bin/env bash
# Incremental build, reinstall and relaunch in demo mode, printing decode failures from the console.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
U="${UDID:-DE4D0BA1-1D0F-4522-B175-AE044A8BCF8B}"
TAB="${1:-fitness}"
LOG="${LOG:-/tmp/demo-console.log}"
xcodebuild -project "$ROOT/Armstrong-Smart-Hub-App.xcodeproj" -scheme Armstrong-Smart-Hub-App -configuration Debug \
  -destination "id=$U" -derivedDataPath "$ROOT/demo-video/.build/DerivedData" build 2>&1 | grep -E " error:|BUILD (SUCCEEDED|FAILED)" | sort -u
xcrun simctl terminate "$U" com.paularmstrong.ArmstrongSmartHubApp 2>/dev/null
xcrun simctl install "$U" "$ROOT/demo-video/.build/DerivedData/Build/Products/Debug-iphonesimulator/Armstrong-Smart-Hub-App.app"
( xcrun simctl launch --console-pty "$U" com.paularmstrong.ArmstrongSmartHubApp -DemoMode YES -DemoTab "$TAB" > "$LOG" 2>&1 & )
sleep "${WAIT:-12}"
grep -E "load failed|Decode failed|Fatal|fatal" "$LOG" | head -10
