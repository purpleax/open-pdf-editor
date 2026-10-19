# Open PDF Editor Roadmap

Started Oct 18, 2026. [DEVELOPMENT.md](DEVELOPMENT.md) has the current state, machine setup and release process. Work goes phase by phase. Each phase from 1 onwards ends with a tested, notarised GitHub release (`make release`). After each phase, work stops until the go-ahead for the next. Tick items as they land, and note anything deferred or changed under the item.

## Decisions

| Decision | Choice | Date |
| --- | --- | --- |
| Name | Open PDF Editor; bundle identifier `com.purpleax.openpdfeditor`; repository `purpleax/open-pdf-editor` | 2026-10-18 |
| Licence | AGPL-3.0, matching MuPDF. The repository is public from the first commit, so every build has its source. The Mac App Store is ruled out. | 2026-10-18 |
| Engine | MuPDF 1.28.5 as a git submodule, built by `scripts/build-mupdf.sh` into an arm64 static library in a hand-made `Frameworks/MuPDF.xcframework` (no full Xcode needed). Tesseract, Leptonica, barcodes and the GLUT/X11 viewers are left out; MuJS, extract and the HTML engine stay in. | 2026-10-18 |
| Calling MuPDF from Swift | A small C target (`MuPDFBridge`) wraps every MuPDF call in `fz_try`/`fz_catch` and returns errors as values, because MuPDF's exceptions are `setjmp`/`longjmp` and Swift can't unwind through them | 2026-10-18 |
| App | Swift and AppKit, built with SwiftPM and a Makefile like mdview: `NSDocument` per PDF, native window tabs, `NSToolbar`, split view with sidebars and an inspector | 2026-10-18 |
| Platforms | macOS 14 or later, Apple Silicon (arm64) only. Intel Macs are not supported. | 2026-10-18 |
| Updates | Sparkle 2.10.0 (SwiftPM), EdDSA-signed updates. The appcast is `appcast.xml` on `main` of this repository, written by `make release`. Only when asked (Open PDF Editor › Check for Updates…): no automatic checks or installs (changed 2026-10-19). | 2026-10-18 |
| Releases | GitHub Releases on this repository: a DMG and a zip per version, signed with the Developer ID, notarised and stapled (scripts adapted from mdview) | 2026-10-18 |
| OCR | Apple's Vision framework on device; MuPDF writes the invisible text layer. Not MuPDF's Tesseract build. | 2026-10-18 |
| Text editing | Within a line only: insert, replace and delete characters in one text run, change its font, size and colour, using the embedded font's glyphs or a fallback font. No reflow across lines. | 2026-10-18 |
| Digital signatures | MuPDF's signer callbacks backed by Security.framework (CMS) and Keychain identities; verification against the system trust store. No bundled OpenSSL. | 2026-10-18 |
| Printing | The saved PDF handed to PDFKit's print operation, for the native print panel | 2026-10-18 |
| Undo | MuPDF's document journal, bridged to `NSUndoManager` | 2026-10-18 |
| Security review | Before every release, a separate review acting as a security researcher scans the code (the C bridge, PDF parsing, links, attachments, the update path and release scripts). Findings above Low are fixed before publishing. | 2026-10-18 |
| Saving | Every save writes the original file byte for byte with all changes since opening appended as one incremental update (keeps signatures valid). The open document is never itself saved: MuPDF writes a snapshot and the bridge restores its incremental-section count, so saves don't disturb the undo journal and each save is complete on its own. Repaired files are written whole. Redaction and Reduce File Size will force a full rewrite. | 2026-10-19 |
| Autosave | A Settings switch, Save changes automatically, off by default (changed 2026-10-19 from always on). On: autosave in place with Versions, as in Preview (File › Revert To, Duplicate, Rename, Move To). Off: File › Save and Save As…, Revert to Saved, and closing a changed document asks. Undo survives saving either way. | 2026-10-19 |
| Annotation replies and status | Replies are Text annotations with /IRT, and review status a hidden reply with /State and /StateModel Review, as Acrobat writes them. They are not drawn on the page; they appear in the Comments list. | 2026-10-19 |
| Markup tools | A markup bar under the toolbar (View › Show Markup Toolbar, ⇧⌘A) with the tools, colour and line width, as in Preview; the inspector edits the selected annotation | 2026-10-19 |
| Risky features | Any feature that adds a security risk (for example form JavaScript) gets a switch in a Settings window (⌘,) and is off until turned on. The phase that adds the first such feature adds the Settings window. Each one is named in its roadmap item, with what it exposes. Features already in the app that get a switch: opening web and email links, and converting non-PDF, non-image documents in Create PDF from Files. Saving attachments has none (it already warns and quarantines). | 2026-10-19 |
| Welcome window | With no documents open (at launch, or reopened from the Dock), a welcome window shows the app's icon and name, with New PDF and Open… under them, instead of going straight to the Open panel. File › New (⌘N) makes an untitled PDF of one blank page (Letter in the US and Canada, A4 elsewhere). | 2026-10-19 |
| Edit Content | Edit › Edit Content (⌥⌘E), a mode with its own bar (Select, Text, Image, Link), exclusive with Edit Fields, cropping and the markup tools. A bridge content processor lists and rewrites the page's own content stream: text operations and image drawings are identified by their order on the page. | 2026-10-19 |
| Editing text | One text operation is one run. New characters use the run's font when its glyphs are there; otherwise the whole run is drawn in a matching system font, embedded as a Type0 Identity-H font subset to the glyphs used, with its own ToUnicode. Colour changes only where the fill is grey, RGB or CMYK. Text inside Form XObjects, Type3, vertical and invisible text isn't edited. | 2026-10-19 |
| Images from files | Read with ImageIO (MuPDF's decoders never see the file), turned upright, handed over as JPEG (unchanged when it needs no turning) or PNG; at most 100 MB and 40 megapixels. | 2026-10-19 |
| Stamps | Headers, footers, page numbers and watermarks are drawn after the page's content as /Artifact marked content with an /OPDFStamp tag, so this app removes exactly what it added. | 2026-10-19 |
| Metadata | Title, Author, Subject and Keywords edited in the inspector; ModDate set; XMP rewritten to match when present, keeping PDF/A identification. | 2026-10-19 |
| Form JavaScript | Off, with no switch: values are set as typed, and calculated fields don't recalculate. Revisit only if asked. | 2026-10-19 |
| Filling and editing forms | Filling is always on: with the Select tool, click a field to fill it in. Editing fields is a mode (Forms › Edit Fields, ⌥⌘F) with its own bar of field tools; fields are selected, moved, resized and deleted like annotations and set up in the inspector. | 2026-10-19 |
| XFA | Not supported. Filling in a hybrid AcroForm/XFA form removes /XFA, so other apps show the values typed here. | 2026-10-19 |
| Flatten Form | `pdf_bake_document` for widgets only, as one undoable step, saved incrementally like every change. | 2026-10-19 |
| Signature fields | Made empty in 0.4.0; signing them is Phase 6. | 2026-10-19 |
| Full rewrite ("rebase") | Redaction and security changes write the whole document again (garbage collected; scrubbed for redaction), reopen it from the new bytes and carry on from there. Undo history is cleared, and the alert says so first. Later saves are incremental on top of the clean bytes. | 2026-10-19 |
| Redaction | Tools › Redact marks text (drag across it) or an area (drag anywhere else). Tools › Apply Redactions… removes, for good, whatever is under the marks: text (any character touching a mark), image pixels, line art touching a mark, links, annotations with their replies, and form fields with their values. It draws black boxes, scrubs hidden leftovers (thumbnails, PieceInfo, document JavaScript; XMP rebuilt), writes the document whole and saves it, and offers to delete the file's earlier versions (checked). Flatten Annotations refuses while marks remain. | 2026-10-19 |
| Online certificate checks | A Settings switch, Check certificates online, off by default (Risky features): fetching missing intermediate certificates and checking revocation tells the certificates' servers that a signed document is being opened. Off, signatures are checked against this Mac's trust store only. | 2026-10-19 |
| Signing | Clicking an empty signature field opens Sign…: a Keychain identity, reason and location. The document with its unsaved changes is signed on a copy (a real incremental save, the only kind that finishes a signature), the open document goes on from the signed bytes, and it is saved at once. Signatures are checked when the file's bytes change, not on every edit; a gap in the signed ranges must hold exactly that signature's /Contents. | 2026-10-19 |
| Encryption | File › Security… sets, changes or removes the passwords and permissions, with AES-256 only. It needs owner access: a file opened with the user password asks for the owner password first. | 2026-10-19 |
| Permissions | Enforced when a file is opened without owner access. Printing, copying text, editing (content, fields, metadata), comments, filling in forms and page changes are each disabled per the owner's settings, and a notice under the toolbar says what isn't allowed, with Enter Owner Password…. | 2026-10-19 |

## Phase 0: Foundations

- [x] Repository, AGPL-3.0 licence, spec and roadmap
- [x] MuPDF submodule pinned to 1.28.5, with only the libraries the build uses checked out
- [x] MuPDF xcframework (arm64) built by `scripts/build-mupdf.sh`
- [x] Swift package: the C bridge, the app, and a command-line smoke test that renders a page
- [x] Sparkle linked, with Check for Updates… in the app menu and an EdDSA key in the Keychain
- [x] Signing, packaging (DMG and zip, notarised) and release scripts adapted from mdview, plus the appcast
- [x] Public repository on GitHub, pushed
- [x] App icon (`make icon`)

## Phase 1: Viewer (0.1.0)

- [x] Tiled page view rendering at the screen's scale, with a page cache and low-resolution placeholders
  - Pages are layers: a 320-pixel preview of the whole page under 512-pixel tiles for the current zoom; tiles of the previous zoom stay until the new ones arrive. Zoom is the scroll view's magnification.
- [x] Continuous, single-page and two-page layouts; fit to width, fit to page, actual size; zoom with pinch and ⌘+/⌘−
  - Two-page layouts can show the cover page on its own (on by default). Fit Page in two-page layouts fits a full spread.
- [x] Rotate view
- [x] Thumbnails sidebar and outline sidebar
- [x] Find with highlighted results and a results list
  - Match Case and Whole Words; accents are ignored; matches across line breaks are found.
- [x] Text selection and copy
  - Drag, double-click for a word, triple-click for a paragraph, Shift-click to extend, across pages.
- [x] Password-protected PDFs
- [x] Document properties, attachments and layers panels
  - Properties are in the inspector (⌥⌘I); attachments and layers are sidebar tabs. Attachments can be saved, not opened.
- [x] Print
- [x] Window tabs, toolbar, full screen, Dark Mode
  - Dark Mode uses the system's colours (pages stay white); not yet checked by eye.
- [x] VoiceOver reads page text
  - Every page is a text element with its lines and character positions, including pages off screen; not yet tried with VoiceOver itself.
- [x] About window with the open-source licences (Help › Acknowledgements)
- [x] Test corpus and render tests (`make test`)
- [x] Added: links (pages in the document, and web and mail links), Back and Forward (⌘[ ⌘]), Go to Page (⌥⌘G), and windows reopening at the same page and zoom

## 0.1.1: Security fixes

From the first release-time security review (all findings above Low fixed, plus the cheap Low ones):

- [x] Page sizes capped at 200,000 points and every render at 16,384 pixels a side and 64 megapixels, so absurd pages can't crash the app or exhaust memory (Medium)
- [x] Saved attachments are quarantined (and the app sets LSFileQuarantineEnabled), with a warning before saving apps, scripts, installers, disk images and archives, and cleaned file names (Medium)
- [x] Document work runs on threads with 16 MB stacks instead of GCD's 512 KB, and outlines deeper than 256 levels are refused before MuPDF walks them (Medium)
- [x] Only MuPDF's PDF handler is registered, so a file named .pdf can't open in its HTML or other engines (Low)
- [x] Layer changes clear cached text and the selection, and selections are clamped to the page's text (Low)
- [x] Ad hoc signing works with macOS's bash 3.2 (build fix)
- [x] Found on the second pass: document dates with impossible time zones crashed the inspector; dates are now range-checked (Medium). Saving an attachment over an existing file goes through a temporary file, so a failed save leaves the old file in place (Low)
- Left for later (Low): printing re-reads the file with PDFKit; some engine calls run on the main thread; external links open on one click without showing the address; Sparkle feed signing.

## Phase 2: Annotations (0.2.0)

- [x] Highlight, underline, strikethrough
  - Drag across text with the tool, or pick the tool (Tools menu) with text already selected.
- [x] Sticky notes and text boxes
  - A popover edits the comment or the box's text when it is placed, and on double-click.
- [x] Shapes, lines and arrows, freehand drawing
- [x] Stamps (MuPDF's standard stamps: Approved, Draft, Confidential and the rest)
- [x] Annotation list with replies, status and filters (sidebar Comments tab, ⌥⌘4)
  - Filters by type, author and review status; reply, set Accepted / Rejected / Cancelled / Completed, or delete from the buttons or the context menu.
- [x] Undo and redo through MuPDF's journal; incremental save
  - Autosave in place with Versions; undo survives saving (see Decisions).
- [x] Flatten annotations (Tools › Flatten Annotations…, undoable)
- [x] Security review before release: one High (a damaged file repaired mid-session could lose edits) and two Medium (saves upsetting undo; geometry amplification) fixed, with the cheap Lows; see the commit "Fix 0.2.0 review findings"
  - Left for later (Low): preparing a large PDF for editing runs at open on the main thread (about 1.6 s for a million objects); deleting a reply chain of tens of thousands is slow; a same-length in-place rewrite of the open file isn't detected
- [x] Added: select, move and resize annotations (handles; line end points); the inspector edits colour, fill, opacity, line width, text size and comment; markup bar (⇧⌘A) with per-tool colour, width, text size and stamp; Delete key; `make selftest`, a scripted run through annotating in a separate test build

## Phase 3: Pages (0.3.0)

- [x] Insert, delete, reorder (drag in thumbnails), rotate, crop and extract pages
  - Pages menu, the thumbnails' context menu, and Delete in the thumbnails; commands apply to the pages selected in the thumbnails, or else the current page. ⌘L / ⌘R now turn pages (saved in the PDF); turning the view moved to ⌥⌘L / ⌥⌘R. Crop (⌃⌘K): drag an area, then crop that page, the selected pages or all pages.
- [x] Merge PDFs and split a PDF
  - Merge: Pages › Insert Pages from File…, or drop files between thumbnails. Split: every N pages, or at each top-level bookmark, into a folder.
- [x] Create a PDF from images and from other documents MuPDF reads
  - File › Create PDF from Files… (⌥⌘N): PDFs, images, EPUB, XPS, CBZ, SVG, HTML, text and Word, Excel and PowerPoint files, combined in name order. Other formats are only opened in that conversion, never as documents.
- [x] Reduce file size (File › Reduce File Size…: a smaller copy, images at 200, 150 or 100 dpi)
- [x] Every page change is one undoable step and saves incrementally, like annotations
- [x] Security review before release: four Medium fixed (cleanup on the shared MuPDF context outside the document lock during Insert Pages; moving pages through `pdf_rearrange_pages`, which rebuilt the catalog and dropped forms, attachments and metadata, and recursed without limit through a deep outline; conversion with no memory cap and no way to cancel), with the cheap Lows; see the commit "Fix 0.3.0 review findings". The re-review found one more Medium, older than 0.3.0: MuPDF's global HarfBuzz state was shared by contexts with separate locks (two documents drawing text boxes, or a conversion beside drawing, could crash); every context now shares one set of locks and one allocator
  - Left for later (Low): deleted pages and crops stay in the file's earlier revision, because saves append (Reduce File Size writes a clean copy); Insert, Extract, Split and Create PDF copy page contents but not annotations, links or form fields; HTML and SVG conversion embeds images from the source file's own folder, following symlinks; a conversion that stays under the memory cap runs until cancelled (no time limit)

## Phase 4: Forms (0.4.0)

- [x] Fill in and save forms
  - With the Select tool: click a text field to type in place (Return, Tab or clicking away fills it in, Escape doesn't; Tab and Shift-Tab move between the fields you type into), click checkboxes and radio buttons, choose from a menu for dropdowns and list boxes (a list box that takes several choices adds or removes the one chosen). View › Highlight Form Fields tints the fields that can be filled in. Each change is one undoable step and saves incrementally.
  - Form JavaScript doesn't run: values are kept as typed, and calculated fields don't recalculate. Filling in a form removes its XFA data.
  - Left for later (Low): MuPDF draws a dropdown's stored value rather than its label, and doesn't mark a list box's choices; filling one in sets NeedAppearances, so other apps draw them properly.
- [x] Create and edit text fields, checkboxes, radio buttons, dropdowns and signature fields
  - Forms › Edit Fields (⌥⌘F) shows the field bar: Select, Text Field, Checkbox, Radio Button, Dropdown, List Box and Signature Field. Drag out a field, or click for the usual size; a new radio button joins the selected radio button's group. Fields are moved, resized and deleted like annotations, and set up in the inspector: name (unique, no full stops), tooltip, required, read-only, a text field's lines, hidden typing, length and boxes, and a dropdown's or list's choices ("value | label" per line). Signature fields are made empty; signing is Phase 6.
- [x] Flatten forms
  - Forms › Flatten Form… draws every field into its page and removes the form, as one undoable step; on a signed document the alert says the signatures will no longer be valid. Saves stay incremental, so earlier values remain in the file's history (as with crops and deleted pages).
  - Left for later (Low): an empty signature field is flattened as MuPDF's "SIGN" tag.
- [x] Settings window for risky features (see above)
- [x] Security review before release: three Medium fixed. A field that is its own descendant crashed the app when filled in or deleted (MuPDF's walks recurse without noticing), and fields reached many times over hung making or renaming a field; field trees are now checked, bounded, before MuPDF walks them (under the widget and each of its ancestors, since /Parent and /Kids needn't agree; the re-review found the first fix checked only the top), and such fields are listed read-only. A small file could make the field listing copy large amounts of memory, kept for every page; strings now cost a fixed amount against a 2 MB budget per page, and fields are kept for 40 pages. The Settings gates and the update change were checked and hold. Two Lows from the re-review were fixed too: a damaged tree shared by many fields is walked once per page, and new field names look further when the nearby numbers are taken.
  - Left for later (Low): the inspector's choices editor rewrites a dropdown's or list's options from its text, so options cut short by the limits, or containing "|", a new line or surrounding spaces, are changed if it is edited. A page with thousands of fields that need appearances is slow to load the first time (MuPDF makes them all; as in 0.3.0).
- [x] Settings window (⌘,) with switches for risky features, each off until turned on (see Decisions: Risky features)
  - Open web and email links (pages and bookmarks): a PDF can send you to any address its author chose
  - Create PDF from HTML, SVG, EPUB, XPS, Word, Excel and PowerPoint files: MuPDF's parsers for those formats, and HTML and SVG reading images from the source file's folder
  - With links off, clicking one shows its address and offers Settings; link tooltips show the address. With conversion off, the engine registers only the PDF and image handlers and checks each file's content, so a renamed file is refused too.
- [x] Updates only through Check for Updates…: no automatic checks, including where an earlier version saved a yes to Sparkle's question

## Phase 5: Content editing (0.5.0)

- [x] Add, replace, move, resize and delete images
  - Edit Content's Image tool: drag out an area (or click, for the image's own proportions) and choose a file; select an image drawing to move it, resize it (Shift keeps its proportions), delete it or Replace… it (fitted inside the same box). Files are read with ImageIO and handed to MuPDF as JPEG or PNG, at most 100 MB and 40 megapixels. One drawing of an image used twice changes alone.
- [x] Headers, footers, watermarks and page numbers
  - Pages › Add Headers & Footers…, Add Page Numbers… (<<page>>, <<pages>> and <<date>> in any of the six places) and Add Watermark… (text, size, colour, opacity, angle), for all pages or a range, each one undoable step. Stamps are drawn after the page's content, upright as the page is shown and inside its visible area, in Helvetica or, for other characters, an embedded subset system font. Each is marked content (/Artifact with this app's /OPDFStamp tag), so Remove Headers & Footers and Remove Watermarks take off exactly what this app added.
- [x] Links
  - Edit › Edit Content (⌥⌘E) shows the content bar. With the Link tool, drag out an area and choose a web or email address (http, https, mailto) or a page; links are outlined, and are selected, moved, resized, retargeted (inspector) and deleted like annotations. Each change is one undoable step. MuPDF's pdf_set_link_rect doesn't map page space to PDF space, so the bridge writes /Rect itself.
- [x] Edit text within a line: characters, font, size and colour
  - Edit Content's Text tool: click a text run (one text operation of the page's content) to select it; double-click, Return or Edit Text in the inspector to type over it in place. The inspector changes its font (font panel), size and colour (when its fill is grey, RGB or CMYK). New characters use the run's own font when its glyphs are really there; when they aren't, the whole run is drawn in a matching system font (the same font if installed), embedded with only the glyphs used. Text after the edit in the same line of operations moves with it; other text keeps its place.
  - Not editable, and the inspector says why: Type3 text, vertical text, invisible text (OCR layers), and text inside Form XObjects (not listed). Replaced text stays in the file's earlier revision (incremental saves).
