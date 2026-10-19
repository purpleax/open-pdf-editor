#include "MuPDFBridge.h"

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <mupdf/pdf/clean.h>
#include <mupdf/pdf/image-rewriter.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// MuPDF's PDF handler (not in its public headers; declared the same way in
// its own sources). Only PDF is registered: MuPDF sniffs content, so with
// every handler a file named .pdf could open in its HTML, EPUB, XPS or
// image engines instead.
extern fz_document_handler pdf_document_handler;

// MuPDF's pdf_link (source/pdf/pdf-annot-imp.h, not in its public headers):
// the links fz_load_links returns for a PDF page, with their annotation
// objects. Declared the same way; MuPDF is pinned (thirdparty/mupdf).
typedef struct {
    fz_link super;
    pdf_page *page;
    pdf_obj *obj;
} mupdf_pdf_link;

// Outlines deeper or larger than this are not loaded: MuPDF walks them
// recursively, so a hostile file could exhaust the stack.
#define MAX_OUTLINE_DEPTH 256
#define MAX_OUTLINE_ITEMS 100000

// Cloned contexts for rendering display lists in parallel.
#define POOL_SIZE 8

struct opdf_doc {
    // The base context: used only while holding `lock`.
    fz_context *ctx;
    fz_document *doc;
    pthread_mutex_t lock;

    // Set by opdf_prepare_for_editing.
    bool edits_prepared;
    bool repaired_before_edits;

    pthread_mutex_t pool_lock;
    pthread_cond_t pool_cond;
    fz_context *pool[POOL_SIZE];
    bool pool_busy[POOL_SIZE];
};

struct opdf_cookie {
    fz_cookie cookie;
};

// --- Helpers -----------------------------------------------------------------

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

static char *dup_string(const char *s) {
    return s ? strdup(s) : NULL;
}

// --- Locks and memory, shared by every MuPDF context ------------------------
//
// MuPDF keeps some state in globals (HarfBuzz's context, for one) and
// guards it with the context's locks, so every context in the process must
// share one set of locks. For the same reason a block allocated through one
// context can be freed through another, so every context uses the same
// allocator: each block's header says which budget it was counted against.

static pthread_mutex_t mupdf_mutexes[FZ_LOCK_MAX];
static pthread_once_t mupdf_mutexes_once = PTHREAD_ONCE_INIT;

static void init_mupdf_mutexes(void) {
    for (int i = 0; i < FZ_LOCK_MAX; i++) pthread_mutex_init(&mupdf_mutexes[i], NULL);
}

static void lock_mupdf(void *user, int lock) {
    (void)user;
    pthread_mutex_lock(&mupdf_mutexes[lock]);
}

static void unlock_mupdf(void *user, int lock) {
    (void)user;
    pthread_mutex_unlock(&mupdf_mutexes[lock]);
}

static fz_locks_context *shared_locks(void) {
    static fz_locks_context locks = { NULL, lock_mupdf, unlock_mupdf };
    pthread_once(&mupdf_mutexes_once, init_mupdf_mutexes);
    return &locks;
}

struct opdf_cancel { atomic_int requested; };

#define BLOCK_MAGIC 0x4f504446u
#define BUDGETS 32

typedef struct {
    uint32_t magic;
    int32_t budget;       // -1: not counted
    uint64_t size;
} block_header;           // 16 bytes, which keeps blocks 16-byte aligned
_Static_assert(sizeof(block_header) == 16, "block header size");

// Bytes in use per budget. A block freed after its budget was given up and
// taken again only makes the new holder's count lower, which is harmless.
static atomic_llong budget_used[BUDGETS];
static atomic_int budget_taken[BUDGETS];

// What a context's allocations are counted against (its alloc user data).
typedef struct {
    int budget;           // -1: not counted (documents)
    long long base;       // budget_used when the budget was taken
    long long limit;
    atomic_int over_limit;
    opdf_cancel *cancel;
} allocator_owner;

static allocator_owner uncounted_owner = { .budget = -1 };

static bool owner_cancelled(allocator_owner *o) {
    return o->cancel && atomic_load(&o->cancel->requested);
}

// May this owner have `more` bytes? Cancelled or over the limit: no.
static bool owner_allows(allocator_owner *o, size_t more) {
    if (o->budget < 0) return true;
    if (owner_cancelled(o)) return false;
    long long in_use = atomic_load(&budget_used[o->budget]) - o->base;
    if (more > (size_t)LLONG_MAX || (long long)more > o->limit - in_use) {
        atomic_store(&o->over_limit, 1);
        return false;
    }
    return true;
}

static void *shared_malloc(void *user, size_t size) {
    allocator_owner *o = user;
    if (size > SIZE_MAX - sizeof(block_header) || !owner_allows(o, size)) return NULL;
    block_header *h = malloc(sizeof *h + size);
    if (!h) return NULL;
    *h = (block_header){ BLOCK_MAGIC, o->budget, size };
    if (h->budget >= 0) atomic_fetch_add(&budget_used[h->budget], (long long)size);
    return h + 1;
}

static block_header *header_of(void *ptr) {
    block_header *h = (block_header *)ptr - 1;
    // Every block comes from shared_malloc; anything else is memory corruption.
    if (h->magic != BLOCK_MAGIC) abort();
    return h;
}

static void shared_free(void *user, void *ptr) {
    (void)user;
    if (!ptr) return;
    block_header *h = header_of(ptr);
    if (h->budget >= 0) atomic_fetch_sub(&budget_used[h->budget], (long long)h->size);
    h->magic = 0;
    free(h);
}

static void *shared_realloc(void *user, void *ptr, size_t size) {
    allocator_owner *o = user;
    if (!ptr) return shared_malloc(user, size);
    if (size == 0) {
        shared_free(user, ptr);
        return NULL;
    }
    block_header *h = header_of(ptr);
    size_t old = (size_t)h->size;
    if (size > SIZE_MAX - sizeof(block_header)) return NULL;
    if (size > old && !owner_allows(o, size - old)) return NULL;
    block_header *grown = realloc(h, sizeof *h + size);
    if (!grown) return NULL;
    grown->size = size;
    if (grown->budget >= 0) atomic_fetch_add(&budget_used[grown->budget], (long long)size - (long long)old);
    return grown + 1;
}

// For contexts that hold documents: counted nowhere, never refused.
static fz_alloc_context document_alloc = { &uncounted_owner, shared_malloc, shared_realloc, shared_free };

// MuPDF prints errors and warnings to stderr by default. Errors reach the
// caller through opdf_error, and warnings (repaired files, odd fonts) are
// not actionable, so both are kept off the console.
static void quiet(void *user, const char *message) {
    (void)user;
    (void)message;
}

static void make_quiet(fz_context *ctx) {
    fz_set_error_callback(ctx, quiet, NULL);
    fz_set_warning_callback(ctx, quiet, NULL);
}

static void lock_doc(opdf_doc *doc) { pthread_mutex_lock(&doc->lock); }
static void unlock_doc(opdf_doc *doc) { pthread_mutex_unlock(&doc->lock); }

static fz_context *pool_acquire(opdf_doc *doc, int *slot) {
    pthread_mutex_lock(&doc->pool_lock);
    for (;;) {
        for (int i = 0; i < POOL_SIZE; i++) {
            if (!doc->pool_busy[i]) {
                doc->pool_busy[i] = true;
                *slot = i;
                pthread_mutex_unlock(&doc->pool_lock);
                return doc->pool[i];
            }
        }
        pthread_cond_wait(&doc->pool_cond, &doc->pool_lock);
    }
}

static void pool_release(opdf_doc *doc, int slot) {
    pthread_mutex_lock(&doc->pool_lock);
    doc->pool_busy[slot] = false;
    pthread_cond_signal(&doc->pool_cond);
    pthread_mutex_unlock(&doc->pool_lock);
}

static fz_rect rect_from(opdf_rect r) { return fz_make_rect(r.x0, r.y0, r.x1, r.y1); }
static opdf_rect rect_to(fz_rect r) { return (opdf_rect){ r.x0, r.y0, r.x1, r.y1 }; }

static fz_matrix page_matrix(fz_rect bounds, float scale, int rotation) {
    fz_matrix m = fz_pre_rotate(fz_scale(scale, scale), (float)rotation);
    fz_rect box = fz_transform_rect(bounds, m);
    m.e -= box.x0;
    m.f -= box.y0;
    return m;
}

// --- Documents ---------------------------------------------------------------

void opdf_free(void *pointer) {
    free(pointer);
}

const char *opdf_mupdf_version(void) {
    return FZ_VERSION;
}

opdf_doc *opdf_open(const char *path, opdf_error *err) {
    clear_error(err);
    opdf_doc *d = calloc(1, sizeof *d);
    if (!d) {
        set_message(err, "Out of memory");
        return NULL;
    }
    pthread_mutex_init(&d->lock, NULL);
    pthread_mutex_init(&d->pool_lock, NULL);
    pthread_cond_init(&d->pool_cond, NULL);
    d->ctx = fz_new_context(&document_alloc, shared_locks(), FZ_STORE_DEFAULT);
    if (!d->ctx) {
        set_message(err, "Could not create a MuPDF context");
        opdf_close(d);
        return NULL;
    }
    make_quiet(d->ctx);
    fz_try(d->ctx) {
        fz_register_document_handler(d->ctx, &pdf_document_handler);
        d->doc = fz_open_document(d->ctx, path);
        // Every change is recorded for undo.
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (pdf) pdf_enable_journal(d->ctx, pdf);
    }
    fz_catch(d->ctx) {
        set_error(err, d->ctx);
        opdf_close(d);
        return NULL;
    }
    for (int i = 0; i < POOL_SIZE; i++) {
        d->pool[i] = fz_clone_context(d->ctx);
        if (!d->pool[i]) {
            set_message(err, "Could not create a MuPDF context");
            opdf_close(d);
            return NULL;
        }
        make_quiet(d->pool[i]);
    }
    return d;
}

void opdf_close(opdf_doc *d) {
    if (!d) return;
    for (int i = 0; i < POOL_SIZE; i++)
        if (d->pool[i]) fz_drop_context(d->pool[i]);
    if (d->ctx) {
        fz_drop_document(d->ctx, d->doc);
        fz_drop_context(d->ctx);
    }
    pthread_mutex_destroy(&d->lock);
    pthread_mutex_destroy(&d->pool_lock);
    pthread_cond_destroy(&d->pool_cond);
    free(d);
}

bool opdf_is_pdf(opdf_doc *d) {
    lock_doc(d);
    bool is_pdf = pdf_specifics(d->ctx, d->doc) != NULL;
    unlock_doc(d);
    return is_pdf;
}

bool opdf_needs_password(opdf_doc *d) {
    bool needs = false;
    lock_doc(d);
    fz_try(d->ctx)
        needs = fz_needs_password(d->ctx, d->doc) != 0;
    fz_catch(d->ctx)
        needs = false;
    unlock_doc(d);
    return needs;
}

bool opdf_authenticate(opdf_doc *d, const char *password) {
    bool ok = false;
    lock_doc(d);
    fz_try(d->ctx)
        ok = fz_authenticate_password(d->ctx, d->doc, password) != 0;
    fz_catch(d->ctx)
        ok = false;
    unlock_doc(d);
    return ok;
}

int opdf_page_count(opdf_doc *d, opdf_error *err) {
    clear_error(err);
    int count = -1;
    lock_doc(d);
    fz_try(d->ctx)
        count = fz_count_pages(d->ctx, d->doc);
    fz_catch(d->ctx) {
        set_error(err, d->ctx);
        count = -1;
    }
    unlock_doc(d);
    return count;
}

bool opdf_page_bounds_all(opdf_doc *d, opdf_rect *out, int count, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    bool ok = true;
    lock_doc(d);
    pdf_document *pdf = pdf_specifics(ctx, d->doc);
    for (int i = 0; i < count; i++) {
        fz_page *page = NULL;
        fz_var(page);
        fz_try(ctx) {
            if (pdf) {
                fz_rect box;
                fz_matrix ctm;
                pdf_obj *obj = pdf_lookup_page_obj(ctx, pdf, i);
                pdf_page_obj_transform(ctx, obj, &box, &ctm);
                out[i] = rect_to(fz_transform_rect(box, ctm));
            } else {
                page = fz_load_page(ctx, d->doc, i);
                out[i] = rect_to(fz_bound_page(ctx, page));
            }
        }
        fz_always(ctx)
            fz_drop_page(ctx, page);
        fz_catch(ctx) {
            out[i] = (opdf_rect){ 0, 0, 0, 0 };
            if (fz_caught(ctx) == FZ_ERROR_TRYLATER || fz_caught(ctx) == FZ_ERROR_SYSTEM) {
                set_error(err, ctx);
                ok = false;
                break;
            }
        }
    }
    unlock_doc(d);
    return ok;
}

char *opdf_metadata(opdf_doc *d, const char *key) {
    char *result = NULL;
    char small[512];
    fz_var(result);
    lock_doc(d);
    fz_try(d->ctx) {
        int needed = fz_lookup_metadata(d->ctx, d->doc, key, small, sizeof small);
        if (needed > 0 && (size_t)needed <= sizeof small) {
            result = strdup(small);
        } else if (needed > 0) {
            result = malloc((size_t)needed);
            if (result) fz_lookup_metadata(d->ctx, d->doc, key, result, (size_t)needed);
        }
    }
    fz_catch(d->ctx)
        result = NULL;
    unlock_doc(d);
    if (result && !result[0]) {
        free(result);
        result = NULL;
    }
    return result;
}

opdf_matrix opdf_page_matrix(opdf_rect bounds, float scale, int rotation) {
    fz_matrix m = page_matrix(rect_from(bounds), scale, rotation);
    return (opdf_matrix){ m.a, m.b, m.c, m.d, m.e, m.f };
}

// --- Rendering ---------------------------------------------------------------

static bool is_reply(fz_context *ctx, pdf_annot *annot);

// The page's contents, annotations (but not replies) and form fields.
static fz_display_list *new_display_list(fz_context *ctx, fz_page *page) {
    pdf_page *pp = pdf_page_from_fz_page(ctx, page);
    if (!pp) return fz_new_display_list_from_page(ctx, page);
    fz_display_list *list = fz_new_display_list(ctx, fz_bound_page(ctx, page));
    fz_device *dev = NULL;
    fz_var(dev);
    fz_try(ctx) {
        dev = fz_new_list_device(ctx, list);
        pdf_run_page_contents(ctx, pp, dev, fz_identity, NULL);
        for (pdf_annot *a = pdf_first_annot(ctx, pp); a; a = pdf_next_annot(ctx, a))
            if (!is_reply(ctx, a)) pdf_run_annot(ctx, a, dev, fz_identity, NULL);
        pdf_run_page_widgets(ctx, pp, dev, fz_identity, NULL);
        fz_close_device(ctx, dev);
    }
    fz_always(ctx)
        fz_drop_device(ctx, dev);
    fz_catch(ctx) {
        fz_drop_display_list(ctx, list);
        fz_rethrow(ctx);
    }
    return list;
}

opdf_list *opdf_list_load(opdf_doc *d, int page_number, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    fz_page *page = NULL;
    fz_display_list *list = NULL;
    fz_var(page);
    fz_var(list);
    lock_doc(d);
    fz_try(ctx) {
        page = fz_load_page(ctx, d->doc, page_number);
        list = new_display_list(ctx, page);
    }
    fz_always(ctx)
        fz_drop_page(ctx, page);
    fz_catch(ctx) {
        set_error(err, ctx);
        fz_drop_display_list(ctx, list);
        list = NULL;
    }
    unlock_doc(d);
    return (opdf_list *)list;
}

void opdf_list_drop(opdf_doc *d, opdf_list *list) {
    if (!list) return;
    int slot;
    fz_context *ctx = pool_acquire(d, &slot);
    fz_drop_display_list(ctx, (fz_display_list *)list);
    pool_release(d, slot);
}

opdf_cookie *opdf_cookie_new(void) {
    return calloc(1, sizeof(opdf_cookie));
}

void opdf_cookie_abort(opdf_cookie *cookie) {
    if (cookie) __atomic_store_n(&cookie->cookie.abort, 1, __ATOMIC_RELAXED);
}

void opdf_cookie_free(opdf_cookie *cookie) {
    free(cookie);
}

bool opdf_list_render(opdf_doc *d, opdf_list *list, opdf_rect bounds, float scale, int rotation,
                      int x, int y, int width, int height, unsigned char *samples,
                      opdf_cookie *cookie, opdf_error *err) {
    clear_error(err);
    if (!list || !samples || width <= 0 || height <= 0 || !(scale > 0) || !isfinite(scale)) {
        set_message(err, "Nothing to render");
        return false;
    }
    // Backstop for the caller's limits: no int overflow in the area, and no
    // more than 64 megapixels (the caller allocates width * height * 4).
    if (x < -(INT_MAX / 2) || y < -(INT_MAX / 2) ||
        (int64_t)x + width > INT_MAX || (int64_t)y + height > INT_MAX ||
        (int64_t)width * (int64_t)height > (int64_t)64 * 1024 * 1024) {
        set_message(err, "Render area out of range");
        return false;
    }
    int slot;
    fz_context *ctx = pool_acquire(d, &slot);
    fz_pixmap *pix = NULL;
    fz_device *dev = NULL;
    bool ok = false;
    fz_var(pix);
    fz_var(dev);
    fz_try(ctx) {
        fz_irect area = { x, y, x + width, y + height };
        pix = fz_new_pixmap_with_bbox_and_data(ctx, fz_device_rgb(ctx), area, NULL, 1, samples);
        fz_clear_pixmap_with_value(ctx, pix, 255);
        dev = fz_new_draw_device(ctx, fz_identity, pix);
        fz_run_display_list(ctx, (fz_display_list *)list, dev, page_matrix(rect_from(bounds), scale, rotation),
                            fz_rect_from_irect(area), cookie ? &cookie->cookie : NULL);
        fz_close_device(ctx, dev);
        ok = !(cookie && cookie->cookie.abort);
    }
    fz_always(ctx) {
        fz_drop_device(ctx, dev);
        fz_drop_pixmap(ctx, pix);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        ok = false;
    }
    pool_release(d, slot);
    return ok;
}

