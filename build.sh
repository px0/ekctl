#!/bin/bash
# Build script for ekctl - macOS EventKit CLI tool

set -e

echo "Building ekctl..."

# Build in release mode, embedding the Info.plist so macOS TCC can persist permissions
# -sectcreate __TEXT __info_plist embeds the plist into the binary itself (no app bundle needed)
swift build -c release \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker Info.plist

# Get the binary path
BINARY_PATH=".build/release/ekctl"

# Sign the binary with our stable "Spock Dev" identity + entitlements
# A stable identity means TCC permissions survive rebuilds
echo "Signing binary with Spock Dev identity + entitlements..."
# Use Apple Development cert SHA-1 for stable identity (TCC ties permissions to the bundle ID in the embedded Info.plist)
SIGNING_IDENTITY="${EKCTL_SIGNING_IDENTITY:-}"
codesign --force --sign "$SIGNING_IDENTITY" --entitlements ekctl.entitlements --timestamp=none "$BINARY_PATH"

echo ""
echo "Build complete!"
echo "Binary location: $BINARY_PATH"
echo ""
echo "To install, run:"
echo "  cp $BINARY_PATH /opt/homebrew/bin/ekctl"
echo ""
echo "First run will prompt for Calendar and Reminders access."
echo "The Info.plist is embedded in the binary — TCC permissions will persist."