- [x] Welcome window with New PDF and Open…, and File › New (asked for during the phase)
- [x] Edit metadata
  - Title, Author, Subject and Keywords are edited in the inspector (one undoable step each), and ModDate is set. A file with XMP metadata gets a new XMP packet to match, keeping its PDF/A identification.
- [x] Security review before release: two Medium fixed. A second stamping with an embedded font replaced the first one's font under the same name (earlier stamps lost their letters); stamp fonts now get a name of their own on each page. Rewriting a page (any text or image edit, or removing stamps) didn't keep some inline images (array colour spaces, colour-key masks); such pages now refuse the edit instead. Cheap Lows fixed too: stray EMCs before a stamp could make Remove drop the rest of the page; a font set by an ExtGState was written back under a wrong name (now refused); added JPEGs kept their EXIF and GPS data (images are now always written again by ImageIO, without metadata); and the 64 MB limit on page content now measures decoded content. The re-review confirmed the fixes and found one more Low, also fixed: a stamp could reuse a font name planted by the file, written unescaped into the stamp's content; only names this app makes are reused now.
  - Left for later (Low): changing the document's information rewrites its XMP from the Info fields (other XMP properties such as rights are dropped, and a PDF/A claim is kept); replaced or deleted images stay in the page's resources and in earlier revisions of the file; any file can mark its own content with this app's stamp tag, so Remove Watermarks would remove it.

