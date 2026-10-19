// MuPDFBridge: the only code that calls MuPDF directly.
//
// MuPDF reports errors with setjmp/longjmp (fz_try / fz_catch), which Swift
// cannot unwind through. Every function here catches them and reports a
// failure through an opdf_error instead.
//
// Threads: every function may be called from any thread. Calls that touch
// the document are serialised by a lock inside opdf_doc. Display lists are
// rendered outside that lock on a pool of cloned MuPDF contexts, so several
// tiles can render at once while the document is busy with something else.
//
// Coordinates: "page space" is MuPDF's, with the page's own /Rotate already
// applied, y pointing down, and the origin wherever the page's box puts it
// (see opdf_page_bounds_all). "View space" is page space scaled, rotated by
// the view rotation and moved so the page's top-left corner is at (0, 0); it
// is what opdf_page_matrix returns and what opdf_list_render draws.
#ifndef MUPDF_BRIDGE_H
#define MUPDF_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct opdf_doc opdf_doc;
typedef struct opdf_list opdf_list;
typedef struct opdf_cookie opdf_cookie;

typedef struct {
    int code;            // 0 when there is no error; MuPDF's error code otherwise
    char message[256];
} opdf_error;

typedef struct {
    float x0, y0, x1, y1;
} opdf_rect;

typedef struct {
    float a, b, c, d, e, f;
} opdf_matrix;

// Frees strings and arrays returned by this bridge.
void opdf_free(void *pointer);

// MuPDF's version string, e.g. "1.28.5".
const char *opdf_mupdf_version(void);

// --- Documents --------------------------------------------------------------

// Opens a document (PDF or any format MuPDF reads). NULL on failure.
opdf_doc *opdf_open(const char *path, opdf_error *err);
void opdf_close(opdf_doc *doc);

bool opdf_is_pdf(opdf_doc *doc);
bool opdf_needs_password(opdf_doc *doc);
// Whether opening the document takes a password (known once opdf_needs_password
// has been asked, and kept up to date by opdf_rebase).
bool opdf_needs_open_password(opdf_doc *doc);
// True when the password unlocks the document.
bool opdf_authenticate(opdf_doc *doc, const char *password);
// Whether the last password given was the owner password (or the document
// isn't encrypted): full access, including changing its security.
bool opdf_is_owner(opdf_doc *doc);
// What may be done with it (OPDF_ALLOW_*): everything for the owner,
// otherwise what the document's permissions grant.
enum {
    OPDF_ALLOW_PRINT = 1 << 0, OPDF_ALLOW_COPY = 1 << 1, OPDF_ALLOW_EDIT = 1 << 2,
    OPDF_ALLOW_ANNOTATE = 1 << 3, OPDF_ALLOW_FORMS = 1 << 4, OPDF_ALLOW_ASSEMBLE = 1 << 5,
};
int opdf_allowed(opdf_doc *doc);
// The permission bits (P) the document grants without the owner password
// (all of them when it isn't encrypted).
int opdf_permission_bits(opdf_doc *doc);

// Number of pages, or -1 on failure.
int opdf_page_count(opdf_doc *doc, opdf_error *err);

// Bounds of every page in page space, into out[0..count-1]. Fast for PDFs:
// pages are not loaded. Pages that fail get an empty rectangle.
bool opdf_page_bounds_all(opdf_doc *doc, opdf_rect *out, int count, opdf_error *err);

// Metadata by MuPDF key ("format", "encryption", "info:Title", ...).
// A new string to free with opdf_free, or NULL when there is none.
char *opdf_metadata(opdf_doc *doc, const char *key);

// What opdf_metadata_set changes: NULL leaves a value as it is, "" removes
// it. Each is at most OPDF_MAX_METADATA_TEXT bytes.
typedef struct {
    const char *title;
    const char *author;
    const char *subject;
    const char *keywords;
} opdf_metadata_spec;
#define OPDF_MAX_METADATA_TEXT 65536

// Sets the document's Title, Author, Subject and Keywords, and its ModDate
// to `now` (seconds since 1970). A document with XMP metadata gets a new
// XMP packet to match, keeping its PDF/A identification. One undoable step.
bool opdf_metadata_set(opdf_doc *doc, const opdf_metadata_spec *spec, int64_t now, opdf_error *err);

// The matrix from page space to view space for a page with these bounds.
opdf_matrix opdf_page_matrix(opdf_rect bounds, float scale, int rotation);

