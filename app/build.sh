#!/bin/zsh
# Builds pi².app.
#
#   ./build.sh            Development build. The app runs the engine from ../engine with the Node on your PATH, so
#                         engine edits take effect on the next engine start. Only works on this machine.
#   ./build.sh release    Self-contained build. Node and the engine are copied into the app, which can then be
#                         moved anywhere on this Mac (or another Mac with the same chip).
#
# Optional, for a release build you want to give to someone else:
#   SIGN_IDENTITY="Developer ID Application: …"   sign with that identity and the hardened runtime
#   NOTARY_PROFILE="profile-name"                 then notarize with that `notarytool` keychain profile and staple
# Without SIGN_IDENTITY the app gets an ad-hoc signature, which is enough to run it on this Mac.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-dev}"
CONFIG=debug
[[ "$MODE" == release ]] && CONFIG=release

swift build -c "$CONFIG" --product pi2
APP="build/pi².app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c "$CONFIG" --show-bin-path)/pi2" "$APP/Contents/MacOS/pi2"

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

NODE="$(command -v node)"
ENGINE_KEYS=""
if [[ "$MODE" == release ]]; then
  # The engine and its runtime go inside the bundle; the app finds them there.
  cp "$NODE" "$APP/Contents/Resources/node"
  ENGINE="$APP/Contents/Resources/engine"
  mkdir -p "$ENGINE"
  cp -R ../engine/src "$ENGINE/src"
  cp ../engine/package.json ../engine/package-lock.json "$ENGINE/"
  (cd "$ENGINE" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund >/dev/null 2>&1)
else
  ENGINE_KEYS="<key>PI2NodePath</key><string>$NODE</string>
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
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  $ENGINE_KEYS
</dict></plist>
PLIST

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
  [[ -f "$APP/Contents/Resources/node" ]] && codesign --force --options runtime --timestamp --entitlements build/node.entitlements --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/node"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$APP" build/pi2.zip
    xcrun notarytool submit build/pi2.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
  fi
else
  # Ad-hoc signature: enough to run here and to let the app ask for notification permission.
  [[ -f "$APP/Contents/Resources/node" ]] && codesign --force --sign - "$APP/Contents/Resources/node" 2>/dev/null
  codesign --force --sign - "$APP" 2>/dev/null || true
fi
echo "Built $PWD/$APP ($MODE)"
