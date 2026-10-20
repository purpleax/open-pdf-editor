#!/bin/bash
# Builds the user guide, build/guide/Guide.pdf, from docs/guide/guide.html
# with mutool (built first if needed).
set -euo pipefail
cd "$(dirname "$0")/.."
MUTOOL=$(scripts/build-mutool.sh)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
mkdir -p build/guide
rm -f build/guide/Guide.pdf
"$MUTOOL" run scripts/make-guide.js docs/guide/guide.html build/guide/Guide.pdf "$VERSION"