// --- Rendering --------------------------------------------------------------

// A page's display list (its drawing commands), loaded under the document
// lock; rendered with opdf_list_render on any thread. NULL on failure.
opdf_list *opdf_list_load(opdf_doc *doc, int page, opdf_error *err);
void opdf_list_drop(opdf_doc *doc, opdf_list *list);

opdf_cookie *opdf_cookie_new(void);
void opdf_cookie_abort(opdf_cookie *cookie);
void opdf_cookie_free(opdf_cookie *cookie);

// Renders the part of the page at (x, y, width, height) in view space, for
// this scale (1 = 72 dpi) and view rotation (0, 90, 180, 270), into samples:
// width * height RGBA pixels, 4 bytes each, rows packed, opaque, white
// behind the page. cookie may be NULL; aborting it stops the render.
bool opdf_list_render(opdf_doc *doc, opdf_list *list, opdf_rect bounds, float scale, int rotation,
                      int x, int y, int width, int height, unsigned char *samples,
                      opdf_cookie *cookie, opdf_error *err);

// --- Text -------------------------------------------------------------------

// One character in reading order. quad is in page space: upper-left,
// upper-right, lower-left, lower-right corners as x, y pairs.
typedef struct {
    int32_t c;           // Unicode scalar
    int32_t line;        // index of its line on the page, from 0
    int32_t block;       // index of its block (paragraph) on the page, from 0
    float quad[8];
} opdf_char;

// The page's text as characters in reading order. A new array to free with
// opdf_free; *count is set. NULL with *count 0 for a page without text.
opdf_char *opdf_text_load(opdf_doc *doc, int page, int *count, opdf_error *err);

// --- Links ------------------------------------------------------------------

typedef struct {
    opdf_rect rect;      // in page space
    char *uri;
    bool external;       // a web or file link rather than a place in this document
    int page;            // for internal links: the target page, or -1
    float x, y;          // for internal links: the target point in page space (NaN if none)
    int id;              // the link annotation's object number (0: can't be changed)
} opdf_link;

// A new array; free with opdf_links_free.
opdf_link *opdf_links_load(opdf_doc *doc, int page, int *count, opdf_error *err);
void opdf_links_free(opdf_link *links, int count);

// Making and changing links: each is one undoable step. A link goes to a web
// address (`uri`: http, https or mailto only) or, when `uri` is NULL, to
// `target_page` of this document. Rectangles are in page space.
// Returns the new link's id, or 0.
int opdf_link_create(opdf_doc *doc, int page, opdf_rect rect, const char *uri, int target_page, opdf_error *err);
// Changes a link's rectangle, and its target unless `retarget` is false.
bool opdf_link_update(opdf_doc *doc, int page, int id, opdf_rect rect, bool retarget, const char *uri, int target_page,
                      opdf_error *err);
bool opdf_link_delete(opdf_doc *doc, int page, int id, opdf_error *err);

// --- Outline ----------------------------------------------------------------

typedef struct {
    char *title;
    char *uri;
    int depth;           // 0 for top-level items
    bool open;           // shown expanded by default
    int page;            // target page, or -1
    float x, y;          // target point in page space (NaN if none)
} opdf_outline_item;

// The outline flattened in order (parents before children). A new array;
// free with opdf_outline_free. NULL with *count 0 when there is none.
opdf_outline_item *opdf_outline_load(opdf_doc *doc, int *count, opdf_error *err);
void opdf_outline_free(opdf_outline_item *items, int count);

// --- Attachments (PDF embedded files) ----------------------------------------

typedef struct {
    char *name;          // key in the document's EmbeddedFiles name tree
    char *filename;
    char *mimetype;
    int64_t size;        // bytes, or -1 if unknown
    int64_t created;     // seconds since 1970, or -1 if unknown
    int64_t modified;
} opdf_attachment;

opdf_attachment *opdf_attachments_load(opdf_doc *doc, int *count, opdf_error *err);
void opdf_attachments_free(opdf_attachment *items, int count);
// Writes the attachment with this name (opdf_attachment.name) to path.
bool opdf_attachment_save(opdf_doc *doc, const char *name, const char *path, opdf_error *err);

// --- Layers (PDF optional content) -----------------------------------------

typedef struct {
    char *text;
    int depth;
    int type;            // 0 label, 1 checkbox, 2 radio button
    bool selected;
    bool locked;
} opdf_layer;

