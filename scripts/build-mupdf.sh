#!/bin/bash
# Builds MuPDF (thirdparty/mupdf) as an Apple Silicon (arm64) static library
# and wraps it in Frameworks/MuPDF.xcframework for SwiftPM's binary target.
#
#   scripts/build-mupdf.sh          rebuild only when MuPDF or this script changed
#   scripts/build-mupdf.sh --force  always rebuild
#
# MuPDF's own Makefile builds it, and its two libraries (MuPDF and its
# third-party code) are merged into one with libtool. The xcframework is
# written by hand rather than with xcodebuild -create-xcframework, so the
# Command Line Tools are enough. Intel Macs are not supported.
#
# Configuration: no Tesseract or Leptonica (OCR uses Apple's Vision), no
# barcodes, no GLUT/X11/curl viewers. MuJS (form JavaScript, off by default in
# the app) and extract (export to Word) stay on, as does the HTML engine
# (EPUB, Office and text to PDF).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

die() { echo "build-mupdf: $*" >&2; exit 1; }
MUPDF=thirdparty/mupdf
[ -f "$MUPDF/Makefile" ] || die "MuPDF is missing: git submodule update --init thirdparty/mupdf, then scripts/fetch-mupdf-deps.sh"

MIN_MACOS=14.0
ARCH=arm64
OUT=$ROOT/build/mupdf
XCF=$ROOT/Frameworks/MuPDF.xcframework
MAKE_OPTS=(build=release barcode=no tesseract=no HAVE_GLUT=no HAVE_X11=no HAVE_CURL=no)

# Rebuild when the MuPDF commit, its submodules or this script change.
STAMP=$( { git -C "$MUPDF" rev-parse HEAD; git -C "$MUPDF" submodule status; shasum "$0"; } | shasum | cut -d' ' -f1)
if [ "${1:-}" != "--force" ] && [ -f "$XCF/.stamp" ] && [ "$(cat "$XCF/.stamp")" = "$STAMP" ]; then
    echo "build-mupdf: up to date ($(git -C "$MUPDF" describe --tags))"
    exit 0
fi

JOBS=$(sysctl -n hw.ncpu)
arch=$ARCH
mkdir -p "$OUT"
echo "build-mupdf: building $arch"
make -C "$MUPDF" -j"$JOBS" "${MAKE_OPTS[@]}" OUT="$OUT/$arch" \
    XCFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
    XLDFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
    libs > "$OUT-$arch.log" 2>&1 || { tail -30 "$OUT-$arch.log" >&2; die "$arch build failed (log: $OUT-$arch.log)"; }
# MuPDF's build regenerates some tracked files under generated/ when their
# timestamps are older than the fonts they come from (as after a clone). The
# content is the same apart from a trailing empty string, so put the tracked
# copies back to keep the submodule clean; releases need a clean tree.
git -C "$MUPDF" checkout -q -- generated

rm -rf "$XCF"
SLICE=$XCF/macos-arm64
mkdir -p "$SLICE/Headers"
xcrun libtool -static -no_warning_for_no_symbols -o "$SLICE/libmupdf.a" \
    "$OUT/$arch/libmupdf.a" "$OUT/$arch/libmupdf-third.a"
cp -R "$MUPDF/include/mupdf" "$SLICE/Headers/"
cat > "$SLICE/Headers/module.modulemap" <<'MAP'
module MuPDF {
    header "mupdf/fitz.h"
    header "mupdf/pdf.h"
    export *
}
MAP
cat > "$XCF/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libmupdf.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST
echo "$STAMP" > "$XCF/.stamp"
echo "build-mupdf: $(git -C "$MUPDF" describe --tags) -> Frameworks/MuPDF.xcframework ($(du -sh "$SLICE/libmupdf.a" | cut -f1), $(xcrun lipo -archs "$SLICE/libmupdf.a"))"