## Phase 6: Security and signing (0.6.0)

- [x] Redaction that removes the content underneath
  - Tools › Redact (⌃⌘X): drag across text to mark it, or drag out an area. Marks show as red outlines, and can be moved, resized or deleted until applied.
  - Tools › Apply Redactions…: removes text, image pixels, line art, links, annotations (with replies) and form fields (with their values) under the marks; draws black boxes; removes thumbnails, PieceInfo and document JavaScript and rebuilds XMP; writes the document whole (keeping its encryption) and saves it. Earlier versions of the file are deleted unless the box is unchecked. Can't be undone; signed documents are warned their signatures will no longer be valid.
  - Any character touching a mark is removed, even if the mark only grazes it, so a generous area can take neighbouring lines too.
  - Left for later (Low): content inside patterns, soft masks and Type3 glyphs isn't redacted (MuPDF doesn't look inside them).
- [x] Passwords, encryption and permissions
  - File › Security…: a password to open the document, and an owner password that limits printing, copying, editing, comments and filling in forms. Applying writes the document whole, encrypted with AES-256 (or with no encryption when both are off); undo history is cleared. A signed document is warned that its signatures will no longer be valid.
  - Opened without the owner password, a restricted document disables what its owner doesn't allow (menus, tools, inspector, printing, copying), with a notice under the toolbar and Enter Owner Password….