// The document's layer list as its author arranged it for display.
opdf_layer *opdf_layers_load(opdf_doc *doc, int *count, opdf_error *err);
void opdf_layers_free(opdf_layer *items, int count);
// Turns the layer at this index on or off (radio buttons switch within their
// group). Display lists loaded before this are out of date.
bool opdf_layer_toggle(opdf_doc *doc, int index, opdf_error *err);


// --- Annotations -----------------------------------------------------------
//
// Annotations are identified by their PDF object number, which stays the
// same while the document is open. Geometry is in page space. Every change
// is one step in MuPDF's undo journal (see opdf_undo).

typedef struct {
    int id;              // PDF object number
    int type;            // MuPDF's pdf_annot_type (0 Text, 2 FreeText, 3 Line, 4 Square, 5 Circle, 8 Highlight, ...)
    opdf_rect rect;
    int color_n;         // 0 none, 1 grey, 3 RGB, 4 CMYK
    float color[4];
    int interior_n;
    float interior[4];
    float opacity;
    float border_width;
    int flags;
    char *contents;
    char *author;
    char *subject;
    char *icon_name;     // Text icons and stamp names
    int64_t modified;    // seconds since 1970, or -1
    int64_t created;
    int in_reply_to;     // id of the annotation this replies to, or 0
    char *state;         // review state of a status reply ("Accepted", ...)
    char *state_model;   // "Review" or "Marked"
    int quad_count;
    float *quads;        // quad_count * 8 floats: ul, ur, ll, lr corners
    int ink_stroke_count;
    int *ink_counts;     // points in each stroke
    float *ink_points;   // all strokes' points as x, y pairs
    bool has_line;
    float line[4];       // x0, y0, x1, y1
    int line_start, line_end;  // pdf_line_ending
    float font_size;     // FreeText
    int text_color_n;
    float text_color[4];
    // Can't be changed here: its geometry was too large and has been cut
    // short, or it has no object number of its own (id 0).
    bool read_only;
} opdf_annot;

// Limits on what is read from a file, so a crafted file can't make the app
// allocate or loop without bound. Annotations over a limit are cut short
// and marked read-only.
#define OPDF_MAX_ANNOTS_PER_PAGE 5000
#define OPDF_MAX_QUADS 10000
#define OPDF_MAX_INK_STROKES 1000
#define OPDF_MAX_INK_POINTS 100000
#define OPDF_MAX_PAGE_POINTS 500000

// Every annotation on a page except links, popups and form fields (at most
// OPDF_MAX_ANNOTS_PER_PAGE, each listed once).
opdf_annot *opdf_annots_load(opdf_doc *doc, int page, int *count, opdf_error *err);
void opdf_annots_free(opdf_annot *items, int count);

// Which fields of an opdf_annot_spec to apply.
enum {
    OPDF_FIELD_RECT = 1 << 0,
    OPDF_FIELD_COLOR = 1 << 1,
    OPDF_FIELD_INTERIOR = 1 << 2,
    OPDF_FIELD_OPACITY = 1 << 3,
    OPDF_FIELD_BORDER = 1 << 4,
    OPDF_FIELD_CONTENTS = 1 << 5,
    OPDF_FIELD_AUTHOR = 1 << 6,
    OPDF_FIELD_ICON = 1 << 7,
    OPDF_FIELD_QUADS = 1 << 8,
    OPDF_FIELD_INK = 1 << 9,
    OPDF_FIELD_LINE = 1 << 10,
    OPDF_FIELD_LINE_ENDINGS = 1 << 11,
    OPDF_FIELD_FONT = 1 << 12,
};

typedef struct {
    int type;
    opdf_rect rect;
    int color_n;         // 0 none, 3 RGB
    float color[3];
    int interior_n;
    float interior[3];
    float opacity;
    float border_width;
    const char *contents;
    const char *author;
    const char *icon_name;
    int quad_count;
    const float *quads;
    int ink_stroke_count;
    const int *ink_counts;
    const float *ink_points;
    float line[4];
    int line_start, line_end;
    float font_size;
    float text_color[3];
} opdf_annot_spec;

// Creates an annotation from the fields given; the new id, or 0 on failure.
int opdf_annot_create(opdf_doc *doc, int page, const opdf_annot_spec *spec, unsigned fields,
                      const char *operation, opdf_error *err);
