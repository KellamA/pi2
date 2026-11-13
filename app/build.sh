#!/bin/zsh
# Builds pi².app.
#
#   ./build.sh            Development build. The app runs the engine from ../engine with the Node on your PATH, so
#                         engine edits take effect on the next engine start. Only works on this machine.
#   ./build.sh release    Self-contained build. Node and the engine are copied into the app, which can then be
#                         moved anywhere on this Mac (or another Mac with the same chip).
#
# The version is in app/VERSION. The build number is the number of commits on the branch, so it only goes up as long as
# releases are made from main; set PI2_BUILD_NUMBER to override it.
#
# Optional, for a release build you want to give to someone else (docs/releasing.md has the whole procedure):
#   SIGN_IDENTITY="Developer ID Application: …"   sign with that identity and the hardened runtime
#   NOTARY_PROFILE="profile-name"                 then notarize with that `notarytool` keychain profile and staple,
#   or NOTARY_KEY=path NOTARY_KEY_ID=… NOTARY_ISSUER=…   with an App Store Connect API key instead (what CI uses)
#   SPARKLE_PUBLIC_KEY="…"                        the updates key; without it the build does not update itself
#   SPARKLE_FEED_URL="https://…/appcast.xml"      where to look for updates; defaults to the newest GitHub release
# Without SIGN_IDENTITY the app gets an ad-hoc signature, which is enough to run it on this Mac.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-dev}"
CONFIG=debug
[[ "$MODE" == release ]] && CONFIG=release

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${PI2_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
# Names this exact build. The app compares it with the engine's after an update and restarts an engine from before.
BUILD_ID="$VERSION+$BUILD_NUMBER.$(git rev-parse --short HEAD 2>/dev/null || echo local).$(date -u +%Y%m%d%H%M%S)"

NODE="$(command -v node)"
if [[ "$MODE" == release ]]; then
  # The Node copied into the app must stand alone. Homebrew's links against libraries in /opt/homebrew, which other
  # Macs do not have; the builds from nodejs.org (and actions/setup-node) only use the system's.
  if otool -L "$NODE" | tail -n +2 | awk '{print $1}' | grep -vqE '^(/usr/lib/|/System/Library/)'; then
    echo "The node at $NODE uses libraries outside macOS, so it cannot be copied into the app. Use a build from nodejs.org." >&2
    exit 1
  fi
fi

swift build -c "$CONFIG" --product pi2
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/pi².app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/pi2" "$APP/Contents/MacOS/pi2"
# Sparkle, for updates. ditto keeps the framework's symbolic links.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Icon: drawn once by make-icon.swift, then scaled to the sizes macOS wants.
if [[ ! -f build/AppIcon.icns || make-icon.swift -nt build/AppIcon.icns ]]; then
  swift make-icon.swift build/icon-1024.png
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The transcript page: plain HTML, CSS and JavaScript with no build step, loaded from here by the app.
cp -R Web/transcript "$APP/Contents/Resources/transcript"

EXTRA_KEYS=""
if [[ "$MODE" == release ]]; then
  # The engine and its runtime go inside the bundle; the app finds them there.
  cp "$NODE" "$APP/Contents/Resources/node"
  ENGINE="$APP/Contents/Resources/engine"
  mkdir -p "$ENGINE"
  cp -R ../engine/src "$ENGINE/src"
  cp ../engine/package.json ../engine/package-lock.json "$ENGINE/"
  (cd "$ENGINE" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null 2>&1)
  echo "$BUILD_ID" > "$ENGINE/BUILD"
  EXTRA_KEYS="<key>PI2BuildID</key><string>$BUILD_ID</string>"
  if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    FEED="${SPARKLE_FEED_URL:-https://github.com/KellamA/pi2/releases/latest/download/appcast.xml}"
    EXTRA_KEYS="$EXTRA_KEYS
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SURequireSignedFeed</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>"
  fi
else
  EXTRA_KEYS="<key>PI2NodePath</key><string>$NODE</string>
  <key>PI2EngineMain</key><string>$(cd ../engine && pwd)/src/main.ts</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>pi2</string>
  <key>CFBundleIdentifier</key><string>dev.pi2.app</string>
  <key>CFBundleName</key><string>pi²</string>
  <key>CFBundleDisplayName</key><string>pi²</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>dev.pi2.conversation</string>
    <key>UTTypeDescription</key><string>pi² conversation</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
  $EXTRA_KEYS
</dict></plist>
PLIST

notarize() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  # Node compiles JavaScript at run time, which the hardened runtime only allows with these entitlements.
  cat > build/node.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
ENT
  sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }
  [[ -f "$APP/Contents/Resources/node" ]] && sign --entitlements build/node.entitlements "$APP/Contents/Resources/node"
  # Sparkle from the inside out, as its documentation sets out, so all of it carries the same team as the app.
  sign "$SPARKLE/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Autoupdate"
  sign "$SPARKLE/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign "$APP"
  codesign --verify --deep --strict "$APP"
  if [[ -n "${NOTARY_PROFILE:-}" || -n "${NOTARY_KEY:-}" ]]; then
    ditto -c -k --keepParent "$APP" build/pi2-notarize.zip
    notarize build/pi2-notarize.zip
    rm build/pi2-notarize.zip
    xcrun stapler staple "$APP"
  fi
else
  # Ad-hoc signature: enough to run here and to let the app ask for notification permission. Sparkle keeps the
  # signature it came with.
  [[ -f "$APP/Contents/Resources/node" ]] && codesign --force --sign - "$APP/Contents/Resources/node" 2>/dev/null
  codesign --force --sign - "$APP" 2>/dev/null || true
fi
echo "Built $PWD/$APP ($MODE, $VERSION build $BUILD_NUMBER)"
