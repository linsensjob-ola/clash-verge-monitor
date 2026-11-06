#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="/Applications/码表.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -framework SwiftUI -framework AppKit -framework IOKit \
  Sources/main.swift -o "$APP/Contents/MacOS/SysMon"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>码表</string>
  <key>CFBundleDisplayName</key><string>码表</string>
  <key>CFBundleIdentifier</key><string>studio.yomo.sysmon</string>
  <key>CFBundleExecutable</key><string>SysMon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
</dict>
</plist>
PLIST
# 图标
if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build
  python3 tools/mkicon.py >/dev/null 2>&1 || true
  [ -d build/AppIcon.iconset ] && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || true
fi
if [ -f build/AppIcon.icns ]; then
  cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "OK: $APP"
pkill -f "码表.app/Contents/MacOS/SysMon" 2>/dev/null || true
