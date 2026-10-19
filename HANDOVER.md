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
- **In progress: Phase 6, security and signing (0.6.0).** The plan is approved (below). Done and committed locally:
  1. Rebase (`opdf_rebase`, `EngineDocument.rebase`).
  2. Passwords, encryption and permissions: File › Security…, the restriction notice, `DocumentModel.allowed` / `edit(needs:)`, `opdf_allowed`, `opdf_permission_bits` (read from /Encrypt: MuPDF reports every permission to the owner), `opdf_needs_open_password` (recorded at open, since trying "" later would clobber the crypt key). Self-test run `security`.

  3. Redaction: `redact_document` in the bridge (run on the rebase copy, so a failure leaves the open document as it was), `opdf_rebase_options.redact`, `EngineDocument.applyRedactions`, the Redact tool, Tools › Apply Redactions…, self-test run `redact`. Marked areas and annotation rects are compared in page space (`pdf_annot_rect`), not the raw /Rect.

  4. Digital signatures: `CMS.c`/`cms.h` (Security.framework only: CMSEncoder/CMSDecoder/SecTrust; BER lengths, as CMSEncoder writes indefinite ones), `opdf_sign_field` (snapshot to a temp copy, sign, `disallow_new_increments` while adding /Reason and /Location so they stay in the signing revision, real incremental save, reopen from the bytes), `opdf_signatures` (checks the byte-range gap is this signature's /Contents), `Signatures.swift` in PDFCore, the Sign… sheet, the inspector's Signatures section, Settings › Check certificates online, `HAVE_LIBCRYPTO=no`, `signer.p12` in the corpus (imported in memory: macOS 15+), self-test run `sign`. Verified independently with `openssl smime -verify`.

  5. Handwritten and image signatures: `opdf_annot_create_image_stamp`, a picture in `opdf_sign_field`, `SavedSignatures.swift` (keychain store: attributes listed, then each item's data read on its own, as the file-based keychain requires; a memory store the self-test always uses; `SignaturePad`; `SignatureManager`), the Signature tool and markup-bar popup. The keychain store itself has no automated test (the self-test must not touch the user's keychain): check it by hand.

  6. Finish: docs (ROADMAP 0.6.0 notes, README, DEVELOPMENT), security review and re-review, all fixes in (see ROADMAP Phase 6). 135 tests and every self-test run pass.

  Next: release 0.6.0 once the user agrees (dry run first), then ask about installing.

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
- The self-test prints "data race detected: @MainActor function at EditorDocument.swift:12": NSDocumentController makes documents off the main thread when reading concurrently, and the SDK marks `NSDocument.init()` main-actor, so it can't be declared nonisolated. Present since before Phase 6; harmless (a warning).

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

## Phase 6 exploration notes (MuPDF redaction, encryption, saving)
- **Redaction:** `pdf_redact_page` / `pdf_apply_redaction`, as a journaled operation that deletes the Redact annotations.
  - Set every `pdf_redact_options` field explicitly: a zeroed struct is not the same as NULL. Use black boxes on, text REMOVE, image PIXELS (or REMOVE), and line art REMOVE_IF_TOUCHED.
  - MuPDF deletes only Links and FreeText under the area. Widgets (and their /V values), Ink, Square, Stamp, markup, notes and attachments must be cleared by the bridge.
  - The structure tree beyond /ActualText and /Alt of removed glyphs is untouched.
  - `doc->redacted` is never cleared, even by undo. After it is set, `pdf_can_be_saved_incrementally` is 0, so the current `opdf_save` refuses ("This document can't be saved.").
  - Removing content needs a full save with `do_garbage >= 1` (3 is best). /Info, XMP, document JavaScript, /Thumb, EmbeddedFiles, /PieceInfo, the outline, OCGs and widget values survive unless scrubbed by the bridge.
  - macOS Versions (with autosave on) keeps older, unredacted copies.
- **A full rewrite mutates the open document** (garbage collection drops the page tree and renumbers objects). Two designs:
  - (a) rewrite a copy at save time (write the snapshot to a buffer, open it in a separate context as `opdf_reduce_file` does, scrub, save whole); this keeps undo.
  - (b) rebase at apply time, like `opdf_prepare_for_editing` (write whole, reopen, re-authenticate, swap `d->doc`), clearing undo ("can't be undone").
  - Either way, a full rewrite invalidates signatures: warn, reusing the `flattenForm` signed warning.
- **Encryption:**
  - `pdf_write_options.do_encrypt` (KEEP 0, NONE, RC4_40, RC4_128, AES_128, AES_256), `permissions`, `opwd_utf8`/`upwd_utf8` (char[128], so at most 127 bytes). Use AES-256 (R6, UTF-8 passwords).
  - An incremental save requires KEEP, so adding, changing or removing a password needs a full write.
  - Permission bits are `PDF_PERM_PRINT 1<<2 … PRINT_HQ 1<<11`.
- **Permissions:** `pdf_has_permission` / `fz_has_permission` (FZ_PERMISSION_PRINT 'p', COPY 'c', EDIT 'e', ANNOTATE 'n', FORM 'f', ACCESSIBILITY 'y', ASSEMBLE 'a', PRINT_HQ 'h') return true when unencrypted or owner-unlocked.
  - `pdf_authenticate_password` returns 0 (wrong), 2 (user), 4 (owner) or 6 (both); `opdf_authenticate` collapses it to a bool.
  - `pdf_needs_password` re-runs with "" and resets access.
  - **The app enforces no permissions today.** Changing or removing security must require owner access.

## Phase 6 exploration notes (signing and verification)
- **Signer and verifier structs:**
  - `pdf_pkcs7_signer` (`form.h:214-236`): keep, drop, get_signing_name (fz-allocated DN), max_digest_size (must return the same value twice; estimate it rather than trial-sign, to avoid two Keychain prompts), create_digest(fz_stream of the ByteRange spans → DER detached CMS; returns its length).
  - SubFilter is `adbe.pkcs7.detached`.
- **`pdf_sign_signature(ctx, widget, signer, flags, graphic fz_image, reason, location)`** only queues the signature. It is finished at save time, and only by a real (non-snapshot) incremental save to a file (`complete_signatures`, `pdf-write.c:1730`). The bridge's `opdf_save` uses `do_snapshot=1`, which never signs.
  - Needed: a dedicated sign-and-save call. Copy the original bytes, then `pdf_save_document(path, do_incremental=1, do_snapshot=0)` with the journal detached, then reopen from the saved file (as in `prepare_for_editing`); undo resets.
  - `opdf_save` must refuse while `pdf_has_unsaved_sigs` is true.
  - Undo doesn't remove a queued signature (only `pdf_clear_signature`).
  - Encrypted PDFs with signatures: untested and risky; test them.
- **Verification:**
  - `pdf_pkcs7_verifier`: check_certificate (DER only), check_digest (spans + DER), get_signatory. `/Contents` includes zero padding; trim it to the DER length.
  - Verification reads the file on disk, so reopen after signing.
  - `pdf_validate_signature` returns -1 (unsaved changes break the lock), 0 (valid), or n (invalidated n saves ago).
  - Errors (`form.h:201-212`) have no expired or revoked codes; keep richer results in the bridge's verifier.
- **Security.framework:**
  - Signing: CMSEncoder (AddSigners with SecIdentity, detached content, SHA-256 via CMSEncoderSetSignerAlgorithm, signing time, chain mode, UpdateContent streaming).
  - Verifying: CMSDecoder (detached content as CFData), CMSDecoderCopySignerStatus, then SecTrust (`SecTrustEvaluateWithError`; `SecTrustSetNetworkFetchAllowed` false unless the user turns it on).
  - Identities: `SecItemCopyMatching` with kSecClassIdentity.
  - PAdES (ETSI.CAdES.detached) would need a hand-built SignerInfo (signingCertificateV2); start with adbe.pkcs7.detached.
  - Keep the callbacks in C (they run inside MuPDF's fz_try), link Security.framework in the MuPDFBridge target, and add `HAVE_LIBCRYPTO=no` to `scripts/build-mupdf.sh`.
- **Test fixtures:** `signed.pdf` is fake. Verification needs a really signed fixture (a self-signed P12 made in a test, and signed with the new code).


## Phase 6 plan (approved 2026-10-19)

The user's choices: saved signatures in the Keychain; Apply Redactions rewrites now with no undo; offer to delete earlier Versions (checked by default). Work through the steps in order, one local commit each.


| Decision | Choice |
| --- | --- |
| Full rewrite ("rebase") | Redaction and security changes write the whole document again (garbage collection, scrubbed), reopen it from the new bytes, and continue from there. Undo history is cleared; the alert says so first. Later saves are incremental on top of the clean bytes. |
| Redaction | Mark with Tools › Redact (text like Highlight, or a dragged area); Tools › Apply Redactions… removes text, images (pixels), line art, annotations, links and field values under the marks. It draws black boxes, scrubs hidden leftovers (thumbnails, PieceInfo, document JavaScript, XMP rebuilt), saves, and optionally deletes earlier Versions. Signatures are invalidated, with a warning. |
| Encryption | File › Security… sets, changes or removes passwords and permissions, using AES-256 only. It needs owner access: you are asked for the owner password if the file was opened with the user password. |
| Permissions | Enforced when a file was opened without owner access. Print, copy text, edit (content, pages, forms creation), annotate and fill in are each disabled per its bit, and the window says why. |
| Digital signatures | CMS detached signatures (adbe.pkcs7.detached, SHA-256) made by CMSEncoder from a Keychain identity. Signing is a real incremental save to the file, then a reopen. Verification uses CMSDecoder and SecTrust against the system trust store. |
| Online certificate checks | A Settings switch, off by default (Risky features): revocation and missing intermediates fetched over the network. |
| Saved signatures | Drawn or imported images stored as items in your login Keychain, placed as stamp annotations with that image, and usable as the picture in a digital signature. |

### Steps (one local commit each)

### 1. Rebase: writing the document whole
- **Bridge:** `opdf_rebase(doc, const opdf_rebase_options *, err)`.
  - Writes with `do_garbage=3`, compression, and encryption settings (KEEP, NONE or AES_256 with passwords and permission bits) into a buffer.
  - Reopens from the buffer, authenticates with the new password, re-enables the journal, and swaps `d->doc` (the pattern of `opdf_prepare_for_editing`).
  - A scrub option removes `/Thumb`, `/PieceInfo`, document JavaScript (Names/JavaScript, an OpenAction JavaScript action, catalog `/AA`), and rebuilds XMP from Info (`rewrite_xmp`).
- **PDFCore:** `EngineDocument.rebase(...)`.
- **App:** `EditorDocument` calls `undoManager.removeAllActions()`, updates the model (`structureChanged`), and marks the document edited.
- **Tests:** a rebased document keeps its pages, text, annotations and forms; old objects are gone from the bytes; a signed document is detected.

### 2. Passwords, encryption, permissions
- **Bridge:** `opdf_access(doc)` (none, user or owner, from `pdf_authenticate_password`'s bits), `opdf_permissions(doc)`, and an owner re-authentication call.
- **App: File › Security…** sheet:
  - user and owner passwords, permission checkboxes (print, copy, edit, annotate, fill in forms, assemble pages), and Remove Security;
  - a signed-document warning;
  - applied with `rebase`.
- **Enforcement:** `DocumentModel` gains `permissions`. Each command checks the matching bit (print, copy, edit modes, page commands, markup tools, form filling), plus a banner in the window.
- **Tests:**
  - set a password, save and reopen (it asks for the password);
  - change it, then remove it;
  - user versus owner access;
  - permission bits are written and read back;
  - non-Latin passwords (R6).

### 3. Redaction
- **App:**
  - `AnnotationTool.redact`: text marking reuses `markText`; areas reuse `createShape`.
  - **Tools › Apply Redactions…** alert, with an "Also delete earlier versions of this file" checkbox, checked by default.
  - The signature warning.
- **Bridge:** `opdf_apply_redactions(doc, err)`.
  1. For every page: `pdf_redact_page` with every option set (black boxes; text REMOVE; images PIXELS; line art REMOVE_IF_TOUCHED).
  2. Delete annotations under the marks (any kind except the Redact marks, which MuPDF removes), and clear widget values (or delete those widgets).
  3. Then `opdf_rebase` with scrub.
- **App, afterwards:** save at once (untitled documents ask where). If chosen, `NSFileVersion.removeOtherVersionsOfItem`.
- **Tests:**
  - the text is gone from the extracted text and from the file's bytes;
  - image pixels are blanked; annotations and field values are gone;
  - thumbnails, PieceInfo and JavaScript are scrubbed;
  - text outside the marks is kept.

### 4. Digital signatures
- **Bridge (C, Security.framework linked to MuPDFBridge):**
  - **Signer** (`pdf_pkcs7_signer`): wraps a SecIdentity. Its size estimate is the certificate chain plus 8 KB. `create_digest` streams the ranges into CMSEncoder (detached, SHA-256, signing time, chain without root).
  - **Verifier** (`pdf_pkcs7_verifier`): CMSDecoder with the ranges as detached content; the `/Contents` padding is trimmed. Trust is a SecTrust with network fetch only if the setting allows it. The bridge keeps richer results (expired, untrusted, self-signed).
  - `opdf_sign_field(doc, page, id, identity, image, reason, location, path, err)`:
    1. `pdf_sign_signature`;
    2. copy the original bytes, then `pdf_save_document(path, incremental, no snapshot)`;
    3. reopen.
  - `opdf_save` refuses while signatures are unsaved.
  - `opdf_signatures(doc)` lists each signature with signer, time, status (`pdf_validate_signature` and verifier) and whether it was changed after signing.
  - `scripts/build-mupdf.sh`: `HAVE_LIBCRYPTO=no`.
- **App:**
  - Clicking an unsigned signature field (Select tool) opens **Sign…**: a Keychain identity popup, an optional saved signature picture, reason and location. It saves first if needed.
  - A **Signatures** section in the inspector shows each signature's status in plain words.
  - **Settings:** "Check certificates online", off by default.
- **Tests:**
  - a test identity: a P12 generated at corpus time with `/usr/bin/openssl`, imported in memory (`SecPKCS12Import`; if that needs a keychain, a temporary keychain in the test);
  - sign, reopen and verify as valid;
  - edit, save, and report "changed after signing";
  - tamper with the bytes and report invalid;
  - a self-signed certificate reports not trusted;
  - an encrypted document signs and verifies, or signing is refused with a message.

### 5. Handwritten and image signatures
- **App:**
  - **Tools › Signatures…**: draw (a pen pad) or import (`ImageImport`) a signature, and name, delete or choose one. Stored as Keychain items (generic password data, PNG, labelled), read only by this app.
  - A **Signature** tool places the chosen one as a stamp annotation with its image, moved and resized like stamps.
- **Bridge:** `opdf_annot_set_stamp_image(doc, page, id, png, len)` (`pdf_set_annot_stamp_image`).
- **Tests:** a stamp image round-trips through save and reopen, and draws.

### 6. Finish
- Extend the self-test:
  - Security… sets a password and permissions, and the document reopens;
  - apply a redaction, and the text is gone;
  - place a signature stamp;
  - sign with the test identity, and the inspector shows the status.
- Docs:
  - ROADMAP: ticks, decisions, and 0.6.0 release notes, folding in the autosave draft.
  - SPEC, README, DEVELOPMENT (the new save rules: rebase, and signing as a real save), HANDOVER.
- A security review (subagent, proof-of-concept inputs: hostile CMS blobs, ByteRanges, encryption dictionaries, redaction leftovers). Fix everything above Low, then re-review.
- Release after your go-ahead: dry run, then the real release. Ask about installing.

### Left for later
- PAdES (ETSI.CAdES.detached) and timestamps.
- Certificate-based (public-key) encryption.
- Redaction inside patterns and soft masks (MuPDF doesn't recurse there).
- Signing with smart cards may prompt during save (it works through the Keychain).

### Verification
- `make test`: new suites for rebase, security, permissions, redaction, signatures, stamp images, and all 116 existing tests.
- `make selftest`, with the new run's log and snapshots.
- By hand: a password-protected save opens in Preview with the password; a redacted file has no recoverable text (`strings` and `mutool show`); a signature made here is reported by `mutool sign -v` and shown in Preview.