bool opdf_annot_update(opdf_doc *doc, int page, int id, const opdf_annot_spec *spec, unsigned fields,
                       const char *operation, opdf_error *err);
// Applies a matrix to an annotation's rectangle and geometry (move, resize).
bool opdf_annot_transform(opdf_doc *doc, int page, int id, opdf_matrix matrix, const char *operation, opdf_error *err);
// Deletes an annotation and its replies.
bool opdf_annot_delete(opdf_doc *doc, int page, int id, const char *operation, opdf_error *err);
// Adds a reply note to an annotation; the reply's id, or 0.
int opdf_annot_reply(opdf_doc *doc, int page, int parent, const char *author, const char *contents, opdf_error *err);
// Sets the review status of an annotation (one status per author): a hidden
// reply with State/StateModel, as other PDF apps write it. NULL state removes it.
bool opdf_annot_set_status(opdf_doc *doc, int page, int parent, const char *author, const char *state, opdf_error *err);

// --- Page content ----------------------------------------------------------
//
// What the page's own content stream draws, for editing: its text
// operations (Tj, TJ, ' and ") and image drawings (Do of an image), each
// identified by its order on the page. Text inside Form XObjects, inline
// images and annotations aren't included.

enum {
    OPDF_RUN_EDITABLE = 0,
    OPDF_RUN_TYPE3,       // drawn with a Type3 font
    OPDF_RUN_VERTICAL,    // vertical writing
    OPDF_RUN_INVISIBLE,   // render mode 3 (an OCR layer, for one)
    OPDF_RUN_TOO_LONG,    // over the limits, listed only in part
};

typedef struct {
    int op;              // which text operation on the page, from 0
    char *text;          // UTF-8
    opdf_rect rect;      // page space
    int quad_count;
    float *quads;        // one per character, as in opdf_char
    char *font;          // the font's name (no subset prefix)
    bool serif, bold, italic, monospaced;
    float size;          // as drawn, in points
    int color_n;         // fill colour: 1 grey, 3 RGB, 4 CMYK; 0 for any other kind
    float color[4];
    int not_editable;    // OPDF_RUN_*
} opdf_text_run;

typedef struct {
    int op;              // which image drawing on the page, from 0
    opdf_rect rect;      // page space
    float matrix[6];     // the image's unit square to page space
    int width, height;   // pixels
} opdf_image_placement;

typedef struct {
    opdf_text_run *runs;
    int run_count;
    opdf_image_placement *images;
    int image_count;
} opdf_page_content;

// Limits on what is read from a page's content.
#define OPDF_MAX_CONTENT_BYTES (64 << 20)  // decoded content stream
#define OPDF_MAX_CONTENT_OPS 200000        // text operations and image drawings
#define OPDF_MAX_RUN_CHARS 10000
#define OPDF_MAX_PAGE_CHARS 200000
#define OPDF_MAX_GSTATE_DEPTH 256

bool opdf_page_content_load(opdf_doc *doc, int page, opdf_page_content *out, opdf_error *err);
void opdf_page_content_free(opdf_page_content *content);
// Images. `data` is a JPEG or PNG file (other formats are converted
// before they get here), at most OPDF_MAX_IMAGE_BYTES and
// OPDF_MAX_IMAGE_PIXELS. Rectangles are in page space; an image is drawn
// upright as the page is shown. Each is one undoable step.
#define OPDF_MAX_IMAGE_BYTES (100 << 20)
#define OPDF_MAX_IMAGE_PIXELS 40000000
// Draws a new image over the page's content, filling `rect`.
bool opdf_image_add(opdf_doc *doc, int page, opdf_rect rect, const unsigned char *data, size_t len, opdf_error *err);
// Moves or resizes image drawing `op` so that it fills `rect`.
bool opdf_image_set_rect(opdf_doc *doc, int page, int op, opdf_rect rect, opdf_error *err);
bool opdf_image_delete(opdf_doc *doc, int page, int op, opdf_error *err);
// Draws another image instead, fitted inside the same box.
bool opdf_image_replace(opdf_doc *doc, int page, int op, const unsigned char *data, size_t len, opdf_error *err);

// Text. A run is one text operation (opdf_text_run.op). Each edit is one
// undoable step. New characters are drawn with the run's own font when it
// has their glyphs, and otherwise with `font_data` (an sfnt font file:
// TrueType or OpenType), embedded with only the glyphs used.
#define OPDF_MAX_EDIT_TEXT 10000          // bytes of new text
#define OPDF_MAX_FONT_BYTES (50 << 20)

