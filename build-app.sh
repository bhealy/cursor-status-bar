#!/bin/bash
set -euo pipefail

APP_NAME="CursorStatusBar"
BUNDLE_ID="com.bhealy.cursor-status-bar"
VERSION="1.0.0"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${BUILD_DIR}/dist"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"

echo "==> Building release binary..."
cd "${BUILD_DIR}"
swift build -c release 2>&1

BINARY="${BUILD_DIR}/.build/release/${APP_NAME}"
if [ ! -f "${BINARY}" ]; then
    echo "ERROR: Binary not found at ${BINARY}"
    exit 1
fi

echo "==> Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
cp "${BINARY}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Cursor Status Bar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

echo "==> App bundle created at: ${APP_BUNDLE}"

# Create DMG
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}.dmg"
echo "==> Creating DMG..."
rm -f "${DMG_PATH}"
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${APP_BUNDLE}" \
    -ov -format UDZO \
    "${DMG_PATH}" 2>&1

echo ""
echo "=== Done ==="
echo "  App bundle: ${APP_BUNDLE}"
echo "  DMG:        ${DMG_PATH}"
echo ""
echo "To install: open the DMG and drag to /Applications"
echo "To run:     open ${APP_BUNDLE}"
