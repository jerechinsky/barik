#!/usr/bin/env bash
# ABOUTME: Build and install Barik to /Applications
# ABOUTME: Handles quitting running instance, building, and relaunching

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Barik.app"
DEST="/Applications/$APP_NAME"

echo "Building Barik..."
cd "$SCRIPT_DIR"
xcodebuild -scheme Barik -configuration Release -derivedDataPath "$BUILD_DIR" build

if ! [ -d "$BUILD_DIR/Build/Products/Release/$APP_NAME" ]; then
    echo "Build failed - app not found"
    exit 1
fi

SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing Barik for stable macOS permissions..."
    codesign --force --options runtime \
        --entitlements "$SCRIPT_DIR/Barik/Barik.entitlements" \
        --sign "$SIGNING_IDENTITY" \
        "$BUILD_DIR/Build/Products/Release/$APP_NAME"
fi

echo "Stopping running instance..."
pkill -x Barik 2>/dev/null || true
sleep 1

echo "Installing to /Applications..."
rm -rf "$DEST"
cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME" "$DEST"

echo "Launching Barik..."
open "$DEST"

echo "Done!"