typedef struct {
    const char *text;           // the run's new text (UTF-8); NULL keeps it as it is
    const unsigned char *font_data;
    size_t font_len;
    bool whole_font;            // draw the whole run in font_data's font
    float size_scale;           // > 0: the run's size times this
    int color_n;                // 1 grey or 3 RGB: a new colour; 0 keeps it
    float color[3];
} opdf_text_edit;

bool opdf_text_run_edit(opdf_doc *doc, int page, int op, const opdf_text_edit *edit, opdf_error *err);
// The characters of `text` (UTF-8) that run `op`'s font can't draw, as a
// new UTF-8 string (empty when it can draw them all), to free with opdf_free.
char *opdf_text_run_missing(opdf_doc *doc, int page, int op, const char *text, opdf_error *err);

// Headers, footers, page numbers and watermarks: text stamped over the
// page's content, marked so that this app can remove what it added.
enum { OPDF_STAMP_HEADER = 0, OPDF_STAMP_FOOTER = 1, OPDF_STAMP_WATERMARK = 2 };
enum { OPDF_STAMPS_HEADERS_FOOTERS = 1, OPDF_STAMPS_WATERMARKS = 2 };

typedef struct {
    int page;
    int kind;            // OPDF_STAMP_*
    int align;           // headers and footers: 0 left, 1 centre, 2 right
    const char *text;    // UTF-8, as it is to appear on this page
    float size;          // points
    float color[3];      // RGB
    float opacity;       // 0 to 1
    float angle;         // watermarks: degrees, anticlockwise
    float margin;        // headers and footers: from the edge, in points
} opdf_stamp;

// Stamps every item, as one undoable step. Text is drawn in Helvetica, or
// with font_data (an sfnt file, embedded with only the glyphs used) when
// given. Upright as each page is shown, inside its visible area.
bool opdf_stamp_pages(opdf_doc *doc, const opdf_stamp *stamps, int count, const unsigned char *font_data, size_t font_len,
                      opdf_error *err);
// Removes the stamps of these kinds (OPDF_STAMPS_*) this app added, from
// every page; *pages is how many pages had some. One undoable step.
bool opdf_stamps_remove(opdf_doc *doc, int kinds, int *pages, opdf_error *err);

// Writes the page's content again through the editing machinery with no
// change (for tests: what it draws must not change). One undoable step.
bool opdf_page_content_rewrite(opdf_doc *doc, int page, opdf_error *err);

// --- Form fields -----------------------------------------------------------
//
// Each form field widget on a page, identified like annotations by its PDF
// object number. Form JavaScript never runs: values are set as given, and
// calculated fields aren't recalculated.

// MuPDF's pdf_widget_type.
enum {
    OPDF_FIELD_UNKNOWN = 0,
    OPDF_FIELD_BUTTON = 1,      // push button
    OPDF_FIELD_CHECKBOX = 2,
    OPDF_FIELD_COMBOBOX = 3,    // dropdown
    OPDF_FIELD_LISTBOX = 4,
    OPDF_FIELD_RADIO = 5,
    OPDF_FIELD_SIGNATURE = 6,
    OPDF_FIELD_TEXT = 7,
};

typedef struct {
    int id;              // the widget's PDF object number
    int type;            // OPDF_FIELD_*
    opdf_rect rect;
    char *name;          // full name ("address.street")
    char *tooltip;       // /TU, or NULL
    char *value;         // text, a dropdown's choice, or a checkbox or radio group's state ("Off" when off)
    char *on_state;      // checkbox and radio: this widget's state when on
    bool is_on;          // checkbox and radio: this widget is on
    int flags;           // /Ff (PDF_FIELD_IS_READ_ONLY, PDF_TX_FIELD_IS_MULTILINE, ...)
    int max_length;      // text: /MaxLen, or 0
    int option_count;    // dropdown and list box
    char **option_values;  // what is stored when chosen
    char **option_labels;  // what is shown
    int selected_count;  // list box: the chosen options' values
    char **selected;
    bool is_signed;      // signature: has a signature
    // Can't be filled in here: read-only in the file, a kind that isn't
    // filled in (push buttons, signatures, file selection, rich text), over
    // a limit, or no object number of its own (id 0).
    bool read_only;
} opdf_field;

