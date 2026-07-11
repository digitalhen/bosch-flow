#!/bin/bash
# Developer-ID sign + notarize + staple "Bosch Flow.app" for warning-free
# distribution. Produces dist/Bosch-Flow-1.0.zip (committed to the repo).
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
APP="Bosch Flow.app"
ID="${SIGN_ID:-Developer ID Application: Henry Williams (GBGWWD9Z22)}"
PROFILE="${NOTARY_PROFILE:-bosch-flow}"

echo "› build"
./build.sh >/dev/null

echo "› sign (Developer ID + hardened runtime + timestamp)"
codesign --force --sign "$ID" --options runtime --timestamp "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags.*runtime"

echo "› notarize (waits for Apple)"
mkdir -p dist
ditto -c -k --keepParent "$APP" dist/_notarize.zip
xcrun notarytool submit dist/_notarize.zip --keychain-profile "$PROFILE" --wait

echo "› staple + package"
xcrun stapler staple "$APP"
rm -f dist/_notarize.zip
ditto -c -k --keepParent "$APP" dist/Bosch-Flow-1.0.zip

echo "› verify"
spctl -a -vv "$APP"
echo "done -> dist/Bosch-Flow-1.0.zip (notarized + stapled)"
