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
// True when the password unlocks the document.
bool opdf_authenticate(opdf_doc *doc, const char *password);

// Number of pages, or -1 on failure.
int opdf_page_count(opdf_doc *doc, opdf_error *err);

// Bounds of every page in page space, into out[0..count-1]. Fast for PDFs:
// pages are not loaded. Pages that fail get an empty rectangle.
bool opdf_page_bounds_all(opdf_doc *doc, opdf_rect *out, int count, opdf_error *err);

// Metadata by MuPDF key ("format", "encryption", "info:Title", ...).
// A new string to free with opdf_free, or NULL when there is none.
char *opdf_metadata(opdf_doc *doc, const char *key);

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
} opdf_link;

// A new array; free with opdf_links_free.
opdf_link *opdf_links_load(opdf_doc *doc, int page, int *count, opdf_error *err);
void opdf_links_free(opdf_link *links, int count);

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

// --- Undo, saving, flattening ---------------------------------------------

// Call once the document is unlocked and before any change. Loads every
// object so that MuPDF repairs a damaged file now: a repair later would
// throw away the changes made since opening. A repaired file is rewritten
// in memory and reopened from there (password: for encrypted files), so it
// can be saved incrementally like any other. *repaired says whether that
// happened.
bool opdf_prepare_for_editing(opdf_doc *doc, const char *password, bool *repaired, opdf_error *err);

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

// Writes a smaller copy of the PDF at in_path to out_path: images above a
// resolution are downsampled and recompressed (quality 0 high, 1 medium,
// 2 small), and unused or duplicate objects are removed.
bool opdf_reduce_file(const char *in_path, const char *password, const char *out_path, int quality,
                      opdf_cancel *cancel, opdf_error *err);

#ifdef __cplusplus
}
#endif

#endif
