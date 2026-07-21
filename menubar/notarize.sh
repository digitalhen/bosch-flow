#!/bin/bash
# Developer-ID sign + notarize + staple "Bike Bar.app" for warning-free
# distribution. Produces dist/Bike-Bar-<ver>.zip (committed to the repo).
#
# The app now embeds a PyInstaller-frozen Python backend, so signing is done
# inside-out: every nested Mach-O (CPython + dylibs + the boschflowd launcher)
# is signed with the hardened runtime first, then the outer bundle. The frozen
# CPython also needs two entitlements to run under the hardened runtime.
#
# One-time credential setup (keeps secrets OUT of this repo):
#   xcrun notarytool store-credentials bosch-flow \
#     --key   ~/.appstoreconnect/private_keys/AuthKey_XXXXX.p8 \
#     --key-id XXXXX --issuer <issuer-uuid>
#
# Requires: a valid "Developer ID Application" cert and an in-effect Apple
# Developer Program License Agreement (accept updates at developer.apple.com).
set -e
cd "$(dirname "$0")"
APP="Bike Bar.app"
ID="${SIGN_ID:-Developer ID Application: Henry Williams (GBGWWD9Z22)}"
PROFILE="${NOTARY_PROFILE:-bosch-flow}"
BACKEND="$APP/Contents/Resources/backend"

echo "› build"
./build.sh >/dev/null

echo "› entitlements (frozen CPython needs JIT-ish memory + library loading)"
ENT=build/entitlements.plist
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
	<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
PLIST

echo "› sign every nested Mach-O in the backend (dylibs, .so, Python.framework, launcher)"
# Detect Mach-O by content, not extension — the Python.framework binary has no
# suffix and would otherwise keep its ad-hoc signature (fails notarization).
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then
    codesign --force --options runtime --timestamp --entitlements "$ENT" --sign "$ID" "$f"
  fi
done < <(find "$BACKEND" -type f -print0)
# sign the launcher last — it loads everything above
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$ID" "$BACKEND/boschflowd"

echo "› sign Sparkle.framework inside-out (its own signatures aren't Developer ID)"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SPK" ]; then
  codesign --force --options runtime --timestamp --sign "$ID" "$SPK/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  codesign --force --options runtime --timestamp --sign "$ID" "$SPK/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  codesign --force --options runtime --timestamp --sign "$ID" "$SPK/Autoupdate"
  codesign --force --options runtime --timestamp --sign "$ID" "$SPK/Updater.app"
  codesign --force --options runtime --timestamp --sign "$ID" "$SPK/XPCServices/Installer.xpc"
  codesign --force --options runtime --timestamp --sign "$ID" "$SPK/XPCServices/Downloader.xpc"
  codesign --force --options runtime --timestamp --sign "$ID" "$APP/Contents/Frameworks/Sparkle.framework"
fi

echo "› sign app (Developer ID + hardened runtime + timestamp)"
codesign --force --options runtime --timestamp --entitlements "$ENT" \
  --sign "$ID" "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags.*runtime"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "› notarize (waits for Apple)"
mkdir -p dist
ditto -c -k --keepParent "$APP" dist/_notarize.zip
xcrun notarytool submit dist/_notarize.zip --keychain-profile "$PROFILE" --wait

echo "› staple + package"
xcrun stapler staple "$APP"
rm -f dist/_notarize.zip
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="dist/Bike-Bar-${VER}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "› verify"
spctl -a -vv "$APP"
echo "done -> $ZIP (notarized + stapled)"
