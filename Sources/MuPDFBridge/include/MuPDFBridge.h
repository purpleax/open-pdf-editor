// MuPDFBridge: the only code that calls MuPDF directly.
//
// MuPDF reports errors with setjmp/longjmp (fz_try / fz_catch), which Swift
// cannot unwind through. Every function here catches them and reports a
// failure through an opdf_error instead. Swift code calls only these.
//
// A document owns its own MuPDF context. A document and its context are not
// thread-safe: use each document from one thread (or actor) at a time.
#ifndef MUPDF_BRIDGE_H
#define MUPDF_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct opdf_doc opdf_doc;

typedef struct {
    int code;            // 0 when there is no error; MuPDF's error code otherwise
    char message[256];
} opdf_error;

// An RGBA bitmap, 8 bits per channel, premultiplied alpha.
typedef struct {
    int width;
    int height;
    int stride;
    unsigned char *samples;
    void *handle;        // owned by the bridge; free with opdf_bitmap_free
} opdf_bitmap;

// MuPDF's version string, e.g. "1.28.5".
const char *opdf_mupdf_version(void);

// Opens a document (PDF or any format MuPDF reads). NULL on failure.
opdf_doc *opdf_open(const char *path, opdf_error *err);
void opdf_close(opdf_doc *doc);

bool opdf_needs_password(opdf_doc *doc);
// True when the password unlocks the document.
bool opdf_authenticate(opdf_doc *doc, const char *password);

// Number of pages, or -1 on failure.
int opdf_page_count(opdf_doc *doc, opdf_error *err);

// Page size in points (1/72 inch), after the page's own rotation.
bool opdf_page_size(opdf_doc *doc, int page, float *width, float *height, opdf_error *err);

// Renders a page at scale (1 = 72 dpi) into a new bitmap. False on failure.
bool opdf_render_page(opdf_doc *doc, int page, float scale, opdf_bitmap *out, opdf_error *err);
void opdf_bitmap_free(opdf_doc *doc, opdf_bitmap *bitmap);

#ifdef __cplusplus
}
#endif

#endif
