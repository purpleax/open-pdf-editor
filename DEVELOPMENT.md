# Developing Open PDF Editor

The latest snapshot of where the work stands, and how the user wants it run, is in [HANDOVER.md](HANDOVER.md).

Everything needed to pick up the work on another Mac: where things stand, how the project is run, how to set up a machine (including the release secrets), how the code fits together, the rules that keep it safe, and how to test and release.

[SPEC.md](SPEC.md) is the feature list. [ROADMAP.md](ROADMAP.md) is the plan, the Decisions table (which wins over everything else) and the release notes.

## Where things stand

- **Released:** 0.3.0 (October 19, 2026): viewer, annotations, page management. Phases 0–3 in ROADMAP.md are done.
- **Released:** 0.4.0, forms.
- **Released:** 0.5.0, content editing.
- **Released:** 0.6.0, security and signing, with saving automatically as a setting.
- **Released:** 0.7.0, editing like a word processor; 0.7.1, select and type.
- **Released:** 0.8.0, OCR and export.
- **Next:** 1.0.0, the user guide (Phase 9).
- **Known Lows** (accepted, not yet fixed) are listed under each phase's "Security review" item in ROADMAP.md. They are the backlog to pick from when a phase touches the same code.
- **Version:** `Resources/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`), set only by `make release`.

## How the project is run

