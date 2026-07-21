#!/bin/bash
# One-line installer:
#   curl -fsSL https://apps.cleartextlabs.com/bike-bar/install.sh | bash
#
# Releases ship as a notarized zip on GitHub whose filename carries the version
# (Bosch-Bar-1.4.zip), so there is no stable /latest/download/<name> URL to hit —
# we ask the API for the newest release's zip asset instead.
set -e

REPO="digitalhen/bosch-bar"
APP="/Applications/Bosch Bar.app"

echo "Installing Bosch Bar..."

URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' \
  | head -1 \
  | sed 's/.*"\(https[^"]*\)"$/\1/')

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
[ -d "$TMP/Bosch Bar.app" ] || { echo "Unexpected archive layout." >&2; exit 1; }

# Quit a running copy so we're not swapping the bundle out from under it.
osascript -e 'tell application "Bosch Bar" to quit' 2>/dev/null || true
sleep 1
pkill -f "Bosch Bar.app/Contents/MacOS/BoschBar" 2>/dev/null || true

rm -rf "$APP"
ditto "$TMP/Bosch Bar.app" "$APP"

# The build is Developer ID-signed, notarized and stapled, so Gatekeeper is happy;
# clearing quarantine just skips the "downloaded from the internet" prompt.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Bosch Bar installed to /Applications"
echo "Starting Bosch Bar..."
open "$APP"
echo
echo "It lives in your menu bar (🚲 + battery %). Click it, then Sign in..."
