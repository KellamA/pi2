#!/bin/zsh
# Puts pi² Remote inside an app bundle and signs it (#675, docs/pi2-remote.md, "Packaging"). build.sh calls it.
#
# An owner's path (.github/CODEOWNERS): pi² Remote holds the Mac's keys, and how it is signed decides what may run
# inside it. An entitlement such as com.apple.security.cs.allow-dyld-environment-variables or
# disable-library-validation would let any program of the person's start it with a library of its own loaded before
# main, which could then use its Keychain items and Secure Enclave keys. app/check-release-build.mts checks a release
# build's helper for exactly what this script gives it.
#
#   remote-helper.sh place <app> <helper executable> <bundle id> <version> <build number>
#       copies the executable to <app>/Contents/Helpers/pi² Remote.app/Contents/MacOS/pi² Remote, with its Info.plist:
#       no Dock icon (LSUIElement), the Local Network usage description macOS shows when a release build first
#       advertises on Bonjour, and _pi2._tcp, the one Bonjour service it uses.
#   remote-helper.sh sign <app> [<signing identity>]
#       signs the helper, before the app is: ad hoc with no identity; with one, with the hardened runtime and a
#       timestamp, and no entitlements. Its Keychain access group (keychain-access-groups) comes with its provisioning
#       profile (P14, #686): it goes here, and in check-release-build.mts's list of the entitlements it may have.
set -euo pipefail

usage() {
  echo "usage: remote-helper.sh place <app> <helper executable> <bundle id> <version> <build number>" >&2
  echo "       remote-helper.sh sign <app> [<signing identity>]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
MODE=$1
APP=$2
REMOTE="$APP/Contents/Helpers/pi² Remote.app"

case "$MODE" in
  place)
    [[ $# -eq 6 ]] || usage
    EXECUTABLE=$3 BUNDLE_ID=$4 VERSION=$5 BUILD_NUMBER=$6
    rm -rf "$REMOTE"
    mkdir -p "$REMOTE/Contents/MacOS"
    cp "$EXECUTABLE" "$REMOTE/Contents/MacOS/pi² Remote"
    cat > "$REMOTE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>pi² Remote</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>pi² Remote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>pi² lets your paired iPhone reach this Mac directly when both are on the same network.</string>
  <key>NSBonjourServices</key><array><string>_pi2._tcp</string></array>
</dict></plist>
PLIST
    ;;
  sign)
    [[ $# -le 3 ]] || usage
    [[ -d "$REMOTE" ]] || { echo "remote-helper.sh: $APP has no Contents/Helpers/pi² Remote.app to sign" >&2; exit 1; }
    if [[ -n "${3:-}" ]]; then
      codesign --force --options runtime --timestamp --sign "$3" "$REMOTE"
    else
      codesign --force --sign - "$REMOTE"
    fi
    ;;
  *) usage ;;
esac
