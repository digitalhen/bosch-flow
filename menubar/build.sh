#!/bin/bash
# Build "Bosch Bar.app" — a menu bar app that embeds and supervises the Python
# backend (frozen with PyInstaller), posts native notifications, and handles the
# onebikeapp-ios:// login redirect for in-app sign-in.
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
APP="Bosch Bar.app"
PYI="$ROOT/.venv/bin/pyinstaller"
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
swiftc -O -o "build/BoschBar" BoschBar.swift \
  -framework AppKit -framework SwiftUI -framework Combine \
  -framework UserNotifications -framework ServiceManagement \
  -F vendor -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks

echo "freezing backend (PyInstaller)…"
if [ ! -x "$PYI" ]; then
  echo "  pyinstaller not found at $PYI — run: $ROOT/.venv/bin/pip install -r requirements-build.txt" >&2
  exit 1
fi
BK_DIST="$ROOT/menubar/build/backend_dist"
( cd "$ROOT" && "$PYI" --noconfirm --clean \
    --name boschflowd \
    --distpath "$BK_DIST" \
    --workpath "$ROOT/menubar/build/backend_work" \
    --specpath "$ROOT/menubar/build" \
    --collect-submodules uvicorn \
    --collect-submodules app \
    --add-data "$ROOT/web:web" \
    --hidden-import app.main \
    --hidden-import httpx \
    --hidden-import starlette \
    serve.py >/dev/null )

cp build/BoschBar "$APP/Contents/MacOS/BoschBar"
mkdir -p "$APP/Contents/Resources/backend"
# copy the frozen onedir contents so the executable lands at Resources/backend/boschflowd
cp -R "$BK_DIST/boschflowd/." "$APP/Contents/Resources/backend/"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp bikebell.aiff "$APP/Contents/Resources/bikebell.aiff"   # custom notification sound

echo "embedding Sparkle.framework…"
mkdir -p "$APP/Contents/Frameworks"
# strip build-only pieces (Headers/Modules) from the embedded copy — runtime doesn't need them
ditto vendor/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/Modules" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Headers" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/PrivateHeaders" \
       "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Modules"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>Bosch Bar</string>
	<key>CFBundleDisplayName</key><string>Bosch Bar</string>
	<key>CFBundleExecutable</key><string>BoschBar</string>
	<!-- bundle id kept as com.boschflow.menubar so existing installs auto-update across the rename -->
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
	<key>SUFeedURL</key><string>https://github.com/digitalhen/bosch-bar/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key><string>kfnnicvmSp/Ya4BsHnp66K6DQtmAaGppupoFE/d71gU=</string>
	<key>SUEnableAutomaticChecks</key><true/>
	<key>SUAutomaticallyUpdate</key><false/>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key><string>Bosch eBike Flow OAuth</string>
			<key>CFBundleURLSchemes</key>
			<array><string>onebikeapp-ios</string></array>
		</dict>
	</array>
</dict>
</plist>
PLIST

# version is env-overridable so the release script can stamp each build
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION:-1.0}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD:-1}" "$APP/Contents/Info.plist"

codesign --force --deep -s - "$APP"
echo "built: $(pwd)/$APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
