#!/bin/zsh
# Builds the spike and wraps it in an app bundle that knows where the dev engine and Node are.
# Milestone 3 replaces these dev paths with a bundled runtime and a login item.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c debug
NODE="$(command -v node)"
ENGINE_MAIN="$(cd ../engine && pwd)/src/main.ts"
APP="build/pi².app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c debug --show-bin-path)/pi2" "$APP/Contents/MacOS/pi2"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>pi2</string>
  <key>CFBundleIdentifier</key><string>dev.pi2.app</string>
  <key>CFBundleName</key><string>pi²</string>
  <key>CFBundleDisplayName</key><string>pi²</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>PI2NodePath</key><string>$NODE</string>
  <key>PI2EngineMain</key><string>$ENGINE_MAIN</string>
</dict></plist>
PLIST
# Ad-hoc signature: enough for macOS to let the app ask for notification permission.
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $PWD/$APP"
