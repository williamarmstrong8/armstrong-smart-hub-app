#!/usr/bin/env bash
# Builds the app (Debug, Simulator), installs it fresh and launches it in demo mode.
#
#   demo-video/scripts/launch_demo.sh [tab] [appearance]
#     tab:        home | fitness | focus     (default: home)
#     appearance: dark | light               (default: dark)
#   SKIP_BUILD=1   reuse the last build
#   DEVICE="iPhone 18 Pro"                   simulator name
#
# Demo mode answers every hub request inside the app from DemoData.swift: no network,
# no Bluetooth, NFC or Screen Time. The app is uninstalled first, so each take starts clean.
set -euo pipefail

TAB="${1:-home}"
APPEARANCE="${2:-dark}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED="$ROOT/demo-video/.build/DerivedData"
BUNDLE="com.paularmstrong.ArmstrongSmartHubApp"

# The newest iOS runtime's simulator of that name (the app targets iOS 27).
UDID="${UDID:-$(xcrun simctl list devices available -j | DEVICE="$DEVICE" python3 -c '
import json, os, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted((k for k in devices if "iOS" in k), key=lambda k: [int(x) for x in k.split("iOS-")[1].split("-")])
for r in reversed(runtimes):
    for d in devices[r]:
        if d["name"] == os.environ["DEVICE"]:
            print(d["udid"]); sys.exit()
')}"
[ -n "$UDID" ] || { echo "No simulator named $DEVICE" >&2; exit 1; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance "$APPEARANCE"
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 --operatorName "" --dataNetwork wifi
# No keyboard predictions or autocorrect bar in shots.
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences KeyboardPrediction -bool NO || true
xcrun simctl spawn "$UDID" defaults write com.apple.Preferences KeyboardShowPredictionBar -bool NO || true

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  xcodebuild -project "$ROOT/Armstrong-Smart-Hub-App.xcodeproj" -scheme Armstrong-Smart-Hub-App \
    -configuration Debug -destination "id=$UDID" -derivedDataPath "$DERIVED" \
    -quiet build
fi

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Armstrong-Smart-Hub-App.app"
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE" -DemoMode YES -DemoTab "$TAB" >/dev/null
echo "Launched $BUNDLE on $DEVICE ($UDID) — tab=$TAB appearance=$APPEARANCE"
