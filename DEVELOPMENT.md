# Developing Open PDF Editor

Everything needed to pick up the work on another Mac: where things stand, how the project is run, how to set up a machine (including the release secrets), how the code fits together, the rules that keep it safe, and how to test and release.

[SPEC.md](SPEC.md) is the feature list. [ROADMAP.md](ROADMAP.md) is the plan, the Decisions table (which wins over everything else) and the release notes.

## Where things stand

- **Released:** 0.3.0 (October 19, 2026): viewer, annotations, page management. Phases 0–3 in ROADMAP.md are done.
- **Next:** Phase 4, forms (0.4.0). It has not been started; wait for the go-ahead (see below).
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
- Autosave in place with Versions; printing goes through PDFKit from a saved temporary copy.

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
- `make selftest`: builds a separate copy of the app with `-DSELFTEST`. It drives the real code paths (annotating, undo, save, replies, flatten, page operations, crop through mouse events) and writes `build/selftest/log.txt`, window snapshots, and a real screen capture (`5c-screen.png`). Check the log for `FAIL` and look at the images. Layer snapshots can differ from the screen, so trust the screen capture.
- Things only checked by hand so far: Dark Mode, VoiceOver with VoiceOver running, and drag-to-select in the real UI.

## Releasing

1. Finish the phase: tick ROADMAP.md, and add a `- **x.y.z**: …` entry under Releases (it becomes the GitHub release notes and the update's description).
2. Run `make test` and `make selftest`.
3. **Security review.** A separate reviewer, acting as a security researcher, reviews the phase's changes (`git diff <previous tag>`) without modifying the repository.
   - **Threat model:** untrusted PDFs and other files opened, inserted or converted. Attacker goals: code execution, memory corruption, crashes or hangs that lose work, damage to the user's document, writing outside the chosen place, unexpected overwrites, data leaks, and silently weakened documents.
   - **Method:** build and run proof-of-concept inputs, and mark each finding CONFIRMED or PLAUSIBLE. Give each a severity, file:line and a fix.
   - **Afterwards:** fix everything above Low, re-review, and record the outcome under the phase in ROADMAP.md, with any accepted Lows.
4. Commit, then `make release VERSION=x.y.z`. It checks the tree is clean and current, sets the version, builds, signs, notarises and staples the DMG and zip, signs the zip for Sparkle, writes `appcast.xml`, commits, tags, pushes, and creates the GitHub release. Installed copies pick it up from `appcast.xml` on `main`.
5. Quit the app, `make install`, and reopen it.

## Phase 4 starting points

- The custom display list in the bridge draws page contents, then annotations except replies, then widgets: form fields already render.
- MuJS is compiled in, but form JavaScript should stay off unless agreed (it's a security surface).
- `signed.pdf` in the corpus has a signature field. Remember that forms add `/AcroForm` to the catalog, which grafting and the page operations must keep.
