# Open PDF Editor: Apple Silicon (arm64) only.
APP := build/Open PDF Editor.app
EXE := OpenPDFEditor
SWIFT_BUILD := swift build -c release --arch arm64

.PHONY: mupdf build icon smoke corpus test install dmg release hooks clean distclean

# MuPDF as Frameworks/MuPDF.xcframework (skipped when up to date).
mupdf:
	@test -f thirdparty/mupdf/thirdparty/zlib/zlib.h || scripts/fetch-mupdf-deps.sh
	scripts/build-mupdf.sh

# Build the app bundle, signed with SIGN_ID from scripts/signing.env
# (ad hoc without one).
build: mupdf
	$(SWIFT_BUILD)
	$(eval BIN := $(shell $(SWIFT_BUILD) --show-bin-path))
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" "$(APP)/Contents/Frameworks"
	cp "$(BIN)/$(EXE)" "$(APP)/Contents/MacOS/$(EXE)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	scripts/acknowledgements.sh > "$(APP)/Contents/Resources/Acknowledgements.txt"
	# Sparkle, thinned to arm64; its XPC services are only for sandboxed apps.
	ditto --arch arm64 "$(BIN)/Sparkle.framework" "$(APP)/Contents/Frameworks/Sparkle.framework"
	rm -rf "$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
	       "$(APP)/Contents/Frameworks/Sparkle.framework/XPCServices"
	scripts/sign-app.sh "$(APP)"

# Regenerate Resources/AppIcon.icns.
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

# Render page 1 of a PDF to build/smoke.png:  make smoke PDF=file.pdf
smoke: mupdf
	@test -n "$(PDF)" || { echo "usage: make smoke PDF=file.pdf"; exit 1; }
	$(SWIFT_BUILD) --product pdfsmoke
	"$(shell $(SWIFT_BUILD) --show-bin-path)/pdfsmoke" "$(PDF)" build/smoke.png

# Generate the test PDFs in build/corpus (builds mutool the first time).
corpus: mupdf
	scripts/make-corpus.sh

# Engine tests: text, search, outline, links, attachments, layers, passwords,
# and renders compared with Tests/PDFCoreTests/Golden (UPDATE_GOLDEN=1 rewrites them).
# With the Command Line Tools, SwiftPM's macro plugin server often fails to
# load Swift Testing's macros, so the compiler loads the library itself.
TESTING_MACROS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
test: corpus
	swift build --arch arm64 --build-tests -Xswiftc -load-plugin-library -Xswiftc "$(TESTING_MACROS)"
	$(if $(UPDATE_GOLDEN),UPDATE_GOLDEN=1) swift test --arch arm64 --skip-build

# Copy the app to /Applications.
install: build
	rm -rf "/Applications/Open PDF Editor.app"
	ditto "$(APP)" "/Applications/Open PDF Editor.app"

# dist/Open-PDF-Editor-<version>.dmg and .zip from a fresh build; notarized
# when scripts/signing.env has a Developer ID and a notary profile.
dmg: build
	scripts/package.sh

# Build, tag, push main, publish a GitHub release and update appcast.xml.
#   make release VERSION=0.1.0
#   make release VERSION=0.1.0 DRY_RUN=1   (build and package only)
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z [DRY_RUN=1]"; exit 1; }
	scripts/release.sh $(VERSION) $(if $(DRY_RUN),--dry-run)

# Only allow pushing main as a release (see scripts/git-hooks/pre-push).
hooks:
	git config core.hooksPath scripts/git-hooks

clean:
	rm -rf .build build/*.app dist

# Also MuPDF's build and the xcframework (a full MuPDF rebuild takes a few minutes).
distclean: clean
	rm -rf build Frameworks
