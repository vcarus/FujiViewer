#!/bin/bash
# Builds FujiViewer in release mode and assembles a double-clickable FujiViewer.app.
#
# Usage: ./build-app.sh [--universal]
#   --universal   one binary for Apple Silicon and Intel; slower, used for released downloads.
#
# The release workflow sets FUJIVIEWER_VERSION to the tag it is building.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="FujiViewer"
BUNDLE_ID="com.fujiviewer.FujiViewer"
VERSION="${FUJIVIEWER_VERSION:-1.0}"
APP_DIR="$APP_NAME.app"

BUILD_ARGS=(-c release)
case "${1:-}" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    "") ;;
    *) echo "usage: $0 [--universal]" >&2; exit 2 ;;
esac

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"

if [ ! -x "$BINARY" ]; then
    echo "error: $BINARY not found" >&2
    exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> rendering AppIcon.icns"
ICONSET_DIR="$BIN_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
swift Icon/make-icon.swift "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$BIN_DIR/AppIcon.icns"
cp "$BIN_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.photography</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP_DIR"
codesign --verify --verbose "$APP_DIR"

echo "==> done: $(pwd)/$APP_DIR"