- [x] Digital signatures with Keychain identities, and verification
  - Click an empty signature field to sign it with a certificate from your keychain (the Keychain may ask to allow the key's use), with an optional reason and location. The signature is a detached CMS (adbe.pkcs7.detached, SHA-256) made by Security.framework; MuPDF is built without OpenSSL on every Mac.
  - The inspector's Signatures section says, for each signature field: who signed and when (by the signer's clock), whether the document has changed since, and whether the certificate is trusted, self-signed, untrusted, expired or revoked. Settings › Check certificates online (off by default) allows fetching certificates and revocation checks.
  - Left for later (Low): PAdES (ETSI.CAdES.detached) and timestamps; verification at the signing time rather than now; whether later changes are ones the signature allows (MDP).
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

- **Next release** (draft): Saving automatically is now a choice in Settings, and off to begin with: changes are kept when you choose File › Save, and closing a changed document asks first. Turn on Save changes automatically for the previous behaviour, with File › Revert To for earlier versions.

- **0.5.0**: Editing. Edit › Edit Content (⌥⌘E) lets you change what's on the page: click text with the Text tool and double-click to retype it, or change its font, size and colour in the inspector (when a character isn't in the PDF's own font, a matching Mac font is embedded with just the letters used); add, move, resize, replace and delete images; and draw links to web pages, email addresses or other pages. Pages › Add Headers & Footers, Add Page Numbers and Add Watermark stamp text on all or some pages, and can be removed again. Change the document's title, author, subject and keywords in the inspector. When no document is open, a new welcome window offers New PDF or Open…, and File › New makes a blank PDF. Every change can be undone.

