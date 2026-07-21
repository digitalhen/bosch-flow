#!/bin/bash
# Cut an auto-update release: build + notarize at the given version, EdDSA-sign
# the zip for Sparkle, generate appcast.xml, and publish both to GitHub Releases.
#
#   ./make-release.sh <version> <build#> ["release notes"]
#   e.g. ./make-release.sh 1.1 2 "Embedded backend, in-app login, unit sync."
#
# The build number MUST increase every release — Sparkle compares it (sparkle:version)
# to decide whether an update is available. The app's SUFeedURL is
# https://github.com/digitalhen/bike-bar/releases/latest/download/appcast.xml,
# so the newest release's appcast.xml is what installed apps read.
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:-}"; BUILD="${2:-}"; NOTES="${3:-Bug fixes and improvements.}"
if [ -z "$VER" ] || [ -z "$BUILD" ]; then
  echo "usage: ./make-release.sh <version> <build#> [\"notes\"]" >&2; exit 1
fi
REPO="digitalhen/bike-bar"
KEYFILE="$HOME/.appstoreconnect/private_keys/sparkle_ed25519.key"
TAG="v${VER}-build${BUILD}"
[ -f "$KEYFILE" ] || { echo "missing Sparkle key: $KEYFILE" >&2; exit 1; }

echo "== 1/4 build + notarize $VER (build $BUILD) =="
APP_VERSION="$VER" APP_BUILD="$BUILD" ./notarize.sh

ZIP="dist/Bosch-Bar-${VER}.zip"
[ -f "$ZIP" ] || { echo "notarize.sh did not produce $ZIP" >&2; exit 1; }

echo "== 2/4 EdDSA-sign the update =="
read -r SIG LEN < <(swift sparkle_sign.swift "$ZIP" "$KEYFILE")
echo "   sig=${SIG:0:16}… length=$LEN"

echo "== 3/4 write appcast.xml =="
URL="https://github.com/${REPO}/releases/download/${TAG}/Bosch-Bar-${VER}.zip"
PUBDATE="$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Bosch Bar</title>
    <item>
      <title>Version ${VER}</title>
      <description><![CDATA[${NOTES}]]></description>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VER}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="${URL}" length="${LEN}" type="application/octet-stream"
        sparkle:edSignature="${SIG}"/>
    </item>
  </channel>
</rss>
XML

echo "== 4/4 publish GitHub release ${TAG} =="
gh release create "$TAG" "$ZIP" dist/appcast.xml \
  --repo "$REPO" --title "Bosch Bar ${VER}" --notes "$NOTES"

echo "done — ${TAG} published; installed apps will see it via the appcast."
