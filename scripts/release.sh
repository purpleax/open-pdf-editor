#!/bin/bash
# Builds Open PDF Editor, publishes it as a GitHub release, updates the
# Sparkle appcast and pushes main.
#
#   scripts/release.sh <version>            e.g. scripts/release.sh 0.1.0
#   scripts/release.sh <version> --dry-run  build, package and sign the update only
#
# Steps: check the repository is clean and current, and the signing identity;
# set the version in Resources/Info.plist; build and verify the app; package
# it as a DMG and a zip in dist/ (signed and notarised with the Developer ID,
# see scripts/signing.sh); sign the zip for Sparkle with the EdDSA key in the
# Keychain (account "open-pdf-editor"); write appcast.xml; commit the version
# and appcast; tag v<version>; push main and the tag; create the GitHub release
# with both files attached. The release notes are the version's entry in the
# Releases section of ROADMAP.md (written for users), not the commit log.
# Pushes to main are expected to go through here (see scripts/git-hooks/pre-push).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

die() { echo "release: $*" >&2; exit 1; }

VERSION="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh <version, e.g. 0.1.0> [--dry-run]"
TAG="v$VERSION"
REPO="${OPDF_REPO:-purpleax/open-pdf-editor}"
SPARKLE_ACCOUNT=open-pdf-editor
PLIST=Resources/Info.plist
APPCAST=appcast.xml
PB=/usr/libexec/PlistBuddy
NAME="Open PDF Editor"
FILE_BASE="Open-PDF-Editor-$VERSION"

# --- Checks -------------------------------------------------------------
[ "$(git rev-parse --show-toplevel)" = "$PWD" ] || die "run from the open-pdf-editor repository"
[ "$(git branch --show-current)" = "main" ] || die "releases are made from main"
[ -z "$(git status --porcelain)" ] || die "commit or stash your changes first"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG already exists"
if [ "$DRY_RUN" = 0 ]; then
    gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
    git fetch -q origin
    [ "$(git rev-list --count HEAD..origin/main)" = 0 ] || die "origin/main has commits you don't have; pull first"
    [ "$SIGN_ID" != "-" ] && [ "$NOTARIZE" = 1 ] || die "public releases need a Developer ID and a notary profile (scripts/signing.env)"
fi
check_signing || die "fix the signing settings (scripts/signing.env) first"
SPARKLE_BIN=$(scripts/sparkle-tools.sh)

# What's new: the version's entry in ROADMAP.md ("- **x.y.z**: ..."), for users.
WHATS_NEW=$(grep -m1 -F -- "- **$VERSION**: " ROADMAP.md | sed "s/^- \*\*$VERSION\*\*: //" || true)
[ -n "$WHATS_NEW" ] || die "add a \"- **$VERSION**: ...\" entry under Releases in ROADMAP.md (it becomes the release notes)"

# --- Version ------------------------------------------------------------
OLD_VERSION=$($PB -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(( $($PB -c "Print :CFBundleVersion" "$PLIST") + 1 ))
restore() { git checkout -q -- "$PLIST"; git checkout -q -- "$APPCAST" 2>/dev/null || rm -f "$APPCAST"; }
trap restore ERR
$PB -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
$PB -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "release: $OLD_VERSION -> $VERSION (build $BUILD)"

# --- Build and package --------------------------------------------------
make build
APP="build/$NAME.app"
codesign --verify --strict --deep "$APP"
[ "$($PB -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")" = "$VERSION" ] || die "built app has the wrong version"
[ "$(lipo -archs "$APP/Contents/MacOS/OpenPDFEditor")" = "arm64" ] || die "the app should be arm64 only"

scripts/package.sh "$VERSION"
ZIP="dist/$FILE_BASE.zip"
DMG="dist/$FILE_BASE.dmg"
ZIP_SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
DMG_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# --- Sparkle appcast ----------------------------------------------------
# sign_update prints: sparkle:edSignature="..." length="..."
ED_SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP")
[[ "$ED_SIGNATURE" == *'sparkle:edSignature="'* ]] || die "sign_update failed: $ED_SIGNATURE"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_TEXT=$(printf '%s' "$WHATS_NEW" | xml_escape)
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$NAME</title>
    <link>https://github.com/$REPO</link>
    <description>Updates for $NAME</description>
    <language>en</language>
    <item>
      <title>$NAME $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown">$NOTES_TEXT</description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$FILE_BASE.zip" $ED_SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$APPCAST" || die "appcast.xml is not well-formed"

NOTES="dist/notes-$VERSION.md"
{
    echo "## What's new"
    echo
    echo "$WHATS_NEW"
    echo
    echo "## Install"
    echo
    echo "1. Download \`$FILE_BASE.dmg\` below and open it."
    echo "2. Drag **$NAME** onto the **Applications** folder in the window that opens."
    echo "3. Open it from Applications. It is signed and notarised by Apple, so it opens straight away."
    echo
    echo "Already installed? Choose **$NAME › Check for Updates…**."
    echo
    echo "Requires macOS 14 or later on a Mac with Apple silicon. Intel Macs are not supported."
    echo
    echo "$NAME is free software under the GNU AGPL-3.0. The source for this version is the \`$TAG\` tag of this repository."
    echo
    echo "SHA-256:"
    echo "- \`$FILE_BASE.dmg\`: \`$DMG_SHA\`"
    echo "- \`$FILE_BASE.zip\`: \`$ZIP_SHA\`"
} > "$NOTES"

if [ "$DRY_RUN" = 1 ]; then
    cp "$APPCAST" "dist/appcast-$VERSION.xml"
    restore
    trap - ERR
    echo "release: dry run: Info.plist and appcast.xml restored; nothing committed, tagged or pushed."
    echo "release: notes in $NOTES, appcast in dist/appcast-$VERSION.xml"
    exit 0
fi

# --- Commit, tag, push, publish -----------------------------------------
# The release goes up before main is pushed, so the appcast never points at
# a download that doesn't exist yet.
git add "$PLIST" "$APPCAST"
git commit -q -m "Release $TAG" -- "$PLIST" "$APPCAST"
trap - ERR
git tag -a "$TAG" -m "$NAME $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$ZIP" --repo "$REPO" --title "$NAME $VERSION" --notes-file "$NOTES" --verify-tag
git push origin main
echo "release: published $TAG; appcast updated"
