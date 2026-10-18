#!/bin/bash
# Packages "build/Open PDF Editor.app" into dist/: Open-PDF-Editor-<version>.zip and
# Open-PDF-Editor-<version>.dmg (the app plus an Applications link to drag it to).
#
# With a Developer ID and a notary profile (scripts/signing.env), the app is
# notarized by Apple and stapled before packaging, and the DMG is signed,
# notarized and stapled too, so both open without Gatekeeper warnings, even
# offline.
#
#   scripts/package.sh [version]   (default: the built app's version)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

die() { echo "package: $*" >&2; exit 1; }
APP="build/Open PDF Editor.app"
[ -d "$APP" ] || die "build the app first (make build)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
ZIP="dist/Open-PDF-Editor-$VERSION.zip"
DMG="dist/Open-PDF-Editor-$VERSION.dmg"
mkdir -p dist
check_signing

codesign --verify --strict --deep "$APP" || die "the app's signature is invalid"
if [ "$SIGN_ID" != "-" ]; then
    # Captured first: with pipefail, grep -q closing the pipe early would fail codesign.
    details=$(codesign -dvv "$APP" 2>&1)
    grep -qF "Authority=$SIGN_ID" <<< "$details" || die "the app isn't signed with $SIGN_ID (make build)"
    grep -q "flags=.*runtime" <<< "$details" || die "the app isn't signed with the hardened runtime"
fi

# Uploads a file to Apple's notary service and waits for the result.
notarize() {
    local file=$1 out=dist/notary-result.json
    echo "package: notarizing $(basename "$file") (usually a few minutes)"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$out" || true
    local status id
    status=$(plutil -extract status raw -o - "$out" 2>/dev/null || echo unknown)
    id=$(plutil -extract id raw -o - "$out" 2>/dev/null || echo "")
    if [ "$status" != "Accepted" ]; then
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || cat "$out" >&2
        die "notarization of $(basename "$file") failed: $status"
    fi
}

# Without extended attributes: stored as ._ files they land inside the
# bundle when unzipped with plain unzip and break the signature.
zip_app() { rm -f "$ZIP"; ditto -c -k --keepParent --norsrc --noextattr --noacl "$APP" "$ZIP"; }

if [ "$NOTARIZE" = 1 ]; then
    zip_app
    notarize "$ZIP"
    xcrun stapler staple "$APP"
fi
zip_app

# The DMG: the app and a link to /Applications.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGE/Open PDF Editor.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Open PDF Editor $VERSION" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG"
if [ "$SIGN_ID" != "-" ]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type execute "$APP" || die "Gatekeeper rejects the app"
    spctl --assess --type open --context context:primary-signature "$DMG" || die "Gatekeeper rejects the DMG"
    echo "package: notarized and stapled"
elif [ "$SIGN_ID" != "-" ]; then
    echo "package: signed with $SIGN_ID but not notarized (no NOTARY_PROFILE)"
else
    echo "package: signed ad hoc (no Developer ID): other Macs will need Open Anyway"
fi
echo "package: $ZIP ($(du -h "$ZIP" | cut -f1)), $DMG ($(du -h "$DMG" | cut -f1))"