// Limits on what is read, as for annotations: fields over a limit are cut
// short and marked read-only.
#define OPDF_MAX_FIELDS_PER_PAGE 2000
#define OPDF_MAX_FIELD_OPTIONS 1000
#define OPDF_MAX_FIELD_TEXT 100000   // bytes of a value, name or option

// What the document's form holds: fields at all, XFA data, and a signed
// signature field (looked for among the first 10,000 fields).
typedef struct {
    bool has_fields;
    bool has_xfa;
    bool is_signed;
} opdf_form_info;
bool opdf_form_get_info(opdf_doc *doc, opdf_form_info *info, opdf_error *err);

// Every form field widget on a page (at most OPDF_MAX_FIELDS_PER_PAGE, each
// listed once).
opdf_field *opdf_fields_load(opdf_doc *doc, int page, int *count, opdf_error *err);
void opdf_fields_free(opdf_field *items, int count);

// Each is one undoable step named "Fill In Field". They refuse read-only
// fields. Filling in a field removes /XFA (other apps would show its old
// data instead of the values typed here).
// Text field or dropdown: the new text (a dropdown takes one of its option values).
bool opdf_field_set_text(opdf_doc *doc, int page, int id, const char *text, opdf_error *err);
// List box: the chosen option values (more than one only if it allows that).
bool opdf_field_set_choices(opdf_doc *doc, int page, int id, const char *const *values, int count, opdf_error *err);
// Checkbox or radio button: turns it on, or a checkbox off (a radio
// button stays on unless its group allows none).
bool opdf_field_toggle(opdf_doc *doc, int page, int id, opdf_error *err);

// Creating and changing fields. Each is one undoable step.

// A new field of this kind (OPDF_FIELD_TEXT, _CHECKBOX, _RADIO, _COMBOBOX,
// _LISTBOX or _SIGNATURE) with a new unique name, adding the document's
// form if it has none. A radio button joins the group of the radio button
// `group` (its id), or starts a group of its own when `group` is 0.
// Returns the new widget's id, or 0.
int opdf_field_create(opdf_doc *doc, int page, int type, opdf_rect rect, int group, opdf_error *err);

// The flags a field's settings may change.
#define OPDF_FIELD_SETTABLE_FLAGS ((1 << 0) | (1 << 1) | (1 << 12) | (1 << 13) | (1 << 18) | (1 << 21) | (1 << 24))

// What opdf_field_update changes; NULL or -1 leaves a setting as it is.
typedef struct {
    const char *name;        // the field's own name: no dots, unique among the form's fields
    const char *tooltip;     // "" removes it
    int flags_mask;          // which of OPDF_FIELD_SETTABLE_FLAGS to change...
    int flags;               // ...and to what
    int max_length;          // text: 0 for none, -1 unchanged
    int option_count;        // dropdown and list box: -1 unchanged
    const char *const *option_values;
    const char *const *option_labels;   // NULL, or a label per value ("" or the value: none)
} opdf_field_spec;

bool opdf_field_update(opdf_doc *doc, int page, int id, const opdf_field_spec *spec, opdf_error *err);
// Moves or resizes a field's widget (a matrix on its rectangle).
bool opdf_field_transform(opdf_doc *doc, int page, int id, opdf_matrix matrix, opdf_error *err);
// Deletes a field's widget, and the field once it has no widgets left.
bool opdf_field_delete(opdf_doc *doc, int page, int id, opdf_error *err);

// --- Undo, saving, flattening ---------------------------------------------

// Call once the document is unlocked and before any change. Loads every
// object so that MuPDF repairs a damaged file now: a repair later would
// throw away the changes made since opening. A repaired file is rewritten
// in memory and reopened from there (password: for encrypted files), so it
// can be saved incrementally like any other. *repaired says whether that
// happened.
bool opdf_prepare_for_editing(opdf_doc *doc, const char *password, bool *repaired, opdf_error *err);

// Writing the document whole ("rebase"): the document as it is now is
// written out again in full (unused objects and earlier revisions dropped),
// opened from those bytes, and edited from then on. Undo history is gone.
// Redaction and security changes use it.
enum { OPDF_ENCRYPT_KEEP = 0, OPDF_ENCRYPT_NONE = 1, OPDF_ENCRYPT_AES256 = 2 };
typedef struct {
    int encryption;              // OPDF_ENCRYPT_*
    const char *open_password;   // what the document was unlocked with (KEEP), or NULL
    const char *user_password;   // AES256: to open ("" for none)
    const char *owner_password;  // AES256: for full access (required)
    int permissions;             // AES256: PDF_PERM_* bits granted to the user password
    bool scrub;                  // also remove thumbnails, PieceInfo and document JavaScript, and rebuild XMP
    int64_t now;                 // for the rebuilt XMP
} opdf_rebase_options;
bool opdf_rebase(opdf_doc *doc, const opdf_rebase_options *options, opdf_error *err);