- **Phase by phase.** Each phase ends with a tested, notarised release. After a release, work stops until the go-ahead for the next phase.
- **Propose before building.** Anything not already in the roadmap (a new feature, a change of behaviour, a new dependency) is proposed first and built only once agreed. Keep the app focused; don't add services, accounts or network features.
- **Security review before every release.** A separate reviewer, acting as a security researcher, scans the code before publishing (see [Releasing](#releasing)). Every finding above Low is fixed, then re-reviewed, before the release goes out. Lows are fixed when cheap, or recorded in ROADMAP.md.
- **After a release:** quit the app, run `make install`, and reopen it, so /Applications always has the released build.
- **Apple Silicon only, macOS 14+.** No Intel code or slices anywhere (MuPDF, Sparkle and the app are all thinned to arm64).
- **Releases are always signed with the Developer ID** and notarised; never ad hoc.
- **Commits:** plain messages describing the change, with no co-author or attribution trailers. Pushes to `main` happen through `make release` (the pre-push hook enforces this).
- **Docs and release notes** are written for people using or building the app. Release notes are the version's entry under Releases in ROADMAP.md, in plain user terms.
- **Tick items in ROADMAP.md as they land**, noting anything changed or deferred under the item, and record new decisions in the Decisions table with the date.

## Setting up a Mac

### To build and test

1. An Apple silicon Mac with macOS 14 or later.
2. The Command Line Tools: `xcode-select --install`. Full Xcode isn't needed and isn't used; the project builds with SwiftPM (Swift 6) and Make.
3. Clone with the MuPDF submodule (but not MuPDF's own submodules, most of which aren't used):

   ```bash
   git clone --recurse-submodules=thirdparty/mupdf https://github.com/purpleax/open-pdf-editor.git
   ```

4. Build, test and run the scripted check:

   ```bash
   cd open-pdf-editor && make build && make test && make selftest
   ```

   The first `make build` fetches the MuPDF dependencies it uses (`scripts/fetch-mupdf-deps.sh`) and compiles MuPDF into `Frameworks/MuPDF.xcframework`, which takes a few minutes. `make test` builds `mutool` and generates the test PDFs in `build/corpus`.

Without `scripts/signing.env` builds are signed ad hoc, which is fine for development but can't be released.

### To release (maintainer machine only)

These secrets are not in the repository. Copy them from the current release Mac, and never commit them.

| What | Where it lives | Moving it |
| --- | --- | --- |
| Developer ID Application certificate and private key ("Developer ID Application: Guy Brown (6KNB5NZMBV)") | Login keychain | Keychain Access › export the identity as a .p12 with a password; import it on the new Mac. Check with `security find-identity -v -p codesigning`. |
| Notary credentials | Keychain profile `mdview-notary` (shared with mdview) | Recreate on the new Mac: `xcrun notarytool store-credentials mdview-notary --apple-id <Apple ID> --team-id 6KNB5NZMBV` and an app-specific password. |
| Signing settings | `scripts/signing.env` (git-ignored) | Copy `scripts/signing.env.example` and set `SIGN_ID` and `NOTARY_PROFILE` as above. |
| Sparkle EdDSA private key | Keychain item, service `https://sparkle-project.org`, account `open-pdf-editor` | On the old Mac: `"$(scripts/sparkle-tools.sh)/generate_keys" --account open-pdf-editor -x sparkle-key.txt`. On the new Mac: `"$(scripts/sparkle-tools.sh)/generate_keys" --account open-pdf-editor -f sparkle-key.txt`, then delete the file. `generate_keys --account open-pdf-editor -p` must print the public key in `Resources/Info.plist` (`SUPublicEDKey`). |
| GitHub access | `gh` | `brew install gh`, then `gh auth login` as purpleax. |

Then enable the pre-push hook with `make hooks`, and check each piece without publishing anything:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

```bash
xcrun notarytool history --keychain-profile mdview-notary
```

```bash
"$(scripts/sparkle-tools.sh)/generate_keys" --account open-pdf-editor -p
```

```bash
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Resources/Info.plist
```

```bash
gh auth status
```

The two public keys must be identical (`ogR5u+Tx9ayLBr7r0ZH4sXoCra+h7h/JpSRl0z1ePaU=`). If the Sparkle key is wrong, installed copies refuse the update, and there is no way to reach them except a manual download. A full rehearsal is `make release VERSION=x.y.z DRY_RUN=1` once the next version's release notes are in ROADMAP.md: it builds, signs, notarises and packages, then puts back the version and appcast without committing or pushing.

### Working from two Macs

Both Macs can build and release once each is set up as above, with the same Sparkle key copied rather than generated anew.

- **Keep the clone out of `~/Documents` and `~/Desktop`** when iCloud's "Desktop & Documents" syncing is on. SwiftPM's build database fails there with `disk I/O error`.
- **Pull before you start, and before releasing.** `make release` refuses to run when `origin/main` has commits you don't have.
- **Move unreleased work on a branch.** The pre-push hook only stops pushes to `main`, so `git push -u origin wip` on one Mac and `git fetch && git switch wip` (then `git pull`) on the other carries work between them. Merge it into `main` and release from either Mac, then delete the branch.

## How the code fits together

| Layer | Path | What it does |
| --- | --- | --- |
| MuPDF | `thirdparty/mupdf` (submodule, 1.28.5) | The engine. Built by `scripts/build-mupdf.sh` without Tesseract, barcodes or viewers. Never patched. |
| C bridge | `Sources/MuPDFBridge` | Every MuPDF call, wrapped in `fz_try`/`fz_catch`, returning `opdf_error`. The only code that touches MuPDF. |
| Engine | `Sources/PDFCore` | Swift over the bridge: `EngineDocument` (thread-safe), text, layout, annotations, page operations, `PDFFiles` (combine, reduce), `EngineExecutor` (worker threads with 16 MB stacks). Unit-tested. |
| App | `Sources/OpenPDFEditor` | AppKit: `EditorDocument` (NSDocument), `DocumentModel` (caches), the viewer, sidebars, inspector, menus and Sparkle. |
| Tools | `Sources/pdfsmoke` | `make smoke PDF=…` renders page 1. |

### Threads, locks and MuPDF contexts

- Each open document (`opdf_doc`) has a **base context**, used only while holding the document's own mutex (`lock_doc`/`unlock_doc`), and a pool of 8 cloned contexts that render display lists in parallel without the document lock.
- **Every MuPDF context in the process shares one set of MuPDF locks and one allocator** (`shared_locks()`, `shared_malloc`/`shared_realloc`/`shared_free`). MuPDF keeps global state (HarfBuzz's and OpenJPEG's contexts) guarded by a context's locks, and a block can be freed through a different context than the one that allocated it. Each block has a 16-byte header (magic, budget, size); a bad header aborts.
- **Conversion and reduction** (`opdf_convert_files`, `opdf_reduce_file`) run in contexts of their own with a counted budget (3 GB cap) and an `opdf_cancel` flag: once cancelled, every allocation fails, so MuPDF stops wherever it is. Every document handler (EPUB, Office, HTML…) is registered only in these contexts; document contexts register only the PDF handler.
- Swift side: `EngineExecutor.render` (tiles), `.background` (text, search, outline), `.conversion` (one thread). Edits run on the main thread. `DocumentModel`'s page geometry changes only on the main thread; other threads use `bounds(page:)`.

### Saving and undo

- MuPDF's journal is on from open; each edit is one journal operation (`WITH_PAGE_OPERATION` for one page, `WITH_DOC_OPERATION` for the whole document) and is registered with `NSUndoManager` by `EditorDocument` (each undo registers its redo).
- **Saving** writes the original file byte for byte with every change appended as one incremental update (signatures stay valid). The journal is detached during the save and the incremental-section count restored afterwards, so saving never touches undo. Saving refuses if the file changed on disk.
- `opdf_prepare_for_editing` runs at open: if MuPDF had to repair the file, it is rewritten in memory first, so a repair can't happen mid-session and lose edits. If that fails the document opens view-only.
- Saving automatically in place, with Versions, is a setting (off by default); printing goes through PDFKit from a saved temporary copy.
- **Rewriting whole** (`opdf_rebase`): security changes, Apply Redactions and signing write the document again and the open document goes on from the new bytes (`d->doc` swapped, journal restarted), so undo history is cleared. Each works on a copy first; if it fails, the open document is as it was. Later saves are incremental on top of the new bytes.
- **Signing** is the one real (non-snapshot) incremental save: `opdf_sign_field` snapshots to a temporary file, signs that copy, saves it incrementally (which is what finishes a signature) and reopens from the result. Anything added to the signature after `pdf_sign_signature` must go in the same revision (`disallow_new_increments`), or it lands outside the signed bytes. `opdf_save` refuses while a signature is unfinished.

### Rendering and caches

- `DocumentModel` caches display lists, text, links and annotations, keyed by page, with a revision per page. A value loaded while its page changed isn't cached.
- After an edit: `pagesChanged(pages)` → `pagesDidChange`. After a page operation: `structureChanged()` reloads geometry and drops everything → `structureDidChange`, and every view reloads.
- `TileRenderer` renders 512-pixel tiles at zoom levels 2^(level/4) and 320-pixel previews, with a 384 MB LRU cache. `PageView` keeps old tiles until new ones arrive; render callbacks check page, rotation and revision, so a late result never lands on the wrong page.

### Pages (0.3.0)

- Bridge: delete, reorder (`reorder_page_tree`, which gives the root `/Pages` a new `/Kids` and copies inherited attributes onto each page), insert blank, rotate, crop, insert from a PDF (grafting), extract.
- `PageEditor` runs each as one undoable step and handles panels, errors and file writing (`writeReplacing`, `writeNew`, which never overwrite unexpectedly or leave the chosen folder).

## Rules that keep it safe

These come from real bugs and review findings. Break one and something crashes or loses data.

- **Never use a document's base context without holding its lock**, including on error paths. `WITH_DOC_OPERATION` leaves the lock held so the caller can free what it made and then `unlock_doc`. `WITH_PAGE_OPERATION` unlocks itself.
- **Every `fz_new_context` must use `shared_locks()` and the shared allocator.**
- **Variables changed inside `fz_try` and used after it must be `fz_var`'d.** Swift must never be called back from inside `fz_try`.
- **Don't use `pdf_rearrange_pages`:** it rebuilds the catalog (losing forms, attachments, metadata and page labels) and recurses without limit through outlines.
- **Grafting copies page contents and resources only**, not annotations, links or form fields.
- **Untrusted input is bounded:** page sizes (`maxPageSide`, render caps), outline depth and count, annotation geometry (`OPDF_MAX_*`), pages per insert or combine. New parsers of file data need limits and a corpus test.
- **Attachments** are saved with quarantine, and risky types ask first (`AttachmentSafety`).
- **External links** open only for http, https and mailto.
- **Swift 6 concurrency:** UI classes are `@MainActor`. From `DispatchQueue.main.async`, use `MainActor.assumeIsolated`. Engine types are `@unchecked Sendable` because the bridge locks.

## Testing

- `make test`: Swift Testing in `Tests/PDFCoreTests`, against PDFs generated by `Tests/Corpus/make-corpus.js` (run with `mutool`). There are no third-party files in the corpus. Render tests compare with `Golden/*.png` (`UPDATE_GOLDEN=1 make test` rewrites them). Security regressions live in `*SecurityTests.swift`. The Makefile loads the Swift Testing macro plugin directly, because SwiftPM's plugin server is unreliable with the Command Line Tools.
- `make selftest`: builds a separate copy of the app with `-DSELFTEST`. It drives the real code paths (annotating, undo, save, replies, flatten, page operations, crop, forms, content editing, security, redaction and signing, through mouse events and sheets) and writes `build/selftest/log.txt`, window snapshots, and a real screen capture (`5c-screen.png`). Check the log for `FAIL` and look at the images. Layer snapshots can differ from the screen, so trust the screen capture.
- Things only checked by hand so far: Dark Mode, VoiceOver with VoiceOver running, and drag-to-select in the real UI.

## Releasing

1. Finish the phase: tick ROADMAP.md, and add a `- **x.y.z**: …` entry under Releases (it becomes the GitHub release notes and the update's description).
2. Run `make guide-images` (the guide's screenshots, from the self-test), look at `docs/guide/images`, and update `docs/guide/guide.html` for anything the phase changed. Then run `make test` and `make selftest`.
3. **Security review.** A separate reviewer, acting as a security researcher, reviews the phase's changes (`git diff <previous tag>`) without modifying the repository.
   - **Threat model:** untrusted PDFs and other files opened, inserted or converted. Attacker goals: code execution, memory corruption, crashes or hangs that lose work, damage to the user's document, writing outside the chosen place, unexpected overwrites, data leaks, and silently weakened documents.
   - **Method:** build and run proof-of-concept inputs, and mark each finding CONFIRMED or PLAUSIBLE. Give each a severity, file:line and a fix.
   - **Afterwards:** fix everything above Low, re-review, and record the outcome under the phase in ROADMAP.md, with any accepted Lows.
4. Commit, then `make release VERSION=x.y.z`. It checks the tree is clean and current, sets the version, builds, signs, notarises and staples the DMG and zip, signs the zip for Sparkle, writes `appcast.xml`, commits, tags, pushes, and creates the GitHub release. Installed copies pick it up from `appcast.xml` on `main`.
5. Quit the app, `make install`, and reopen it.

## User guide (1.0.0)

- **Source:** `docs/guide/guide.html` and `guide.css`, laid out by MuPDF's HTML engine, not a browser: `page-break-before` is ignored (chapters start after `<div class="page-break">`), centring images doesn't work, and images load only by relative path. Pictures are in `docs/guide/images`.
- **Build:** `make guide` runs `scripts/make-guide.js` with mutool (`scripts/build-mutool.sh`): Letter pages through a `DocumentWriter`, then bookmarks from the HTML's headings and its links added to the PDF, and the title with the version. `make build` copies it into the app as `Open PDF Editor Guide.pdf`.
- **Screenshots:** `make guide-images` runs the self-test's `guide` run (`SelfTest+Guide.swift`) on `sample.pdf` in light mode at a fixed size, with a made-up author, the settings shown off (and put back) and a test signing identity, and copies the PNGs into `docs/guide/images`. Save panels can't be captured (they are another process), so their accessory view is drawn instead.
- **App:** `AppDelegate.showGuide` copies the guide into `~/Library/Caches/<bundle id>/Guide` when the build changes and opens the copy with the outline showing.
- **Tests:** `GuideTests` (bookmarks, links, pictures, and every menu title named in the guide), and the self-test's guide run checks Help opens the copy, once.

## Forms (0.4.0)

- **Engine:** `Sources/PDFCore/Forms.swift` over the bridge's "Form fields" and "Creating and changing form fields" sections. Fields are widgets, identified by object number like annotations; `opdf_fields_load` has its own limits (`OPDF_MAX_FIELDS_PER_PAGE`, options, bytes per page). `pdf_enable_js` is never called, so no form script runs.
- **Where values live:** a field's value is on its field dictionary, which for a radio button is the group (the widget's parent). `field_holder` finds it. MuPDF's `pdf_field_value` rewrites stream values in place, so the bridge reads values itself (`field_value`).
- **App:** `FormController` (finding, filling, editing), `FieldEditor` (typing in place), `PagesView+Forms.swift` (filling with the Select tool), `PagesView+FieldEditing.swift` (Forms › Edit Fields), `FieldInspectorViewController`.
- **Not yet:** Insert, Extract, Split and Create PDF don't carry form fields across (grafting drops `/Annots`).

## OCR and export (0.8.0)

- **Scans** (`opdf_page_text_info`, `PageTextInfo`): a counting device over the page's own contents (visible characters, invisible ones, images on a 32×32 grid). A scan has under 20 visible characters, no invisible text and images over half the page. `DocumentModel.textInfo` caches it per page version for the notice.
- **Recognition** (`TextRecognizer`): the page's contents only (`displayList(contentsOnly:)`, so comments and field values aren't read) at 300 dpi, within the render limits; Vision's lines split at whitespace; a word's own box from Vision only when it's believable (inside the line, in order, not the whole line), else the line divided by characters. Each word's space reaches the next word.
- **Text layer** (`opdf_text_layers_set`, `RecognizedWord`): one journal step; per page, remove the old layer (streams marked `/OPDFOCR true`, or `/OPDFOCR BMC` blocks cut out by `rewrite_page_content` when editing merged the content, plus `OPDFOCR<n>` GlyphLessFont resources), skip words over the page's own text, then a new deflated stream at the front of `/Contents`: `3 Tr`, one `Tm` per word (`[dx dy dy -dx x y]` in page space concatenated with the inverse page transform), `Tz` fitting the letters to the box, UTF-16 hex codes, and the space drawn at its own `Tz` across the gap.
- **Export** (`opdf_export_*`, `PDFExporter`): a temp copy of the document as it is now, opened in a capped context (NO_HANDLERS, `pdf_open_document`). Pages go through `export_filter` into MuPDF's writers: for docx, invisible text becomes filled text and images are re-encoded as PNG (the docx device ignores invisible text and takes images' compressed data as they are); for docx and HTML, page-size images on pages with invisible text are dropped. TIFF is the bridge's own streaming writer (`write_tiff_page`: RGB, Deflate with predictor 2, IFD before each page's strips), since ImageIO kept every page in memory (4 GB for 150 pages at 300 dpi).
- **App:** `DocumentWindowController+Recognition.swift` (sheet, `recognize(pages:…)`, scan notice), `+Export.swift` (`ExportOptions`, `export(_:viewer:_:to:then:)`), `ProgressSheet` with a bar, `PageEditor.writeNew` for folders.
- **Tests:** `scanned.pdf` (plain, `/Rotate 90`, offset CropBox, strips over a layered image, a stamped page number, an existing text layer) and `restricted.pdf` (print only) in the corpus; `RecognitionTests`, `ExportTests` (every corpus file through every format); self-test runs `ocr` and `export`. Vision's first use in a new build takes ~25 s to load its model.

