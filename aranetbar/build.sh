#!/bin/bash
#
# Build AranetBar.app
#
# A standalone bundle so the app gets its own Bluetooth (TCC) permission entry
# and can be launched from Finder or at login. Running the .swift file directly
# also works, but then it borrows your terminal's Bluetooth permission.
#
set -e

APP_NAME="AranetBar"
BUNDLE_ID="ai.thefocus.aranetbar"

echo "🔨 Building ${APP_NAME}.app..."

rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

echo "📦 Compiling aranetbar.swift..."
swiftc -O \
    -target "$(uname -m)-apple-macosx13.0" \
    aranetbar.swift \
    -o "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

if [ -f AppIcon.icns ]; then
    echo "🎨 Adding app icon..."
    cp AppIcon.icns "${APP_NAME}.app/Contents/Resources/AppIcon.icns"
else
    echo "⚠️  AppIcon.icns missing - regenerate it with: python3 make_icon.py"
fi

echo "📝 Creating Info.plist..."
cat > "${APP_NAME}.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>AranetBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>AranetBar reads your Aranet4's Bluetooth advertisement to show CO2, temperature, humidity and battery in the menu bar. No data leaves your Mac.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>AranetBar reads your Aranet4's Bluetooth advertisement to show its readings in the menu bar.</string>
</dict>
</plist>
EOF

echo "🔏 Signing app (ad-hoc)..."
codesign --force --deep --sign - "${APP_NAME}.app"

echo ""
echo "✅ Build complete: ${APP_NAME}.app"
echo ""
echo "🚀 To run:"
echo "   open ${APP_NAME}.app"
echo ""
echo "💡 First launch asks for Bluetooth permission — allow it."
echo "   To start at login: System Settings > General > Login Items."
echo ""
echo "🧪 Quick check without the UI:"
echo "   ./aranetbar.swift --once"
