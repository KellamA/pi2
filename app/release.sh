#!/bin/zsh
# Packages a release build for download and for updates. Run it after `./build.sh release`.
#
# Makes, in build/release:
#   pi2-<version>.dmg    what people download: the app and a link to Applications, signed and notarized
#   pi2-<version>.zip    what Sparkle downloads to update an installed copy
#   appcast.xml          the update feed, pointing at the zip, with the release notes; signed with the updates key
#   notes.md             this version's section of CHANGELOG.md, for the GitHub release
#
#   SPARKLE_PRIVATE_KEY      the updates key, as `generate_keys -x` exports it (required)
#   SIGN_IDENTITY            sign the disk image with it; then NOTARY_PROFILE, or NOTARY_KEY, NOTARY_KEY_ID and
#                            NOTARY_ISSUER, to notarize it (as for build.sh)
#   DOWNLOAD_URL             the folder the zip is published in; defaults to this version's GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP="build/pi².app"
[[ -d "$APP" ]] || { echo "Build the app first: ./build.sh release" >&2; exit 1; }
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || { echo "Set SPARKLE_PRIVATE_KEY to the updates key." >&2; exit 1; }
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" >/dev/null 2>&1 \
  || { echo "This build has no updates key. Build it with SPARKLE_PUBLIC_KEY set." >&2; exit 1; }
REPO="https://github.com/KellamA/pi2"
DOWNLOAD_URL="${DOWNLOAD_URL:-$REPO/releases/download/v$VERSION}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin" # Sparkle's tools, which come with its Swift package
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

# The update archive. Sparkle unpacks it and checks the app's signature against the one installed.
ZIP="$OUT/pi2-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The disk image: the app beside a link to Applications.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/pi².app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/pi2-$VERSION.dmg"
hdiutil create -quiet -volname "pi² $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  elif [[ -n "${NOTARY_KEY:-}" ]]; then
    xcrun notarytool submit "$DMG" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
    xcrun stapler staple "$DMG"
  fi
fi

# This version's notes, from its section of the changelog, with links into the repository made absolute.
awk -v version="$VERSION" '
  /^## / { inside = ($2 == version); next }
  inside { print }
' ../CHANGELOG.md | sed -E "s#\]\((docs/[^)]*)\)#]($REPO/blob/v$VERSION/\1)#g" > "$OUT/notes.md"
[[ -s "$OUT/notes.md" ]] || { echo "CHANGELOG.md has no section for $VERSION." >&2; exit 1; }

# The feed. One item, the newest release: every copy updates straight to it.
ENCLOSURE="$(echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP")"
NOTES="$(sed 's/]]>/]]]]><![CDATA[>/g' "$OUT/notes.md")"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>pi²</title>
    <link>$REPO</link>
    <item>
      <title>pi² $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[$NOTES]]></description>
      <enclosure url="$DOWNLOAD_URL/pi2-$VERSION.zip" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML
echo "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$OUT/appcast.xml"
echo "Packaged $VERSION (build $BUILD_NUMBER) in $PWD/$OUT"
ls -lh "$OUT"
