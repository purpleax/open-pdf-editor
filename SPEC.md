# Open PDF Editor

Open PDF Editor is a free, fully featured PDF editor for macOS. It aims to match the features of Foxit PDF Editor and similar commercial apps as closely as an open-source engine allows. It is built on the MuPDF engine and looks and feels like a native Mac app. It is open source under the AGPL-3.0 licence, to match MuPDF, and is distributed to the public as a notarised app that updates when asked.

Where this spec and ROADMAP.md disagree, the Decisions table in ROADMAP.md wins.

## Platform

- macOS 14 Sonoma or later, on Apple Silicon Macs only. Intel Macs are not supported.
- Distributed as a signed, notarised DMG and zip from GitHub Releases. Not on the Mac App Store, which the AGPL rules out.
- Updates through Sparkle, checking an appcast in this repository only when the user chooses Check for Updates…

## Look and feel

- A native macOS app that follows Apple's Human Interface Guidelines.
- Document windows with tabs, a toolbar, sidebars and an inspector.
- Supports Dark Mode, keyboard shortcuts, trackpad gestures, full screen and accessibility, including VoiceOver reading of page text.

## Viewing and navigation

- Opens PDFs quickly and renders them sharply at any zoom level.
- Continuous scroll, single-page and two-page layouts, fit to width and fit to page, and rotate view.
- A thumbnails sidebar, a bookmarks and outline sidebar, and full-text search with highlighted results.
- Text selection and copy.
- Opens password-protected PDFs.
- Document properties, attachments and layers panels.
- Prints documents.

## Review and annotation

- Highlight, underline, strikethrough, sticky notes and text boxes.
- Shapes, lines and arrows, freehand drawing, and stamps.
- An annotation list where users can review, reply to and filter comments.
- Flatten annotations into the page.

## Forms

- Fill in and save interactive PDF forms (AcroForms). XFA forms are not supported. Form JavaScript doesn't run.
- Create and edit form fields: text fields, checkboxes, radio buttons, dropdowns and signature fields.
- Form JavaScript is off by default.

## Editing

- Edit existing text like a word processor: click in a paragraph for a caret, type, delete and select across its lines, and it re-wraps within its box. Change font, size, bold, italic, underline, colour and alignment. Add new text boxes. Text does not flow from one paragraph, column or page to the next.
- Add, replace, move, resize and delete images.
- Add headers, footers, watermarks, page numbers and links.
- Edit document metadata.

## Page management

- Insert, delete, reorder, rotate, crop and extract pages.
- Merge several PDFs into one, or split a PDF into several.
- Create PDFs from images and from the formats MuPDF reads (EPUB, XPS, CBZ, SVG, HTML, text and Office documents).
- Reduce file size.

## Security and signing

- True redaction that permanently removes the content underneath.
- Password protection, encryption and permission settings.
- Digital signatures using certificates from the Keychain, plus handwritten and image signatures. Signature verification against the system trust store.

## Recognition and export

- OCR with Apple's Vision framework that makes scanned documents searchable and selectable.
- Export to images, plain text, Word (DOCX) and HTML.

## Out of scope

- Text flowing from one paragraph, column or page to the next.
- XFA forms, PDF/A conversion and document comparison.
- Long-term signature validation and timestamp servers, until after 1.0.
