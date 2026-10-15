#!/usr/bin/env bash
# ABOUTME: Build and install Barik to /Applications
# ABOUTME: Handles quitting running instance, building, and relaunching

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Barik.app"
DEST="/Applications/$APP_NAME"

SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
if [ -z "$SIGNING_IDENTITY" ] && [ "${BARIK_ALLOW_ADHOC:-0}" != "1" ]; then
    echo "No valid Apple Development signing identity is available." >&2
    echo "Stopping before replacing Barik: an ad-hoc rebuild invalidates existing Accessibility approval." >&2
    echo "Restore the signing identity, or use BARIK_ALLOW_ADHOC=1 only when ready to reapprove the new build in System Settings." >&2
    exit 1
fi

echo "Building Barik..."
cd "$SCRIPT_DIR"
xcodebuild -scheme Barik -configuration Release -derivedDataPath "$BUILD_DIR" build

if ! [ -d "$BUILD_DIR/Build/Products/Release/$APP_NAME" ]; then
    echo "Build failed - app not found"
    exit 1
fi

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
open "$DEST" --args "$@"

echo "Done!"