// --- Text --------------------------------------------------------------------

typedef struct {
    opdf_char *items;
    int count;
    int capacity;
    int line;
    int block;
    bool failed;
} char_buffer;

static void append_char(char_buffer *buf, fz_stext_char *ch) {
    if (buf->failed) return;
    if (buf->count == buf->capacity) {
        int capacity = buf->capacity ? buf->capacity * 2 : 1024;
        opdf_char *items = realloc(buf->items, (size_t)capacity * sizeof *items);
        if (!items) {
            buf->failed = true;
            return;
        }
        buf->items = items;
        buf->capacity = capacity;
    }
    opdf_char *out = &buf->items[buf->count++];
    out->c = ch->c;
    out->line = buf->line;
    out->block = buf->block;
    fz_quad q = ch->quad;
    float values[8] = { q.ul.x, q.ul.y, q.ur.x, q.ur.y, q.ll.x, q.ll.y, q.lr.x, q.lr.y };
    memcpy(out->quad, values, sizeof values);
}

static void walk_blocks(char_buffer *buf, fz_stext_block *block) {
    for (; block; block = block->next) {
        if (block->type == FZ_STEXT_BLOCK_TEXT) {
            bool any = false;
            for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
                bool line_any = false;
                for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) {
                    append_char(buf, ch);
                    line_any = true;
                }
                if (line_any) {
                    buf->line++;
                    any = true;
                }
            }
            if (any) buf->block++;
        } else if (block->type == FZ_STEXT_BLOCK_STRUCT && block->u.s.down) {
            walk_blocks(buf, block->u.s.down->first_block);
        }
    }
}

opdf_char *opdf_text_load(opdf_doc *d, int page_number, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    fz_page *page = NULL;
    fz_stext_page *text = NULL;
    char_buffer buf = { 0 };
    fz_var(page);
    fz_var(text);
    lock_doc(d);
    fz_try(ctx) {
        fz_stext_options options;
        memset(&options, 0, sizeof options);
        options.flags = FZ_STEXT_CLIP;
        page = fz_load_page(ctx, d->doc, page_number);
        text = fz_new_stext_page_from_page(ctx, page, &options);
        walk_blocks(&buf, text->first_block);
    }
    fz_always(ctx) {
        fz_drop_stext_page(ctx, text);
        fz_drop_page(ctx, page);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        buf.failed = true;
    }
    unlock_doc(d);
    if (buf.failed) {
        if (err && err->code == 0) set_message(err, "Out of memory");
        free(buf.items);
        return NULL;
    }
    *count = buf.count;
    return buf.items;
}

// --- Links -------------------------------------------------------------------

opdf_link *opdf_links_load(opdf_doc *d, int page_number, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    fz_page *page = NULL;
    fz_link *links = NULL;
    opdf_link *result = NULL;
    int n = 0;
    fz_var(page);
    fz_var(links);
    fz_var(result);
    fz_var(n);
    lock_doc(d);
    fz_try(ctx) {
        page = fz_load_page(ctx, d->doc, page_number);
        links = fz_load_links(ctx, page);
        int total = 0;
        for (fz_link *l = links; l; l = l->next) total++;
        if (total > 0) {
            result = calloc((size_t)total, sizeof *result);
            if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
        for (fz_link *l = links; l; l = l->next) {
            if (!l->uri) continue;
            opdf_link *out = &result[n++];
            out->rect = rect_to(l->rect);
            out->uri = dup_string(l->uri);
            out->external = fz_is_external_link(ctx, l->uri) != 0;
            if (pdf_page_from_fz_page(ctx, page)) out->id = pdf_to_num(ctx, ((mupdf_pdf_link *)l)->obj);
            out->page = -1;
            out->x = NAN;
            out->y = NAN;
            if (!out->external) {
                fz_try(ctx) {
                    float x = NAN, y = NAN;
                    fz_location loc = fz_resolve_link(ctx, d->doc, l->uri, &x, &y);
                    if (loc.page >= 0) out->page = fz_page_number_from_location(ctx, d->doc, loc);
                    out->x = x;
                    out->y = y;
                }
                fz_catch(ctx) {
                    out->page = -1;
                }
            }
        }
    }
    fz_always(ctx) {
        fz_drop_link(ctx, links);
        fz_drop_page(ctx, page);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_links_free(result, n);
        result = NULL;
        n = 0;
    }
    unlock_doc(d);
    *count = n;
    return result;
}

void opdf_links_free(opdf_link *links, int count) {
    if (!links) return;
    for (int i = 0; i < count; i++) free(links[i].uri);
    free(links);
}

// A link's address, checked: a web address (http, https, mailto; printable
// ASCII, at most 2048 bytes), or a page of this document.
static char *link_uri(fz_context *ctx, fz_document *doc, const char *uri, int target_page) {
    if (uri) {
        size_t len = strlen(uri);
        if (len == 0 || len > 2048) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That address is empty or too long");
        for (size_t i = 0; i < len; i++)
            if ((unsigned char)uri[i] <= 0x20 || (unsigned char)uri[i] >= 0x7f) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That address has characters a link can't hold");
        size_t scheme = !fz_strncasecmp(uri, "http://", 7) ? 7 : !fz_strncasecmp(uri, "https://", 8) ? 8 : !fz_strncasecmp(uri, "mailto:", 7) ? 7 : 0;
        if (!scheme) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Links can go to web addresses (http, https) and email addresses (mailto) only");
        if (len == scheme) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That address is missing everything after its start");
        return fz_strdup(ctx, uri);
    }
    if (target_page < 0 || target_page >= fz_count_pages(ctx, doc)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "There is no such page");
    return pdf_new_uri_from_explicit_dest(ctx, fz_make_link_dest_xyz(0, target_page, NAN, NAN, NAN));
}

static fz_link *find_link(fz_context *ctx, pdf_page *page, int id) {
    if (id <= 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This link can't be changed");
    for (fz_link *l = page->links; l; l = l->next)
        if (pdf_to_num(ctx, ((mupdf_pdf_link *)l)->obj) == id) return l;
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such link");
}

static fz_rect link_rect(fz_context *ctx, opdf_rect rect) {
    fz_rect r = fz_make_rect(rect.x0, rect.y0, rect.x1, rect.y1);
    if (fz_is_empty_rect(r) || r.x1 - r.x0 > 14400 || r.y1 - r.y0 > 14400) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That link is the wrong size");
    return r;
}

// --- Outline -----------------------------------------------------------------

typedef struct {
    opdf_outline_item *items;
    int count;
    int capacity;
} outline_buffer;

static void walk_outline(fz_context *ctx, fz_document *doc, outline_buffer *buf, fz_outline *node, int depth) {
    for (; node; node = node->next) {
        if (buf->count == buf->capacity) {
            int capacity = buf->capacity ? buf->capacity * 2 : 64;
            opdf_outline_item *items = realloc(buf->items, (size_t)capacity * sizeof *items);
            if (!items) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            buf->items = items;
            buf->capacity = capacity;
        }
        opdf_outline_item *out = &buf->items[buf->count++];
        memset(out, 0, sizeof *out);
        out->title = dup_string(node->title ? node->title : "");
        out->uri = dup_string(node->uri);
        out->depth = depth;
        out->open = node->is_open;
        out->page = -1;
        out->x = node->x;
        out->y = node->y;
        if (node->page.page >= 0) {
            fz_try(ctx)
                out->page = fz_page_number_from_location(ctx, doc, node->page);
            fz_catch(ctx)
                out->page = -1;
        }
        walk_outline(ctx, doc, buf, node->down, depth + 1);
    }
}

// Walks a PDF outline without recursion. False when it is deeper or larger
// than the limits (cycles hit the item limit).
static bool outline_within_limits(fz_context *ctx, pdf_document *pdf) {
    pdf_obj *next_at[MAX_OUTLINE_DEPTH];
    int depth = 0, items = 0;
    pdf_obj *node = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/Outlines/First");
    while (node) {
        if (++items > MAX_OUTLINE_ITEMS) return false;
        pdf_obj *child = pdf_dict_get(ctx, node, PDF_NAME(First));
        if (child) {
            if (depth + 1 >= MAX_OUTLINE_DEPTH) return false;
            next_at[depth++] = pdf_dict_get(ctx, node, PDF_NAME(Next));
            node = child;
            continue;
        }
        node = pdf_dict_get(ctx, node, PDF_NAME(Next));
        while (!node && depth > 0) node = next_at[--depth];
    }
    return true;
}

opdf_outline_item *opdf_outline_load(opdf_doc *d, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    fz_outline *outline = NULL;
    outline_buffer buf = { 0 };
    fz_var(outline);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (pdf && !outline_within_limits(ctx, pdf))
            fz_throw(ctx, FZ_ERROR_LIMIT, "The outline is nested too deeply to show");
        outline = fz_load_outline(ctx, d->doc);
        walk_outline(ctx, d->doc, &buf, outline, 0);
    }
    fz_always(ctx)
        fz_drop_outline(ctx, outline);
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_outline_free(buf.items, buf.count);
        buf.items = NULL;
        buf.count = 0;
    }
    unlock_doc(d);
    *count = buf.count;
    return buf.items;
}

void opdf_outline_free(opdf_outline_item *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) {
        free(items[i].title);
        free(items[i].uri);
    }
    free(items);
}

// --- Attachments -------------------------------------------------------------

opdf_attachment *opdf_attachments_load(opdf_doc *d, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    pdf_obj *tree = NULL;
    opdf_attachment *result = NULL;
    int n = 0;
    fz_var(tree);
    fz_var(result);
    fz_var(n);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (pdf) {
            tree = pdf_load_name_tree(ctx, pdf, PDF_NAME(EmbeddedFiles));
            int total = pdf_dict_len(ctx, tree);
            if (total > 0) {
                result = calloc((size_t)total, sizeof *result);
                if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
            }
            for (int i = 0; i < total; i++) {
                pdf_obj *fs = pdf_dict_get_val(ctx, tree, i);
                if (!pdf_is_embedded_file(ctx, fs)) continue;
                pdf_filespec_params params;
                pdf_get_filespec_params(ctx, fs, &params);
                opdf_attachment *out = &result[n++];
                out->name = dup_string(pdf_to_name(ctx, pdf_dict_get_key(ctx, tree, i)));
                out->filename = dup_string(params.filename);
                out->mimetype = dup_string(params.mimetype);
                out->size = params.size;
                out->created = params.created;
                out->modified = params.modified;
            }
        }
    }
    fz_always(ctx)
        pdf_drop_obj(ctx, tree);
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_attachments_free(result, n);
        result = NULL;
        n = 0;
    }
    unlock_doc(d);
    *count = n;
    return result;
}

void opdf_attachments_free(opdf_attachment *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) {
        free(items[i].name);
        free(items[i].filename);
        free(items[i].mimetype);
    }
    free(items);
}

bool opdf_attachment_save(opdf_doc *d, const char *name, const char *path, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    pdf_obj *tree = NULL;
    fz_buffer *contents = NULL;
    bool ok = false;
    fz_var(tree);
    fz_var(contents);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        tree = pdf_load_name_tree(ctx, pdf, PDF_NAME(EmbeddedFiles));
        pdf_obj *fs = NULL;
        int total = pdf_dict_len(ctx, tree);
        for (int i = 0; i < total && !fs; i++) {
            const char *key = pdf_to_name(ctx, pdf_dict_get_key(ctx, tree, i));
            if (key && strcmp(key, name) == 0) fs = pdf_dict_get_val(ctx, tree, i);
        }
        if (!fs || !pdf_is_embedded_file(ctx, fs)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such attachment");
        contents = pdf_load_embedded_file_contents(ctx, fs);
        fz_save_buffer(ctx, contents, path);
        ok = true;
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, contents);
        pdf_drop_obj(ctx, tree);
    }
    fz_catch(ctx)
        set_error(err, ctx);
    unlock_doc(d);
    return ok;
}

// --- Layers ------------------------------------------------------------------

opdf_layer *opdf_layers_load(opdf_doc *d, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    opdf_layer *result = NULL;
    int n = 0;
    fz_var(result);
    fz_var(n);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        int total = pdf ? pdf_count_layer_config_ui(ctx, pdf) : 0;
        if (total > 0) {
            result = calloc((size_t)total, sizeof *result);
            if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        }
        for (int i = 0; i < total; i++) {
            pdf_layer_config_ui info;
            memset(&info, 0, sizeof info);
            pdf_layer_config_ui_info(ctx, pdf, i, &info);
            opdf_layer *out = &result[n++];
            out->text = dup_string(info.text ? info.text : "");
            out->depth = info.depth;
            out->type = (int)info.type;
            out->selected = info.selected != 0;
            out->locked = info.locked != 0;
        }
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_layers_free(result, n);
        result = NULL;
        n = 0;
    }
    unlock_doc(d);
    *count = n;
    return result;
}

void opdf_layers_free(opdf_layer *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) free(items[i].text);
    free(items);
}

bool opdf_layer_toggle(opdf_doc *d, int index, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    bool ok = false;
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        pdf_layer_config_ui info;
        memset(&info, 0, sizeof info);
        pdf_layer_config_ui_info(ctx, pdf, index, &info);
        if (info.locked) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This layer is locked");
        if (info.type == PDF_LAYER_UI_RADIOBOX)
            pdf_select_layer_config_ui(ctx, pdf, index);
        else if (info.type == PDF_LAYER_UI_CHECKBOX)
            pdf_toggle_layer_config_ui(ctx, pdf, index);
        ok = true;
    }
    fz_catch(ctx)
        set_error(err, ctx);
    unlock_doc(d);
    return ok;
}

// --- Annotations ---------------------------------------------------------------

static void *checked_calloc(fz_context *ctx, size_t count, size_t size) {
    void *p = calloc(count ? count : 1, size);
    if (!p) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    return p;
}

// Replies and review statuses: Text annotations "in reply to" another
// (not those grouped with it). Listed, but not drawn on the page.
static bool is_reply(fz_context *ctx, pdf_annot *annot) {
    pdf_obj *obj = pdf_annot_obj(ctx, annot);
    if (!pdf_dict_get(ctx, obj, PDF_NAME(IRT))) return false;
    if (pdf_name_eq(ctx, pdf_dict_get(ctx, obj, PDF_NAME(RT)), PDF_NAME(Group))) return false;
    return pdf_annot_type(ctx, annot) == PDF_ANNOT_TEXT;
}

static bool listed_type(int type) {
    return type != PDF_ANNOT_LINK && type != PDF_ANNOT_POPUP && type != PDF_ANNOT_WIDGET;
}

// The annotation's rectangle, or for markup without one, its drawn bounds.
static fz_rect annot_rect(fz_context *ctx, pdf_annot *annot) {
    return pdf_annot_has_rect(ctx, annot) ? pdf_annot_rect(ctx, annot) : pdf_bound_annot(ctx, annot);
}

static int annot_id(fz_context *ctx, pdf_annot *annot) {
    return pdf_to_num(ctx, pdf_annot_obj(ctx, annot));
}

static pdf_annot *find_annot(fz_context *ctx, pdf_page *page, int id) {
    if (id <= 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This annotation can't be changed");
    for (pdf_annot *a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a))
        if (annot_id(ctx, a) == id) return a;
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such annotation");
}

static pdf_page *load_pdf_page(fz_context *ctx, fz_document *doc, int number) {
    fz_page *page = fz_load_page(ctx, doc, number);
    pdf_page *pdf = pdf_page_from_fz_page(ctx, page);
    if (!pdf) {
        fz_drop_page(ctx, page);
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF page");
    }
    return pdf;
}

