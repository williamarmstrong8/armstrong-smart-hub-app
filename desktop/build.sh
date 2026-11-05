#!/bin/zsh
# Builds Armstrong Hub.app (the Mac app) with swiftc and installs it in ~/Applications.
#   ./desktop/build.sh            build and install
#   ./desktop/build.sh --no-install
set -euo pipefail

here=${0:A:h}
out=$here/build
app="$out/Armstrong Hub.app"
hub=https://armstrong-smart-hub.vercel.app

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -framework AppKit -framework WebKit \
  "$here/ArmstrongHub.swift" -o "$app/Contents/MacOS/ArmstrongHub"

# The hub's own icon (app/icon.tsx), as an .icns.
iconset=$out/AppIcon.iconset
rm -rf "$iconset" && mkdir -p "$iconset"
curl -fsS "$hub/icon" -o "$out/icon.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$out/icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$out/icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Armstrong Hub</string>
  <key>CFBundleDisplayName</key><string>Armstrong Hub</string>
  <key>CFBundleIdentifier</key><string>com.williamarmstrong.hub.desktop</string>
  <key>CFBundleExecutable</key><string>ArmstrongHub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac.
codesign --force --deep --sign - "$app"

if [[ ${1:-} != --no-install ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Armstrong Hub.app"
  cp -R "$app" ~/Applications/
  echo "Installed ~/Applications/Armstrong Hub.app"
fi
