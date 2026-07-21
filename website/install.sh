#!/bin/bash
# One-line installer:
#   curl -fsSL https://apps.cleartextlabs.com/bike-bar/install.sh | bash
#
# Every release publishes an unversioned Bike-Bar.zip alongside the versioned one,
# so this URL is permanent. Releases from before that (<= 1.5) only have the
# versioned name, hence the API fallback.
set -e

REPO="digitalhen/bike-bar"
APP="/Applications/Bike Bar.app"
LEGACY="/Applications/Bosch Bar.app"
URL="https://github.com/${REPO}/releases/latest/download/Bike-Bar.zip"

echo "Installing Bike Bar..."

if ! curl -fsSLI "$URL" >/dev/null 2>&1; then
  URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.zip"' \
    | head -1 \
    | sed 's/.*"\(https[^"]*\)"$/\1/')
fi

if [ -z "$URL" ]; then
  echo "Could not find a release zip for ${REPO}." >&2
  echo "Download it manually: https://github.com/${REPO}/releases/latest" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/BoschBar.zip"

echo "Downloading $(basename "$URL")..."
curl -fSL --progress-bar "$URL" -o "$ZIP"

unzip -q "$ZIP" -d "$TMP"
[ -d "$TMP/Bike Bar.app" ] || { echo "Unexpected archive layout." >&2; exit 1; }

# Quit a running copy so we're not swapping the bundle out from under it.
osascript -e 'tell application "Bike Bar" to quit' 2>/dev/null || true
osascript -e 'tell application "Bosch Bar" to quit' 2>/dev/null || true
sleep 1
pkill -f "B.{3} Bar.app/Contents/MacOS/BoschBar" 2>/dev/null || true

rm -rf "$APP"
ditto "$TMP/Bike Bar.app" "$APP"

# Pre-rename installs sat at "Bosch Bar.app". Same bundle id, so leaving it in
# place would mean two copies both eligible to launch at login.
if [ -d "$LEGACY" ]; then
  echo "Removing the old Bosch Bar.app..."
  rm -rf "$LEGACY"
fi

# The build is Developer ID-signed, notarized and stapled, so Gatekeeper is happy;
# clearing quarantine just skips the "downloaded from the internet" prompt.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Bike Bar installed to /Applications"
echo "Starting Bike Bar..."
open "$APP"
echo
echo "It lives in your menu bar (🚲 + battery %). Click it, then Sign in..."