- **0.4.0**: Forms. Click a form field to fill it in: type into text fields in place (Tab moves to the next one), tick checkboxes and radio buttons, and choose from dropdowns and lists. View › Highlight Form Fields tints the fields you can fill in. Forms › Edit Fields lets you add text fields, checkboxes, radio buttons, dropdowns, list boxes and signature fields, move and resize them, and set their name, tooltip, choices and options in the inspector. Forms › Flatten Form makes what you filled in part of the pages. Every change can be undone. Scripts in forms never run. The new Settings window (⌘,) has switches for opening web and email links and for converting documents other than PDFs and images; both are off until you turn them on, and pointing at a link shows where it goes. The app no longer checks for updates by itself: use Check for Updates… when you want to.

- **0.3.0**: Page management. Rotate, delete, insert blank pages, crop and extract pages from the new Pages menu or by right-clicking thumbnails. Select several thumbnails to change them together, and drag them to put pages in a new order. Insert the pages of another PDF, or drop PDFs, images and other documents between the thumbnails to add them. Split a document every few pages or at its bookmarks, make one PDF from a set of files (PDFs, images, EPUB, Word, Excel, PowerPoint and more) with File › Create PDF from Files, and save a smaller copy with File › Reduce File Size. Every change can be undone. ⌘L and ⌘R now turn pages; turning just the view is ⌥⌘L and ⌥⌘R.

