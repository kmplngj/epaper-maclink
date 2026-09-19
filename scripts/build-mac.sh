#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
MACLINK_SDK="${MACLINK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
swift build --package-path macos -c release --sdk "$MACLINK_SDK"
APP="dist/MacLink.app"
mkdir -p "$APP/Contents/MacOS"
cp macos/.build/release/MacLink "$APP/Contents/MacOS/MacLink"
mkdir -p "$APP/Contents/Resources"
ditto macos/.build/release/MacLink_MacLink.bundle "$APP/Contents/Resources/MacLink_MacLink.bundle"
ditto macos/.build/release/Starscream_Starscream.bundle "$APP/Contents/Resources/Starscream_Starscream.bundle"
mkdir -p "$APP/Contents/Resources/Licenses"
install -m 644 LICENSE "$APP/Contents/Resources/Licenses/MacLink-MIT.txt"
install -m 644 licenses/* "$APP/Contents/Resources/Licenses/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>de.maclink.app</string>
<key>CFBundleName</key><string>MacLink</string>
<key>CFBundleExecutable</key><string>MacLink</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>MacLink reads your selected calendars to show your upcoming week on your e-paper displays.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>MacLink reads your selected reminder lists to show your tasks on your e-paper displays.</string>
<key>NSLocalNetworkUsageDescription</key><string>MacLink publishes display images to your home server and reads your selected Home Assistant sensors.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :MacLinkSourceFolder string $(pwd)" "$APP/Contents/Info.plist"
MACLINK_SIGN_IDENTITY="${MACLINK_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*) \([A-F0-9]\{40\}\).*/\1/p' | head -n 1)}"
codesign --force --sign "${MACLINK_SIGN_IDENTITY:--}" "$APP"
printf '%s\n' "$APP"