static void fill_annot(fz_context *ctx, pdf_annot *a, opdf_annot *o, int *budget) {
    pdf_obj *obj = pdf_annot_obj(ctx, a);
    o->id = annot_id(ctx, a);
    o->read_only = o->id == 0;
    o->type = pdf_annot_type(ctx, a);
    o->rect = rect_to(annot_rect(ctx, a));
    pdf_annot_color(ctx, a, &o->color_n, o->color);
    if (pdf_annot_has_interior_color(ctx, a)) pdf_annot_interior_color(ctx, a, &o->interior_n, o->interior);
    o->opacity = pdf_annot_opacity(ctx, a);
    o->border_width = pdf_annot_has_border(ctx, a) ? pdf_annot_border_width(ctx, a) : 0;
    o->flags = pdf_annot_flags(ctx, a);
    o->contents = dup_string(pdf_annot_contents(ctx, a));
    if (pdf_annot_has_author(ctx, a)) o->author = dup_string(pdf_annot_author(ctx, a));
    if (pdf_annot_has_subject(ctx, a)) o->subject = dup_string(pdf_annot_subject(ctx, a));
    if (pdf_annot_has_icon_name(ctx, a)) o->icon_name = dup_string(pdf_annot_icon_name(ctx, a));
    o->modified = pdf_annot_modification_date(ctx, a);
    o->created = pdf_annot_creation_date(ctx, a);
    pdf_obj *irt = pdf_dict_get(ctx, obj, PDF_NAME(IRT));
    if (irt) o->in_reply_to = pdf_to_num(ctx, irt);
    pdf_obj *state = pdf_dict_gets(ctx, obj, "State");
    if (state) o->state = dup_string(pdf_to_text_string(ctx, state));
    pdf_obj *model = pdf_dict_gets(ctx, obj, "StateModel");
    if (model) o->state_model = dup_string(pdf_to_text_string(ctx, model));

    if (pdf_annot_has_quad_points(ctx, a)) {
        int n = pdf_annot_quad_point_count(ctx, a);
        if (n > OPDF_MAX_QUADS || n > *budget) {
            n = n > OPDF_MAX_QUADS ? OPDF_MAX_QUADS : n;
            if (n > *budget) n = *budget > 0 ? *budget : 0;
            o->read_only = true;
        }
        *budget -= n;
        if (n > 0) {
            o->quads = checked_calloc(ctx, (size_t)n * 8, sizeof(float));
            o->quad_count = n;
            for (int i = 0; i < n; i++) {
                fz_quad q = pdf_annot_quad_point(ctx, a, i);
                float v[8] = { q.ul.x, q.ul.y, q.ur.x, q.ur.y, q.ll.x, q.ll.y, q.lr.x, q.lr.y };
                memcpy(&o->quads[i * 8], v, sizeof v);
            }
        }
    }
    if (pdf_annot_has_ink_list(ctx, a)) {
        int strokes = pdf_annot_ink_list_count(ctx, a);
        if (strokes > OPDF_MAX_INK_STROKES) {
            strokes = OPDF_MAX_INK_STROKES;
            o->read_only = true;
        }
        if (strokes > 0) {
            o->ink_counts = checked_calloc(ctx, (size_t)strokes, sizeof(int));
            o->ink_stroke_count = strokes;
            // Points are counted against this annotation's and the page's limits.
            int allowed = *budget < OPDF_MAX_INK_POINTS ? *budget : OPDF_MAX_INK_POINTS;
            if (allowed < 0) allowed = 0;
            size_t total = 0;
            for (int i = 0; i < strokes; i++) {
                int n = pdf_annot_ink_list_stroke_count(ctx, a, i);
                if (n < 0) n = 0;
                if ((size_t)n > (size_t)allowed - total) {
                    n = (int)((size_t)allowed - total);
                    o->read_only = true;
                }
                o->ink_counts[i] = n;
                total += (size_t)n;
            }
            *budget -= (int)total;
            o->ink_points = checked_calloc(ctx, total * 2, sizeof(float));
            size_t k = 0;
            for (int i = 0; i < strokes; i++)
                for (int j = 0; j < o->ink_counts[i]; j++) {
                    fz_point p = pdf_annot_ink_list_stroke_vertex(ctx, a, i, j);
                    o->ink_points[k++] = p.x;
                    o->ink_points[k++] = p.y;
                }
        }
    }
    if (pdf_annot_has_line(ctx, a)) {
        fz_point p0, p1;
        pdf_annot_line(ctx, a, &p0, &p1);
        o->has_line = true;
        o->line[0] = p0.x; o->line[1] = p0.y; o->line[2] = p1.x; o->line[3] = p1.y;
        if (pdf_annot_has_line_ending_styles(ctx, a)) {
            enum pdf_line_ending s, e;
            pdf_annot_line_ending_styles(ctx, a, &s, &e);
            o->line_start = (int)s;
            o->line_end = (int)e;
        }
    }
    if (o->type == PDF_ANNOT_FREE_TEXT) {
        const char *font = NULL;
        pdf_annot_default_appearance(ctx, a, &font, &o->font_size, &o->text_color_n, o->text_color);
    }
}

opdf_annot *opdf_annots_load(opdf_doc *d, int page_number, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    fz_page *page = NULL;
    opdf_annot *items = NULL;
    int n = 0, capacity = 0;
    fz_var(page);
    fz_var(items);
    fz_var(n);
    fz_var(capacity);
    lock_doc(d);
    fz_try(ctx) {
        page = fz_load_page(ctx, d->doc, page_number);
        pdf_page *pp = pdf_page_from_fz_page(ctx, page);
        int budget = OPDF_MAX_PAGE_POINTS;
        for (pdf_annot *a = pp ? pdf_first_annot(ctx, pp) : NULL; a && n < OPDF_MAX_ANNOTS_PER_PAGE; a = pdf_next_annot(ctx, a)) {
            if (!listed_type(pdf_annot_type(ctx, a))) continue;
            // An object listed twice in /Annots is listed here once.
            int id = annot_id(ctx, a);
            bool seen = false;
            for (int i = 0; i < n && id != 0 && !seen; i++) seen = items[i].id == id;
            if (seen) continue;
            if (n == capacity) {
                int grown = capacity ? capacity * 2 : 16;
                opdf_annot *bigger = realloc(items, (size_t)grown * sizeof *items);
                if (!bigger) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
                items = bigger;
                capacity = grown;
            }
            memset(&items[n], 0, sizeof items[n]);
            n++;
            fill_annot(ctx, a, &items[n - 1], &budget);
        }
    }
    fz_always(ctx)
        fz_drop_page(ctx, page);
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_annots_free(items, n);
        items = NULL;
        n = 0;
    }
    unlock_doc(d);
    *count = n;
    return items;
}

void opdf_annots_free(opdf_annot *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) {
        opdf_annot *o = &items[i];
        free(o->contents);
        free(o->author);
        free(o->subject);
        free(o->icon_name);
        free(o->state);
        free(o->state_model);
        free(o->quads);
        free(o->ink_counts);
        free(o->ink_points);
    }
    free(items);
}

static void apply_spec(fz_context *ctx, pdf_annot *a, const opdf_annot_spec *s, unsigned fields) {
    if ((fields & OPDF_FIELD_QUADS) && pdf_annot_has_quad_points(ctx, a) && s->quad_count > 0 && s->quads)
        pdf_set_annot_quad_points(ctx, a, s->quad_count, (const fz_quad *)s->quads);
    if ((fields & OPDF_FIELD_INK) && pdf_annot_has_ink_list(ctx, a) && s->ink_stroke_count > 0 && s->ink_counts && s->ink_points)
        pdf_set_annot_ink_list(ctx, a, s->ink_stroke_count, s->ink_counts, (const fz_point *)s->ink_points);
    if ((fields & OPDF_FIELD_LINE) && pdf_annot_has_line(ctx, a))
        pdf_set_annot_line(ctx, a, fz_make_point(s->line[0], s->line[1]), fz_make_point(s->line[2], s->line[3]));
    if ((fields & OPDF_FIELD_LINE_ENDINGS) && pdf_annot_has_line_ending_styles(ctx, a))
        pdf_set_annot_line_ending_styles(ctx, a, (enum pdf_line_ending)s->line_start, (enum pdf_line_ending)s->line_end);
    if ((fields & OPDF_FIELD_RECT) && pdf_annot_has_rect(ctx, a))
        pdf_set_annot_rect(ctx, a, rect_from(s->rect));
    if (fields & OPDF_FIELD_COLOR)
        pdf_set_annot_color(ctx, a, s->color_n, s->color);
    if ((fields & OPDF_FIELD_INTERIOR) && pdf_annot_has_interior_color(ctx, a))
        pdf_set_annot_interior_color(ctx, a, s->interior_n, s->interior);
    if (fields & OPDF_FIELD_OPACITY)
        pdf_set_annot_opacity(ctx, a, fz_clamp(s->opacity, 0, 1));
    if ((fields & OPDF_FIELD_BORDER) && pdf_annot_has_border(ctx, a))
        pdf_set_annot_border_width(ctx, a, fz_clamp(s->border_width, 0, 100));
    if (fields & OPDF_FIELD_CONTENTS)
        pdf_set_annot_contents(ctx, a, s->contents ? s->contents : "");
    if ((fields & OPDF_FIELD_AUTHOR) && pdf_annot_has_author(ctx, a) && s->author)
        pdf_set_annot_author(ctx, a, s->author);
    if ((fields & OPDF_FIELD_ICON) && pdf_annot_has_icon_name(ctx, a) && s->icon_name)
        pdf_set_annot_icon_name(ctx, a, s->icon_name);
    if ((fields & OPDF_FIELD_FONT) && pdf_annot_type(ctx, a) == PDF_ANNOT_FREE_TEXT)
        pdf_set_annot_default_appearance(ctx, a, "Helv", fz_clamp(s->font_size, 4, 144), 3, s->text_color);
    pdf_set_annot_modification_date(ctx, a, (int64_t)time(NULL));
}

