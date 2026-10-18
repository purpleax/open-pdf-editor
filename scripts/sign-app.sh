#!/bin/bash
# Signs the app bundle from the inside out: Sparkle's helpers, Sparkle, then
# the app. Called by make build.
#   scripts/sign-app.sh "build/Open PDF Editor.app"
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
APP=$1
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Resources/OpenPDFEditor.entitlements "$APP"
codesign --verify --strict --deep "$APP"
