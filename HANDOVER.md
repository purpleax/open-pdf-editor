# Handover

The state of the work and how it is run, for picking it up in a new session or on the other Mac. DEVELOPMENT.md has the lasting project guide; this file is the latest snapshot.

## Where things stand
- **Repository:** `/Users/guybrown/open-pdf-editor` on branch `main`.
  - Keep the clone out of iCloud-synced `~/Documents` and `~/Desktop`. SwiftPM's build database fails there with "disk I/O error".
  - GitHub: `purpleax/open-pdf-editor`.
- **Released and installed:**
  - **0.5.0** (2026-10-19, `v0.5.0`, commit `0f713f8`) is on GitHub and in the appcast.
  - /Applications now runs 0.5.0. The user upgraded from 0.4.0 with Check for Updates, which confirmed the Sparkle update path works.
- **Committed locally, not released:**
  - `b8cd77c` "Save changes automatically is a setting, off by default". It ships with 0.6.0.
  - Draft release notes are under ROADMAP.md › Releases as "**Next release** (draft)". Fold them into the 0.6.0 entry.
- **In progress: Phase 6, security and signing (0.6.0).** The user said to start it. Three read-only explorations were launched; no plan is written yet and no code is changed:
  1. MuPDF redaction (`pdf_redact_page`, `pdf_redact_options`), encryption and permissions (`pdf_write_options` `do_encrypt`, `PDF_PERM_*`), and full-rewrite saving against the bridge's incremental save.
  2. MuPDF signer and verifier callbacks (`pdf_pkcs7_signer`, `pdf_pkcs7_verifier`, `pdf_sign_signature`, digest completion at save time) against Security.framework CMS (CMSEncoder, CMSDecoder, SecTrust). Includes whether `opdf_save` (original bytes + appended `pdf_save_document`) breaks signature byte ranges.
  3. App hooks: annotation tools for a Redact tool, stamp images for handwritten signatures, password UI, signature fields, inspector and menus, Settings.

  If those results are lost, rerun them, then write the plan.
- **Phase 6 roadmap items:**
  - redaction that removes the content underneath;
  - passwords, encryption and permissions;
  - digital signatures with Keychain identities, and verification;
  - handwritten and image signatures.

  Also in 0.6.0: the autosave setting.
- **Open questions to put to the user while planning Phase 6** (suggested defaults):
  - Where saved signature images live: the Keychain (private) or Application Support.
  - Whether signature verification may use the network for revocation (OCSP/CRL). Suggested: off, or a Settings switch that is off by default, per the Risky features rule.
  - Whether redaction always writes a cleaned full copy (it must not save incrementally) and warns that signatures will be invalidated.

## How the user wants to work (agreed in this session)
- **No manual pushes or releases by the user.** Claude does every push and release, but only after the user agrees in chat. Ask with a wrap-up question and buttons.
- **Releases:**
  - `make release VERSION=x.y.z DRY_RUN=1` first, then the real release if it passes. The pre-push hook only allows `main` to be pushed as a tagged release.
  - After a release, `make install` is normal, except that the user asked for no install after 0.5.0 so they could test the upgrade. Ask each time whether to install.
- **Phase by phase:**
  - Each phase starts with a plan (plan mode, exploration, then ExitPlanMode for approval).
  - Each ends with tests, a self-test, and a separate security review as a subagent acting as a security researcher. Fix everything above Low, re-review, record Lows in ROADMAP.md, then the release after agreement.
  - Work stops after a release until the user says to start the next phase.
- **Risky features get a Settings switch, off by default** (ROADMAP.md Decisions: Risky features). Existing switches: Save changes automatically, Open web and email links, Convert other documents into PDFs.
- **No automatic update checks.** Updates only through Check for Updates….
- **Two Macs:** the user builds and releases from either.
  - Both have the Developer ID (Guy Brown, 6KNB5NZMBV), the notary profile `mdview-notary`, the Sparkle key (Keychain account `open-pdf-editor`), `scripts/signing.env` and `make hooks`.
  - Pull before working and before releasing; `release.sh` refuses when behind.
  - Unreleased work moves between Macs on a branch other than `main`.
- **Commits:** plain messages with no co-author or attribution trailers. This is a project rule in DEVELOPMENT.md and overrides tool defaults.
- **Docs:** written for people using or building the app, in British spelling. Release notes go in ROADMAP.md › Releases in plain user terms.

## What was built in this session (since 0.3.0)
- **Machine setup:** release secrets checked, the Sparkle key imported, `signing.env` written, hooks enabled. DEVELOPMENT.md has a "Working from two Macs" section.
- **0.4.0 (Forms):**
  - fill in, create and edit fields (Forms › Edit Fields), Flatten Form;
  - the Settings window, with switches for web links and document conversion;
  - no automatic update checks.
  - Security review: field-tree cycle and DAG checks, listing budgets.
- **0.5.0 (Content editing):**
  - Edit › Edit Content: text runs (font, size, colour, with embedded subset fallback fonts), images, links;
  - Pages › Add Headers & Footers, Page Numbers and Watermark, and removing them;
  - metadata editing with XMP kept in step;
  - the welcome window (New PDF or Open…) and File › New.
  - Security review: stamp font names, inline images refused on rewrite, stamp removal depth, ExtGState font names, image metadata stripped, a decoded content limit, and only this app's own stamp font names reused.