bool opdf_can_undo(opdf_doc *doc);
bool opdf_can_redo(opdf_doc *doc);
bool opdf_undo(opdf_doc *doc, opdf_error *err);
bool opdf_redo(opdf_doc *doc, opdf_error *err);
bool opdf_has_unsaved_changes(opdf_doc *doc);

// Writes the document with its changes to path (never the open file): the
// original file, byte for byte, with every change since opening appended as
// one incremental update (which keeps digital signatures valid). The open
// document is left as it was, so it can be saved again and keeps its undo
// history. Repaired files, which can't take incremental updates, are written
// whole.
bool opdf_save(opdf_doc *doc, const char *path, opdf_error *err);

// Draws every annotation into its page's content and removes them (form
// fields are left alone). One undoable step.
bool opdf_flatten_annotations(opdf_doc *doc, opdf_error *err);

// Draws every form field into its page and removes the form: what was
// filled in stays visible but can no longer be changed. Signatures in the
// form stop being valid. One undoable step.
bool opdf_flatten_form(opdf_doc *doc, opdf_error *err);

// --- Pages -------------------------------------------------------------------
//
// Each is one step in the undo journal. Page numbers are from 0.

// Deletes these pages (any order; duplicates ignored). At least one page
// must remain.
bool opdf_pages_delete(opdf_doc *doc, const int *pages, int count, opdf_error *err);
// Puts the pages in a new order: `order` lists every page exactly once.
bool opdf_pages_reorder(opdf_doc *doc, const int *order, int count, opdf_error *err);
// Inserts a blank page of this size (points) before page `at` (or at the end).
bool opdf_page_insert_blank(opdf_doc *doc, int at, float width, float height, opdf_error *err);
// Turns pages by a multiple of 90 degrees (clockwise when positive).
bool opdf_pages_rotate(opdf_doc *doc, const int *pages, int count, int degrees, opdf_error *err);
// Sets the visible area (crop box) of pages to `box`, in each page's own
// page space, limited to the page.
bool opdf_pages_crop(opdf_doc *doc, const int *pages, int count, opdf_rect box, opdf_error *err);
// Copies every page of another PDF in before page `at`; *inserted is how
// many. password may be NULL.
bool opdf_insert_file(opdf_doc *doc, int at, const char *path, const char *password, int *inserted, opdf_error *err);

// Writes these pages, in this order, as a new PDF (the document is unchanged).
bool opdf_extract_pages(opdf_doc *doc, const int *pages, int count, const char *path, opdf_error *err);

// A flag that stops a conversion or reduction partway (from any thread).
typedef struct opdf_cancel opdf_cancel;
opdf_cancel *opdf_cancel_new(void);
void opdf_cancel_request(opdf_cancel *cancel);
void opdf_cancel_free(opdf_cancel *cancel);

// Makes one PDF of several files: PDFs (pages copied as they are), images,
// and the other kinds MuPDF reads (EPUB, XPS, CBZ, SVG, HTML, text, Office),
// which are laid out on pages of width x height points. Uses its own MuPDF
// context, with every document handler only when allow_documents is true
// (otherwise only PDFs and images are read, whatever a file is named);
// nothing is open afterwards. Memory is capped (and cancel, which may be
// NULL, stops it at the next allocation).
bool opdf_convert_files(const char *const *paths, int count, const char *out_path, float width, float height,
                        bool allow_documents, opdf_cancel *cancel, opdf_error *err);

// Writes a new PDF of one blank page of width x height points to path,
// for a new document.
bool opdf_write_blank(const char *path, float width, float height, opdf_error *err);

// Writes a smaller copy of the PDF at in_path to out_path: images above a
// resolution are downsampled and recompressed (quality 0 high, 1 medium,
// 2 small), and unused or duplicate objects are removed.
bool opdf_reduce_file(const char *in_path, const char *password, const char *out_path, int quality,
                      opdf_cancel *cancel, opdf_error *err);

#ifdef __cplusplus
}
#endif

#endif
