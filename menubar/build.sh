#!/bin/bash
# Build "Bosch Flow.app" — a menu bar app (menu bar status + native notifications).
set -e
cd "$(dirname "$0")"
APP="Bosch Flow.app"
rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS"

echo "generating app icon…"
if [ ! -f build/AppIcon.icns ]; then
  swiftc -O -o build/makeicon makeicon.swift -framework AppKit
  ./build/makeicon build/icon1024.png
  ICONSET=build/AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

echo "compiling…"
swiftc -O -o "build/BoschFlow" BoschFlow.swift \
  -framework AppKit -framework SwiftUI -framework Combine -framework UserNotifications

cp build/BoschFlow "$APP/Contents/MacOS/BoschFlow"
mkdir -p "$APP/Contents/Resources"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Bosch Flow</string>
	<key>CFBundleDisplayName</key><string>Bosch Flow</string>
	<key>CFBundleExecutable</key><string>BoschFlow</string>
	<key>CFBundleIdentifier</key><string>com.boschflow.menubar</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSAppTransportSecurity</key>
	<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
echo "built: $(pwd)/$APP"