- **0.2.0**: Annotations. Highlight, underline and strike through text; add notes, text boxes, rectangles, ovals, lines, arrows, freehand drawings and stamps from the new markup toolbar (⇧⌘A). Select an annotation to move or resize it, or change its colour, fill, opacity, line width and text in the inspector. The new Comments sidebar lists every annotation with replies and review status, and filters by type, author and status. Everything can be undone, even after saving; documents save automatically, with File › Revert To for earlier versions. Saving adds your changes to the end of the file, so digital signatures stay valid. Tools › Flatten Annotations makes them part of the pages.

- **0.1.1**: Security fixes. PDFs with impossibly large pages can no longer crash the app or use up memory, and a deeply nested outline can no longer crash it. Saving an attachment now asks first when the file could contain an app or a script, and saved attachments are checked by macOS before they open. A document with a malformed date no longer crashes the inspector. Only real PDFs are opened, and a rare crash after showing or hiding a layer is fixed.
- **0.1.0**: The first release: a fast PDF viewer built on MuPDF. Pages render sharply at any zoom, with continuous, single-page and two-page layouts, Fit Width, Fit Page and rotation. The sidebar has page thumbnails, the outline, search results with highlighted matches, attachments you can save and layers you can show or hide. Select and copy text, follow links, go back and forward, open password-protected PDFs, print, and see the document's properties in the inspector. Works in tabs, full screen and Dark Mode, with VoiceOver, and updates itself.