// Runs `body` inside one journal operation on a loaded PDF page, with the
// document locked; abandons the operation if anything throws.
#define WITH_PAGE_OPERATION(d, page_number, operation, err, ...) \
    do { \
        fz_context *ctx = (d)->ctx; \
        pdf_page *pp = NULL; \
        int began = 0; \
        fz_var(pp); \
        fz_var(began); \
        lock_doc(d); \
        fz_try(ctx) { \
            pdf_document *pdf = pdf_specifics(ctx, (d)->doc); \
            if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF"); \
            pp = load_pdf_page(ctx, (d)->doc, (page_number)); \
            pdf_begin_operation(ctx, pdf, (operation) ? (operation) : "Edit"); \
            began = 1; \
            __VA_ARGS__ \
            pdf_update_page(ctx, pp); \
            pdf_end_operation(ctx, pdf); \
            began = 0; \
        } \
        fz_always(ctx) \
            fz_drop_page(ctx, (fz_page *)pp); \
        fz_catch(ctx) { \
            set_error((err), ctx); \
            if (began) { \
                fz_try(ctx) pdf_abandon_operation(ctx, pdf_specifics(ctx, (d)->doc)); \
                fz_catch(ctx) {} \
            } \
        } \
        unlock_doc(d); \
    } while (0)

int opdf_annot_create(opdf_doc *d, int page_number, const opdf_annot_spec *spec, unsigned fields,
                      const char *operation, opdf_error *err) {
    clear_error(err);
    int id = 0;
    pdf_annot *annot = NULL;
    fz_var(id);
    fz_var(annot);
    WITH_PAGE_OPERATION(d, page_number, operation, err, {
        annot = pdf_create_annot(ctx, pp, (enum pdf_annot_type)spec->type);
        fz_try(ctx) {
            apply_spec(ctx, annot, spec, fields);
            pdf_update_annot(ctx, annot);
            id = annot_id(ctx, annot);
        }
        fz_always(ctx) {
            pdf_drop_annot(ctx, annot);
            annot = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    if (err && err->code) id = 0;
    return id;
}

bool opdf_annot_update(opdf_doc *d, int page_number, int id, const opdf_annot_spec *spec, unsigned fields,
                       const char *operation, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, operation, err, {
        pdf_annot *a = find_annot(ctx, pp, id);
        apply_spec(ctx, a, spec, fields);
        pdf_update_annot(ctx, a);
    });
    return !(err && err->code);
}

bool opdf_annot_transform(opdf_doc *d, int page_number, int id, opdf_matrix matrix, const char *operation, opdf_error *err) {
    clear_error(err);
    fz_matrix m = { matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f };
    fz_quad *quads = NULL;
    int *counts = NULL;
    fz_point *points = NULL;
    fz_var(quads);
    fz_var(counts);
    fz_var(points);
    WITH_PAGE_OPERATION(d, page_number, operation, err, {
        pdf_annot *a = find_annot(ctx, pp, id);
        if (pdf_annot_has_quad_points(ctx, a) && pdf_annot_quad_point_count(ctx, a) > OPDF_MAX_QUADS)
            fz_throw(ctx, FZ_ERROR_LIMIT, "This annotation is too large to change");
        if (pdf_annot_has_ink_list(ctx, a)) {
            int strokes = pdf_annot_ink_list_count(ctx, a), points = 0;
            if (strokes > OPDF_MAX_INK_STROKES) fz_throw(ctx, FZ_ERROR_LIMIT, "This annotation is too large to change");
            for (int i = 0; i < strokes; i++) {
                int c = pdf_annot_ink_list_stroke_count(ctx, a, i);
                if (c < 0 || c > OPDF_MAX_INK_POINTS - points) fz_throw(ctx, FZ_ERROR_LIMIT, "This annotation is too large to change");
                points += c;
            }
        }
        if (pdf_annot_has_vertices(ctx, a) && pdf_annot_vertex_count(ctx, a) > OPDF_MAX_INK_POINTS)
            fz_throw(ctx, FZ_ERROR_LIMIT, "This annotation is too large to change");
        if (pdf_annot_has_quad_points(ctx, a)) {
            int n = pdf_annot_quad_point_count(ctx, a);
            if (n > 0) {
                quads = checked_calloc(ctx, (size_t)n, sizeof *quads);
                for (int i = 0; i < n; i++) quads[i] = fz_transform_quad(pdf_annot_quad_point(ctx, a, i), m);
                pdf_set_annot_quad_points(ctx, a, n, quads);
            }
        }
        if (pdf_annot_has_ink_list(ctx, a)) {
            int strokes = pdf_annot_ink_list_count(ctx, a);
            if (strokes > 0) {
                counts = checked_calloc(ctx, (size_t)strokes, sizeof *counts);
                size_t total = 0;
                for (int i = 0; i < strokes; i++) {
                    counts[i] = pdf_annot_ink_list_stroke_count(ctx, a, i);
                    total += (size_t)(counts[i] > 0 ? counts[i] : 0);
                }
                points = checked_calloc(ctx, total, sizeof *points);
                size_t k = 0;
                for (int i = 0; i < strokes; i++)
                    for (int j = 0; j < counts[i]; j++)
                        points[k++] = fz_transform_point(pdf_annot_ink_list_stroke_vertex(ctx, a, i, j), m);
                pdf_set_annot_ink_list(ctx, a, strokes, counts, points);
            }
        }
        if (pdf_annot_has_line(ctx, a)) {
            fz_point p0, p1;
            pdf_annot_line(ctx, a, &p0, &p1);
            pdf_set_annot_line(ctx, a, fz_transform_point(p0, m), fz_transform_point(p1, m));
        }
        if (pdf_annot_has_vertices(ctx, a)) {
            int n = pdf_annot_vertex_count(ctx, a);
            for (int i = 0; i < n; i++)
                pdf_set_annot_vertex(ctx, a, i, fz_transform_point(pdf_annot_vertex(ctx, a, i), m));
        }
        if (pdf_annot_has_rect(ctx, a))
            pdf_set_annot_rect(ctx, a, fz_transform_rect(pdf_annot_rect(ctx, a), m));
        pdf_set_annot_modification_date(ctx, a, (int64_t)time(NULL));
        pdf_update_annot(ctx, a);
    });
    free(quads);
    free(counts);
    free(points);
    return !(err && err->code);
}

bool opdf_annot_delete(opdf_doc *d, int page_number, int id, const char *operation, opdf_error *err) {
    clear_error(err);
    pdf_annot **annots = NULL;
    int *parent = NULL;
    bool *doomed = NULL;
    fz_var(annots);
    fz_var(parent);
    fz_var(doomed);
    WITH_PAGE_OPERATION(d, page_number, operation, err, {
        (void)find_annot(ctx, pp, id);
        // The annotation, its replies, their replies, ...: each annotation's
        // parent is found once, then marks spread down level by level.
        int n = 0;
        for (pdf_annot *a = pdf_first_annot(ctx, pp); a; a = pdf_next_annot(ctx, a)) n++;
        annots = checked_calloc(ctx, (size_t)n, sizeof *annots);
        parent = checked_calloc(ctx, (size_t)n, sizeof *parent);
        doomed = checked_calloc(ctx, (size_t)n, sizeof *doomed);
        int *ids = checked_calloc(ctx, (size_t)n, sizeof *ids);
        int *irt = checked_calloc(ctx, (size_t)n, sizeof *irt);
        int i = 0;
        for (pdf_annot *a = pdf_first_annot(ctx, pp); a && i < n; a = pdf_next_annot(ctx, a), i++) {
            annots[i] = a;
            ids[i] = annot_id(ctx, a);
            irt[i] = pdf_to_num(ctx, pdf_dict_get(ctx, pdf_annot_obj(ctx, a), PDF_NAME(IRT)));
            doomed[i] = ids[i] == id;
        }
        // Parent indices through a sorted copy of the ids: O(n log n).
        int *order = checked_calloc(ctx, (size_t)n, sizeof *order);
        for (i = 0; i < n; i++) order[i] = i;
        for (int gap = n / 2; gap > 0; gap /= 2)   // shell sort by id
            for (i = gap; i < n; i++)
                for (int j = i; j >= gap && ids[order[j - gap]] > ids[order[j]]; j -= gap) {
                    int t = order[j]; order[j] = order[j - gap]; order[j - gap] = t;
                }
        for (i = 0; i < n; i++) {
            parent[i] = -1;
            if (irt[i] <= 0) continue;
            int lo = 0, hi = n - 1;
            while (lo <= hi) {
                int mid = (lo + hi) / 2, v = ids[order[mid]];
                if (v == irt[i]) { parent[i] = order[mid]; break; }
                if (v < irt[i]) lo = mid + 1; else hi = mid - 1;
            }
        }
        free(order);
        free(ids);
        free(irt);
        // Each pass marks one more level; a chain of n needs at most n passes,
        // and cycles stop when nothing changes.
        bool changed = true;
        for (int pass = 0; changed && pass <= n; pass++) {
            changed = false;
            for (i = 0; i < n; i++)
                if (!doomed[i] && parent[i] >= 0 && doomed[parent[i]]) {
                    doomed[i] = true;
                    changed = true;
                }
        }
        for (i = n - 1; i >= 0; i--)
            if (doomed[i]) pdf_delete_annot(ctx, pp, annots[i]);
    });
    free(annots);
    free(parent);
    free(doomed);
    return !(err && err->code);
}

int opdf_annot_reply(opdf_doc *d, int page_number, int parent, const char *author, const char *contents, opdf_error *err) {
    clear_error(err);
    int id = 0;
    pdf_annot *reply = NULL;
    fz_var(id);
    fz_var(reply);
    WITH_PAGE_OPERATION(d, page_number, "Reply", err, {
        pdf_annot *p = find_annot(ctx, pp, parent);
        fz_rect r = annot_rect(ctx, p);
        reply = pdf_create_annot(ctx, pp, PDF_ANNOT_TEXT);
        fz_try(ctx) {
            pdf_set_annot_rect(ctx, reply, fz_make_rect(r.x0, r.y0, r.x0 + 20, r.y0 + 20));
            pdf_set_annot_contents(ctx, reply, contents ? contents : "");
            if (author) pdf_set_annot_author(ctx, reply, author);
            pdf_dict_put(ctx, pdf_annot_obj(ctx, reply), PDF_NAME(IRT), pdf_annot_obj(ctx, p));
            pdf_set_annot_modification_date(ctx, reply, (int64_t)time(NULL));
            pdf_update_annot(ctx, reply);
            id = annot_id(ctx, reply);
        }
        fz_always(ctx) {
            pdf_drop_annot(ctx, reply);
            reply = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    if (err && err->code) id = 0;
    return id;
}

bool opdf_annot_set_status(opdf_doc *d, int page_number, int parent, const char *author, const char *state, opdf_error *err) {
    clear_error(err);
    pdf_annot *created = NULL;
    fz_var(created);
    WITH_PAGE_OPERATION(d, page_number, "Set Status", err, {
        pdf_annot *p = find_annot(ctx, pp, parent);
        const char *who = author ? author : "";
        // This author's existing review status, if any.
        pdf_annot *existing = NULL;
        for (pdf_annot *a = pdf_first_annot(ctx, pp); a && !existing; a = pdf_next_annot(ctx, a)) {
            pdf_obj *obj = pdf_annot_obj(ctx, a);
            if (pdf_to_num(ctx, pdf_dict_get(ctx, obj, PDF_NAME(IRT))) != parent) continue;
            pdf_obj *model = pdf_dict_gets(ctx, obj, "StateModel");
            if (!model || strcmp(pdf_to_text_string(ctx, model), "Review") != 0) continue;
            const char *by = pdf_annot_has_author(ctx, a) ? pdf_annot_author(ctx, a) : "";
            if (strcmp(by ? by : "", who) == 0) existing = a;
        }
        if (!state || !state[0]) {
            if (existing) pdf_delete_annot(ctx, pp, existing);
        } else {
            pdf_annot *target = existing;
            if (!target) {
                // Held by the page's annotation list too; this reference is
                // dropped below, or when the operation fails.
                created = pdf_create_annot(ctx, pp, PDF_ANNOT_TEXT);
                target = created;
                fz_rect r = annot_rect(ctx, p);
                pdf_set_annot_rect(ctx, target, fz_make_rect(r.x0, r.y0, r.x0 + 20, r.y0 + 20));
                pdf_set_annot_author(ctx, target, who);
                pdf_dict_put(ctx, pdf_annot_obj(ctx, target), PDF_NAME(IRT), pdf_annot_obj(ctx, p));
                pdf_dict_puts_drop(ctx, pdf_annot_obj(ctx, target), "StateModel", pdf_new_text_string(ctx, "Review"));
                pdf_set_annot_flags(ctx, target, PDF_ANNOT_IS_HIDDEN | PDF_ANNOT_IS_NO_VIEW | PDF_ANNOT_IS_PRINT);
            }
            fz_try(ctx) {
                pdf_dict_puts_drop(ctx, pdf_annot_obj(ctx, target), "State", pdf_new_text_string(ctx, state));
                char text[256];
                fz_snprintf(text, sizeof text, "%s set by %s", state, who);
                pdf_set_annot_contents(ctx, target, text);
                pdf_set_annot_modification_date(ctx, target, (int64_t)time(NULL));
                pdf_update_annot(ctx, target);
            }
            fz_always(ctx) {
                if (created) pdf_drop_annot(ctx, created);
                created = NULL;
            }
            fz_catch(ctx)
                fz_rethrow(ctx);
        }
    });
    return !(err && err->code);
}

// --- Editing links ----------------------------------------------------------------

int opdf_link_create(opdf_doc *d, int page_number, opdf_rect rect, const char *uri, int target_page, opdf_error *err) {
    clear_error(err);
    int id = 0;
    char *target = NULL;
    fz_link *link = NULL;
    fz_var(id);
    fz_var(target);
    fz_var(link);
    WITH_PAGE_OPERATION(d, page_number, "New Link", err, {
        fz_try(ctx) {
            fz_rect r = link_rect(ctx, rect);
            target = link_uri(ctx, d->doc, uri, target_page);
            link = pdf_create_link(ctx, pp, r, target);
            id = pdf_to_num(ctx, ((mupdf_pdf_link *)link)->obj);
            if (id == 0) id = pdf_obj_parent_num(ctx, ((mupdf_pdf_link *)link)->obj);
        }
        fz_always(ctx) {
            fz_drop_link(ctx, link);
            link = NULL;
            fz_free(ctx, target);
            target = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    if (err && err->code) id = 0;
    return id;
}

bool opdf_link_update(opdf_doc *d, int page_number, int id, opdf_rect rect, bool retarget, const char *uri, int target_page,
                      opdf_error *err) {
    clear_error(err);
    char *target = NULL;
    fz_var(target);
    WITH_PAGE_OPERATION(d, page_number, "Change Link", err, {
        fz_try(ctx) {
            fz_link *link = find_link(ctx, pp, id);
            pdf_obj *obj = ((mupdf_pdf_link *)link)->obj;
            // MuPDF's pdf_set_link_rect doesn't map page space to PDF
            // space; /Rect is written here as pdf_create_link writes it.
            fz_rect mediabox;
            fz_matrix ctm;
            pdf_page_transform(ctx, pp, &mediabox, &ctm);
            fz_rect r = link_rect(ctx, rect);
            pdf_dict_put_rect(ctx, obj, PDF_NAME(Rect), fz_transform_rect(r, fz_invert_matrix(ctm)));
            link->rect = r;
            if (retarget) {
                target = link_uri(ctx, d->doc, uri, target_page);
                pdf_dict_put_drop(ctx, obj, PDF_NAME(A), pdf_new_action_from_link(ctx, pdf, target));
                pdf_dict_del(ctx, obj, PDF_NAME(Dest));
            }
        }
        fz_always(ctx) {
            fz_free(ctx, target);
            target = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    return !(err && err->code);
}

bool opdf_link_delete(opdf_doc *d, int page_number, int id, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Delete Link", err, {
        pdf_delete_link(ctx, pp, find_link(ctx, pp, id));
    });
    return !(err && err->code);
}

// --- Form fields ---------------------------------------------------------------

// Bytes of names, values and options listed for one page, so a crafted file
// can't make the app copy without bound.
// Each string also costs a fixed amount, so empty ones count too.
#define OPDF_MAX_PAGE_FIELD_BYTES (2 << 20)
#define OPDF_FIELD_STRING_COST 32

// Object numbers seen, in an open-addressed hash set.
typedef struct {
    int *slots;     // number + 1; 0 is empty
    int capacity;   // a power of two
    int count;
} num_set;

static void num_set_free(num_set *set) {
    free(set->slots);
    *set = (num_set){ 0 };
}

static bool num_set_contains(const num_set *set, int num) {
    if (!set->capacity) return false;
    for (unsigned i = (unsigned)num * 2654435761u; ; i++) {
        int slot = set->slots[i & (unsigned)(set->capacity - 1)];
        if (slot == 0) return false;
        if (slot == num + 1) return true;
    }
}

// Adds num; false if it was already there.
static bool num_set_add(fz_context *ctx, num_set *set, int num) {
    if (num_set_contains(set, num)) return false;
    if ((set->count + 1) * 2 > set->capacity) {
        int grown = set->capacity ? set->capacity * 2 : 256;
        int *slots = calloc((size_t)grown, sizeof *slots);
        if (!slots) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        for (int i = 0; i < set->capacity; i++) {
            int slot = set->slots[i];
            if (!slot) continue;
            unsigned j = (unsigned)(slot - 1) * 2654435761u;
            while (slots[j & (unsigned)(grown - 1)]) j++;
            slots[j & (unsigned)(grown - 1)] = slot;
        }
        free(set->slots);
        set->slots = slots;
        set->capacity = grown;
    }
    unsigned j = (unsigned)num * 2654435761u;
    while (set->slots[j & (unsigned)(set->capacity - 1)]) j++;
    set->slots[j & (unsigned)(set->capacity - 1)] = num + 1;
    set->count++;
    return true;
}

// Field trees (/Fields and /Kids) are checked before MuPDF walks them: its
// own walks recurse without noticing a field that is its own descendant,
// or one reached twice (which makes them exponential). A tree is accepted
// when it has at most FIELD_TREE_BUDGET nodes, none reached twice, none
// deeper than 64.
#define FIELD_TREE_BUDGET 20000

static bool walk_field(fz_context *ctx, pdf_obj *node, int depth, int *budget, num_set *seen) {
    if (--*budget < 0 || depth > 64) return false;
    if (pdf_is_indirect(ctx, node) && !num_set_add(ctx, seen, pdf_to_num(ctx, node))) return false;
    pdf_obj *kids = pdf_dict_get(ctx, node, PDF_NAME(Kids));
    for (int i = 0, n = pdf_array_len(ctx, kids); i < n; i++)
        if (!walk_field(ctx, pdf_array_get(ctx, kids, i), depth + 1, budget, seen)) return false;
    return true;
}

// Walks the trees under these roots (an array of fields, or one field).
static bool field_trees_ok(fz_context *ctx, pdf_obj *roots) {
    num_set seen = { 0 };
    int budget = FIELD_TREE_BUDGET;
    bool ok = true;
    fz_var(ok);
    fz_try(ctx) {
        if (pdf_is_array(ctx, roots)) {
            for (int i = 0, n = pdf_array_len(ctx, roots); i < n && ok; i++) ok = walk_field(ctx, pdf_array_get(ctx, roots, i), 0, &budget, &seen);
        } else if (roots) {
            ok = walk_field(ctx, roots, 0, &budget, &seen);
        }
    }
    fz_always(ctx)
        num_set_free(&seen);
    fz_catch(ctx)
        fz_rethrow(ctx);
    return ok;
}

// Nodes already walked while listing a page, so its fields share the work.
typedef struct {
    num_set sound;
    num_set damaged;
} field_checks;

// MuPDF's walks for a widget start at the widget or at one of its
// ancestors (/Parent and /Kids needn't agree), so the tree under each of
// them is checked. `checks` may be NULL.
static bool field_group_ok(fz_context *ctx, pdf_obj *widget, field_checks *checks) {
    pdf_obj *node = widget;
    for (int i = 0; i < 64; i++) {
        bool indirect = checks && pdf_is_indirect(ctx, node);
        int num = indirect ? pdf_to_num(ctx, node) : 0;
        if (indirect && num_set_contains(&checks->damaged, num)) return false;
        if (!indirect || !num_set_contains(&checks->sound, num)) {
            bool ok = field_trees_ok(ctx, node);
            if (indirect) num_set_add(ctx, ok ? &checks->sound : &checks->damaged, num);
            if (!ok) return false;
        }
        pdf_obj *parent = pdf_dict_get(ctx, node, PDF_NAME(Parent));
        if (!pdf_is_dict(ctx, parent)) return true;
        node = parent;
    }
    return false;
}

// The whole form, before MuPDF looks fields up by name or removes one.
static void check_form_tree(fz_context *ctx, pdf_document *pdf) {
    pdf_obj *fields = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm/Fields");
    if (!field_trees_ok(ctx, fields)) fz_throw(ctx, FZ_ERROR_FORMAT, "This form's fields are damaged, so they can't be changed");
}

static pdf_annot *find_widget(fz_context *ctx, pdf_page *page, int id) {
    if (id <= 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field can't be changed");
    int n = 0;
    for (pdf_annot *w = pdf_first_widget(ctx, page); w && n < OPDF_MAX_FIELDS_PER_PAGE; w = pdf_next_widget(ctx, w), n++)
        if (annot_id(ctx, w) == id) return w;
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such field");
}

// A copy of s of at most OPDF_MAX_FIELD_TEXT bytes, counted against
// *budget; cut short (at a character boundary) sets *cut. NULL stays NULL.
static char *dup_field_text(fz_context *ctx, const char *s, int *budget, bool *cut) {
    if (!s) return NULL;
    size_t limit = OPDF_MAX_FIELD_TEXT;
    if (*budget < 0) *budget = 0;
    if ((size_t)*budget < limit) limit = (size_t)*budget;
    size_t n = strnlen(s, limit + 1);
    if (n > limit) {
        n = limit;
        while (n > 0 && ((unsigned char)s[n] & 0xC0) == 0x80) n--;
        *cut = true;
    }
    char *copy = checked_calloc(ctx, n + 1, 1);
    memcpy(copy, s, n);
    *budget -= (int)n + OPDF_FIELD_STRING_COST;
    return copy;
}

// A field's value as text, without changing the document (MuPDF's
// pdf_field_value rewrites stream values in place). The first of several
// list box choices.
static const char *field_value(fz_context *ctx, pdf_obj *field) {
    pdf_obj *v = pdf_dict_get_inheritable(ctx, field, PDF_NAME(V));
    if (pdf_is_array(ctx, v)) v = pdf_array_get(ctx, v, 0);
    if (pdf_is_array(ctx, v)) v = pdf_array_get(ctx, v, 1);
    if (pdf_is_name(ctx, v)) return pdf_to_name(ctx, v);
    if (pdf_is_string(ctx, v)) return pdf_to_text_string(ctx, v);
    return "";
}

// Fields filled in here: text (not file selection or rich text), checkboxes,
// radio buttons, dropdowns and list boxes, unless the file makes them
// read-only.
static bool fillable(fz_context *ctx, pdf_annot *w) {
    pdf_obj *obj = pdf_annot_obj(ctx, w);
    int flags = pdf_field_flags(ctx, obj);
    if (flags & PDF_FIELD_IS_READ_ONLY) return false;
    switch (pdf_widget_type(ctx, w)) {
    case PDF_WIDGET_TYPE_TEXT:
        return !(flags & (PDF_TX_FIELD_IS_FILE_SELECT | PDF_TX_FIELD_IS_RICH_TEXT));
    case PDF_WIDGET_TYPE_CHECKBOX:
    case PDF_WIDGET_TYPE_RADIOBUTTON:
    case PDF_WIDGET_TYPE_COMBOBOX:
    case PDF_WIDGET_TYPE_LISTBOX:
        return true;
    default:
        return false;
    }
}

static void fill_field(fz_context *ctx, pdf_annot *w, opdf_field *o, int *budget, field_checks *checks) {
    pdf_obj *obj = pdf_annot_obj(ctx, w);
    bool cut = false;
    o->id = annot_id(ctx, w);
    o->type = (int)pdf_widget_type(ctx, w);
    o->rect = rect_to(pdf_bound_widget(ctx, w));
    o->flags = pdf_field_flags(ctx, obj);
    // MuPDF refuses names over 16 KB: such a field is listed without one.
    char *name = NULL;
    fz_var(name);
    fz_try(ctx) {
        name = pdf_load_field_name(ctx, obj);
        o->name = dup_field_text(ctx, name, budget, &cut);
    }
    fz_always(ctx)
        fz_free(ctx, name);
    fz_catch(ctx) {
        if (fz_caught(ctx) != FZ_ERROR_LIMIT) fz_rethrow(ctx);
        cut = true;
    }
    pdf_obj *tu = pdf_dict_get_inheritable(ctx, obj, PDF_NAME(TU));
    if (tu) o->tooltip = dup_field_text(ctx, pdf_to_text_string(ctx, tu), budget, &cut);
    o->value = dup_field_text(ctx, field_value(ctx, obj), budget, &cut);
    if (o->type == PDF_WIDGET_TYPE_CHECKBOX || o->type == PDF_WIDGET_TYPE_RADIOBUTTON) {
        o->on_state = dup_field_text(ctx, pdf_to_name(ctx, pdf_button_field_on_state(ctx, obj)), budget, &cut);
        pdf_obj *as = pdf_dict_get(ctx, obj, PDF_NAME(AS));
        o->is_on = pdf_is_name(ctx, as) && !pdf_name_eq(ctx, as, PDF_NAME(Off));
    }
    if (o->type == PDF_WIDGET_TYPE_TEXT) o->max_length = pdf_text_widget_max_len(ctx, w);
    if (o->type == PDF_WIDGET_TYPE_COMBOBOX || o->type == PDF_WIDGET_TYPE_LISTBOX) {
        int n = pdf_choice_field_option_count(ctx, obj);
        if (n > OPDF_MAX_FIELD_OPTIONS) {
            n = OPDF_MAX_FIELD_OPTIONS;
            cut = true;
        }
        if (n > 0) {
            o->option_values = checked_calloc(ctx, (size_t)n, sizeof(char *));
            o->option_labels = checked_calloc(ctx, (size_t)n, sizeof(char *));
            o->option_count = n;
            for (int i = 0; i < n; i++) {
                // Out of budget: the rest of the page's options aren't read.
                if (*budget <= 0) {
                    o->option_count = i;
                    cut = true;
                    break;
                }
                o->option_values[i] = dup_field_text(ctx, pdf_choice_field_option(ctx, obj, 1, i), budget, &cut);
                o->option_labels[i] = dup_field_text(ctx, pdf_choice_field_option(ctx, obj, 0, i), budget, &cut);
            }
        }
        pdf_obj *v = pdf_dict_get_inheritable(ctx, obj, PDF_NAME(V));
        if (o->type == PDF_WIDGET_TYPE_LISTBOX && pdf_is_array(ctx, v)) {
            int k = pdf_array_len(ctx, v);
            if (k > OPDF_MAX_FIELD_OPTIONS) {
                k = OPDF_MAX_FIELD_OPTIONS;
                cut = true;
            }
            if (k > 0) {
                o->selected = checked_calloc(ctx, (size_t)k, sizeof(char *));
                o->selected_count = k;
                for (int i = 0; i < k; i++) {
                    if (*budget <= 0) {
                        o->selected_count = i;
                        cut = true;
                        break;
                    }
                    pdf_obj *e = pdf_array_get(ctx, v, i);
                    if (pdf_is_array(ctx, e)) e = pdf_array_get(ctx, e, 0);
                    o->selected[i] = dup_field_text(ctx, pdf_to_text_string(ctx, e), budget, &cut);
                }
            }
        } else if (o->type == PDF_WIDGET_TYPE_LISTBOX && o->value && o->value[0]) {
            o->selected = checked_calloc(ctx, 1, sizeof(char *));
            o->selected_count = 1;
            o->selected[0] = dup_field_text(ctx, o->value, budget, &cut);
        }
    }
    if (o->type == PDF_WIDGET_TYPE_SIGNATURE) o->is_signed = pdf_widget_is_signed(ctx, w) != 0;
    o->read_only = o->id == 0 || cut || !fillable(ctx, w) || !field_group_ok(ctx, obj, checks);
}

opdf_field *opdf_fields_load(opdf_doc *d, int page_number, int *count, opdf_error *err) {
    clear_error(err);
    *count = 0;
    fz_context *ctx = d->ctx;
    fz_page *page = NULL;
    opdf_field *items = NULL;
    int n = 0, capacity = 0;
    // Field trees already walked, shared by the page's fields.
    field_checks checks = { { 0 }, { 0 } };
    fz_var(page);
    fz_var(items);
    fz_var(n);
    fz_var(capacity);
    lock_doc(d);
    fz_try(ctx) {
        page = fz_load_page(ctx, d->doc, page_number);
        pdf_page *pp = pdf_page_from_fz_page(ctx, page);
        int budget = OPDF_MAX_PAGE_FIELD_BYTES;
        int walked = 0;
        for (pdf_annot *w = pp ? pdf_first_widget(ctx, pp) : NULL; w && walked < OPDF_MAX_FIELDS_PER_PAGE;
             w = pdf_next_widget(ctx, w), walked++) {
            // An object listed twice in /Annots is listed here once.
            int id = annot_id(ctx, w);
            bool seen = false;
            for (int i = 0; i < n && id != 0 && !seen; i++) seen = items[i].id == id;
            if (seen) continue;
            if (n == capacity) {
                int grown = capacity ? capacity * 2 : 16;
                opdf_field *bigger = realloc(items, (size_t)grown * sizeof *items);
                if (!bigger) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
                items = bigger;
                capacity = grown;
            }
            memset(&items[n], 0, sizeof items[n]);
            n++;
            // A malformed field is listed read-only with what could be read,
            // rather than hiding the page's other fields.
            fz_try(ctx)
                fill_field(ctx, w, &items[n - 1], &budget, &checks);
            fz_catch(ctx) {
                if (fz_caught(ctx) == FZ_ERROR_SYSTEM) fz_rethrow(ctx);
                items[n - 1].read_only = true;
            }
        }
    }
    fz_always(ctx) {
        fz_drop_page(ctx, page);
        num_set_free(&checks.sound);
        num_set_free(&checks.damaged);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_fields_free(items, n);
        items = NULL;
        n = 0;
    }
    unlock_doc(d);
    *count = n;
    return items;
}

static void free_strings(char **strings, int count) {
    if (!strings) return;
    for (int i = 0; i < count; i++) free(strings[i]);
    free(strings);
}

void opdf_fields_free(opdf_field *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) {
        opdf_field *o = &items[i];
        free(o->name);
        free(o->tooltip);
        free(o->value);
        free(o->on_state);
        free_strings(o->option_values, o->option_count);
        free_strings(o->option_labels, o->option_count);
        free_strings(o->selected, o->selected_count);
    }
    free(items);
}

// Looks through the field tree, breadth first, for a signed signature
// field; *budget bounds the fields visited (and so any cycle).
static bool has_signed_field(fz_context *ctx, pdf_obj *fields, int *budget) {
    int n = pdf_array_len(ctx, fields);
    for (int i = 0; i < n && *budget > 0; i++, (*budget)--) {
        pdf_obj *field = pdf_array_get(ctx, fields, i);
        if (pdf_name_eq(ctx, pdf_dict_get_inheritable(ctx, field, PDF_NAME(FT)), PDF_NAME(Sig)) &&
            pdf_is_dict(ctx, pdf_dict_get(ctx, field, PDF_NAME(V))))
            return true;
    }
    for (int i = 0; i < n && *budget > 0; i++) {
        pdf_obj *kids = pdf_dict_get(ctx, pdf_array_get(ctx, fields, i), PDF_NAME(Kids));
        if (kids && has_signed_field(ctx, kids, budget)) return true;
    }
    return false;
}

bool opdf_form_get_info(opdf_doc *d, opdf_form_info *info, opdf_error *err) {
    clear_error(err);
    memset(info, 0, sizeof *info);
    fz_context *ctx = d->ctx;
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        pdf_obj *form = pdf ? pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm") : NULL;
        pdf_obj *fields = pdf_dict_get(ctx, form, PDF_NAME(Fields));
        int budget = 10000;
        info->has_fields = pdf_array_len(ctx, fields) > 0;
        info->has_xfa = pdf_dict_get(ctx, form, PDF_NAME(XFA)) != NULL;
        info->is_signed = has_signed_field(ctx, fields, &budget);
    }
    fz_catch(ctx)
        set_error(err, ctx);
    unlock_doc(d);
    return !(err && err->code);
}

// Other apps prefer a form's XFA data to its fields, so once a field is
// filled in here the XFA (now out of date) goes.
static void remove_xfa(fz_context *ctx, pdf_document *pdf) {
    pdf_obj *form = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm");
    if (pdf_dict_get(ctx, form, PDF_NAME(XFA))) pdf_dict_del(ctx, form, PDF_NAME(XFA));
}

// MuPDF draws a dropdown's stored value rather than its label, and doesn't
// mark a list box's choices: once one is filled in, other apps are asked to
// draw the form's fields themselves.
static void ask_for_appearances(fz_context *ctx, pdf_document *pdf) {
    pdf_obj *form = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm");
    if (pdf_is_dict(ctx, form) && !pdf_dict_get_bool(ctx, form, PDF_NAME(NeedAppearances)))
        pdf_dict_put_bool(ctx, form, PDF_NAME(NeedAppearances), 1);
}

// The field to fill in, checked against the kinds given.
static pdf_annot *fillable_widget(fz_context *ctx, pdf_page *page, int id, int type_a, int type_b) {
    pdf_annot *w = find_widget(ctx, page, id);
    int type = pdf_widget_type(ctx, w);
    if (!fillable(ctx, w)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field can't be filled in");
    if (!field_group_ok(ctx, pdf_annot_obj(ctx, w), NULL)) fz_throw(ctx, FZ_ERROR_FORMAT, "This field is damaged, so it can't be filled in");
    if (type != type_a && type != type_b) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This field doesn't take that kind of value");
    return w;
}

static bool is_option(fz_context *ctx, pdf_obj *field, const char *value) {
    int n = pdf_choice_field_option_count(ctx, field);
    for (int i = 0; i < n; i++)
        if (!strcmp(pdf_choice_field_option(ctx, field, 1, i), value)) return true;
    return false;
}

bool opdf_field_set_text(opdf_doc *d, int page_number, int id, const char *text, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Fill In Field", err, {
        pdf_annot *w = fillable_widget(ctx, pp, id, PDF_WIDGET_TYPE_TEXT, PDF_WIDGET_TYPE_COMBOBOX);
        pdf_obj *obj = pdf_annot_obj(ctx, w);
        if (!text) text = "";
        if (strlen(text) > OPDF_MAX_FIELD_TEXT) fz_throw(ctx, FZ_ERROR_LIMIT, "The text is too long for a form field");
        if (pdf_widget_type(ctx, w) == PDF_WIDGET_TYPE_TEXT) {
            int max = pdf_text_widget_max_len(ctx, w);
            if (max > 0 && (int)fz_utflen(text) > max) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The text is longer than this field allows");
        } else if (!(pdf_field_flags(ctx, obj) & PDF_CH_FIELD_IS_EDIT) && text[0] && !is_option(ctx, obj, text)) {
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "That isn't one of this field's choices");
        }
        if (!pdf_set_annot_field_value(ctx, pdf, w, text, 1)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The field didn't take the text");
        if (pdf_widget_type(ctx, w) == PDF_WIDGET_TYPE_COMBOBOX) ask_for_appearances(ctx, pdf);
        remove_xfa(ctx, pdf);
    });
    return !(err && err->code);
}

bool opdf_field_set_choices(opdf_doc *d, int page_number, int id, const char *const *values, int count, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Fill In Field", err, {
        pdf_annot *w = fillable_widget(ctx, pp, id, PDF_WIDGET_TYPE_LISTBOX, PDF_WIDGET_TYPE_LISTBOX);
        pdf_obj *obj = pdf_annot_obj(ctx, w);
        if (count < 0 || count > OPDF_MAX_FIELD_OPTIONS || (count > 0 && !values))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Too many choices");
        if (count > 1 && !pdf_choice_widget_is_multiselect(ctx, w))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This list takes one choice");
        for (int i = 0; i < count; i++)
            if (!values[i] || !is_option(ctx, obj, values[i])) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That isn't one of this field's choices");
        if (count == 0) {
            pdf_dict_del(ctx, obj, PDF_NAME(V));
            pdf_dict_del(ctx, obj, PDF_NAME(I));
            pdf_annot_request_synthesis(ctx, w);
        } else {
            pdf_choice_widget_set_value(ctx, w, count, (const char **)values);
        }
        ask_for_appearances(ctx, pdf);
        remove_xfa(ctx, pdf);
    });
    return !(err && err->code);
}

bool opdf_field_toggle(opdf_doc *d, int page_number, int id, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Fill In Field", err, {
        pdf_annot *w = fillable_widget(ctx, pp, id, PDF_WIDGET_TYPE_CHECKBOX, PDF_WIDGET_TYPE_RADIOBUTTON);
        pdf_toggle_widget(ctx, w);
        remove_xfa(ctx, pdf);
    });
    return !(err && err->code);
}

// --- Creating and changing form fields ------------------------------------------

// The document's form, made if it has none, with the fonts new fields use.
static pdf_obj *ensure_form(fz_context *ctx, pdf_document *pdf) {
    pdf_obj *root = pdf_dict_get(ctx, pdf_trailer(ctx, pdf), PDF_NAME(Root));
    pdf_obj *form = pdf_dict_get(ctx, root, PDF_NAME(AcroForm));
    if (!pdf_is_dict(ctx, form)) form = pdf_dict_put_dict(ctx, root, PDF_NAME(AcroForm), 4);
    if (!pdf_is_array(ctx, pdf_dict_get(ctx, form, PDF_NAME(Fields)))) pdf_dict_put_array(ctx, form, PDF_NAME(Fields), 8);
    if (!pdf_dict_get(ctx, form, PDF_NAME(DA))) pdf_dict_put_text_string(ctx, form, PDF_NAME(DA), "/Helv 0 Tf 0 g");
    pdf_obj *dr = pdf_dict_get(ctx, form, PDF_NAME(DR));
    if (!pdf_is_dict(ctx, dr)) dr = pdf_dict_put_dict(ctx, form, PDF_NAME(DR), 1);
    pdf_obj *fonts = pdf_dict_get(ctx, dr, PDF_NAME(Font));
    if (!pdf_is_dict(ctx, fonts)) fonts = pdf_dict_put_dict(ctx, dr, PDF_NAME(Font), 2);
    const char *names[2] = { "Helv", "ZaDb" };
    const char *bases[2] = { "Helvetica", "ZapfDingbats" };
    for (int i = 0; i < 2; i++) {
        if (pdf_dict_gets(ctx, fonts, names[i])) continue;
        pdf_obj *font = pdf_add_new_dict(ctx, pdf, 4);
        fz_try(ctx) {
            pdf_dict_put(ctx, font, PDF_NAME(Type), PDF_NAME(Font));
            pdf_dict_put(ctx, font, PDF_NAME(Subtype), PDF_NAME(Type1));
            pdf_dict_put_name(ctx, font, PDF_NAME(BaseFont), bases[i]);
            if (i == 0) pdf_dict_put(ctx, font, PDF_NAME(Encoding), PDF_NAME(WinAnsiEncoding));
            pdf_dict_puts(ctx, fonts, names[i], font);
        }
        fz_always(ctx)
            pdf_drop_obj(ctx, font);
        fz_catch(ctx)
            fz_rethrow(ctx);
    }
    return form;
}

// The field dictionary a widget belongs to: the widget itself, or its
// parent when the widget has no name of its own (a radio group's button).
static pdf_obj *field_holder(fz_context *ctx, pdf_obj *widget) {
    pdf_obj *parent = pdf_dict_get(ctx, widget, PDF_NAME(Parent));
    if (!pdf_dict_get(ctx, widget, PDF_NAME(T)) && pdf_is_dict(ctx, parent)) return parent;
    return widget;
}

// A thin grey border, as new fields are drawn.
static void put_field_look(fz_context *ctx, pdf_obj *obj, const char *caption) {
    pdf_obj *mk = pdf_dict_put_dict(ctx, obj, PDF_NAME(MK), 2);
    pdf_obj *bc = pdf_dict_put_array(ctx, mk, PDF_NAME(BC), 3);
    for (int i = 0; i < 3; i++) pdf_array_push_real(ctx, bc, 0.6);
    if (caption) pdf_dict_put_text_string(ctx, mk, PDF_NAME(CA), caption);
    pdf_obj *bs = pdf_dict_put_dict(ctx, obj, PDF_NAME(BS), 1);
    pdf_dict_put_real(ctx, bs, PDF_NAME(W), 1);
}

// A radio button's or checkbox's state names: until its appearance is made,
// MuPDF finds the "on" state among /AP/N's keys.
static void seed_states(fz_context *ctx, pdf_obj *obj, const char *on) {
    pdf_obj *ap = pdf_dict_put_dict(ctx, obj, PDF_NAME(AP), 1);
    pdf_obj *n = pdf_dict_put_dict(ctx, ap, PDF_NAME(N), 2);
    pdf_dict_put_dict(ctx, n, PDF_NAME(Off), 0);
    pdf_dict_puts_drop(ctx, n, on, pdf_new_dict(ctx, pdf_get_bound_document(ctx, obj), 0));
    pdf_dict_put(ctx, obj, PDF_NAME(AS), PDF_NAME(Off));
}

int opdf_field_create(opdf_doc *d, int page_number, int type, opdf_rect rect, int group, opdf_error *err) {
    clear_error(err);
    int id = 0;
    pdf_annot *annot = NULL;
    pdf_obj *parent = NULL;
    fz_var(id);
    fz_var(annot);
    fz_var(parent);
    WITH_PAGE_OPERATION(d, page_number, "New Field", err, {
        fz_rect r = fz_make_rect(rect.x0, rect.y0, rect.x1, rect.y1);
        if (fz_is_empty_rect(r) || r.x1 - r.x0 > 14400 || r.y1 - r.y0 > 14400) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That field is the wrong size");
        const char *prefix;
        switch (type) {
        case OPDF_FIELD_TEXT: prefix = "Text"; break;
        case OPDF_FIELD_CHECKBOX: prefix = "Checkbox"; break;
        case OPDF_FIELD_RADIO: prefix = "Radio"; break;
        case OPDF_FIELD_COMBOBOX: prefix = "Dropdown"; break;
        case OPDF_FIELD_LISTBOX: prefix = "List"; break;
        case OPDF_FIELD_SIGNATURE: prefix = "Signature"; break;
        default: fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a kind of field that can be made");
        }
        pdf_obj *form = ensure_form(ctx, pdf);
        pdf_obj *fields = pdf_dict_get(ctx, form, PDF_NAME(Fields));
        check_form_tree(ctx, pdf);
        if (type == OPDF_FIELD_RADIO && group) {
            pdf_annot *other = find_widget(ctx, pp, group);
            if (pdf_widget_type(ctx, other) != PDF_WIDGET_TYPE_RADIOBUTTON) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That isn't a radio button");
            pdf_obj *holder = field_holder(ctx, pdf_annot_obj(ctx, other));
            if (holder == pdf_annot_obj(ctx, other)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That radio button's group can't take more buttons");
            parent = pdf_keep_obj(ctx, holder);
        }
        fz_try(ctx) {
        // A new name, looked for from the number of fields on (MuPDF's
        // pdf_create_field_name starts at 0, slow on forms with many names).
        char name[64];
        bool named = false;
        // 100 tries from the number of fields on, then further afield.
        int base = pdf_array_len(ctx, fields);
        for (int tries = 0; tries < 200 && !named; tries++) {
            int i = tries < 100 ? base + tries : base + 1000 + tries * 7919;
            fz_snprintf(name, sizeof name, "%s%d", prefix, i);
            named = !pdf_lookup_field(ctx, fields, name);
        }
        if (!named) fz_throw(ctx, FZ_ERROR_LIMIT, "Could not find a new name for the field");
        annot = pdf_create_annot(ctx, pp, PDF_ANNOT_WIDGET);
        fz_try(ctx) {
            pdf_obj *obj = pdf_annot_obj(ctx, annot);
            pdf_set_annot_rect(ctx, annot, r);
            switch (type) {
            case OPDF_FIELD_TEXT:
                pdf_dict_put(ctx, obj, PDF_NAME(FT), PDF_NAME(Tx));
                pdf_dict_put_text_string(ctx, obj, PDF_NAME(DA), "/Helv 0 Tf 0 g");
                put_field_look(ctx, obj, NULL);
                break;
            case OPDF_FIELD_CHECKBOX:
                pdf_dict_put(ctx, obj, PDF_NAME(FT), PDF_NAME(Btn));
                pdf_dict_put_text_string(ctx, obj, PDF_NAME(DA), "/ZaDb 0 Tf 0 g");
                pdf_dict_put(ctx, obj, PDF_NAME(V), PDF_NAME(Off));
                put_field_look(ctx, obj, "4");
                seed_states(ctx, obj, "Yes");
                break;
            case OPDF_FIELD_RADIO: {
                if (!parent) {
                    parent = pdf_add_new_dict(ctx, pdf, 5);
                    pdf_dict_put(ctx, parent, PDF_NAME(FT), PDF_NAME(Btn));
                    pdf_dict_put_int(ctx, parent, PDF_NAME(Ff), PDF_BTN_FIELD_IS_RADIO | PDF_BTN_FIELD_IS_NO_TOGGLE_TO_OFF);
                    pdf_dict_put_text_string(ctx, parent, PDF_NAME(T), name);
                    pdf_dict_put(ctx, parent, PDF_NAME(V), PDF_NAME(Off));
                    pdf_dict_put_array(ctx, parent, PDF_NAME(Kids), 2);
                    pdf_array_push(ctx, fields, parent);
                }
                pdf_obj *kids = pdf_dict_get(ctx, parent, PDF_NAME(Kids));
                if (pdf_array_len(ctx, kids) >= OPDF_MAX_FIELD_OPTIONS) fz_throw(ctx, FZ_ERROR_LIMIT, "This group has too many buttons");
                // Each button's own "on" state: Choice1, Choice2, ...
                char state[32];
                for (int k = 1; ; k++) {
                    fz_snprintf(state, sizeof state, "Choice%d", k);
                    bool used = false;
                    for (int i = 0, n = pdf_array_len(ctx, kids); i < n && !used; i++)
                        used = pdf_dict_gets(ctx, pdf_dict_getp(ctx, pdf_array_get(ctx, kids, i), "AP/N"), state) != NULL;
                    if (!used) break;
                }
                pdf_dict_put(ctx, obj, PDF_NAME(Parent), parent);
                pdf_array_push(ctx, kids, obj);
                pdf_dict_put_text_string(ctx, obj, PDF_NAME(DA), "/ZaDb 0 Tf 0 g");
                put_field_look(ctx, obj, "l");
                seed_states(ctx, obj, state);
                break;
            }
            case OPDF_FIELD_COMBOBOX:
            case OPDF_FIELD_LISTBOX:
                pdf_dict_put(ctx, obj, PDF_NAME(FT), PDF_NAME(Ch));
                if (type == OPDF_FIELD_COMBOBOX) pdf_dict_put_int(ctx, obj, PDF_NAME(Ff), PDF_CH_FIELD_IS_COMBO);
                pdf_dict_put_array(ctx, obj, PDF_NAME(Opt), 0);
                pdf_dict_put_text_string(ctx, obj, PDF_NAME(DA), "/Helv 0 Tf 0 g");
                put_field_look(ctx, obj, NULL);
                break;
            case OPDF_FIELD_SIGNATURE:
                pdf_dict_put(ctx, obj, PDF_NAME(FT), PDF_NAME(Sig));
                put_field_look(ctx, obj, NULL);
                break;
            }
            if (type != OPDF_FIELD_RADIO) {
                pdf_dict_put_text_string(ctx, obj, PDF_NAME(T), name);
                pdf_array_push(ctx, fields, obj);
            }
            pdf_annot_request_synthesis(ctx, annot);
            pdf_update_annot(ctx, annot);
            id = annot_id(ctx, annot);
        }
        fz_always(ctx) {
            pdf_drop_annot(ctx, annot);
            annot = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
        }
        fz_always(ctx) {
            pdf_drop_obj(ctx, parent);
            parent = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    if (err && err->code) id = 0;
    return id;
}

bool opdf_field_update(opdf_doc *d, int page_number, int id, const opdf_field_spec *spec, opdf_error *err) {
    clear_error(err);
    pdf_obj *opt = NULL;
    fz_var(opt);
    WITH_PAGE_OPERATION(d, page_number, "Change Field", err, {
        pdf_annot *w = find_widget(ctx, pp, id);
        pdf_obj *obj = pdf_annot_obj(ctx, w);
        pdf_obj *holder = field_holder(ctx, obj);
        int type = pdf_widget_type(ctx, w);
        fz_try(ctx) {
        if (spec->name) {
            size_t len = strlen(spec->name);
            if (len == 0 || len > 255 || strchr(spec->name, '.')) fz_throw(ctx, FZ_ERROR_ARGUMENT, "A field's name can't be empty, longer than 255 bytes, or contain a full stop");
            // Fields with the same name share a value, so names stay unique.
            check_form_tree(ctx, pdf);
            pdf_obj *fields = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm/Fields");
            pdf_obj *same = pdf_lookup_field(ctx, fields, spec->name);
            if (same && pdf_objcmp(ctx, same, holder)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Another field already has that name");
            pdf_dict_put_text_string(ctx, holder, PDF_NAME(T), spec->name);
        }
        if (spec->tooltip) {
            if (strlen(spec->tooltip) > OPDF_MAX_FIELD_TEXT) fz_throw(ctx, FZ_ERROR_LIMIT, "The tooltip is too long");
            if (spec->tooltip[0]) pdf_dict_put_text_string(ctx, holder, PDF_NAME(TU), spec->tooltip);
            else pdf_dict_del(ctx, holder, PDF_NAME(TU));
        }
        if (spec->max_length >= 0) {
            if (type != PDF_WIDGET_TYPE_TEXT) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Only text fields have a length");
            if (spec->max_length > 100000) fz_throw(ctx, FZ_ERROR_LIMIT, "That length is too long");
            if (spec->max_length > 0) pdf_dict_put_int(ctx, holder, PDF_NAME(MaxLen), spec->max_length);
            else pdf_dict_del(ctx, holder, PDF_NAME(MaxLen));
        }
        int mask = spec->flags_mask & OPDF_FIELD_SETTABLE_FLAGS;
        if (mask) {
            int flags = (pdf_field_flags(ctx, holder) & ~mask) | (spec->flags & mask);
            pdf_dict_put_int(ctx, holder, PDF_NAME(Ff), flags);
        }
        if (type == PDF_WIDGET_TYPE_TEXT && (pdf_field_flags(ctx, holder) & PDF_TX_FIELD_IS_COMB) &&
            pdf_text_widget_max_len(ctx, w) <= 0)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "A field split into boxes needs a number of characters");
        if (spec->option_count >= 0) {
            if (type != PDF_WIDGET_TYPE_COMBOBOX && type != PDF_WIDGET_TYPE_LISTBOX) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Only dropdowns and lists have choices");
            if (spec->option_count > OPDF_MAX_FIELD_OPTIONS || (spec->option_count > 0 && !spec->option_values))
                fz_throw(ctx, FZ_ERROR_LIMIT, "Too many choices");
            opt = pdf_new_array(ctx, pdf, spec->option_count);
            for (int i = 0; i < spec->option_count; i++) {
                const char *value = spec->option_values[i];
                const char *label = spec->option_labels ? spec->option_labels[i] : NULL;
                if (!value || strlen(value) > OPDF_MAX_FIELD_TEXT || (label && strlen(label) > OPDF_MAX_FIELD_TEXT))
                    fz_throw(ctx, FZ_ERROR_ARGUMENT, "A choice is missing or too long");
                if (label && label[0] && strcmp(label, value)) {
                    pdf_obj *pair = pdf_array_push_array(ctx, opt, 2);
                    pdf_array_push_text_string(ctx, pair, value);
                    pdf_array_push_text_string(ctx, pair, label);
                } else {
                    pdf_array_push_text_string(ctx, opt, value);
                }
            }
            pdf_dict_put(ctx, holder, PDF_NAME(Opt), opt);
            // A value that is no longer a choice goes.
            const char *value = field_value(ctx, holder);
            if (value[0] && !is_option(ctx, holder, value)) {
                pdf_dict_del(ctx, holder, PDF_NAME(V));
                pdf_dict_del(ctx, holder, PDF_NAME(I));
            }
        }
        pdf_annot_request_synthesis(ctx, w);
        }
        fz_always(ctx) {
            pdf_drop_obj(ctx, opt);
            opt = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    return !(err && err->code);
}

bool opdf_field_transform(opdf_doc *d, int page_number, int id, opdf_matrix matrix, opdf_error *err) {
    clear_error(err);
    fz_matrix m = { matrix.a, matrix.b, matrix.c, matrix.d, matrix.e, matrix.f };
    WITH_PAGE_OPERATION(d, page_number, "Move Field", err, {
        pdf_annot *w = find_widget(ctx, pp, id);
        fz_rect r = fz_transform_rect(pdf_annot_rect(ctx, w), m);
        if (fz_is_empty_rect(r) || r.x1 - r.x0 > 14400 || r.y1 - r.y0 > 14400) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That field is the wrong size");
        pdf_set_annot_rect(ctx, w, r);
        pdf_annot_request_synthesis(ctx, w);
    });
    return !(err && err->code);
}

bool opdf_field_delete(opdf_doc *d, int page_number, int id, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Delete Field", err, {
        pdf_annot *w = find_widget(ctx, pp, id);
        check_form_tree(ctx, pdf);
        if (!field_group_ok(ctx, pdf_annot_obj(ctx, w), NULL)) fz_throw(ctx, FZ_ERROR_FORMAT, "This field is damaged, so it can't be deleted");
        pdf_obj *obj = pdf_annot_obj(ctx, w);
        pdf_obj *parent = pdf_keep_obj(ctx, pdf_dict_get(ctx, obj, PDF_NAME(Parent)));
        fz_try(ctx) {
            pdf_delete_annot(ctx, pp, w);
            // A group left with no buttons goes too.
            pdf_obj *fields = pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm/Fields");
            if (parent && pdf_array_len(ctx, pdf_dict_get(ctx, parent, PDF_NAME(Kids))) == 0) {
                for (int i = 0, n = pdf_array_len(ctx, fields); i < n; i++)
                    if (!pdf_objcmp(ctx, pdf_array_get(ctx, fields, i), parent)) {
                        pdf_array_delete(ctx, fields, i);
                        break;
                    }
            }
        }
        fz_always(ctx)
            pdf_drop_obj(ctx, parent);
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    return !(err && err->code);
}

// --- Undo, saving, flattening -----------------------------------------------

static bool journal_query(opdf_doc *d, int (*query)(fz_context *, pdf_document *)) {
    bool result = false;
    lock_doc(d);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        result = pdf && query(d->ctx, pdf);
    }
    fz_catch(d->ctx)
        result = false;
    unlock_doc(d);
    return result;
}

bool opdf_can_undo(opdf_doc *d) { return journal_query(d, pdf_can_undo); }
bool opdf_can_redo(opdf_doc *d) { return journal_query(d, pdf_can_redo); }
bool opdf_has_unsaved_changes(opdf_doc *d) { return journal_query(d, pdf_has_unsaved_changes); }

static bool journal_step(opdf_doc *d, void (*step)(fz_context *, pdf_document *), opdf_error *err) {
    clear_error(err);
    bool ok = false;
    lock_doc(d);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (!pdf) fz_throw(d->ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        step(d->ctx, pdf);
        ok = true;
    }
    fz_catch(d->ctx)
        set_error(err, d->ctx);
    unlock_doc(d);
    return ok;
}

bool opdf_undo(opdf_doc *d, opdf_error *err) { return journal_step(d, pdf_undo, err); }
bool opdf_redo(opdf_doc *d, opdf_error *err) { return journal_step(d, pdf_redo, err); }

bool opdf_save(opdf_doc *d, const char *path, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    fz_output *out = NULL;
    unsigned char *chunk = NULL;
    bool ok = false;
    fz_var(out);
    fz_var(chunk);
    fz_var(ok);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf || !pdf->file) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        // MuPDF repairs a damaged file when it first trips over it, and a
        // repair throws away the changes made so far. opdf_prepare_for_editing
        // makes that happen before any change; if it happened anyway, the
        // edits are gone from the document and saving would lose them.
        if (d->edits_prepared && pdf_was_repaired(ctx, pdf) && !d->repaired_before_edits)
            fz_throw(ctx, FZ_ERROR_FORMAT, "The document is damaged, and MuPDF had to repair it after it was changed. To keep your work, the document wasn't saved.");
        if (!pdf_can_be_saved_incrementally(ctx, pdf))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "This document can't be saved.");
        // The saved file starts with the bytes the document was opened from.
        // If another app rewrote the file in place since, they're different.
        fz_seek(ctx, pdf->file, 0, SEEK_END);
        if (fz_tell(ctx, pdf->file) != pdf->file_size)
            fz_throw(ctx, FZ_ERROR_FORMAT, "The file was changed by another app while it was open. Close it and open it again.");

        // The original bytes...
        out = fz_new_output_with_path(ctx, path, 0);
        chunk = fz_malloc(ctx, 1 << 16);
        fz_seek(ctx, pdf->file, 0, SEEK_SET);
        size_t n;
        while ((n = fz_read(ctx, pdf->file, chunk, 1 << 16)) > 0)
            fz_write_data(ctx, out, chunk, n);
        fz_close_output(ctx, out);
        fz_drop_output(ctx, out);
        out = NULL;
        // ...then the changes, as a snapshot: an incremental update that
        // doesn't finalise the document. MuPDF then counts the changes as
        // saved, so the next snapshot would hold only newer ones and expect
        // to be appended to this file: restoring the count makes every save
        // the original plus all the changes. Saving is itself an operation
        // MuPDF would journal; with the journal set aside, undo and redo are
        // exactly as they were.
        int sections = pdf->num_incremental_sections;
        if (sections > 0) {
            pdf_journal *journal = pdf->journal;
            pdf->journal = NULL;
            pdf_write_options opts = pdf_default_write_options;
            opts.do_incremental = 1;
            opts.do_snapshot = 1;
            opts.dont_regenerate_id = 1;
            fz_try(ctx)
                pdf_save_document(ctx, pdf, path, &opts);
            fz_always(ctx) {
                pdf->journal = journal;
                pdf->num_incremental_sections = sections;
            }
            fz_catch(ctx)
                fz_rethrow(ctx);
        }
        ok = true;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_free(ctx, chunk);
    }
    fz_catch(ctx)
        set_error(err, ctx);
    unlock_doc(d);
    return ok;
}

bool opdf_prepare_for_editing(opdf_doc *d, const char *password, bool *repaired, opdf_error *err) {
    clear_error(err);
    *repaired = false;
    fz_context *ctx = d->ctx;
    fz_buffer *buf = NULL;
    fz_output *out = NULL;
    fz_stream *stm = NULL;
    pdf_document *fresh = NULL;
    bool ok = false;
    fz_var(buf);
    fz_var(out);
    fz_var(stm);
    fz_var(fresh);
    fz_var(ok);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (pdf && !d->edits_prepared) {
            // Load every object: any repair happens now, before changes exist.
            pdf_check_document(ctx, pdf);
            if (pdf_was_repaired(ctx, pdf)) {
                // Write the repaired document out whole and work on that copy
                // from now on, so it saves incrementally and can't need
                // repairing again.
                buf = fz_new_buffer(ctx, 1 << 20);
                out = fz_new_output_with_buffer(ctx, buf);
                pdf_journal *journal = pdf->journal;
                pdf->journal = NULL;
                fz_try(ctx)
                    pdf_write_document(ctx, pdf, out, NULL);
                fz_always(ctx)
                    pdf->journal = journal;
                fz_catch(ctx)
                    fz_rethrow(ctx);
                fz_close_output(ctx, out);
                stm = fz_open_buffer(ctx, buf);
                fresh = pdf_open_document_with_stream(ctx, stm);
                if (pdf_needs_password(ctx, fresh) && !(password && pdf_authenticate_password(ctx, fresh, password)))
                    fz_throw(ctx, FZ_ERROR_ARGUMENT, "Could not unlock the repaired document");
                pdf_check_document(ctx, fresh);
                if (pdf_was_repaired(ctx, fresh))
                    fz_throw(ctx, FZ_ERROR_FORMAT, "The document is too damaged to edit");
                pdf_enable_journal(ctx, fresh);
                fz_drop_document(ctx, d->doc);
                d->doc = (fz_document *)fresh;
                fresh = NULL;
                *repaired = true;
            }
            d->repaired_before_edits = pdf_was_repaired(ctx, pdf_specifics(ctx, d->doc));
        }
        d->edits_prepared = true;
        ok = true;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, buf);
        fz_drop_document(ctx, (fz_document *)fresh);
    }
    fz_catch(ctx)
        set_error(err, ctx);
    unlock_doc(d);
    return ok;
}

bool opdf_flatten_annotations(opdf_doc *d, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    pdf_page *page = NULL;
    pdf_annot **replies = NULL;
    int began = 0;
    bool ok = false;
    fz_var(page);
    fz_var(replies);
    fz_var(began);
    fz_var(ok);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        pdf_begin_operation(ctx, pdf, "Flatten Annotations");
        began = 1;
        // Replies and statuses are discussion, not drawing: remove them first.
        int pages = pdf_count_pages(ctx, pdf);
        for (int i = 0; i < pages; i++) {
            page = pdf_load_page(ctx, pdf, i);
            // Collected in one pass, then deleted.
            int n = 0;
            for (pdf_annot *a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a))
                if (is_reply(ctx, a)) n++;
            if (n > 0) {
                replies = checked_calloc(ctx, (size_t)n, sizeof *replies);
                int k = 0;
                for (pdf_annot *a = pdf_first_annot(ctx, page); a && k < n; a = pdf_next_annot(ctx, a))
                    if (is_reply(ctx, a)) replies[k++] = a;
                for (int j = 0; j < k; j++) pdf_delete_annot(ctx, page, replies[j]);
                free(replies);
                replies = NULL;
            }
            fz_drop_page(ctx, (fz_page *)page);
            page = NULL;
        }
        pdf_bake_document(ctx, pdf, 1, 0);
        pdf_end_operation(ctx, pdf);
        began = 0;
        ok = true;
    }
    fz_always(ctx) {
        fz_drop_page(ctx, (fz_page *)page);
        free(replies);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        if (began) {
            fz_try(ctx) pdf_abandon_operation(ctx, pdf_specifics(ctx, d->doc));
            fz_catch(ctx) {}
        }
    }
    unlock_doc(d);
    return ok;
}

bool opdf_flatten_form(opdf_doc *d, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    pdf_page *page = NULL;
    int began = 0;
    fz_var(page);
    fz_var(began);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        pdf_begin_operation(ctx, pdf, "Flatten Form");
        began = 1;
        pdf_bake_document(ctx, pdf, 0, 1);
        // MuPDF gives up quietly when baking fails: check it happened.
        if (pdf_dict_getp(ctx, pdf_trailer(ctx, pdf), "Root/AcroForm")) fz_throw(ctx, FZ_ERROR_FORMAT, "The form couldn't be flattened");
        int pages = pdf_count_pages(ctx, pdf);
        for (int i = 0; i < pages; i++) {
            page = pdf_load_page(ctx, pdf, i);
            if (pdf_first_widget(ctx, page)) fz_throw(ctx, FZ_ERROR_FORMAT, "The form couldn't be flattened");
            fz_drop_page(ctx, (fz_page *)page);
            page = NULL;
        }
        pdf_end_operation(ctx, pdf);
        began = 0;
    }
    fz_always(ctx)
        fz_drop_page(ctx, (fz_page *)page);
    fz_catch(ctx) {
        set_error(err, ctx);
        if (began) {
            fz_try(ctx) pdf_abandon_operation(ctx, pdf_specifics(ctx, d->doc));
            fz_catch(ctx) {}
        }
    }
    unlock_doc(d);
    return !(err && err->code);
}

// --- Pages -----------------------------------------------------------------------

// Runs `body` as one journal operation on the whole document. Takes the
// document lock and leaves it held: the caller frees what the body made
// (which may use d->ctx, so must happen under the lock) and then calls
// unlock_doc. Nothing may touch d->ctx without the lock: its error stack
// is shared with the render threads that take it next.
#define WITH_DOC_OPERATION(d, operation, err, ...) \
    do { \
        fz_context *ctx = (d)->ctx; \
        int began = 0; \
        fz_var(began); \
        lock_doc(d); \
        fz_try(ctx) { \
            pdf_document *pdf = pdf_specifics(ctx, (d)->doc); \
            if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF"); \
            pdf_begin_operation(ctx, pdf, (operation)); \
            began = 1; \
            __VA_ARGS__ \
            pdf_end_operation(ctx, pdf); \
            began = 0; \
        } \
        fz_catch(ctx) { \
            set_error((err), ctx); \
            if (began) { \
                fz_try(ctx) pdf_abandon_operation(ctx, pdf_specifics(ctx, (d)->doc)); \
                fz_catch(ctx) {} \
            } \
        } \
    } while (0)

// --- Metadata -------------------------------------------------------------------

static void append_xml_escaped(fz_context *ctx, fz_buffer *buf, const char *s) {
    for (; s && *s; s++) {
        switch (*s) {
        case '&': fz_append_string(ctx, buf, "&amp;"); break;
        case '<': fz_append_string(ctx, buf, "&lt;"); break;
        case '>': fz_append_string(ctx, buf, "&gt;"); break;
        case '"': fz_append_string(ctx, buf, "&quot;"); break;
        default:
            // Control characters aren't allowed in XML 1.0.
            if ((unsigned char)*s >= 0x20 || *s == '\t' || *s == '\n' || *s == '\r') fz_append_byte(ctx, buf, *s);
        }
    }
}

// A PDF/A identification value from an old XMP packet ("1", "B"...), as
// an attribute or an element; at most 8 letters and digits, else NULL.
static bool find_xmp_value(const char *xmp, size_t len, const char *name, char out[9]) {
    size_t n = strlen(name);
    for (size_t i = 0; i + n < len; i++) {
        if (memcmp(xmp + i, name, n)) continue;
        size_t j = i + n;
        if (j < len && xmp[j] == '=') j++;
        if (j < len && (xmp[j] == '"' || xmp[j] == '\'' || xmp[j] == '>')) j++;
        else continue;
        size_t k = 0;
        while (j < len && k < 8 && ((xmp[j] >= '0' && xmp[j] <= '9') || (xmp[j] >= 'A' && xmp[j] <= 'Z') || (xmp[j] >= 'a' && xmp[j] <= 'z')))
            out[k++] = xmp[j++];
        out[k] = 0;
        if (k > 0) return true;
    }
    return false;
}

static void iso_date(int64_t t, char out[32]) {
    time_t secs = (time_t)t;
    struct tm tm;
    gmtime_r(&secs, &tm);
    strftime(out, 32, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

// Rewrites the XMP packet from the Info dictionary.
static void rewrite_xmp(fz_context *ctx, pdf_document *pdf, pdf_obj *stream, pdf_obj *info, int64_t now) {
    char part[9] = "", conformance[9] = "";
    fz_buffer *old = NULL, *buf = NULL;
    fz_var(old);
    fz_var(buf);
    fz_try(ctx) {
        // Only the first 4 MB of the old packet are looked at.
        old = pdf_load_stream(ctx, stream);
        unsigned char *data;
        size_t len = fz_buffer_storage(ctx, old, &data);
        if (len > (4 << 20)) len = 4 << 20;
        bool pdfa = find_xmp_value((const char *)data, len, "pdfaid:part", part);
        if (pdfa) find_xmp_value((const char *)data, len, "pdfaid:conformance", conformance);
        buf = fz_new_buffer(ctx, 2048);
        char modified[32];
        iso_date(now, modified);
        fz_append_string(ctx, buf,
            "<?xpacket begin=\"\xEF\xBB\xBF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n"
            "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
            "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            " xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"");
        if (part[0]) fz_append_string(ctx, buf, " xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"");
        fz_append_string(ctx, buf, ">\n");
        const char *title = pdf_dict_get_text_string(ctx, info, PDF_NAME(Title));
        const char *author = pdf_dict_get_text_string(ctx, info, PDF_NAME(Author));
        const char *subject = pdf_dict_get_text_string(ctx, info, PDF_NAME(Subject));
        const char *keywords = pdf_dict_get_text_string(ctx, info, PDF_NAME(Keywords));
        const char *producer = pdf_dict_get_text_string(ctx, info, PDF_NAME(Producer));
        if (title[0]) {
            fz_append_string(ctx, buf, "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">");
            append_xml_escaped(ctx, buf, title);
            fz_append_string(ctx, buf, "</rdf:li></rdf:Alt></dc:title>\n");
        }
        if (author[0]) {
            fz_append_string(ctx, buf, "<dc:creator><rdf:Seq><rdf:li>");
            append_xml_escaped(ctx, buf, author);
            fz_append_string(ctx, buf, "</rdf:li></rdf:Seq></dc:creator>\n");
        }
        if (subject[0]) {
            fz_append_string(ctx, buf, "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">");
            append_xml_escaped(ctx, buf, subject);
            fz_append_string(ctx, buf, "</rdf:li></rdf:Alt></dc:description>\n");
        }
        if (keywords[0]) {
            fz_append_string(ctx, buf, "<pdf:Keywords>");
            append_xml_escaped(ctx, buf, keywords);
            fz_append_string(ctx, buf, "</pdf:Keywords>\n");
        }
        if (producer[0]) {
            fz_append_string(ctx, buf, "<pdf:Producer>");
            append_xml_escaped(ctx, buf, producer);
            fz_append_string(ctx, buf, "</pdf:Producer>\n");
        }
        int64_t created = pdf_dict_get_date(ctx, info, PDF_NAME(CreationDate));
        if (created > 0) {
            char date[32];
            iso_date(created, date);
            fz_append_printf(ctx, buf, "<xmp:CreateDate>%s</xmp:CreateDate>\n", date);
        }
        fz_append_printf(ctx, buf, "<xmp:ModifyDate>%s</xmp:ModifyDate>\n<xmp:MetadataDate>%s</xmp:MetadataDate>\n", modified, modified);
        if (part[0]) {
            fz_append_printf(ctx, buf, "<pdfaid:part>%s</pdfaid:part>\n", part);
            if (conformance[0]) fz_append_printf(ctx, buf, "<pdfaid:conformance>%s</pdfaid:conformance>\n", conformance);
        }
        fz_append_string(ctx, buf, "</rdf:Description>\n</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>");
        pdf_dict_del(ctx, stream, PDF_NAME(Filter));
        pdf_dict_del(ctx, stream, PDF_NAME(DecodeParms));
        pdf_dict_put(ctx, stream, PDF_NAME(Type), PDF_NAME(Metadata));
        pdf_dict_put(ctx, stream, PDF_NAME(Subtype), PDF_NAME(XML));
        pdf_update_stream(ctx, pdf, stream, buf, 0);
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, old);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

bool opdf_metadata_set(opdf_doc *d, const opdf_metadata_spec *spec, int64_t now, opdf_error *err) {
    clear_error(err);
    WITH_DOC_OPERATION(d, "Change Info", err, {
        const char *values[4] = { spec->title, spec->author, spec->subject, spec->keywords };
        pdf_obj *keys[4] = { PDF_NAME(Title), PDF_NAME(Author), PDF_NAME(Subject), PDF_NAME(Keywords) };
        for (int i = 0; i < 4; i++)
            if (values[i] && strlen(values[i]) > OPDF_MAX_METADATA_TEXT) fz_throw(ctx, FZ_ERROR_LIMIT, "That is too long for the document's information");
        pdf_obj *trailer = pdf_trailer(ctx, pdf);
        pdf_obj *info = pdf_dict_get(ctx, trailer, PDF_NAME(Info));
        if (!pdf_is_dict(ctx, info)) {
            // Adding an object can start a new section with its own copy
            // of the trailer: the Info goes in the current one.
            pdf_obj *made = pdf_add_new_dict(ctx, pdf, 4);
            trailer = pdf_trailer(ctx, pdf);
            pdf_dict_put_drop(ctx, trailer, PDF_NAME(Info), made);
            info = made;
        }
        for (int i = 0; i < 4; i++) {
            if (!values[i]) continue;
            if (values[i][0]) pdf_dict_put_text_string(ctx, info, keys[i], values[i]);
            else pdf_dict_del(ctx, info, keys[i]);
        }
        pdf_dict_put_date(ctx, info, PDF_NAME(ModDate), now);
        pdf_obj *xmp = pdf_dict_getp(ctx, trailer, "Root/Metadata");
        if (pdf_is_stream(ctx, xmp)) rewrite_xmp(ctx, pdf, xmp, info, now);
    });
    unlock_doc(d);
    return !(err && err->code);
}

// Page numbers as a set: true for each page listed (and in range).
static bool *page_set(fz_context *ctx, const int *pages, int count, int total) {
    bool *set = checked_calloc(ctx, (size_t)(total > 0 ? total : 1), sizeof *set);
    for (int i = 0; i < count; i++)
        if (pages[i] >= 0 && pages[i] < total) set[pages[i]] = true;
    return set;
}

bool opdf_pages_delete(opdf_doc *d, const int *pages, int count, opdf_error *err) {
    clear_error(err);
    bool *set = NULL;
    fz_var(set);
    WITH_DOC_OPERATION(d, "Delete Pages", err, {
        int total = pdf_count_pages(ctx, pdf);
        set = page_set(ctx, pages, count, total);
        int remaining = total;
        for (int i = 0; i < total; i++) if (set[i]) remaining--;
        if (remaining < 1) fz_throw(ctx, FZ_ERROR_ARGUMENT, "A document needs at least one page");
        for (int i = total - 1; i >= 0; i--)
            if (set[i]) pdf_delete_page(ctx, pdf, i);
    });
    unlock_doc(d);
    free(set);
    return !(err && err->code);
}

// Puts the pages in a new order by giving the root of the page tree a new
// /Kids list. Unlike pdf_rearrange_pages, the catalog is left alone, so
// forms, attachments, metadata, page labels and the outline all stay.
static void reorder_page_tree(fz_context *ctx, pdf_document *pdf, const int *order, int count, pdf_obj **pages) {
    pdf_obj *inheritable[] = { PDF_NAME(Resources), PDF_NAME(MediaBox), PDF_NAME(CropBox), PDF_NAME(Rotate) };
    pdf_obj *root = pdf_dict_get(ctx, pdf_dict_get(ctx, pdf_trailer(ctx, pdf), PDF_NAME(Root)), PDF_NAME(Pages));
    if (!pdf_is_dict(ctx, root)) fz_throw(ctx, FZ_ERROR_FORMAT, "Cannot find the page tree");
    for (int i = 0; i < count; i++) {
        pages[i] = pdf_keep_obj(ctx, pdf_lookup_page_obj(ctx, pdf, i));
        if (!pdf_is_dict(ctx, pages[i])) fz_throw(ctx, FZ_ERROR_FORMAT, "A page is missing");
    }
    // Each page takes what it inherited from the nodes being left behind.
    for (int i = 0; i < count; i++) {
        for (size_t k = 0; k < sizeof inheritable / sizeof *inheritable; k++) {
            pdf_obj *key = inheritable[k];
            if (pdf_dict_get(ctx, pages[i], key)) continue;
            pdf_obj *value = pdf_dict_get_inheritable(ctx, pages[i], key);
            if (!value) continue;
            // A direct object gets a copy per page, so no two pages share it.
            if (pdf_is_indirect(ctx, value)) pdf_dict_put(ctx, pages[i], key, value);
            else pdf_dict_put_drop(ctx, pages[i], key, pdf_deep_copy_obj(ctx, value));
        }
    }
    pdf_obj *kids = pdf_new_array(ctx, pdf, count);
    fz_try(ctx) {
        for (int i = 0; i < count; i++) {
            pdf_array_push(ctx, kids, pages[order[i]]);
            pdf_dict_put(ctx, pages[order[i]], PDF_NAME(Parent), root);
        }
        pdf_dict_put(ctx, root, PDF_NAME(Kids), kids);
        pdf_dict_put_int(ctx, root, PDF_NAME(Count), count);
    }
    fz_always(ctx)
        pdf_drop_obj(ctx, kids);
    fz_catch(ctx)
        fz_rethrow(ctx);
}

bool opdf_pages_reorder(opdf_doc *d, const int *order, int count, opdf_error *err) {
    clear_error(err);
    bool *seen = NULL;
    pdf_obj **pages = NULL;
    int total = 0;
    fz_var(seen);
    fz_var(pages);
    fz_var(total);
    WITH_DOC_OPERATION(d, "Move Pages", err, {
        total = pdf_count_pages(ctx, pdf);
        if (count != total) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The new order must list every page");
        seen = checked_calloc(ctx, (size_t)(total > 0 ? total : 1), sizeof *seen);
        for (int i = 0; i < count; i++) {
            if (order[i] < 0 || order[i] >= total || seen[order[i]])
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "The new order must list every page once");
            seen[order[i]] = true;
        }
        pages = checked_calloc(ctx, (size_t)(total > 0 ? total : 1), sizeof *pages);
        reorder_page_tree(ctx, pdf, order, count, pages);
    });
    if (pages)
        for (int i = 0; i < total; i++) pdf_drop_obj(d->ctx, pages[i]);
    // Loaded pages learn their new numbers.
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (pdf) pdf_sync_open_pages(d->ctx, pdf);
    }
    fz_catch(d->ctx) {}
    unlock_doc(d);
    free(pages);
    free(seen);
    return !(err && err->code);
}

bool opdf_page_insert_blank(opdf_doc *d, int at, float width, float height, opdf_error *err) {
    clear_error(err);
    fz_buffer *contents = NULL;
    pdf_obj *resources = NULL, *page = NULL;
    fz_var(contents);
    fz_var(resources);
    fz_var(page);
    WITH_DOC_OPERATION(d, "Insert Page", err, {
        if (!(width >= 72 && width <= 14400 && height >= 72 && height <= 14400))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Page size out of range");
        int total = pdf_count_pages(ctx, pdf);
        contents = fz_new_buffer(ctx, 1);
        resources = pdf_new_dict(ctx, pdf, 1);
        page = pdf_add_page(ctx, pdf, fz_make_rect(0, 0, width, height), 0, resources, contents);
        pdf_insert_page(ctx, pdf, (at < 0 || at > total) ? -1 : at, page);
        pdf_drop_obj(ctx, page); page = NULL;
        pdf_drop_obj(ctx, resources); resources = NULL;
        fz_drop_buffer(ctx, contents); contents = NULL;
    });
    // On failure, whatever was made is dropped here.
    pdf_drop_obj(d->ctx, page);
    pdf_drop_obj(d->ctx, resources);
    fz_drop_buffer(d->ctx, contents);
    unlock_doc(d);
    return !(err && err->code);
}

bool opdf_pages_rotate(opdf_doc *d, const int *pages, int count, int degrees, opdf_error *err) {
    clear_error(err);
    bool *set = NULL;
    fz_var(set);
    WITH_DOC_OPERATION(d, degrees > 0 ? "Rotate Right" : "Rotate Left", err, {
        if (degrees % 90 != 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Pages turn in quarter turns");
        int total = pdf_count_pages(ctx, pdf);
        set = page_set(ctx, pages, count, total);
        for (int i = 0; i < total; i++) {
            if (!set[i]) continue;
            pdf_obj *page = pdf_lookup_page_obj(ctx, pdf, i);
            // A file's /Rotate can be any integer; reduce it before adding.
            int rotate = pdf_to_int(ctx, pdf_dict_get_inheritable(ctx, page, PDF_NAME(Rotate))) % 360;
            rotate = ((rotate + degrees % 360) % 360 + 360) % 360;
            rotate -= rotate % 90;
            pdf_dict_put_int(ctx, page, PDF_NAME(Rotate), rotate);
        }
    });
    unlock_doc(d);
    free(set);
    return !(err && err->code);
}

bool opdf_pages_crop(opdf_doc *d, const int *pages, int count, opdf_rect box, opdf_error *err) {
    clear_error(err);
    bool *set = NULL;
    pdf_page *page = NULL;
    fz_var(set);
    fz_var(page);
    WITH_DOC_OPERATION(d, "Crop", err, {
        fz_rect want = rect_from(box);
        if (fz_is_empty_rect(want) || want.x1 - want.x0 < 4 || want.y1 - want.y0 < 4)
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "The crop area is too small");
        int total = pdf_count_pages(ctx, pdf);
        set = page_set(ctx, pages, count, total);
        for (int i = 0; i < total; i++) {
            if (!set[i]) continue;
            page = pdf_load_page(ctx, pdf, i);
            fz_rect visible = fz_intersect_rect(want, pdf_bound_page(ctx, page, FZ_CROP_BOX));
            if (!fz_is_empty_rect(visible) && visible.x1 - visible.x0 >= 4 && visible.y1 - visible.y0 >= 4)
                pdf_set_page_box(ctx, page, FZ_CROP_BOX, visible);
            fz_drop_page(ctx, (fz_page *)page);
            page = NULL;
        }
    });
    if (page) fz_drop_page(d->ctx, (fz_page *)page);
    unlock_doc(d);
    free(set);
    return !(err && err->code);
}

bool opdf_insert_file(opdf_doc *d, int at, const char *path, const char *password, int *inserted, opdf_error *err) {
    clear_error(err);
    *inserted = 0;
    pdf_document *src = NULL;
    pdf_graft_map *map = NULL;
    int n = 0;
    fz_var(src);
    fz_var(map);
    fz_var(n);
    WITH_DOC_OPERATION(d, "Insert Pages", err, {
        src = pdf_open_document(ctx, path);
        if (pdf_needs_password(ctx, src) && !(password && pdf_authenticate_password(ctx, src, password)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "The file is password protected");
        int pages = pdf_count_pages(ctx, src);
        if (pages > 10000) fz_throw(ctx, FZ_ERROR_LIMIT, "The file has too many pages");
        int total = pdf_count_pages(ctx, pdf);
        int where = (at < 0 || at > total) ? total : at;
        map = pdf_new_graft_map(ctx, pdf);
        for (int i = 0; i < pages; i++) {
            pdf_graft_mapped_page(ctx, map, where + i, src, i);
            n++;
        }
    });
    pdf_drop_graft_map(d->ctx, map);
    pdf_drop_document(d->ctx, src);
    unlock_doc(d);
    if (err && err->code) return false;
    *inserted = n;
    return true;
}

bool opdf_extract_pages(opdf_doc *d, const int *pages, int count, const char *path, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    pdf_document *dst = NULL;
    pdf_graft_map *map = NULL;
    bool ok = false;
    fz_var(dst);
    fz_var(map);
    fz_var(ok);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        int total = pdf_count_pages(ctx, pdf);
        dst = pdf_create_document(ctx);
        map = pdf_new_graft_map(ctx, dst);
        int n = 0;
        for (int i = 0; i < count; i++) {
            if (pages[i] < 0 || pages[i] >= total) continue;
            pdf_graft_mapped_page(ctx, map, -1, pdf, pages[i]);
            n++;
        }
        if (n == 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "No pages to extract");
        pdf_write_options opts = pdf_default_write_options;
        opts.do_garbage = 1;
        opts.do_compress = 1;
        opts.do_use_objstms = 1;
        pdf_save_document(ctx, dst, path, &opts);
        ok = true;
    }
    fz_always(ctx) {
        pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, dst);
    }
    fz_catch(ctx)
        set_error(err, ctx);
    unlock_doc(d);
    return ok;
}

// --- Conversion contexts ------------------------------------------------------
//
// Converting and reducing run in contexts of their own, with an allocator
// that counts what is in use: past the cap, or once cancelled, every
// allocation fails, so MuPDF stops with an error wherever it is (even in the
// middle of laying out a document, which can't otherwise be interrupted).

opdf_cancel *opdf_cancel_new(void) {
    opdf_cancel *cancel = calloc(1, sizeof *cancel);
    if (cancel) atomic_init(&cancel->requested, 0);
    return cancel;
}

void opdf_cancel_request(opdf_cancel *cancel) {
    if (cancel) atomic_store(&cancel->requested, 1);
}

void opdf_cancel_free(opdf_cancel *cancel) { free(cancel); }

#define OPDF_CONVERSION_MEMORY ((long long)3 << 30)

// A context whose memory is counted against a budget of its own; release
// the budget with release_budget after dropping the context. `owner` and
// `alloc` must outlive the context. `handlers` registers document handlers
// (only ever in a context like this, which never holds the open document):
// none, PDF and images only, or every kind MuPDF reads.
enum capped_handlers { NO_HANDLERS, PDF_AND_IMAGE_HANDLERS, ALL_HANDLERS };
extern fz_document_handler img_document_handler;
static fz_context *new_capped_context(allocator_owner *owner, fz_alloc_context *alloc, opdf_cancel *cancel,
                                      enum capped_handlers handlers) {
    owner->budget = -1;
    owner->limit = OPDF_CONVERSION_MEMORY;
    owner->cancel = cancel;
    atomic_init(&owner->over_limit, 0);
    for (int i = 0; i < BUDGETS && owner->budget < 0; i++) {
        int expected = 0;
        if (atomic_compare_exchange_strong(&budget_taken[i], &expected, 1)) {
            owner->budget = i;
            owner->base = atomic_load(&budget_used[i]);
        }
    }
    if (owner->budget < 0) return NULL;
    *alloc = (fz_alloc_context){ owner, shared_malloc, shared_realloc, shared_free };
    fz_context *ctx = fz_new_context(alloc, shared_locks(), FZ_STORE_DEFAULT);
    if (!ctx) return NULL;
    make_quiet(ctx);
    if (handlers != NO_HANDLERS) {
        fz_try(ctx) {
            if (handlers == ALL_HANDLERS) {
                fz_register_document_handlers(ctx);
            } else {
                fz_register_document_handler(ctx, &pdf_document_handler);
                fz_register_document_handler(ctx, &img_document_handler);
            }
        }
        fz_catch(ctx) {
            fz_drop_context(ctx);
            return NULL;
        }
    }
    return ctx;
}

static void release_budget(allocator_owner *owner) {
    if (owner->budget >= 0) atomic_store(&budget_taken[owner->budget], 0);
    owner->budget = -1;
}

// Why a capped context couldn't be made.
static void set_no_context_error(opdf_error *err, allocator_owner *owner) {
    set_message(err, owner_cancelled(owner) ? "Cancelled" : "Could not create a MuPDF context");
}

// The error to report from a capped context: why it stopped, if it was the cap.
static void set_capped_error(opdf_error *err, fz_context *ctx, allocator_owner *owner) {
    if (owner_cancelled(owner)) set_message(err, "Cancelled");
    else if (atomic_load(&owner->over_limit)) set_message(err, "The files need too much memory to convert");
    else set_error(err, ctx);
}

bool opdf_convert_files(const char *const *paths, int count, const char *out_path, float width, float height,
                        bool allow_documents, opdf_cancel *cancel, opdf_error *err) {
    clear_error(err);
    allocator_owner allocator;
    fz_alloc_context alloc;
    fz_context *ctx = new_capped_context(&allocator, &alloc, cancel,
                                         allow_documents ? ALL_HANDLERS : PDF_AND_IMAGE_HANDLERS);
    if (!ctx) {
        set_no_context_error(err, &allocator);
        release_budget(&allocator);
        return false;
    }
    pdf_document *out = NULL;
    fz_document *src = NULL;
    fz_buffer *buffer = NULL;
    fz_output *bout = NULL;
    fz_document_writer *writer = NULL;
    fz_stream *stm = NULL;
    pdf_document *converted = NULL;
    pdf_graft_map *map = NULL;
    fz_page *page = NULL;
    fz_device *dev = NULL;
    bool ok = false;
    fz_var(out); fz_var(src); fz_var(buffer); fz_var(bout); fz_var(writer);
    fz_var(stm); fz_var(converted); fz_var(map); fz_var(page); fz_var(dev); fz_var(ok);
    fz_try(ctx) {
        if (!(width >= 72 && width <= 14400 && height >= 72 && height <= 14400))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Page size out of range");
        out = pdf_create_document(ctx);
        int pages_total = 0;
        for (int f = 0; f < count; f++) {
            // With only the PDF and image handlers registered, a file is
            // recognised by its content as one of those, or refused.
            if (!allow_documents && !fz_recognize_document_content(ctx, paths[f]))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Only PDFs and images can be converted while converting other documents is turned off in Settings");
            src = fz_open_document(ctx, paths[f]);
            if (fz_needs_password(ctx, src)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "A file is password protected");
            pdf_document *src_pdf = pdf_specifics(ctx, src);
            if (src_pdf) {
                // PDFs: each page's contents and resources are copied
                // (annotations, links and form fields aren't).
                map = pdf_new_graft_map(ctx, out);
                int n = pdf_count_pages(ctx, src_pdf);
                for (int i = 0; i < n; i++) {
                    if (++pages_total > 20000) fz_throw(ctx, FZ_ERROR_LIMIT, "Too many pages");
                    pdf_graft_mapped_page(ctx, map, -1, src_pdf, i);
                }
                pdf_drop_graft_map(ctx, map);
                map = NULL;
            } else {
                // Anything else: laid out (if it reflows) and drawn into a PDF,
                // whose pages are then copied in.
                if (fz_is_document_reflowable(ctx, src)) fz_layout_document(ctx, src, width, height, 11);
                buffer = fz_new_buffer(ctx, 1 << 16);
                bout = fz_new_output_with_buffer(ctx, buffer);
                writer = fz_new_pdf_writer_with_output(ctx, bout, "compress");
                bout = NULL;   // the writer owns it now
                int n = fz_count_pages(ctx, src);
                for (int i = 0; i < n; i++) {
                    if (++pages_total > 20000) fz_throw(ctx, FZ_ERROR_LIMIT, "Too many pages");
                    page = fz_load_page(ctx, src, i);
                    fz_rect bounds = fz_bound_page(ctx, page);
                    if (fz_is_empty_rect(bounds) || bounds.x1 - bounds.x0 > 14400 || bounds.y1 - bounds.y0 > 14400)
                        bounds = fz_make_rect(0, 0, width, height);
                    dev = fz_begin_page(ctx, writer, bounds);
                    fz_run_page(ctx, page, dev, fz_identity, NULL);
                    dev = NULL;
                    fz_end_page(ctx, writer);
                    fz_drop_page(ctx, page);
                    page = NULL;
                }
                fz_close_document_writer(ctx, writer);
                fz_drop_document_writer(ctx, writer);
                writer = NULL;
                stm = fz_open_buffer(ctx, buffer);
                converted = pdf_open_document_with_stream(ctx, stm);
                map = pdf_new_graft_map(ctx, out);
                int m = pdf_count_pages(ctx, converted);
                for (int i = 0; i < m; i++) pdf_graft_mapped_page(ctx, map, -1, converted, i);
                pdf_drop_graft_map(ctx, map); map = NULL;
                pdf_drop_document(ctx, converted); converted = NULL;
                fz_drop_stream(ctx, stm); stm = NULL;
                fz_drop_buffer(ctx, buffer); buffer = NULL;
            }
            fz_drop_document(ctx, src);
            src = NULL;
        }
        if (pdf_count_pages(ctx, out) == 0) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Nothing to make a PDF of");
        pdf_write_options opts = pdf_default_write_options;
        opts.do_garbage = 1;
        opts.do_compress = 1;
        opts.do_use_objstms = 1;
        pdf_save_document(ctx, out, out_path, &opts);
        ok = true;
    }
    fz_always(ctx) {
        fz_drop_page(ctx, page);
        fz_drop_document_writer(ctx, writer);
        fz_drop_output(ctx, bout);
        pdf_drop_graft_map(ctx, map);
        pdf_drop_document(ctx, converted);
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, buffer);
        fz_drop_document(ctx, src);
        pdf_drop_document(ctx, out);
    }
    fz_catch(ctx)
        set_capped_error(err, ctx, &allocator);
    fz_drop_context(ctx);
    release_budget(&allocator);
    return ok;
}

bool opdf_reduce_file(const char *in_path, const char *password, const char *out_path, int quality,
                      opdf_cancel *cancel, opdf_error *err) {
    clear_error(err);
    allocator_owner allocator;
    fz_alloc_context alloc;
    fz_context *ctx = new_capped_context(&allocator, &alloc, cancel, NO_HANDLERS);
    if (!ctx) {
        set_no_context_error(err, &allocator);
        release_budget(&allocator);
        return false;
    }
    pdf_document *pdf = NULL;
    bool ok = false;
    fz_var(pdf);
    fz_var(ok);
    fz_try(ctx) {
        pdf = pdf_open_document(ctx, in_path);
        if (pdf_needs_password(ctx, pdf) && !(password && pdf_authenticate_password(ctx, pdf, password)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "The file is password protected");
        static const int dpi[3] = { 200, 150, 100 };
        static char *jpeg[3] = { "85", "70", "50" };
        int q = quality < 0 ? 0 : quality > 2 ? 2 : quality;
        pdf_image_rewriter_options opts;
        memset(&opts, 0, sizeof opts);
        opts.color_lossy_image_subsample_method = FZ_SUBSAMPLE_BICUBIC;
        opts.color_lossless_image_subsample_method = FZ_SUBSAMPLE_BICUBIC;
        opts.color_lossy_image_subsample_threshold = dpi[q] * 3 / 2;
        opts.color_lossy_image_subsample_to = dpi[q];
        opts.color_lossless_image_subsample_threshold = dpi[q] * 3 / 2;
        opts.color_lossless_image_subsample_to = dpi[q];
        opts.color_lossy_image_recompress_method = FZ_RECOMPRESS_JPEG;
        opts.color_lossless_image_recompress_method = FZ_RECOMPRESS_JPEG;
        opts.color_lossy_image_recompress_quality = jpeg[q];
        opts.color_lossless_image_recompress_quality = jpeg[q];
        opts.gray_lossy_image_subsample_method = FZ_SUBSAMPLE_BICUBIC;
        opts.gray_lossless_image_subsample_method = FZ_SUBSAMPLE_BICUBIC;
        opts.gray_lossy_image_subsample_threshold = dpi[q] * 3 / 2;
        opts.gray_lossy_image_subsample_to = dpi[q];
        opts.gray_lossless_image_subsample_threshold = dpi[q] * 3 / 2;
        opts.gray_lossless_image_subsample_to = dpi[q];
        opts.gray_lossy_image_recompress_method = FZ_RECOMPRESS_JPEG;
        opts.gray_lossless_image_recompress_method = FZ_RECOMPRESS_JPEG;
        opts.gray_lossy_image_recompress_quality = jpeg[q];
        opts.gray_lossless_image_recompress_quality = jpeg[q];
        opts.bitonal_image_subsample_method = FZ_SUBSAMPLE_AVERAGE;
        opts.bitonal_image_recompress_method = FZ_RECOMPRESS_NEVER;
        pdf_rewrite_images(ctx, pdf, &opts);
        pdf_write_options wopts = pdf_default_write_options;
        wopts.do_garbage = 3;
        wopts.do_compress = 1;
        wopts.do_compress_images = 1;
        wopts.do_compress_fonts = 1;
        wopts.do_use_objstms = 1;
        pdf_save_document(ctx, pdf, out_path, &wopts);
        ok = true;
    }
    fz_always(ctx)
        pdf_drop_document(ctx, pdf);
    fz_catch(ctx)
        set_capped_error(err, ctx, &allocator);
    fz_drop_context(ctx);
    release_budget(&allocator);
    return ok;
}
