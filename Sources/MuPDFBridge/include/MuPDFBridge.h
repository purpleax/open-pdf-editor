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

#ifdef __cplusplus
}
#endif

#endif