## Editing like a word processor (0.7.0)

- **Paragraphs** (`opdf_paragraphs_load`, `Paragraphs.swift`): MuPDF's stext (SEGMENT, COLLECT_STYLES; not PARAGRAPH_BREAK, which over-splits, nor PRESERVE_SPANS, which splits lines at font changes), lines split at gaps over 3 em, blocks that don't stack demoted to one paragraph per line, blocks split at wider spacing or an indented line after a short one, and paragraphs that carry on from one another merged (rewritten lines land at the end of the content, so this isn't just adjacent blocks). Each character is matched by origin to a glyph in `content_proc`'s glyph log, so it is known as (text operation, glyph index). Hard breaks: the next line's first word would have fitted.
- **Writing** (`opdf_paragraph_replace`): dropped glyphs become TJ moves of their width inside `content_proc` (`array_without_drops`; its glyph counting must stay in step with `show_string`); runs are appended under `q <inverse page_ctm> cm` with `Tm [1 0 0 -1 x y]`, TJ adjustments placing each glyph where TextKit put it, in a page font by its codes or an embedded subset (`embed_subset_gids`, which refuses CID-keyed CFF and outline-less fonts).
- **The editor** (`ParagraphEditor`): TextKit 1 in page points over the paragraph (the pages view is in page points; rotated views can't edit); `.pdfFont`/`.pdfFill` mark characters still in a page font and fill, kept up to date in the storage delegate (kerning to the PDF widths; removed when the family, bold/italic or colour changes, by whatever means). Commit keeps original lines before the first change when TextKit breaks them alike.
- **App:** `ContentController.editor/newTextBox/commit`, `TextFormatBarViewController` (in the content bar), the Format menu, `PagesView+ContentEditing` (Edit tool's hit order, Add Text), `PagesView.menu(for:)` (Edit Text).
- **Tests:** `paragraphs.pdf` in the corpus; `ParagraphTests`, `ParagraphEditingTests`; the self-test content run (with a real screen capture, `content-2-screen.png`).

## Security and signing (0.6.0)

- **Permissions:** `opdf_allowed` (everything for the owner or an unencrypted file) feeds `DocumentModel.allowed`; edits name what they need (`model.edit(needs:)`), and menus, tools and inspectors check `allows(_:)`. `opdf_permission_bits` reads /P from /Encrypt itself, because MuPDF reports every permission to the owner. Whether opening needs a password is recorded at open (`opdf_needs_open_password`): trying the empty password later would replace the key.
- **Redaction:** `redact_document` runs inside the rebase on the copy. Marked areas and annotation rectangles are compared in page space (`pdf_annot_rect`), not raw /Rect.
- **CMS:** `CMS.c` and `cms.h` use Security.framework only (no MuPDF headers there). CMSEncoder writes BER with indefinite lengths, so `cms_der_length` parses BER. Verification checks that the gap in the signed ranges decodes to exactly this signature's /Contents. MuPDF is built with `HAVE_LIBCRYPTO=no`.
- **Saved signatures:** `SavedSignatures` (generic-password items in the login keychain; the file-based keychain returns data one item at a time). The self-test swaps in `MemorySignatureStore` and must never touch the keychain.
- **Tests:** `signer.p12` in the corpus is a self-signed identity made with the system's LibreSSL, imported in memory (`kSecImportToMemoryOnly`, macOS 15+). The self-test runs `security`, `redact` and `sign` cover the sheets and tools.

## Content editing (0.5.0)

- **The content processor** (bridge section "Page content"): one `pdf_processor` that tracks the graphics and text state and numbers text operations and image drawings. Recording, it lists them (`opdf_page_content_load`); rewriting, it is chained to MuPDF's buffer processor and passes everything through except the target, which an `emit_text`/`emit_image` hook draws instead (`rewrite_page_content` replaces /Contents with one new deflated stream). Limits: `OPDF_MAX_CONTENT_*`.
- **Text:** `opdf_text_run_edit`: a recording pass finds the run and its font (`run_probe`), `plan_text` encodes each character in that font (`encode_in_font`, checking the glyph really exists) and `embed_subset_font` embeds a fallback (Swift's `FontFile` picks it with CoreText and rebuilds it as a one-face sfnt from its tables).
- **Images:** `opdf_image_*`; `ImageImport` reads files with ImageIO first.
- **Stamps:** `opdf_stamp_pages` appends a q-balanced stream per page; `opdf_stamps_remove` drops `/OPDFStamp` marked content.
- **App:** `ContentController`, `PagesView+ContentEditing.swift`, `TextRunEditor`, `ContentInspectorViewController`, `DocumentWindowController+Content.swift` and `+Stamps.swift`.
