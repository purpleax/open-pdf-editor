# Open PDF Editor Roadmap

Started Oct 18, 2026. Work goes phase by phase. Each phase from 1 onwards ends with a tested, notarised GitHub release (`make release`). After each phase, work stops until the go-ahead for the next. Tick items as they land, and note anything deferred or changed under the item.

## Decisions

| Decision | Choice | Date |
| --- | --- | --- |
| Name | Open PDF Editor; bundle identifier `com.purpleax.openpdfeditor`; repository `purpleax/open-pdf-editor` | 2026-10-18 |
| Licence | AGPL-3.0, matching MuPDF. The repository is public from the first commit, so every build has its source. The Mac App Store is ruled out. | 2026-10-18 |
| Engine | MuPDF 1.28.5 as a git submodule, built by `scripts/build-mupdf.sh` into an arm64 static library in a hand-made `Frameworks/MuPDF.xcframework` (no full Xcode needed). Tesseract, Leptonica, barcodes and the GLUT/X11 viewers are left out; MuJS, extract and the HTML engine stay in. | 2026-10-18 |
| Calling MuPDF from Swift | A small C target (`MuPDFBridge`) wraps every MuPDF call in `fz_try`/`fz_catch` and returns errors as values, because MuPDF's exceptions are `setjmp`/`longjmp` and Swift can't unwind through them | 2026-10-18 |
| App | Swift and AppKit, built with SwiftPM and a Makefile like mdview: `NSDocument` per PDF, native window tabs, `NSToolbar`, split view with sidebars and an inspector | 2026-10-18 |
| Platforms | macOS 14 or later, Apple Silicon (arm64) only. Intel Macs are not supported. | 2026-10-18 |
| Updates | Sparkle 2.10.0 (SwiftPM), automatic checks, EdDSA-signed updates. The appcast is `appcast.xml` on `main` of this repository, written by `make release`. | 2026-10-18 |
| Releases | GitHub Releases on this repository: a DMG and a zip per version, signed with the Developer ID, notarised and stapled (scripts adapted from mdview) | 2026-10-18 |
| OCR | Apple's Vision framework on device; MuPDF writes the invisible text layer. Not MuPDF's Tesseract build. | 2026-10-18 |
| Text editing | Within a line only: insert, replace and delete characters in one text run, change its font, size and colour, using the embedded font's glyphs or a fallback font. No reflow across lines. | 2026-10-18 |
| Digital signatures | MuPDF's signer callbacks backed by Security.framework (CMS) and Keychain identities; verification against the system trust store. No bundled OpenSSL. | 2026-10-18 |
| Printing | The saved PDF handed to PDFKit's print operation, for the native print panel | 2026-10-18 |
| Undo | MuPDF's document journal, bridged to `NSUndoManager` | 2026-10-18 |
| Saving | Incremental saves by default (keeps signatures valid). Redaction and Reduce File Size force a full rewrite with garbage collection. | 2026-10-18 |

## Phase 0: Foundations

- [x] Repository, AGPL-3.0 licence, spec and roadmap
- [x] MuPDF submodule pinned to 1.28.5, with only the libraries the build uses checked out
- [x] MuPDF xcframework (arm64) built by `scripts/build-mupdf.sh`
- [x] Swift package: the C bridge, the app, and a command-line smoke test that renders a page
- [x] Sparkle linked, with Check for Updates… in the app menu and an EdDSA key in the Keychain
- [x] Signing, packaging (DMG and zip, notarised) and release scripts adapted from mdview, plus the appcast
- [ ] Public repository on GitHub, pushed
- [ ] App icon

## Phase 1: Viewer (0.1.0)

- [ ] Tiled page view rendering at the screen's scale, with a page cache and low-resolution placeholders
- [ ] Continuous, single-page and two-page layouts; fit to width, fit to page, actual size; zoom with pinch and ⌘+/⌘−
- [ ] Rotate view
- [ ] Thumbnails sidebar and outline sidebar
- [ ] Find with highlighted results and a results list
- [ ] Text selection and copy
- [ ] Password-protected PDFs
- [ ] Document properties, attachments and layers panels
- [ ] Print
- [ ] Window tabs, toolbar, full screen, Dark Mode
- [ ] VoiceOver reads page text
- [ ] About window with the open-source licences
- [ ] Test corpus and render tests

## Phase 2: Annotations (0.2.0)

- [ ] Highlight, underline, strikethrough
- [ ] Sticky notes and text boxes
- [ ] Shapes, lines and arrows, freehand drawing
- [ ] Stamps
- [ ] Annotation list with replies, status and filters
- [ ] Undo and redo through MuPDF's journal; incremental save
- [ ] Flatten annotations

## Phase 3: Pages (0.3.0)

- [ ] Insert, delete, reorder (drag in thumbnails), rotate, crop and extract pages
- [ ] Merge PDFs and split a PDF
- [ ] Create a PDF from images and from other documents MuPDF reads
- [ ] Reduce file size

## Phase 4: Forms (0.4.0)

- [ ] Fill in and save forms
- [ ] Create and edit text fields, checkboxes, radio buttons, dropdowns and signature fields
- [ ] Flatten forms

## Phase 5: Content editing (0.5.0)

- [ ] Add, replace, move, resize and delete images
- [ ] Headers, footers, watermarks and page numbers
- [ ] Links
- [ ] Edit text within a line: characters, font, size and colour
- [ ] Edit metadata

## Phase 6: Security and signing (0.6.0)

- [ ] Redaction that removes the content underneath
- [ ] Passwords, encryption and permissions
- [ ] Digital signatures with Keychain identities, and verification
- [ ] Handwritten and image signatures

## Phase 7: OCR and export (0.7.0)

- [ ] OCR with Vision, adding a searchable text layer
- [ ] Export to images, plain text, Word and HTML

## Phase 8: 1.0 (1.0.0)

- [ ] User manual, bundled and opened from Help
- [ ] Homebrew cask
- [ ] Website or project page

## Releases

Each entry is the release notes for that version, written for users.
