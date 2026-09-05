#!/bin/bash
# Builds League Vault into a runnable macOS .app bundle. No Xcode required —
# just the Command Line Tools (swiftc + the macOS SDK).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="League Vault"
BUNDLE_ID="com.corbin.leaguevault"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc \
  -O -whole-module-optimization \
  -parse-as-library \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework SwiftUI -framework AppKit -framework Security -framework CryptoKit \
  -o "$APP/Contents/MacOS/LeagueVault" \
  Sources/*.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>LeagueVault</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Local account tracker. Your data never leaves this Mac except for Riot API lookups.</string>
</dict>
</plist>
PLIST

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with the local certificate when one exists, so the app keeps the same identity
# across rebuilds — macOS ties Accessibility permission to the signature, and an ad-hoc
# signature changes every single build. Create one with tools/make-signing-cert.sh.
SIGN_ID="League Vault Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    # Retry once: the first use in a session can lose a race with the keychain's
    # access prompt, and a silent ad-hoc fallback would quietly revoke the app's
    # Accessibility permission.
    if ! codesign --force --deep --sign "$SIGN_ID" "$APP" 2>/tmp/lv-codesign.log; then
        sleep 2
        codesign --force --deep --sign "$SIGN_ID" "$APP" 2>>/tmp/lv-codesign.log || true
    fi

    if codesign -d -r- "$APP" 2>/dev/null | grep -q "certificate leaf"; then
        echo "Signed with $SIGN_ID (Accessibility permission persists across builds)"
    else
        echo
        echo "!!  Could not sign with $SIGN_ID — falling back to ad-hoc."
        echo "!!  macOS will treat this as a DIFFERENT app and revoke its Accessibility"
        echo "!!  permission. Autofill will stop working until you re-grant it."
        echo "!!  $(tail -1 /tmp/lv-codesign.log 2>/dev/null)"
        echo
        codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
    fi
else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "(ad-hoc signing skipped)"
    echo "Tip: run tools/make-signing-cert.sh so Accessibility permission survives rebuilds."
fi

echo "Built $APP"
