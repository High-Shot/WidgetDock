#!/bin/zsh
# Builds WidgetDock.app, installs it in /Applications and starts it.
set -e
cd "$(dirname "$0")"
APP=build/WidgetDock.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macos14.0 -swift-version 5 -parse-as-library WidgetDock.swift -o "$APP/Contents/MacOS/WidgetDock"
# Stop here, before anything is installed, if the app's own checks fail.
"$APP/Contents/MacOS/WidgetDock" --selftest
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WidgetDock</string>
    <key>CFBundleIdentifier</key><string>local.widgetdock</string>
    <key>CFBundleExecutable</key><string>WidgetDock</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>WidgetDock shows the song playing in Music or Spotify, switches light and dark mode, and empties the Trash when you ask.</string>
    <key>NSCalendarsFullAccessUsageDescription</key><string>WidgetDock shows your next calendar event.</string>
    <key>NSLocationUsageDescription</key><string>WidgetDock shows the weather where you are.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>WidgetDock shows the weather where you are.</string>
    <key>NSCalendarsUsageDescription</key><string>WidgetDock shows your next calendar event.</string>
</dict>
</plist>
EOF
# A fixed local certificate keeps macOS permissions (calendar, location, Accessibility) across rebuilds.
if security find-identity -p codesigning | grep -q "WidgetDock Local Signing"; then
  codesign --force --sign "WidgetDock Local Signing" "$APP"
else
  codesign --force --sign - "$APP"
fi
pkill -x WidgetDock || true
while pgrep -x WidgetDock >/dev/null; do sleep 0.2; done
sleep 1
rm -rf /Applications/WidgetDock.app
cp -R "$APP" /Applications/WidgetDock.app
open /Applications/WidgetDock.app
echo "Installed /Applications/WidgetDock.app"
