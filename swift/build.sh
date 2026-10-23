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
VERSION="${VERSION:-1.1.2}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS="13.0"

echo "🔨 Building ${APP_NAME}.app ${VERSION} (${BUILD_NUMBER})..."

rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

echo "📦 Compiling aranetbar.swift..."
BIN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
compile_arch() {
    swiftc -O -module-cache-path "$PWD/.build/modulecache" \
        -target "$1-apple-macosx${MIN_MACOS}" aranetbar.swift -o "$2"
}

# Ship a universal binary so Intel Macs can run it too. Fall back to the host
# architecture if the other slice cannot be built (e.g. a trimmed SDK).
rm -rf .build && mkdir -p .build/modulecache
if compile_arch arm64 .build/arm64 && compile_arch x86_64 .build/x86_64; then
    lipo -create .build/arm64 .build/x86_64 -output "${BIN}"
    echo "   universal binary (arm64 + x86_64)"
else
    echo "   ⚠️  universal build unavailable, compiling host arch only"
    swiftc -O -module-cache-path "$PWD/.build/modulecache" \
        -target "$(uname -m)-apple-macosx${MIN_MACOS}" aranetbar.swift -o "${BIN}"
fi
rm -rf .build

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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>AranetBar reads your Aranet4's Bluetooth advertisement for live readings and, when you open History, downloads its on-board log. No data leaves your Mac.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>AranetBar reads your Aranet4's Bluetooth advertisement and, on request, its stored history log.</string>
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
