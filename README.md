# Open PDF Editor

A free, open-source PDF editor for the Mac, built on the [MuPDF](https://mupdf.com) engine. It aims to cover what commercial editors such as Foxit PDF Editor do: viewing, annotation, forms, page management, editing, redaction, signing and OCR, in a native macOS app.

**Status:** version 0.5.0 views, annotates and edits PDFs, manages their pages, and fills in and edits forms. Security, signing and OCR follow phase by phase: see [ROADMAP.md](ROADMAP.md) for the plan and [SPEC.md](SPEC.md) for the full feature list.

## What it does today

- Sharp rendering at any zoom, with continuous, single-page and two-page layouts, Fit Width, Fit Page and rotation
- Thumbnails, outline, search results, attachments and layers in the sidebar; document properties in the inspector
- Find with highlighted matches, text selection and copy, links, Back and Forward
- Highlights, underlines, strikethroughs, notes, text boxes, shapes, arrows, freehand drawing and stamps, with a Comments list for replies and review status
- Rotate, delete, insert, move, crop and extract pages; merge and split PDFs; make a PDF from images and other documents; reduce file size
- Edit text in place (characters, font, size, colour); add, move, resize, replace and delete images; make and change links
- Headers, footers, page numbers and watermarks; edit the document's title, author, subject and keywords
- Fill in forms; add, move and set up text fields, checkboxes, radio buttons, dropdowns, list boxes and signature fields; flatten forms
- Settings switches, off until turned on, for opening web links and converting documents other than PDFs and images
- Undo that survives saving; autosave with Versions as a setting; saves keep digital signatures valid
- Password-protected PDFs, printing, window tabs, full screen, Dark Mode and VoiceOver
- Updates when you choose Check for Updates…

## Requirements

- macOS 14 Sonoma or later
- A Mac with Apple silicon. Intel Macs are not supported.

## Download

Download the latest DMG from the [Releases page](https://github.com/purpleax/open-pdf-editor/releases). It is signed and notarised. Once installed, Open PDF Editor › Check for Updates… updates it; the app never checks on its own.

## Building from source

You need the Xcode Command Line Tools (`xcode-select --install`) on an Apple silicon Mac. Full Xcode is not required.

```bash
git clone --recurse-submodules=thirdparty/mupdf https://github.com/purpleax/open-pdf-editor.git
```

```bash
cd open-pdf-editor && make build
```

The first build compiles MuPDF, which takes a few minutes. The app is written to `build/Open PDF Editor.app`.

Without a Developer ID the app is signed ad hoc and runs on your own Mac. To sign with your own identity, copy `scripts/signing.env.example` to `scripts/signing.env` and fill it in.

Other targets:

| Command | What it does |
| --- | --- |
| `make test` | Generates the test PDFs and runs the engine and layout tests |
| `make selftest` | Builds a separate test copy of the app and runs it through annotating and page management, saving a log and snapshots to `build/selftest` |
| `make smoke PDF=file.pdf` | Renders page 1 of a PDF to `build/smoke.png` with MuPDF |
| `make install` | Copies the app to /Applications |
| `make dmg` | Builds the DMG and zip in `dist/`, notarised when signing is set up |
| `make release VERSION=x.y.z` | Publishes a release and updates the appcast (maintainers) |
| `make hooks` | Uses the repository's git hooks (pushes to `main` go through `make release`) |
| `make distclean` | Removes all build output, including MuPDF's |

## Project layout

[DEVELOPMENT.md](DEVELOPMENT.md) covers setting up a Mac (including for releases), how the code fits together, the rules that keep it safe, testing and releasing.

| Path | Contents |
| --- | --- |
| `Sources/MuPDFBridge` | C wrappers around MuPDF that turn its exceptions into error values |
| `Sources/PDFCore` | Swift types over the bridge, shared by the app and tools |
| `Sources/OpenPDFEditor` | The AppKit app: viewer, sidebar, inspector, window and menus |
| `Tests` | Engine and layout tests, golden images, and the script that generates the test PDFs |
| `Sources/pdfsmoke` | A command-line check that MuPDF opens and renders a document |
| `thirdparty/mupdf` | MuPDF, as a git submodule |
| `scripts` | MuPDF build, signing, packaging and release scripts |

## Licence

Open PDF Editor is free software, licensed under the [GNU Affero General Public License v3.0](LICENSE), the same licence as MuPDF. It includes MuPDF and its libraries, and [Sparkle](https://sparkle-project.org) for updates. Their licences are listed in the app's Acknowledgements.
