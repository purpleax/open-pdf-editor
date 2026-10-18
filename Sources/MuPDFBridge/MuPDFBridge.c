#include "MuPDFBridge.h"

#include <mupdf/fitz.h>
#include <stdlib.h>
#include <string.h>

struct opdf_doc {
    fz_context *ctx;
    fz_document *doc;
};

static void clear_error(opdf_error *err) {
    if (err) {
        err->code = 0;
        err->message[0] = 0;
    }
}

static void set_error(opdf_error *err, fz_context *ctx) {
    if (!err) return;
    err->code = fz_caught(ctx);
    if (err->code == 0) err->code = FZ_ERROR_GENERIC;
    strlcpy(err->message, fz_caught_message(ctx), sizeof err->message);
}

static void set_message(opdf_error *err, const char *message) {
    if (!err) return;
    err->code = FZ_ERROR_ARGUMENT;
    strlcpy(err->message, message, sizeof err->message);
}

const char *opdf_mupdf_version(void) {
    return FZ_VERSION;
}

opdf_doc *opdf_open(const char *path, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        set_message(err, "Could not create a MuPDF context");
        return NULL;
    }
    fz_document *doc = NULL;
    fz_try(ctx) {
        fz_register_document_handlers(ctx);
        doc = fz_open_document(ctx, path);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        fz_drop_context(ctx);
        return NULL;
    }
    opdf_doc *result = calloc(1, sizeof *result);
    if (!result) {
        fz_drop_document(ctx, doc);
        fz_drop_context(ctx);
        set_message(err, "Out of memory");
        return NULL;
    }
    result->ctx = ctx;
    result->doc = doc;
    return result;
}

void opdf_close(opdf_doc *doc) {
    if (!doc) return;
    fz_drop_document(doc->ctx, doc->doc);
    fz_drop_context(doc->ctx);
    free(doc);
}

bool opdf_needs_password(opdf_doc *doc) {
    bool needs = false;
    fz_try(doc->ctx)
        needs = fz_needs_password(doc->ctx, doc->doc);
    fz_catch(doc->ctx)
        needs = false;
    return needs;
}

bool opdf_authenticate(opdf_doc *doc, const char *password) {
    bool ok = false;
    fz_try(doc->ctx)
        ok = fz_authenticate_password(doc->ctx, doc->doc, password) != 0;
    fz_catch(doc->ctx)
        ok = false;
    return ok;
}

int opdf_page_count(opdf_doc *doc, opdf_error *err) {
    clear_error(err);
    int count = -1;
    fz_try(doc->ctx)
        count = fz_count_pages(doc->ctx, doc->doc);
    fz_catch(doc->ctx) {
        set_error(err, doc->ctx);
        count = -1;
    }
    return count;
}

bool opdf_page_size(opdf_doc *doc, int page, float *width, float *height, opdf_error *err) {
    clear_error(err);
    fz_page *p = NULL;
    bool ok = false;
    fz_var(p);
    fz_try(doc->ctx) {
        p = fz_load_page(doc->ctx, doc->doc, page);
        fz_rect bounds = fz_bound_page(doc->ctx, p);
        *width = bounds.x1 - bounds.x0;
        *height = bounds.y1 - bounds.y0;
        ok = true;
    }
    fz_always(doc->ctx)
        fz_drop_page(doc->ctx, p);
    fz_catch(doc->ctx)
        set_error(err, doc->ctx);
    return ok;
}

bool opdf_render_page(opdf_doc *doc, int page, float scale, opdf_bitmap *out, opdf_error *err) {
    clear_error(err);
    memset(out, 0, sizeof *out);
    if (!(scale > 0)) {
        set_message(err, "Scale must be positive");
        return false;
    }
    fz_pixmap *pix = NULL;
    fz_try(doc->ctx)
        pix = fz_new_pixmap_from_page_number(doc->ctx, doc->doc, page, fz_scale(scale, scale),
                                             fz_device_rgb(doc->ctx), 1);
    fz_catch(doc->ctx) {
        set_error(err, doc->ctx);
        return false;
    }
    out->width = fz_pixmap_width(doc->ctx, pix);
    out->height = fz_pixmap_height(doc->ctx, pix);
    out->stride = (int)fz_pixmap_stride(doc->ctx, pix);
    out->samples = fz_pixmap_samples(doc->ctx, pix);
    out->handle = pix;
    return true;
}

void opdf_bitmap_free(opdf_doc *doc, opdf_bitmap *bitmap) {
    if (!bitmap || !bitmap->handle) return;
    fz_drop_pixmap(doc->ctx, (fz_pixmap *)bitmap->handle);
    memset(bitmap, 0, sizeof *bitmap);
}