- **After 0.5.0 (unreleased):** the autosave setting.
  - **On:** autosave in place with Versions.
  - **Off (the default):** Save, Save As…, Revert to Saved, and closing asks.
  - The document now counts its own changes (`updateChangeCount`) so that closing knows of every change.

## Code map (most recent work)
- **Bridge** (`Sources/MuPDFBridge/MuPDFBridge.c`), sections:
  - Annotations; Form fields; Creating and changing form fields; Editing links;
  - Page content (`content_proc` processor: recording and rewriting);
  - Images (`opdf_image_*`); Editing text (`opdf_text_run_edit`, `embed_subset_font`); Stamps (`opdf_stamp_pages`, `opdf_stamps_remove`); Metadata (`opdf_metadata_set`, `rewrite_xmp`);
  - Pages; Conversion contexts (`opdf_convert_files` `allow_documents`, `opdf_write_blank`).
- **PDFCore:** `Forms.swift`, `Links.swift`, `PageContent.swift`, `ImageImport.swift`, `FontFile.swift`, `Stamps.swift`, plus the existing engine files.
- **App:**
  - `Forms/`, `Content/`, `Viewer/PagesView+Forms|FieldEditing|ContentEditing.swift`;
  - `Inspector/Field|Content|DocumentInfo…`;
  - `Window/DocumentWindowController+Forms|Content|Stamps.swift`;
  - `App/Settings.swift` (Settings, WebLinks, FileMenuDelegate in MainMenu.swift), `App/WelcomeWindowController.swift`.
- **Tests:**
  - `Tests/PDFCoreTests` holds 116 tests in 24 suites, including Form*, Content*, Link, Image, Text, Stamp and Metadata tests.
  - The corpus comes from `Tests/Corpus/make-corpus.js`, plus Python in `scripts/make-corpus.sh` for `contentzip.pdf`.
- **Self-test** (`make selftest`) runs five times:
  - annotations and pages;
  - forms (`OPDF_SELFTEST_FORMS`);
  - content (`OPDF_SELFTEST_CONTENT`);
  - welcome (`OPDF_SELFTEST_WELCOME`);
  - manual saving (`OPDF_SELFTEST_MANUAL`, `-AutosaveDocuments NO`).

  The other runs pass `-AutosaveDocuments YES`. Logs and snapshots go in `build/selftest/…`. Self Test windows appear on screen during runs.

## Known gotchas
- The Self Test app crashing shows a "quit unexpectedly" dialog that looks like the real app. Say so if the user mentions a crash, and check `~/Library/Logs/DiagnosticReports/OpenPDFEditor-*.ips` for `procPath` before concluding.
- Scripted self-test edits run outside real events. NSUndoManager groups only close at the end of a run-loop cycle, so don't call `endUndoGrouping` by hand; it crashes.
- `make test` regenerates the corpus. Run long commands in the background (notarisation takes minutes).
- Sending keystrokes to the app (System Events) isn't permitted; use self-test hooks instead.

## Known Lows (accepted, in ROADMAP.md under each phase)
- Incremental saves keep replaced and deleted content in earlier revisions. Phase 6 redaction should rewrite files.
- Dropdown labels and list-box selections are drawn by MuPDF imperfectly (NeedAppearances is set).
- Insert, Extract and Split don't carry form fields across.
- XMP is rebuilt from Info.
- Any file can mark its own content with this app's stamp tag.

## Phase 6 exploration notes (app side; the MuPDF searches were still running)
- **What's already in the linked MuPDF:** `libmupdf.a` has `pdf_redact_page` / `pdf_apply_redaction`, `pdf_set_annot_stamp_image`, `pdf_sign_signature(_with_appearance)`, `pdf_check_digest`, `pdf_check_certificate`, `pdf_has_permission` and `pdf_document_permissions`. It is built without OpenSSL (`scripts/build-mupdf.sh:29`), so signing and verifying need custom `pdf_pkcs7_signer` / `pdf_pkcs7_verifier` callbacks on Security.framework (`form.h:238-301`).
- **Redact tool:** `Annotation.Kind.redact` exists. Add `AnnotationTool.redact`, marking text like Highlight (`markText`) or a dragged area (`createShape`). Creating it needs no bridge change; applying needs a bridge call around `pdf_redact_page`.
- **Passwords:** `opdf_authenticate` collapses MuPDF's user/owner result to a bool, so it must be exposed to enforce permissions. Nothing enforces permissions today. Writing with new encryption needs a full (non-incremental) write: a new `opdf_save_full`. The models for writing a new file are Reduce File Size (`DocumentWindowController+Pages.swift:86-162`, `PageEditor.writeReplacing`) and Create PDF from Files.
- **Signature fields:** `.signature` fields aren't fillable, so clicking one in Select mode does nothing; that click would open "Sign…". The test corpus's `signed.pdf` is a fake signature.
- **Inspector:** the "Security" row in `DocumentInfoViewController` shows `meta("encryption")`. A Security or Signatures section, or sidebar pane, would follow the existing patterns.
- **Settings:** an "online revocation checking" switch would follow `Settings.swift`, off by default.
