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
#include <unistd.h>

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
    int access;            // pdf_authenticate_password's result for the last password given (4: owner)
    bool needs_open_password; // opening it takes a password (the empty one doesn't work)

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
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        if (pdf && pdf->crypt) {
            // The empty password's access is recorded, as a typed one's is.
            int access = pdf_authenticate_password(d->ctx, pdf, "");
            needs = access == 0;
            if (needs) d->needs_open_password = true;
            else d->access = access;
        } else {
            needs = fz_needs_password(d->ctx, d->doc) != 0;
        }
    }
    fz_catch(d->ctx)
        needs = false;
    unlock_doc(d);
    return needs;
}

bool opdf_needs_open_password(opdf_doc *d) {
    return d->needs_open_password;
}

bool opdf_authenticate(opdf_doc *d, const char *password) {
    bool ok = false;
    lock_doc(d);
    fz_try(d->ctx) {
        int access = fz_authenticate_password(d->ctx, d->doc, password);
        ok = access != 0;
        if (ok) d->access = access;
    }
    fz_catch(d->ctx)
        ok = false;
    unlock_doc(d);
    return ok;
}

bool opdf_is_owner(opdf_doc *d) {
    bool owner = true;
    lock_doc(d);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        // Unencrypted documents are anyone's; encrypted ones need the owner password.
        if (pdf && pdf->crypt) owner = (d->access & 4) != 0;
    }
    fz_catch(d->ctx)
        owner = false;
    unlock_doc(d);
    return owner;
}

int opdf_permission_bits(opdf_doc *d) {
    int bits = -1;
    lock_doc(d);
    fz_try(d->ctx) {
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        // Read from /Encrypt: MuPDF reports every permission to the owner.
        if (pdf && pdf->crypt)
            bits = pdf_dict_get_int(d->ctx, pdf_dict_get(d->ctx, pdf_trailer(d->ctx, pdf), PDF_NAME(Encrypt)), PDF_NAME(P));
    }
    fz_catch(d->ctx)
        bits = -1;
    unlock_doc(d);
    return bits;
}

int opdf_allowed(opdf_doc *d) {
    int allowed = 0;
    lock_doc(d);
    fz_try(d->ctx) {
        const struct { fz_permission perm; int bit; } map[] = {
            { FZ_PERMISSION_PRINT, OPDF_ALLOW_PRINT }, { FZ_PERMISSION_COPY, OPDF_ALLOW_COPY },
            { FZ_PERMISSION_EDIT, OPDF_ALLOW_EDIT }, { FZ_PERMISSION_ANNOTATE, OPDF_ALLOW_ANNOTATE },
            { FZ_PERMISSION_FORM, OPDF_ALLOW_FORMS }, { FZ_PERMISSION_ASSEMBLE, OPDF_ALLOW_ASSEMBLE },
        };
        pdf_document *pdf = pdf_specifics(d->ctx, d->doc);
        bool owner = !pdf || !pdf->crypt || (d->access & 4);
        for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
            if (owner || fz_has_permission(d->ctx, d->doc, map[i].perm)) allowed |= map[i].bit;
    }
    fz_catch(d->ctx)
        allowed = 0;
    unlock_doc(d);
    return allowed;
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

// Deletes the annotations marked in `doomed` (in page order, `n` of them in
// `annots`) with their replies, their replies' replies, and so on.
static void delete_with_replies(fz_context *ctx, pdf_page *pp, int n, pdf_annot **annots, bool *doomed) {
    int *parent = NULL, *ids = NULL, *irt = NULL, *order = NULL;
    fz_var(parent);
    fz_var(ids);
    fz_var(irt);
    fz_var(order);
    fz_try(ctx) {
        parent = checked_calloc(ctx, (size_t)n, sizeof *parent);
        ids = checked_calloc(ctx, (size_t)n, sizeof *ids);
        irt = checked_calloc(ctx, (size_t)n, sizeof *irt);
        order = checked_calloc(ctx, (size_t)n, sizeof *order);
        int i;
        for (i = 0; i < n; i++) {
            ids[i] = annot_id(ctx, annots[i]);
            irt[i] = pdf_to_num(ctx, pdf_dict_get(ctx, pdf_annot_obj(ctx, annots[i]), PDF_NAME(IRT)));
        }
        // Parent indices through a sorted copy of the ids: O(n log n).
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
    }
    fz_always(ctx) {
        free(parent);
        free(ids);
        free(irt);
        free(order);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

bool opdf_annot_delete(opdf_doc *d, int page_number, int id, const char *operation, opdf_error *err) {
    clear_error(err);
    pdf_annot **annots = NULL;
    bool *doomed = NULL;
    fz_var(annots);
    fz_var(doomed);
    WITH_PAGE_OPERATION(d, page_number, operation, err, {
        (void)find_annot(ctx, pp, id);
        int n = 0;
        for (pdf_annot *a = pdf_first_annot(ctx, pp); a; a = pdf_next_annot(ctx, a)) n++;
        annots = checked_calloc(ctx, (size_t)n, sizeof *annots);
        doomed = checked_calloc(ctx, (size_t)n, sizeof *doomed);
        int i = 0;
        for (pdf_annot *a = pdf_first_annot(ctx, pp); a && i < n; a = pdf_next_annot(ctx, a), i++) {
            annots[i] = a;
            doomed[i] = annot_id(ctx, a) == id;
        }
        delete_with_replies(ctx, pp, i, annots, doomed);
    });
    free(annots);
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

// --- Page content ------------------------------------------------------------------
//
// One processor reads the page's content stream, tracking the graphics and
// text state, and numbers its text operations and image drawings. Recording,
// it lists them; rewriting, it is chained to MuPDF's buffer processor and
// passes everything through except the operation being changed.

typedef struct {
    fz_matrix ctm;
    pdf_text_state text;          // text.font is kept
    char font_name[128];          // the font's resource name, from Tf
    int fill_n;                   // 1, 3 or 4 for DeviceGray, RGB, CMYK; 0 otherwise
    float fill[4];
} content_gstate;

typedef struct content_proc content_proc;
struct content_proc {
    pdf_processor super;
    pdf_processor *out;           // the buffer processor when rewriting
    pdf_processor *real_out;      // the same, kept while `out` is switched off
    pdf_document *doc;
    fz_matrix page_ctm;
    content_gstate gs[OPDF_MAX_GSTATE_DEPTH];
    int top;
    int overflow;                 // q's past the limit, ignored with their Q's
    pdf_text_object_state tos;
    int text_ops, image_ops;
    // Recording.
    opdf_page_content *record;
    int run_capacity, image_capacity;
    int chars_left;
    // Rewriting: the operation to replace, and what to draw instead.
    int target_text, target_image;
    // array (TJ) or str/len (Tj, ' and "): the operation being replaced.
    void (*emit_text)(fz_context *ctx, content_proc *p, pdf_obj *array, const char *str, size_t len, void *arg);
    void (*emit_image)(fz_context *ctx, content_proc *p, const char *name, fz_image *image, void *arg);
    // Called at the end of the content, with the graphics state balanced.
    void (*emit_end)(fz_context *ctx, content_proc *p, void *arg);
    void *arg;
    // The state in effect at one text operation (recording).
    int probe_op;
    struct run_probe *probe;
};


#define CHAIN(p) ((p)->out)
#define G(p) (&(p)->gs[(p)->top])

typedef struct run_probe {
    pdf_font_desc *font;   // kept
    bool found;
} run_probe;

static void probe_text_op(fz_context *ctx, content_proc *p) {
    if (p->probe && !p->probe->found && p->text_ops == p->probe_op && G(p)->text.font) {
        p->probe->font = pdf_keep_font(ctx, G(p)->text.font);
        p->probe->found = true;
    }
}

static void cp_q(fz_context *ctx, pdf_processor *proc) {
    content_proc *p = (content_proc *)proc;
    if (p->top + 1 >= OPDF_MAX_GSTATE_DEPTH) {
        p->overflow++;
    } else {
        p->gs[p->top + 1] = p->gs[p->top];
        p->top++;
        pdf_keep_font(ctx, G(p)->text.font);
    }
    if (CHAIN(p)) CHAIN(p)->op_q(ctx, CHAIN(p));
}

static void cp_Q(fz_context *ctx, pdf_processor *proc) {
    content_proc *p = (content_proc *)proc;
    if (p->overflow > 0) {
        p->overflow--;
    } else if (p->top > 0) {
        pdf_drop_font(ctx, G(p)->text.font);
        G(p)->text.font = NULL;
        p->top--;
    }
    if (CHAIN(p)) CHAIN(p)->op_Q(ctx, CHAIN(p));
}

static void cp_cm(fz_context *ctx, pdf_processor *proc, float a, float b, float c, float d, float e, float f) {
    content_proc *p = (content_proc *)proc;
    G(p)->ctm = fz_concat(fz_make_matrix(a, b, c, d, e, f), G(p)->ctm);
    if (CHAIN(p)) CHAIN(p)->op_cm(ctx, CHAIN(p), a, b, c, d, e, f);
}

static void cp_BT(fz_context *ctx, pdf_processor *proc) {
    content_proc *p = (content_proc *)proc;
    p->tos.tm = fz_identity;
    p->tos.tlm = fz_identity;
    if (CHAIN(p)) CHAIN(p)->op_BT(ctx, CHAIN(p));
}

static void cp_Tc(fz_context *ctx, pdf_processor *proc, float v) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.char_space = v;
    if (CHAIN(p)) CHAIN(p)->op_Tc(ctx, CHAIN(p), v);
}

static void cp_Tw(fz_context *ctx, pdf_processor *proc, float v) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.word_space = v;
    if (CHAIN(p)) CHAIN(p)->op_Tw(ctx, CHAIN(p), v);
}

static void cp_Tz(fz_context *ctx, pdf_processor *proc, float v) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.scale = v / 100;
    if (CHAIN(p)) CHAIN(p)->op_Tz(ctx, CHAIN(p), v);
}

static void cp_TL(fz_context *ctx, pdf_processor *proc, float v) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.leading = v;
    if (CHAIN(p)) CHAIN(p)->op_TL(ctx, CHAIN(p), v);
}

static void cp_Ts(fz_context *ctx, pdf_processor *proc, float v) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.rise = v;
    if (CHAIN(p)) CHAIN(p)->op_Ts(ctx, CHAIN(p), v);
}

static void cp_Tr(fz_context *ctx, pdf_processor *proc, int v) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.render = v;
    if (CHAIN(p)) CHAIN(p)->op_Tr(ctx, CHAIN(p), v);
}

static void cp_Tf(fz_context *ctx, pdf_processor *proc, const char *name, pdf_font_desc *font, float size) {
    content_proc *p = (content_proc *)proc;
    pdf_drop_font(ctx, G(p)->text.font);
    G(p)->text.font = pdf_keep_font(ctx, font);
    G(p)->text.size = size;
    fz_strlcpy(G(p)->font_name, name ? name : "", sizeof G(p)->font_name);
    if (CHAIN(p)) CHAIN(p)->op_Tf(ctx, CHAIN(p), name, font, size);
}

static void cp_Td(fz_context *ctx, pdf_processor *proc, float tx, float ty) {
    content_proc *p = (content_proc *)proc;
    pdf_tos_translate(&p->tos, tx, ty);
    if (CHAIN(p)) CHAIN(p)->op_Td(ctx, CHAIN(p), tx, ty);
}

static void cp_TD(fz_context *ctx, pdf_processor *proc, float tx, float ty) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.leading = -ty;
    pdf_tos_translate(&p->tos, tx, ty);
    if (CHAIN(p)) CHAIN(p)->op_TD(ctx, CHAIN(p), tx, ty);
}

static void cp_Tm(fz_context *ctx, pdf_processor *proc, float a, float b, float c, float d, float e, float f) {
    content_proc *p = (content_proc *)proc;
    pdf_tos_set_matrix(&p->tos, a, b, c, d, e, f);
    if (CHAIN(p)) CHAIN(p)->op_Tm(ctx, CHAIN(p), a, b, c, d, e, f);
}

static void cp_Tstar(fz_context *ctx, pdf_processor *proc) {
    content_proc *p = (content_proc *)proc;
    pdf_tos_newline(&p->tos, G(p)->text.leading);
    if (CHAIN(p)) CHAIN(p)->op_Tstar(ctx, CHAIN(p));
}

static void set_fill(content_proc *p, int n, const float *v) {
    G(p)->fill_n = n;
    for (int i = 0; i < 4; i++) G(p)->fill[i] = i < n ? v[i] : 0;
}

static void cp_g(fz_context *ctx, pdf_processor *proc, float g) {
    content_proc *p = (content_proc *)proc;
    set_fill(p, 1, &g);
    if (CHAIN(p)) CHAIN(p)->op_g(ctx, CHAIN(p), g);
}

static void cp_rg(fz_context *ctx, pdf_processor *proc, float r, float g, float b) {
    content_proc *p = (content_proc *)proc;
    float v[3] = { r, g, b };
    set_fill(p, 3, v);
    if (CHAIN(p)) CHAIN(p)->op_rg(ctx, CHAIN(p), r, g, b);
}

static void cp_k(fz_context *ctx, pdf_processor *proc, float c, float m, float y, float k) {
    content_proc *p = (content_proc *)proc;
    float v[4] = { c, m, y, k };
    set_fill(p, 4, v);
    if (CHAIN(p)) CHAIN(p)->op_k(ctx, CHAIN(p), c, m, y, k);
}

static void cp_cs(fz_context *ctx, pdf_processor *proc, const char *name, fz_colorspace *cs) {
    content_proc *p = (content_proc *)proc;
    float zero[4] = { 0, 0, 0, 1 };
    // Only the device spaces by their own names: anything else can't be
    // restored with g, rg or k.
    if (name && !strcmp(name, "DeviceGray")) set_fill(p, 1, zero);
    else if (name && !strcmp(name, "DeviceRGB")) set_fill(p, 3, zero);
    else if (name && !strcmp(name, "DeviceCMYK")) set_fill(p, 4, zero);
    else set_fill(p, 0, zero);
    if (CHAIN(p)) CHAIN(p)->op_cs(ctx, CHAIN(p), name, cs);
}

static void cp_sc_color(fz_context *ctx, pdf_processor *proc, int n, float *color) {
    content_proc *p = (content_proc *)proc;
    if (G(p)->fill_n == n) set_fill(p, n, color);
    else set_fill(p, 0, color);
    if (CHAIN(p)) CHAIN(p)->op_sc_color(ctx, CHAIN(p), n, color);
}

static void cp_sc_pattern(fz_context *ctx, pdf_processor *proc, const char *name, pdf_pattern *pat, int n, float *color) {
    content_proc *p = (content_proc *)proc;
    set_fill(p, 0, color);
    if (CHAIN(p)) CHAIN(p)->op_sc_pattern(ctx, CHAIN(p), name, pat, n, color);
}

static void cp_sc_shade(fz_context *ctx, pdf_processor *proc, const char *name, fz_shade *shade) {
    content_proc *p = (content_proc *)proc;
    float none[4] = { 0 };
    set_fill(p, 0, none);
    if (CHAIN(p)) CHAIN(p)->op_sc_shade(ctx, CHAIN(p), name, shade);
}

// --- Recording text

static opdf_text_run *new_run(fz_context *ctx, content_proc *p) {
    opdf_page_content *c = p->record;
    if (c->run_count == p->run_capacity) {
        int grown = p->run_capacity ? p->run_capacity * 2 : 64;
        opdf_text_run *bigger = realloc(c->runs, (size_t)grown * sizeof *bigger);
        if (!bigger) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        c->runs = bigger;
        p->run_capacity = grown;
    }
    opdf_text_run *run = &c->runs[c->run_count++];
    memset(run, 0, sizeof *run);
    return run;
}

typedef struct {
    opdf_text_run *run;
    fz_buffer *utf8;
    int capacity;
    fz_rect bounds;
} run_builder;

// One glyph of the current string: its Unicode, and its box in page space.
static void record_glyph(fz_context *ctx, content_proc *p, run_builder *b, int cid) {
    pdf_font_desc *font = G(p)->text.font;
    fz_matrix trm;
    float adv;
    pdf_tos_make_trm(ctx, &p->tos, &G(p)->text, font, cid, &trm, &adv);
    if (!b->run) return;
    int ucs[PDF_MRANGE_CAP];
    int n = font->to_unicode ? pdf_lookup_cmap_full(font->to_unicode, cid, ucs) : 0;
    if (n == 0 && cid >= 0 && (size_t)cid < font->cid_to_ucs_len) {
        ucs[0] = font->cid_to_ucs[cid];
        n = 1;
    }
    if (n == 0 || (n == 1 && ucs[0] == 0)) {
        ucs[0] = FZ_REPLACEMENT_CHARACTER;
        n = 1;
    }
    if (b->run->quad_count >= OPDF_MAX_RUN_CHARS || p->chars_left <= 0) {
        b->run->not_editable = OPDF_RUN_TOO_LONG;
        return;
    }
    p->chars_left--;
    for (int i = 0; i < n; i++) {
        char utf[8];
        int len = fz_runetochar(utf, ucs[i]);
        fz_append_data(ctx, b->utf8, utf, (size_t)len);
    }
    fz_matrix m = fz_concat(fz_concat(trm, G(p)->ctm), p->page_ctm);
    float asc = fz_font_ascender(ctx, font->font), desc = fz_font_descender(ctx, font->font);
    fz_quad q = fz_transform_quad(fz_quad_from_rect(fz_make_rect(0, desc, adv, asc)), m);
    if (b->run->quad_count == b->capacity) {
        int grown = b->capacity ? b->capacity * 2 : 32;
        float *bigger = realloc(b->run->quads, (size_t)grown * 8 * sizeof(float));
        if (!bigger) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
        b->run->quads = bigger;
        b->capacity = grown;
    }
    // Upper-left, upper-right, lower-left, lower-right, as opdf_char has them.
    float v[8] = { q.ul.x, q.ul.y, q.ur.x, q.ur.y, q.ll.x, q.ll.y, q.lr.x, q.lr.y };
    memcpy(&b->run->quads[b->run->quad_count * 8], v, sizeof v);
    b->run->quad_count++;
    b->bounds = fz_union_rect(b->bounds, fz_rect_from_quad(q));
}

// Walks a string's glyphs as MuPDF draws them, moving the text position.
static void show_string(fz_context *ctx, content_proc *p, run_builder *b, const unsigned char *s, size_t len) {
    pdf_font_desc *font = G(p)->text.font;
    const unsigned char *end = s + len;
    while (s < end) {
        unsigned int code;
        int inc = pdf_decode_cmap(font->encoding, (unsigned char *)s, (unsigned char *)end, &code);
        if (inc <= 0) break;
        s += inc;
        int cid = pdf_lookup_cmap(font->encoding, code);
        if (cid >= 0) record_glyph(ctx, p, b, cid);
        else pdf_tos_make_trm(ctx, &p->tos, &G(p)->text, font, 0, &(fz_matrix){ 0 }, &(float){ 0 });
        pdf_tos_move_after_char(ctx, &p->tos);
        if (code == 32 && inc == 1) {
            if (font->wmode == 0) p->tos.tm = fz_pre_translate(p->tos.tm, G(p)->text.word_space * G(p)->text.scale, 0);
            else p->tos.tm = fz_pre_translate(p->tos.tm, 0, G(p)->text.word_space);
        }
    }
}

// The run for this text operation, or NULL when not recording (or over the limit).
static void begin_run(fz_context *ctx, content_proc *p, run_builder *b) {
    memset(b, 0, sizeof *b);
    b->bounds = fz_empty_rect;
    pdf_font_desc *font = G(p)->text.font;
    if (!p->record || !font || p->text_ops > OPDF_MAX_CONTENT_OPS) return;
    b->run = new_run(ctx, p);
    b->run->op = p->text_ops;
    b->utf8 = fz_new_buffer(ctx, 64);
    fz_font *f = font->font;
    b->run->font = strdup(f && f->name[0] ? f->name : "");
    if (!b->run->font) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    b->run->serif = f && fz_font_is_serif(ctx, f);
    b->run->bold = f && fz_font_is_bold(ctx, f);
    b->run->italic = f && fz_font_is_italic(ctx, f);
    b->run->monospaced = f && fz_font_is_monospaced(ctx, f);
    fz_matrix m = fz_concat(fz_concat(p->tos.tm, G(p)->ctm), p->page_ctm);
    b->run->size = G(p)->text.size * sqrtf(m.c * m.c + m.d * m.d);
    b->run->color_n = G(p)->fill_n;
    memcpy(b->run->color, G(p)->fill, sizeof b->run->color);
    if (f && f->t3procs) b->run->not_editable = OPDF_RUN_TYPE3;
    else if (font->wmode) b->run->not_editable = OPDF_RUN_VERTICAL;
    else if (G(p)->text.render == 3) b->run->not_editable = OPDF_RUN_INVISIBLE;
}

static void end_run(fz_context *ctx, content_proc *p, run_builder *b) {
    if (!b->run) return;
    fz_terminate_buffer(ctx, b->utf8);
    unsigned char *data;
    fz_buffer_storage(ctx, b->utf8, &data);
    b->run->text = strdup((const char *)data);
    fz_drop_buffer(ctx, b->utf8);
    b->utf8 = NULL;
    if (!b->run->text) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    b->run->rect = rect_to(fz_is_empty_rect(b->bounds) ? fz_make_rect(0, 0, 0, 0) : b->bounds);
}

// A text operation: replaced when it is the target, else passed on and,
// when recording, listed.
static bool text_op_is_target(content_proc *p) {
    return p->emit_text && p->text_ops == p->target_text;
}

static void show_text(fz_context *ctx, content_proc *p, pdf_obj *array, const unsigned char *s, size_t len) {
    run_builder b;
    pdf_font_desc *font = G(p)->text.font;
    if (!font) return;
    begin_run(ctx, p, &b);
    fz_try(ctx) {
        if (array) {
            for (int i = 0, n = pdf_array_len(ctx, array); i < n; i++) {
                pdf_obj *item = pdf_array_get(ctx, array, i);
                if (pdf_is_string(ctx, item)) {
                    show_string(ctx, p, &b, (unsigned char *)pdf_to_str_buf(ctx, item), pdf_to_str_len(ctx, item));
                } else {
                    float adj = -pdf_to_real(ctx, item) * G(p)->text.size * 0.001f;
                    if (font->wmode == 0) p->tos.tm = fz_pre_translate(p->tos.tm, adj * G(p)->text.scale, 0);
                    else p->tos.tm = fz_pre_translate(p->tos.tm, 0, adj);
                }
            }
        } else {
            show_string(ctx, p, &b, s, len);
        }
        end_run(ctx, p, &b);
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, b.utf8);
        fz_rethrow(ctx);
    }
}

static void cp_TJ(fz_context *ctx, pdf_processor *proc, pdf_obj *array) {
    content_proc *p = (content_proc *)proc;
    probe_text_op(ctx, p);
    if (text_op_is_target(p)) {
        p->emit_text(ctx, p, array, NULL, 0, p->arg);
    } else {
        show_text(ctx, p, array, NULL, 0);
        if (CHAIN(p)) CHAIN(p)->op_TJ(ctx, CHAIN(p), array);
    }
    p->text_ops++;
}

static void cp_Tj(fz_context *ctx, pdf_processor *proc, char *str, size_t len) {
    content_proc *p = (content_proc *)proc;
    probe_text_op(ctx, p);
    if (text_op_is_target(p)) p->emit_text(ctx, p, NULL, str, len, p->arg);
    else {
        show_text(ctx, p, NULL, (unsigned char *)str, len);
        if (CHAIN(p)) CHAIN(p)->op_Tj(ctx, CHAIN(p), str, len);
    }
    p->text_ops++;
}

static void cp_squote(fz_context *ctx, pdf_processor *proc, char *str, size_t len) {
    content_proc *p = (content_proc *)proc;
    pdf_tos_newline(&p->tos, G(p)->text.leading);
    probe_text_op(ctx, p);
    if (text_op_is_target(p)) {
        if (CHAIN(p)) CHAIN(p)->op_Tstar(ctx, CHAIN(p));
        p->emit_text(ctx, p, NULL, str, len, p->arg);
    } else {
        show_text(ctx, p, NULL, (unsigned char *)str, len);
        if (CHAIN(p)) CHAIN(p)->op_squote(ctx, CHAIN(p), str, len);
    }
    p->text_ops++;
}

static void cp_dquote(fz_context *ctx, pdf_processor *proc, float aw, float ac, char *str, size_t len) {
    content_proc *p = (content_proc *)proc;
    G(p)->text.word_space = aw;
    G(p)->text.char_space = ac;
    pdf_tos_newline(&p->tos, G(p)->text.leading);
    probe_text_op(ctx, p);
    if (text_op_is_target(p)) {
        if (CHAIN(p)) {
            CHAIN(p)->op_Tw(ctx, CHAIN(p), aw);
            CHAIN(p)->op_Tc(ctx, CHAIN(p), ac);
            CHAIN(p)->op_Tstar(ctx, CHAIN(p));
        }
        p->emit_text(ctx, p, NULL, str, len, p->arg);
    } else {
        show_text(ctx, p, NULL, (unsigned char *)str, len);
        if (CHAIN(p)) CHAIN(p)->op_dquote(ctx, CHAIN(p), aw, ac, str, len);
    }
    p->text_ops++;
}

// --- Images

static void cp_Do_image(fz_context *ctx, pdf_processor *proc, const char *name, fz_image *image) {
    content_proc *p = (content_proc *)proc;
    if (p->emit_image && p->image_ops == p->target_image) {
        p->emit_image(ctx, p, name, image, p->arg);
    } else {
        if (p->record && p->image_ops < OPDF_MAX_CONTENT_OPS) {
            opdf_page_content *c = p->record;
            if (c->image_count == p->image_capacity) {
                int grown = p->image_capacity ? p->image_capacity * 2 : 16;
                opdf_image_placement *bigger = realloc(c->images, (size_t)grown * sizeof *bigger);
                if (!bigger) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
                c->images = bigger;
                p->image_capacity = grown;
            }
            opdf_image_placement *o = &c->images[c->image_count++];
            memset(o, 0, sizeof *o);
            fz_matrix m = fz_concat(G(p)->ctm, p->page_ctm);
            o->op = p->image_ops;
            o->rect = rect_to(fz_transform_rect(fz_unit_rect, m));
            float v[6] = { m.a, m.b, m.c, m.d, m.e, m.f };
            memcpy(o->matrix, v, sizeof v);
            // Images aren't decoded for this processor: the size is the XObject's.
            pdf_obj *xobj = pdf_lookup_resource(ctx, p->super.rstack, PDF_NAME(XObject), name);
            o->width = image ? image->w : pdf_dict_get_int(ctx, xobj, PDF_NAME(Width));
            o->height = image ? image->h : pdf_dict_get_int(ctx, xobj, PDF_NAME(Height));
        }
        if (CHAIN(p)) CHAIN(p)->op_Do_image(ctx, CHAIN(p), name, image);
    }
    p->image_ops++;
}

// Inline images: MuPDF's buffer processor writes back only the simple
// kinds faithfully, so a page with any other kind isn't rewritten.
static void cp_BI(fz_context *ctx, pdf_processor *proc, fz_image *image, const char *colorspace_name) {
    content_proc *p = (content_proc *)proc;
    if (CHAIN(p)) {
        // A colour space by name (a device abbreviation or a resource) is
        // written back as it was; one given inline (an array) only when it
        // is a plain device space.
        bool named = colorspace_name && colorspace_name[0];
        enum fz_colorspace_type type = image && image->colorspace ? fz_colorspace_type(ctx, image->colorspace) : FZ_COLORSPACE_NONE;
        bool device = image && image->colorspace && fz_colorspace_is_device(ctx, image->colorspace) &&
                      (type == FZ_COLORSPACE_GRAY || type == FZ_COLORSPACE_RGB || type == FZ_COLORSPACE_CMYK);
        bool simple = image && (image->imagemask || ((named || device) && !image->use_colorkey && !image->mask));
        if (!simple) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This page has a small picture stored in its content that couldn't be kept through the change");
        CHAIN(p)->op_BI(ctx, CHAIN(p), image, colorspace_name);
    }
}

static void cp_drop(fz_context *ctx, pdf_processor *proc) {
    content_proc *p = (content_proc *)proc;
    for (int i = 0; i <= p->top; i++) {
        pdf_drop_font(ctx, p->gs[i].text.font);
        p->gs[i].text.font = NULL;
    }
}

// A processor for the page; `out` is the buffer processor when rewriting.
static content_proc *new_content_proc(fz_context *ctx, pdf_document *doc, pdf_page *page, pdf_processor *out) {
    content_proc *p = pdf_new_processor(ctx, sizeof *p);
    p->super.chain = out;
    p->out = out;
    p->real_out = out;
    p->doc = doc;
    p->super.drop_processor = cp_drop;
    p->super.op_q = cp_q;
    p->super.op_Q = cp_Q;
    p->super.op_cm = cp_cm;
    p->super.op_BT = cp_BT;
    p->super.op_Tc = cp_Tc;
    p->super.op_Tw = cp_Tw;
    p->super.op_Tz = cp_Tz;
    p->super.op_TL = cp_TL;
    p->super.op_Ts = cp_Ts;
    p->super.op_Tr = cp_Tr;
    p->super.op_Tf = cp_Tf;
    p->super.op_Td = cp_Td;
    p->super.op_TD = cp_TD;
    p->super.op_Tm = cp_Tm;
    p->super.op_Tstar = cp_Tstar;
    p->super.op_TJ = cp_TJ;
    p->super.op_Tj = cp_Tj;
    p->super.op_squote = cp_squote;
    p->super.op_dquote = cp_dquote;
    p->super.op_g = cp_g;
    p->super.op_rg = cp_rg;
    p->super.op_k = cp_k;
    p->super.op_cs = cp_cs;
    p->super.op_sc_color = cp_sc_color;
    p->super.op_sc_pattern = cp_sc_pattern;
    p->super.op_sc_shade = cp_sc_shade;
    p->super.op_Do_image = cp_Do_image;
    p->super.op_BI = cp_BI;
    p->gs[0].ctm = fz_identity;
    p->gs[0].text.scale = 1;
    p->gs[0].text.size = -1;
    float black[1] = { 0 };
    p->top = 0;
    set_fill(p, 1, black);
    p->target_text = -1;
    p->target_image = -1;
    p->probe_op = -1;
    p->chars_left = OPDF_MAX_PAGE_CHARS;
    fz_rect mediabox;
    pdf_page_transform(ctx, page, &mediabox, &p->page_ctm);
    return p;
}

// Runs the processor over the page's own content stream (refused when the
// decoded content is over OPDF_MAX_CONTENT_BYTES).
static void process_page_content(fz_context *ctx, pdf_document *doc, pdf_page *page, content_proc *p) {
    pdf_obj *contents = pdf_page_contents(ctx, page);
    // The decoded content is measured first (read, not kept), so a small
    // stream that inflates enormously is refused before it is interpreted.
    size_t total = 0;
    int n = pdf_is_array(ctx, contents) ? pdf_array_len(ctx, contents) : 1;
    if (n > 10000) fz_throw(ctx, FZ_ERROR_LIMIT, "This page's content is too large to edit");
    unsigned char chunk[65536];
    for (int i = 0; i < n; i++) {
        pdf_obj *obj = pdf_is_array(ctx, contents) ? pdf_array_get(ctx, contents, i) : contents;
        if (!pdf_is_stream(ctx, obj)) continue;
        fz_stream *stm = pdf_open_stream(ctx, obj);
        fz_try(ctx) {
            size_t got;
            while ((got = fz_read(ctx, stm, chunk, sizeof chunk)) > 0) {
                total += got;
                if (total > OPDF_MAX_CONTENT_BYTES) fz_throw(ctx, FZ_ERROR_LIMIT, "This page's content is too large to edit");
            }
        }
        fz_always(ctx)
            fz_drop_stream(ctx, stm);
        fz_catch(ctx)
            fz_rethrow(ctx);
    }
    pdf_process_contents(ctx, &p->super, doc, pdf_page_resources(ctx, page), contents, NULL, NULL);
    // Output switched off (an unclosed stamp being removed) is switched back on.
    p->super.chain = p->real_out;
    p->out = p->real_out;
    if (p->emit_end && CHAIN(p)) {
        // Whatever the content left open is closed first.
        for (int i = p->top + p->overflow; i > 0; i--) CHAIN(p)->op_Q(ctx, CHAIN(p));
        p->emit_end(ctx, p, p->arg);
    }
    pdf_close_processor(ctx, &p->super);
}

bool opdf_page_content_load(opdf_doc *d, int page_number, opdf_page_content *out, opdf_error *err) {
    clear_error(err);
    memset(out, 0, sizeof *out);
    fz_context *ctx = d->ctx;
    pdf_page *page = NULL;
    content_proc *p = NULL;
    fz_var(page);
    fz_var(p);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        page = load_pdf_page(ctx, d->doc, page_number);
        p = new_content_proc(ctx, pdf, page, NULL);
        p->record = out;
        process_page_content(ctx, pdf, page, p);
    }
    fz_always(ctx) {
        pdf_drop_processor(ctx, &p->super);
        fz_drop_page(ctx, (fz_page *)page);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        opdf_page_content_free(out);
    }
    unlock_doc(d);
    return !(err && err->code);
}

void opdf_page_content_free(opdf_page_content *c) {
    if (!c) return;
    for (int i = 0; i < c->run_count; i++) {
        free(c->runs[i].text);
        free(c->runs[i].quads);
        free(c->runs[i].font);
    }
    free(c->runs);
    free(c->images);
    memset(c, 0, sizeof *c);
}

// Rewrites the page's content through `p` (chained to a buffer processor),
// replacing /Contents with one new compressed stream. Call inside an
// operation.
static void rewrite_page_content(fz_context *ctx, pdf_document *pdf, pdf_page *page,
                                 void (*configure)(content_proc *p, void *arg), void *arg) {
    fz_buffer *buf = NULL;
    pdf_processor *out = NULL;
    content_proc *p = NULL;
    unsigned char *deflated = NULL;
    fz_buffer *zbuf = NULL;
    pdf_obj *dict = NULL, *stream = NULL;
    fz_var(buf);
    fz_var(out);
    fz_var(p);
    fz_var(deflated);
    fz_var(zbuf);
    fz_var(dict);
    fz_var(stream);
    fz_try(ctx) {
        buf = fz_new_buffer(ctx, 4096);
        out = pdf_new_buffer_processor(ctx, buf, 0, 1);
        p = new_content_proc(ctx, pdf, page, out);
        if (configure) configure(p, arg);
        process_page_content(ctx, pdf, page, p);
        size_t zlen = 0;
        deflated = fz_new_deflated_data_from_buffer(ctx, &zlen, buf, FZ_DEFLATE_DEFAULT);
        zbuf = fz_new_buffer_from_data(ctx, deflated, zlen);
        deflated = NULL;
        dict = pdf_new_dict(ctx, pdf, 1);
        pdf_dict_put(ctx, dict, PDF_NAME(Filter), PDF_NAME(FlateDecode));
        stream = pdf_add_stream(ctx, pdf, zbuf, dict, 1);
        pdf_dict_put(ctx, page->obj, PDF_NAME(Contents), stream);
    }
    fz_always(ctx) {
        pdf_drop_processor(ctx, &p->super);
        pdf_drop_processor(ctx, out);
        fz_drop_buffer(ctx, buf);
        fz_free(ctx, deflated);
        fz_drop_buffer(ctx, zbuf);
        pdf_drop_obj(ctx, dict);
        pdf_drop_obj(ctx, stream);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

// The page's own resources dictionary (a copy of what it inherits, if it
// has none), and a subdictionary of it.
static pdf_obj *own_resources(fz_context *ctx, pdf_document *pdf, pdf_page *page, pdf_obj *type) {
    pdf_obj *res = pdf_dict_get(ctx, page->obj, PDF_NAME(Resources));
    if (!pdf_is_dict(ctx, res)) {
        pdf_obj *inherited = pdf_page_resources(ctx, page);
        res = pdf_is_dict(ctx, inherited) ? pdf_copy_dict(ctx, inherited) : pdf_new_dict(ctx, pdf, 2);
        pdf_dict_put_drop(ctx, page->obj, PDF_NAME(Resources), res);
    }
    pdf_obj *sub = pdf_dict_get(ctx, res, type);
    if (!pdf_is_dict(ctx, sub)) sub = pdf_dict_put_dict(ctx, res, type, 2);
    return sub;
}

// A name not yet used in a resources subdictionary.
static void new_resource_name(fz_context *ctx, pdf_obj *dict, const char *prefix, char name[32]) {
    for (int i = 0; i < 100000; i++) {
        fz_snprintf(name, 32, "%s%d", prefix, i);
        if (!pdf_dict_gets(ctx, dict, name)) return;
    }
    fz_throw(ctx, FZ_ERROR_LIMIT, "The page has too many resources");
}

// An image from a JPEG or PNG file, checked against the limits.
static fz_image *import_image(fz_context *ctx, const unsigned char *data, size_t len) {
    if (!data || len < 8 || len > OPDF_MAX_IMAGE_BYTES) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That image file is empty or too large");
    int kind = fz_recognize_image_format(ctx, (unsigned char *)data);
    if (kind != FZ_IMAGE_JPEG && kind != FZ_IMAGE_PNG) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Images are added as JPEG or PNG");
    fz_buffer *buf = fz_new_buffer_from_copied_data(ctx, data, len);
    fz_image *image = NULL;
    fz_try(ctx)
        image = fz_new_image_from_buffer(ctx, buf);
    fz_always(ctx)
        fz_drop_buffer(ctx, buf);
    fz_catch(ctx)
        fz_rethrow(ctx);
    if (image->w <= 0 || image->h <= 0 || (int64_t)image->w * image->h > OPDF_MAX_IMAGE_PIXELS) {
        fz_drop_image(ctx, image);
        fz_throw(ctx, FZ_ERROR_LIMIT, "That image has too many pixels");
    }
    return image;
}

// Adds the image to the page's resources under a new name.
static void add_image_resource(fz_context *ctx, pdf_document *pdf, pdf_page *page, fz_image *image, char name[32]) {
    pdf_obj *xobjects = own_resources(ctx, pdf, page, PDF_NAME(XObject));
    new_resource_name(ctx, xobjects, "OPDFIm", name);
    pdf_dict_puts_drop(ctx, xobjects, name, pdf_add_image(ctx, pdf, image));
}

static fz_rect checked_rect(fz_context *ctx, opdf_rect rect) {
    fz_rect r = fz_make_rect(rect.x0, rect.y0, rect.x1, rect.y1);
    if (!(r.x1 - r.x0 >= 1 && r.y1 - r.y0 >= 1 && r.x1 - r.x0 <= 14400 && r.y1 - r.y0 <= 14400)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That is the wrong size");
    return r;
}

typedef struct {
    char name[32];       // the image to draw
    fz_rect rect;        // where, in page space
    float aspect;        // replacing: the new image's width / height
    int mode;            // 0 add, 1 set rect, 2 delete, 3 replace
    int op;              // the image drawing to change
    bool found;
} image_edit;

static void emit_cm(fz_context *ctx, content_proc *p, fz_matrix m) {
    CHAIN(p)->op_cm(ctx, CHAIN(p), m.a, m.b, m.c, m.d, m.e, m.f);
}

// Draws the new image at the end of the page, upright as the page is shown.
static void emit_added_image(fz_context *ctx, content_proc *p, void *arg) {
    image_edit *e = arg;
    fz_rect r = e->rect;
    fz_matrix unit_to_page = fz_make_matrix(r.x1 - r.x0, 0, 0, -(r.y1 - r.y0), r.x0, r.y1);
    CHAIN(p)->op_q(ctx, CHAIN(p));
    emit_cm(ctx, p, fz_concat(unit_to_page, fz_invert_matrix(p->page_ctm)));
    CHAIN(p)->op_Do_image(ctx, CHAIN(p), e->name, NULL);
    CHAIN(p)->op_Q(ctx, CHAIN(p));
}

// Moves, resizes, deletes or replaces the target image drawing.
static void emit_edited_image(fz_context *ctx, content_proc *p, const char *name, fz_image *image, void *arg) {
    image_edit *e = arg;
    e->found = true;
    if (e->mode == 2) return;
    fz_matrix to_page = fz_concat(G(p)->ctm, p->page_ctm);
    fz_rect old = fz_transform_rect(fz_unit_rect, to_page);
    fz_matrix extra = fz_identity;
    if (e->mode == 1) {
        float w = old.x1 - old.x0, h = old.y1 - old.y0;
        if (w < 0.01f || h < 0.01f) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This image is too small to resize");
        float sx = (e->rect.x1 - e->rect.x0) / w, sy = (e->rect.y1 - e->rect.y0) / h;
        fz_matrix t = fz_make_matrix(sx, 0, 0, sy, e->rect.x0 - old.x0 * sx, e->rect.y0 - old.y0 * sy);
        // extra × ctm × page = ctm × page × t
        extra = fz_concat(fz_concat(fz_concat(to_page, t), fz_invert_matrix(p->page_ctm)), fz_invert_matrix(G(p)->ctm));
    } else if (e->mode == 3) {
        float w = sqrtf(to_page.a * to_page.a + to_page.b * to_page.b);
        float h = sqrtf(to_page.c * to_page.c + to_page.d * to_page.d);
        float sx = 1, sy = 1;
        if (w > 0 && h > 0) {
            if (e->aspect > w / h) sy = (w / e->aspect) / h;
            else sx = (h * e->aspect) / w;
        }
        extra = fz_make_matrix(sx, 0, 0, sy, (1 - sx) / 2, (1 - sy) / 2);
    }
    CHAIN(p)->op_q(ctx, CHAIN(p));
    emit_cm(ctx, p, extra);
    CHAIN(p)->op_Do_image(ctx, CHAIN(p), e->mode == 3 ? e->name : name, image);
    CHAIN(p)->op_Q(ctx, CHAIN(p));
}

static void configure_image_edit(content_proc *p, void *arg) {
    image_edit *e = arg;
    if (e->mode == 0) {
        p->emit_end = emit_added_image;
    } else {
        p->emit_image = emit_edited_image;
        p->target_image = e->op;
    }
    p->arg = e;
}

static void edit_image(fz_context *ctx, pdf_document *pdf, pdf_page *page, image_edit *e, int op) {
    e->op = op;
    rewrite_page_content(ctx, pdf, page, configure_image_edit, e);
    if (e->mode != 0 && !e->found) fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such image");
}

bool opdf_image_add(opdf_doc *d, int page_number, opdf_rect rect, const unsigned char *data, size_t len, opdf_error *err) {
    clear_error(err);
    fz_image *image = NULL;
    fz_var(image);
    WITH_PAGE_OPERATION(d, page_number, "Add Image", err, {
        fz_try(ctx) {
            image_edit e = { .mode = 0 };
            e.rect = checked_rect(ctx, rect);
            image = import_image(ctx, data, len);
            add_image_resource(ctx, pdf, pp, image, e.name);
            edit_image(ctx, pdf, pp, &e, -1);
        }
        fz_always(ctx) {
            fz_drop_image(ctx, image);
            image = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    return !(err && err->code);
}

bool opdf_image_set_rect(opdf_doc *d, int page_number, int op, opdf_rect rect, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Move Image", err, {
        image_edit e = { .mode = 1 };
        e.rect = checked_rect(ctx, rect);
        edit_image(ctx, pdf, pp, &e, op);
    });
    return !(err && err->code);
}

bool opdf_image_delete(opdf_doc *d, int page_number, int op, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Delete Image", err, {
        image_edit e = { .mode = 2 };
        edit_image(ctx, pdf, pp, &e, op);
    });
    return !(err && err->code);
}

bool opdf_image_replace(opdf_doc *d, int page_number, int op, const unsigned char *data, size_t len, opdf_error *err) {
    clear_error(err);
    fz_image *image = NULL;
    fz_var(image);
    WITH_PAGE_OPERATION(d, page_number, "Replace Image", err, {
        fz_try(ctx) {
            image_edit e = { .mode = 3 };
            image = import_image(ctx, data, len);
            e.aspect = (float)image->w / (float)image->h;
            add_image_resource(ctx, pdf, pp, image, e.name);
            edit_image(ctx, pdf, pp, &e, op);
        }
        fz_always(ctx) {
            fz_drop_image(ctx, image);
            image = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    return !(err && err->code);
}

// --- Editing text ---------------------------------------------------------------

// The code (1 to 4 bytes) that draws `unicode` in this font, if it has a
// glyph for it: the font's encoding is searched (at most 70,000 codes),
// mapping each code through ToUnicode (or the built-in table) and checking
// the glyph exists and, unless it's a space, has an outline (subset fonts
// keep codes for glyphs they no longer have).
static int encode_in_font(fz_context *ctx, pdf_font_desc *font, int unicode, unsigned char out[4]) {
    if (!font || !font->font || font->font->t3procs || font->wmode) return 0;
    pdf_cmap *cmap = font->encoding;
    int budget = 70000;
    for (int r = 0; cmap && r < cmap->codespace_len; r++) {
        int n = cmap->codespace[r].n;
        if (n < 1 || n > 4) continue;
        unsigned int high = cmap->codespace[r].high;
        for (unsigned int code = cmap->codespace[r].low; code <= high && budget-- > 0 && code != UINT_MAX; code++) {
            int cid = pdf_lookup_cmap(cmap, code);
            if (cid < 0) continue;
            int ucs[PDF_MRANGE_CAP];
            int len = font->to_unicode ? pdf_lookup_cmap_full(font->to_unicode, cid, ucs) : 0;
            if (len == 0 && (size_t)cid < font->cid_to_ucs_len) {
                ucs[0] = font->cid_to_ucs[cid];
                len = 1;
            }
            if (len != 1 || ucs[0] != unicode) continue;
            int gid = pdf_font_cid_to_gid(ctx, font, cid);
            if (unicode != ' ' && (gid <= 0 || fz_is_empty_rect(fz_bound_glyph(ctx, font->font, gid, fz_identity)))) continue;
            for (int i = 0; i < n; i++) out[i] = (unsigned char)(code >> (8 * (n - 1 - i)));
            return n;
        }
    }
    return 0;
}

// The new text, decoded, with how each character is drawn.
typedef struct {
    int count;
    int *unicode;
    int *len;                 // bytes of its code in the run's font, or 0: the fallback font
    unsigned char (*code)[4];
    int *gid;                 // in the fallback font
} text_plan;

static void drop_plan(fz_context *ctx, text_plan *t) {
    fz_free(ctx, t->unicode);
    fz_free(ctx, t->len);
    fz_free(ctx, t->code);
    fz_free(ctx, t->gid);
    memset(t, 0, sizeof *t);
}

static void plan_text(fz_context *ctx, pdf_font_desc *font, const char *utf8, bool whole_font, text_plan *t) {
    size_t bytes = strlen(utf8);
    if (bytes > OPDF_MAX_EDIT_TEXT) fz_throw(ctx, FZ_ERROR_LIMIT, "That text is too long for one edit");
    int capacity = fz_utflen(utf8);
    t->unicode = fz_malloc_array(ctx, capacity + 1, int);
    t->len = fz_malloc_array(ctx, capacity + 1, int);
    t->code = fz_malloc(ctx, (size_t)(capacity + 1) * 4);
    t->gid = fz_malloc_array(ctx, capacity + 1, int);
    for (const char *s = utf8; *s && t->count < capacity; ) {
        int c;
        s += fz_chartorune(&c, s);
        if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        if (c < 0x20 || (c >= 0x7f && c < 0xa0)) continue;
        t->unicode[t->count] = c;
        t->len[t->count] = whole_font ? 0 : encode_in_font(ctx, font, c, t->code[t->count]);
        t->gid[t->count] = 0;
        t->count++;
    }
}

// A ToUnicode CMap for Identity-H codes (glyph ids).
static fz_buffer *identity_to_unicode(fz_context *ctx, const int *gids, const int *unicodes, int count) {
    fz_buffer *buf = fz_new_buffer(ctx, 512);
    fz_try(ctx) {
        fz_append_string(ctx, buf,
            "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n"
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
            "/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n"
            "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        for (int start = 0; start < count; start += 100) {
            int n = count - start < 100 ? count - start : 100;
            fz_append_printf(ctx, buf, "%d beginbfchar\n", n);
            for (int i = start; i < start + n; i++) {
                int u = unicodes[i];
                if (u > 0xffff) {
                    u -= 0x10000;
                    fz_append_printf(ctx, buf, "<%04x> <%04x%04x>\n", gids[i], 0xd800 + (u >> 10), 0xdc00 + (u & 0x3ff));
                } else {
                    fz_append_printf(ctx, buf, "<%04x> <%04x>\n", gids[i], u);
                }
            }
            fz_append_string(ctx, buf, "endbfchar\n");
        }
        fz_append_string(ctx, buf, "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
    }
    fz_catch(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_rethrow(ctx);
    }
    return buf;
}

// Embeds the font in `data` for the characters the plan draws with it:
// subset to those glyphs, with a ToUnicode for them, as a Type0
// Identity-H font. Fills in the plan's glyph ids; returns the font (kept).
static pdf_obj *embed_subset_font(fz_context *ctx, pdf_document *pdf, const unsigned char *data, size_t len, text_plan *t) {
    if (!data || len < 12 || len > OPDF_MAX_FONT_BYTES) fz_throw(ctx, FZ_ERROR_ARGUMENT, "No font was given for characters the text's own font doesn't have");
    fz_buffer *buf = NULL, *subset = NULL, *tounicode = NULL;
    fz_font *full = NULL, *small = NULL;
    pdf_obj *font = NULL;
    int *gids = NULL, *unis = NULL;
    fz_var(buf);
    fz_var(subset);
    fz_var(tounicode);
    fz_var(full);
    fz_var(small);
    fz_var(font);
    fz_var(gids);
    fz_var(unis);
    fz_try(ctx) {
        buf = fz_new_buffer_from_copied_data(ctx, data, len);
        full = fz_new_font_from_buffer(ctx, NULL, buf, 0, 0);
        if (fz_font_flags(full)->never_embed) fz_throw(ctx, FZ_ERROR_ARGUMENT, "The font's licence doesn't allow it to be embedded");
        // Distinct glyphs, with glyph 0 first (the subsetter keeps numbering).
        gids = fz_malloc_array(ctx, t->count + 1, int);
        unis = fz_malloc_array(ctx, t->count + 1, int);
        int n = 0;
        gids[n++] = 0;
        unis[0] = 0;
        for (int i = 0; i < t->count; i++) {
            if (t->len[i]) continue;
            int gid = fz_encode_character(ctx, full, t->unicode[i]);
            if (gid <= 0 && t->unicode[i] != ' ') {
                char utf[8] = { 0 };
                fz_runetochar(utf, t->unicode[i]);
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "No font here has the character “%s”", utf);
            }
            t->gid[i] = gid;
            bool seen = false;
            for (int j = 0; j < n && !seen; j++) seen = gids[j] == gid;
            if (!seen) {
                gids[n] = gid;
                unis[n] = t->unicode[i];
                n++;
            }
        }
        subset = fz_subset_ttf_for_gids(ctx, buf, gids, n, 0, 1);
        small = fz_new_font_from_buffer(ctx, full->name, subset, 0, 0);
        font = pdf_add_cid_font(ctx, pdf, small);
        tounicode = identity_to_unicode(ctx, gids + 1, unis + 1, n - 1);
        pdf_dict_put_drop(ctx, font, PDF_NAME(ToUnicode), pdf_add_stream(ctx, pdf, tounicode, NULL, 0));
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_drop_buffer(ctx, subset);
        fz_drop_buffer(ctx, tounicode);
        fz_drop_font(ctx, full);
        fz_drop_font(ctx, small);
        fz_free(ctx, gids);
        fz_free(ctx, unis);
    }
    fz_catch(ctx) {
        pdf_drop_obj(ctx, font);
        fz_rethrow(ctx);
    }
    return font;
}

// The same, added to the page's font resources under a new name.
static void add_fallback_font(fz_context *ctx, pdf_document *pdf, pdf_page *page, const unsigned char *data, size_t len,
                              text_plan *t, char name[32]) {
    pdf_obj *font = embed_subset_font(ctx, pdf, data, len, t);
    fz_try(ctx) {
        pdf_obj *fonts = own_resources(ctx, pdf, page, PDF_NAME(Font));
        new_resource_name(ctx, fonts, "OPDFFn", name);
        pdf_dict_puts(ctx, fonts, name, font);
    }
    fz_always(ctx)
        pdf_drop_obj(ctx, font);
    fz_catch(ctx)
        fz_rethrow(ctx);
}

typedef struct {
    const opdf_text_edit *edit;
    int op;                   // the text operation to change
    text_plan plan;           // count 0 with no new text: the operation is drawn as it was
    bool keep;                // draw the original operation (style changes only)
    char fallback[32];        // the fallback font's resource name, if used
    bool found;
} text_edit_state;

static void emit_color(fz_context *ctx, content_proc *p, int n, const float *c) {
    if (n == 1) CHAIN(p)->op_g(ctx, CHAIN(p), c[0]);
    else if (n == 3) CHAIN(p)->op_rg(ctx, CHAIN(p), c[0], c[1], c[2]);
    else if (n == 4) CHAIN(p)->op_k(ctx, CHAIN(p), c[0], c[1], c[2], c[3]);
}

static void emit_edited_text(fz_context *ctx, content_proc *p, pdf_obj *array, const char *str, size_t len, void *arg) {
    text_edit_state *e = arg;
    const opdf_text_edit *edit = e->edit;
    e->found = true;
    content_gstate *g = G(p);
    if (edit->color_n && !g->fill_n) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This text's colour can't be changed here");
    // A font set by an ExtGState has no resource name of its own, and a
    // name cut short wouldn't be found: neither can be written back.
    if (!g->font_name[0] || !strcmp(g->font_name, "ExtGState") || strlen(g->font_name) >= sizeof g->font_name - 1)
        fz_throw(ctx, FZ_ERROR_ARGUMENT, "This text's font can't be named, so the text can't be changed here");
    float size = g->text.size * (edit->size_scale > 0 ? edit->size_scale : 1);
    if (edit->color_n) emit_color(ctx, p, edit->color_n, edit->color);
    if (size != g->text.size) CHAIN(p)->op_Tf(ctx, CHAIN(p), g->font_name, NULL, size);
    if (e->keep) {
        if (array) CHAIN(p)->op_TJ(ctx, CHAIN(p), array);
        else CHAIN(p)->op_Tj(ctx, CHAIN(p), (char *)str, len);
    } else {
        // Runs of characters in the same font, each one Tj.
        text_plan *t = &e->plan;
        unsigned char *bytes = fz_malloc(ctx, (size_t)t->count * 4 + 1);
        fz_try(ctx) {
            int i = 0;
            bool in_fallback = false;
            while (i < t->count) {
                bool fallback = t->len[i] == 0;
                if (fallback != in_fallback) {
                    CHAIN(p)->op_Tf(ctx, CHAIN(p), fallback ? e->fallback : g->font_name, NULL, size);
                    in_fallback = fallback;
                }
                size_t n = 0;
                for (; i < t->count && (t->len[i] == 0) == fallback; i++) {
                    if (fallback) {
                        bytes[n++] = (unsigned char)(t->gid[i] >> 8);
                        bytes[n++] = (unsigned char)t->gid[i];
                    } else {
                        memcpy(bytes + n, t->code[i], (size_t)t->len[i]);
                        n += (size_t)t->len[i];
                    }
                }
                CHAIN(p)->op_Tj(ctx, CHAIN(p), (char *)bytes, n);
            }
            if (in_fallback) CHAIN(p)->op_Tf(ctx, CHAIN(p), g->font_name, NULL, size);
        }
        fz_always(ctx)
            fz_free(ctx, bytes);
        fz_catch(ctx)
            fz_rethrow(ctx);
    }
    if (size != g->text.size) CHAIN(p)->op_Tf(ctx, CHAIN(p), g->font_name, NULL, g->text.size);
    if (edit->color_n) emit_color(ctx, p, g->fill_n, g->fill);
}

static void configure_text_edit(content_proc *p, void *arg) {
    text_edit_state *e = arg;
    p->emit_text = emit_edited_text;
    p->target_text = e->op;
    p->arg = e;
}

// The run's font and recorded text, from a recording pass.
static opdf_text_run *find_run(fz_context *ctx, pdf_document *pdf, pdf_page *page, int op, opdf_page_content *content, run_probe *probe) {
    content_proc *p = new_content_proc(ctx, pdf, page, NULL);
    fz_try(ctx) {
        p->record = content;
        p->probe = probe;
        p->probe_op = op;
        process_page_content(ctx, pdf, page, p);
    }
    fz_always(ctx)
        pdf_drop_processor(ctx, &p->super);
    fz_catch(ctx)
        fz_rethrow(ctx);
    for (int i = 0; i < content->run_count; i++)
        if (content->runs[i].op == op) return &content->runs[i];
    fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such text");
}

bool opdf_text_run_edit(opdf_doc *d, int page_number, int op, const opdf_text_edit *edit, opdf_error *err) {
    clear_error(err);
    opdf_page_content content = { 0 };
    run_probe probe = { 0 };
    text_edit_state state = { 0 };
    WITH_PAGE_OPERATION(d, page_number, "Edit Text", err, {
        fz_try(ctx) {
            opdf_text_run *run = find_run(ctx, pdf, pp, op, &content, &probe);
            if (run->not_editable != OPDF_RUN_EDITABLE) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This text can't be edited here");
            if (!probe.found) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This text's font can't be found");
            if (edit->size_scale < 0 || edit->size_scale > 100) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That size is out of range");
            if (edit->color_n != 0 && edit->color_n != 1 && edit->color_n != 3) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That colour isn't grey or RGB");
            state.edit = edit;
            state.keep = !edit->text && !edit->whole_font;
            if (!state.keep) {
                plan_text(ctx, probe.font, edit->text ? edit->text : run->text, edit->whole_font, &state.plan);
                bool needs_fallback = false;
                for (int i = 0; i < state.plan.count; i++) needs_fallback |= state.plan.len[i] == 0;
                if (needs_fallback) add_fallback_font(ctx, pdf, pp, edit->font_data, edit->font_len, &state.plan, state.fallback);
            }
            state.op = op;
            rewrite_page_content(ctx, pdf, pp, configure_text_edit, &state);
            if (!state.found) fz_throw(ctx, FZ_ERROR_ARGUMENT, "No such text");
        }
        fz_always(ctx) {
            drop_plan(ctx, &state.plan);
            pdf_drop_font(ctx, probe.font);
            probe.font = NULL;
            opdf_page_content_free(&content);
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    return !(err && err->code);
}

char *opdf_text_run_missing(opdf_doc *d, int page_number, int op, const char *text, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    pdf_page *page = NULL;
    opdf_page_content content = { 0 };
    run_probe probe = { 0 };
    text_plan plan = { 0 };
    fz_buffer *out = NULL;
    char *result = NULL;
    fz_var(page);
    fz_var(out);
    fz_var(result);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        page = load_pdf_page(ctx, d->doc, page_number);
        find_run(ctx, pdf, page, op, &content, &probe);
        if (!probe.found) fz_throw(ctx, FZ_ERROR_ARGUMENT, "This text's font can't be found");
        plan_text(ctx, probe.font, text ? text : "", false, &plan);
        out = fz_new_buffer(ctx, 16);
        for (int i = 0; i < plan.count; i++) {
            if (plan.len[i]) continue;
            char utf[8];
            fz_append_data(ctx, out, utf, (size_t)fz_runetochar(utf, plan.unicode[i]));
        }
        fz_terminate_buffer(ctx, out);
        unsigned char *data;
        fz_buffer_storage(ctx, out, &data);
        result = strdup((const char *)data);
        if (!result) fz_throw(ctx, FZ_ERROR_SYSTEM, "Out of memory");
    }
    fz_always(ctx) {
        drop_plan(ctx, &plan);
        pdf_drop_font(ctx, probe.font);
        opdf_page_content_free(&content);
        fz_drop_buffer(ctx, out);
        fz_drop_page(ctx, (fz_page *)page);
    }
    fz_catch(ctx) {
        set_error(err, ctx);
        free(result);
        result = NULL;
    }
    unlock_doc(d);
    return result;
}

bool opdf_page_content_rewrite(opdf_doc *d, int page_number, opdf_error *err) {
    clear_error(err);
    WITH_PAGE_OPERATION(d, page_number, "Rewrite Page", err, {
        rewrite_page_content(ctx, pdf, pp, NULL, NULL);
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

// Writes the document as it is now to `path`: the original bytes, then
// every change as one snapshot (see opdf_save). The document is unchanged.
static void write_snapshot(fz_context *ctx, pdf_document *pdf, const char *path) {
    fz_output *out = NULL;
    unsigned char *chunk = NULL;
    fz_var(out);
    fz_var(chunk);
    fz_try(ctx) {
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
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_free(ctx, chunk);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

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

        write_snapshot(ctx, pdf, path);
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

static void rewrite_xmp(fz_context *ctx, pdf_document *pdf, pdf_obj *stream, pdf_obj *info, int64_t now);

// Hidden leftovers a rewrite would otherwise keep: page thumbnails (renders
// of the old pages), PieceInfo (application data), document JavaScript, and
// XMP that may repeat what was removed. Inside an operation.
static void scrub_document(fz_context *ctx, pdf_document *pdf, int64_t now) {
    pdf_obj *trailer = pdf_trailer(ctx, pdf);
    pdf_obj *root = pdf_dict_get(ctx, trailer, PDF_NAME(Root));
    int pages = pdf_count_pages(ctx, pdf);
    for (int i = 0; i < pages; i++) {
        pdf_obj *page = pdf_lookup_page_obj(ctx, pdf, i);
        if (!pdf_is_dict(ctx, page)) continue;
        pdf_dict_del(ctx, page, PDF_NAME(Thumb));
        pdf_dict_dels(ctx, page, "PieceInfo");
        pdf_dict_del(ctx, page, PDF_NAME(AA));
    }
    if (!pdf_is_dict(ctx, root)) return;
    pdf_dict_dels(ctx, root, "PieceInfo");
    pdf_dict_del(ctx, root, PDF_NAME(AA));
    pdf_obj *names = pdf_dict_get(ctx, root, PDF_NAME(Names));
    if (pdf_is_dict(ctx, names)) pdf_dict_del(ctx, names, PDF_NAME(JavaScript));
    pdf_obj *open = pdf_dict_gets(ctx, root, "OpenAction");
    if (pdf_is_dict(ctx, open) && pdf_name_eq(ctx, pdf_dict_get(ctx, open, PDF_NAME(S)), PDF_NAME(JavaScript)))
        pdf_dict_dels(ctx, root, "OpenAction");
    pdf_obj *xmp = pdf_dict_get(ctx, root, PDF_NAME(Metadata));
    if (pdf_is_stream(ctx, xmp)) rewrite_xmp(ctx, pdf, xmp, pdf_dict_get(ctx, trailer, PDF_NAME(Info)), now);
}

// The most marked areas one page may have: past this, redaction is refused.
#define OPDF_MAX_REDACT_AREAS 20000

static bool touches_any(const fz_rect *areas, int count, fz_rect r) {
    for (int i = 0; i < count; i++)
        if (!fz_is_empty_rect(fz_intersect_rect(areas[i], r))) return true;
    return false;
}

// Clears a widget's field value, and its ancestors' (shared values included):
// what was typed there is gone even where another widget showed it.
static void clear_field_values(fz_context *ctx, pdf_obj *widget) {
    pdf_obj *field = widget;
    for (int depth = 0; field && depth < 32; depth++) {
        pdf_dict_del(ctx, field, PDF_NAME(V));
        pdf_dict_del(ctx, field, PDF_NAME(DV));
        pdf_dict_del(ctx, field, PDF_NAME(RV));
        field = pdf_dict_get(ctx, field, PDF_NAME(Parent));
    }
}

// Applies the Redact annotations on every page (see opdf_rebase).
static void redact_document(fz_context *ctx, pdf_document *doc) {
    int pages = pdf_count_pages(ctx, doc);
    pdf_page *page = NULL;
    fz_rect *areas = NULL;
    pdf_annot **annots = NULL;
    bool *doomed = NULL;
    fz_var(page);
    fz_var(areas);
    fz_var(annots);
    fz_var(doomed);
    fz_try(ctx) {
        for (int p = 0; p < pages; p++) {
            page = pdf_load_page(ctx, doc, p);
            // The marked areas: each quad of a mark, or its rectangle (in page
            // space, as pdf_annot_rect gives every annotation's).
            int count = 0, n = 0;
            for (pdf_annot *a = pdf_first_annot(ctx, page); a; a = pdf_next_annot(ctx, a)) {
                n++;
                if (pdf_annot_type(ctx, a) != PDF_ANNOT_REDACT) continue;
                int q = pdf_annot_quad_point_count(ctx, a);
                count += q > 0 ? q : 1;
                if (count > OPDF_MAX_REDACT_AREAS) fz_throw(ctx, FZ_ERROR_LIMIT, "Page %d has too many redaction marks", p + 1);
            }
            if (count > 0) {
                areas = checked_calloc(ctx, (size_t)count, sizeof *areas);
                int k = 0;
                for (pdf_annot *a = pdf_first_annot(ctx, page); a && k < count; a = pdf_next_annot(ctx, a)) {
                    if (pdf_annot_type(ctx, a) != PDF_ANNOT_REDACT) continue;
                    int q = pdf_annot_quad_point_count(ctx, a);
                    if (q > 0)
                        for (int j = 0; j < q && k < count; j++) areas[k++] = fz_rect_from_quad(pdf_annot_quad_point(ctx, a, j));
                    else
                        areas[k++] = pdf_annot_rect(ctx, a);
                }
                count = k;
                // Annotations and fields under the marks, with replies.
                annots = checked_calloc(ctx, (size_t)n, sizeof *annots);
                doomed = checked_calloc(ctx, (size_t)n, sizeof *doomed);
                int i = 0;
                for (pdf_annot *a = pdf_first_annot(ctx, page); a && i < n; a = pdf_next_annot(ctx, a), i++) {
                    annots[i] = a;
                    enum pdf_annot_type type = pdf_annot_type(ctx, a);
                    if (type == PDF_ANNOT_REDACT || type == PDF_ANNOT_POPUP) continue;
                    if (!touches_any(areas, count, pdf_annot_rect(ctx, a))) continue;
                    doomed[i] = true;
                }
                for (pdf_annot *w = pdf_first_widget(ctx, page); w; w = pdf_next_widget(ctx, w))
                    if (touches_any(areas, count, pdf_annot_rect(ctx, w))) clear_field_values(ctx, pdf_annot_obj(ctx, w));
                delete_with_replies(ctx, page, i, annots, doomed);
                for (pdf_annot *w = pdf_first_widget(ctx, page); w;) {
                    pdf_annot *next = pdf_next_widget(ctx, w);
                    if (touches_any(areas, count, pdf_annot_rect(ctx, w))) pdf_delete_annot(ctx, page, w);
                    w = next;
                }
                pdf_redact_options opts = { 1, PDF_REDACT_IMAGE_PIXELS, PDF_REDACT_LINE_ART_REMOVE_IF_TOUCHED, PDF_REDACT_TEXT_REMOVE };
                pdf_redact_page(ctx, doc, page, &opts);
                pdf_update_page(ctx, page);
                free(areas);
                free(annots);
                free(doomed);
                areas = NULL;
                annots = NULL;
                doomed = NULL;
            }
            fz_drop_page(ctx, (fz_page *)page);
            page = NULL;
        }
    }
    fz_always(ctx) {
        fz_drop_page(ctx, (fz_page *)page);
        free(areas);
        free(annots);
        free(doomed);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

bool opdf_rebase(opdf_doc *d, const opdf_rebase_options *o, opdf_error *err) {
    clear_error(err);
    fz_context *ctx = d->ctx;
    char temp[1024] = "";
    pdf_document *copy = NULL, *fresh = NULL;
    fz_buffer *buf = NULL;
    fz_output *out = NULL;
    fz_stream *stm = NULL;
    bool ok = false;
    fz_var(copy);
    fz_var(fresh);
    fz_var(buf);
    fz_var(out);
    fz_var(stm);
    fz_var(ok);
    lock_doc(d);
    fz_try(ctx) {
        pdf_document *pdf = pdf_specifics(ctx, d->doc);
        if (!pdf || !pdf->file) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a PDF");
        if (o->encryption == OPDF_ENCRYPT_AES256) {
            if (!o->owner_password || !o->owner_password[0]) fz_throw(ctx, FZ_ERROR_ARGUMENT, "An owner password is needed");
            if (strlen(o->owner_password) > 127 || (o->user_password && strlen(o->user_password) > 127))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Passwords can be at most 127 bytes long");
        }
        // The document to write: a copy of it as it is now, when it can be
        // saved as a snapshot (so a failure leaves the open document as it
        // was); after a redaction, which can't be, the document itself.
        pdf_document *source = pdf;
        if (pdf_can_be_saved_incrementally(ctx, pdf)) {
            const char *dir = getenv("TMPDIR");
            fz_snprintf(temp, sizeof temp, "%s/opdf-rebase-XXXXXX", dir && dir[0] ? dir : "/tmp");
            int fd = mkstemp(temp);
            if (fd < 0) {
                temp[0] = 0;
                fz_throw(ctx, FZ_ERROR_SYSTEM, "Could not make a temporary file");
            }
            close(fd);
            write_snapshot(ctx, pdf, temp);
            copy = pdf_open_document(ctx, temp);
            if (pdf_needs_password(ctx, copy) && !(o->open_password && pdf_authenticate_password(ctx, copy, o->open_password)))
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Could not unlock the document's copy");
            source = copy;
        }
        if (o->redact) {
            pdf_begin_operation(ctx, source, "Apply Redactions");
            fz_try(ctx) {
                redact_document(ctx, source);
                pdf_end_operation(ctx, source);
            }
            fz_catch(ctx) {
                pdf_abandon_operation(ctx, source);
                fz_rethrow(ctx);
            }
        }
        if (o->scrub) {
            pdf_begin_operation(ctx, source, "Clean Up");
            fz_try(ctx) {
                scrub_document(ctx, source, o->now);
                pdf_end_operation(ctx, source);
            }
            fz_catch(ctx) {
                pdf_abandon_operation(ctx, source);
                fz_rethrow(ctx);
            }
        }
        pdf_write_options opts = pdf_default_write_options;
        opts.do_garbage = 3;
        opts.do_compress = 1;
        opts.do_use_objstms = 1;
        if (o->encryption == OPDF_ENCRYPT_NONE) {
            opts.do_encrypt = PDF_ENCRYPT_NONE;
        } else if (o->encryption == OPDF_ENCRYPT_AES256) {
            opts.do_encrypt = PDF_ENCRYPT_AES_256;
            opts.permissions = o->permissions;
            fz_strlcpy(opts.opwd_utf8, o->owner_password, sizeof opts.opwd_utf8);
            fz_strlcpy(opts.upwd_utf8, o->user_password ? o->user_password : "", sizeof opts.upwd_utf8);
        }
        buf = fz_new_buffer(ctx, 1 << 20);
        out = fz_new_output_with_buffer(ctx, buf);
        pdf_journal *journal = source->journal;
        source->journal = NULL;
        fz_try(ctx)
            pdf_write_document(ctx, source, out, &opts);
        fz_always(ctx)
            source->journal = journal;
        fz_catch(ctx)
            fz_rethrow(ctx);
        fz_close_output(ctx, out);
        stm = fz_open_buffer(ctx, buf);
        fresh = pdf_open_document_with_stream(ctx, stm);
        const char *unlock = o->encryption == OPDF_ENCRYPT_AES256 ? o->owner_password
                           : o->encryption == OPDF_ENCRYPT_NONE ? "" : o->open_password;
        if (pdf_needs_password(ctx, fresh) && !(unlock && pdf_authenticate_password(ctx, fresh, unlock)))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Could not unlock the rewritten document");
        pdf_check_document(ctx, fresh);
        if (pdf_was_repaired(ctx, fresh)) fz_throw(ctx, FZ_ERROR_FORMAT, "The rewritten document is damaged");
        pdf_enable_journal(ctx, fresh);
        // Unlocked with the owner password (or not encrypted): full access.
        d->access = fresh->crypt ? pdf_authenticate_password(ctx, fresh, unlock ? unlock : "") : 4;
        if (o->encryption == OPDF_ENCRYPT_NONE) d->needs_open_password = false;
        if (o->encryption == OPDF_ENCRYPT_AES256) d->needs_open_password = o->user_password && *o->user_password;
        fz_drop_document(ctx, d->doc);
        d->doc = (fz_document *)fresh;
        fresh = NULL;
        d->repaired_before_edits = false;
        d->edits_prepared = true;
        ok = true;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_drop_stream(ctx, stm);
        fz_drop_buffer(ctx, buf);
        pdf_drop_document(ctx, copy);
        pdf_drop_document(ctx, fresh);
        if (temp[0]) unlink(temp);
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

// --- Stamps: headers, footers, page numbers, watermarks -------------------------

static const char *stamp_name(int kind) {
    return kind == OPDF_STAMP_HEADER ? "Header" : kind == OPDF_STAMP_FOOTER ? "Footer" : "Watermark";
}

// A PDF string literal of these bytes.
static void append_pdf_string(fz_context *ctx, fz_buffer *buf, const unsigned char *s, size_t n) {
    fz_append_byte(ctx, buf, '(');
    for (size_t i = 0; i < n; i++) {
        unsigned char c = s[i];
        if (c == '(' || c == ')' || c == '\\') fz_append_printf(ctx, buf, "\\%c", c);
        else if (c < 32 || c > 126) fz_append_printf(ctx, buf, "\\%03o", c);
        else fz_append_byte(ctx, buf, c);
    }
    fz_append_byte(ctx, buf, ')');
}

// One stamp's text encoded for its font, and its width in points.
static void encode_stamp(fz_context *ctx, const opdf_stamp *st, fz_font *helv, text_plan *plan, fz_font *embedded,
                         fz_buffer *bytes, float *width) {
    *width = 0;
    for (int i = 0; i < plan->count; i++) {
        int u = plan->unicode[i];
        if (embedded) {
            fz_append_byte(ctx, bytes, plan->gid[i] >> 8);
            fz_append_byte(ctx, bytes, plan->gid[i] & 0xff);
            *width += fz_advance_glyph(ctx, embedded, plan->gid[i], 0) * st->size;
        } else {
            int c = fz_windows_1252_from_unicode(u);
            if (c < 0) {
                char utf[8] = { 0 };
                fz_runetochar(utf, u);
                fz_throw(ctx, FZ_ERROR_ARGUMENT, "Helvetica has no \u201c%s\u201d", utf);
            }
            fz_append_byte(ctx, bytes, c);
            *width += fz_advance_glyph(ctx, helv, fz_encode_character(ctx, helv, u), 0) * st->size;
        }
    }
}

// Appends the page's stamps as a new content stream, after making sure the
// existing content leaves the graphics state as it found it.
static void stamp_page(fz_context *ctx, pdf_document *pdf, pdf_page *page, const opdf_stamp *stamps, int count,
                       pdf_obj *font_obj, const char *font_name, fz_font *helv, fz_font *embedded,
                       text_plan *plans) {
    fz_buffer *buf = NULL, *bytes = NULL, *pre = NULL, *post = NULL;
    pdf_obj *gs = NULL;
    fz_var(buf);
    fz_var(bytes);
    fz_var(pre);
    fz_var(post);
    fz_var(gs);
    fz_try(ctx) {
        // The font's name on this page: the one it already has there, or a
        // new one (never replacing another font of the same name).
        pdf_obj *fonts = own_resources(ctx, pdf, page, PDF_NAME(Font));
        char name[32] = "";
        // Only a name this code makes is reused (the file's own names are
        // never written into the stamp's content).
        for (int i = 0, n = pdf_dict_len(ctx, fonts); i < n && !name[0]; i++) {
            const char *key = pdf_to_name(ctx, pdf_dict_get_key(ctx, fonts, i));
            size_t prefix = strlen(font_name);
            bool ours = strlen(key) < sizeof name && !strncmp(key, font_name, prefix) && key[prefix] &&
                        strspn(key + prefix, "0123456789") == strlen(key + prefix);
            if (ours && pdf_is_indirect(ctx, pdf_dict_get_val(ctx, fonts, i)) && !pdf_objcmp(ctx, pdf_dict_get_val(ctx, fonts, i), font_obj))
                fz_strlcpy(name, key, sizeof name);
        }
        if (!name[0]) {
            new_resource_name(ctx, fonts, font_name, name);
            pdf_dict_puts(ctx, fonts, name, font_obj);
        }
        font_name = name;
        pdf_obj *states = own_resources(ctx, pdf, page, PDF_NAME(ExtGState));
        fz_rect mediabox;
        fz_matrix ctm;
        pdf_page_transform(ctx, page, &mediabox, &ctm);
        fz_matrix to_pdf = fz_invert_matrix(ctm);
        fz_rect bounds = pdf_bound_page(ctx, page, FZ_CROP_BOX);
        buf = fz_new_buffer(ctx, 512);
        for (int i = 0; i < count; i++) {
            const opdf_stamp *st = &stamps[i];
            if (!(st->size >= 1 && st->size <= 1000)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "That text size is out of range");
            bytes = fz_new_buffer(ctx, 64);
            float width;
            encode_stamp(ctx, st, helv, &plans[i], embedded, bytes, &width);
            if (plans[i].count == 0) {
                fz_drop_buffer(ctx, bytes);
                bytes = NULL;
                continue;
            }
            // The text's matrix in page space (y down), then in PDF space.
            float a = 1, b = 0;
            float x, y;
            float margin = st->margin > 0 ? st->margin : 36;
            if (st->kind == OPDF_STAMP_WATERMARK) {
                float r = st->angle * (float)M_PI / 180;
                a = cosf(r);
                b = -sinf(r);
                float cx = (bounds.x0 + bounds.x1) / 2, cy = (bounds.y0 + bounds.y1) / 2;
                // Centred: start half the width back along the baseline, and
                // a third of the size down.
                float vx = -width / 2, vy = -st->size * 0.35f;
                // The vector through the text's matrix [a b b -a].
                x = cx + a * vx + b * vy;
                y = cy + b * vx - a * vy;
            } else {
                x = st->align == 0 ? bounds.x0 + margin
                  : st->align == 2 ? bounds.x1 - margin - width
                  : (bounds.x0 + bounds.x1 - width) / 2;
                y = st->kind == OPDF_STAMP_HEADER ? bounds.y0 + margin + st->size * 0.8f : bounds.y1 - margin;
            }
            fz_matrix tm = fz_concat(fz_make_matrix(a, b, b, -a, x, y), to_pdf);
            char gsname[32] = "";
            float opacity = st->opacity > 0 && st->opacity < 1 ? st->opacity : 1;
            if (opacity < 1) {
                gs = pdf_new_dict(ctx, pdf, 2);
                pdf_dict_put_real(ctx, gs, PDF_NAME(ca), opacity);
                pdf_dict_put_real(ctx, gs, PDF_NAME(CA), opacity);
                new_resource_name(ctx, states, "OPDFGs", gsname);
                pdf_dict_puts_drop(ctx, states, gsname, gs);
                gs = NULL;
            }
            fz_append_printf(ctx, buf, "/Artifact <</Type /Pagination /Subtype /%s /OPDFStamp /%s>> BDC\nq\n",
                             stamp_name(st->kind), stamp_name(st->kind));
            if (gsname[0]) fz_append_printf(ctx, buf, "/%s gs\n", gsname);
            fz_append_printf(ctx, buf, "%g %g %g rg\nBT\n/%s %g Tf\n%g %g %g %g %g %g Tm\n",
                             fz_clamp(st->color[0], 0, 1), fz_clamp(st->color[1], 0, 1), fz_clamp(st->color[2], 0, 1),
                             font_name, st->size, tm.a, tm.b, tm.c, tm.d, tm.e, tm.f);
            unsigned char *data;
            size_t n = fz_buffer_storage(ctx, bytes, &data);
            if (embedded) {
                fz_append_byte(ctx, buf, '<');
                for (size_t k = 0; k < n; k++) fz_append_printf(ctx, buf, "%02x", data[k]);
                fz_append_byte(ctx, buf, '>');
            } else {
                append_pdf_string(ctx, buf, data, n);
            }
            fz_append_string(ctx, buf, " Tj\nET\nQ\nEMC\n");
            fz_drop_buffer(ctx, bytes);
            bytes = NULL;
        }
        if (fz_buffer_storage(ctx, buf, NULL) == 0) break;
        // Balance the existing content, as pdf_bake_page does.
        pdf_obj *res = pdf_page_resources(ctx, page);
        pdf_obj *contents = pdf_page_contents(ctx, page);
        int prepend = 0, append = 0;
        pdf_count_q_balance(ctx, pdf, res, contents, &prepend, &append);
        if (prepend > 1000 || append > 1000) fz_throw(ctx, FZ_ERROR_LIMIT, "This page's content is too unbalanced to stamp");
        pdf_obj *array = pdf_dict_get(ctx, page->obj, PDF_NAME(Contents));
        if (!pdf_is_array(ctx, array)) {
            pdf_obj *made = pdf_new_array(ctx, pdf, 4);
            if (array) pdf_array_push(ctx, made, array);
            pdf_dict_put_drop(ctx, page->obj, PDF_NAME(Contents), made);
            array = made;
        } else if (pdf_is_indirect(ctx, array)) {
            pdf_obj *copy = pdf_copy_array(ctx, array);
            pdf_dict_put_drop(ctx, page->obj, PDF_NAME(Contents), copy);
            array = copy;
        }
        if (prepend > 0) {
            pre = fz_new_buffer(ctx, (size_t)prepend * 2);
            for (int i = 0; i < prepend; i++) fz_append_string(ctx, pre, "q\n");
            pdf_array_insert_drop(ctx, array, pdf_add_stream(ctx, pdf, pre, NULL, 0), 0);
        }
        post = fz_new_buffer(ctx, (size_t)append * 2 + fz_buffer_storage(ctx, buf, NULL));
        for (int i = 0; i < append; i++) fz_append_string(ctx, post, "Q\n");
        fz_append_buffer(ctx, post, buf);
        pdf_array_push_drop(ctx, array, pdf_add_stream(ctx, pdf, post, NULL, 0));
    }
    fz_always(ctx) {
        fz_drop_buffer(ctx, buf);
        fz_drop_buffer(ctx, bytes);
        fz_drop_buffer(ctx, pre);
        fz_drop_buffer(ctx, post);
        pdf_drop_obj(ctx, gs);
    }
    fz_catch(ctx)
        fz_rethrow(ctx);
}

bool opdf_stamp_pages(opdf_doc *d, const opdf_stamp *stamps, int count, const unsigned char *font_data, size_t font_len,
                      opdf_error *err) {
    clear_error(err);
    fz_font *helv = NULL, *embedded = NULL;
    pdf_obj *font_obj = NULL;
    text_plan *plans = NULL;
    text_plan all = { 0 };
    pdf_page *page = NULL;
    fz_buffer *fontbuf = NULL;
    fz_var(helv);
    fz_var(embedded);
    fz_var(font_obj);
    fz_var(plans);
    fz_var(page);
    fz_var(fontbuf);
    WITH_DOC_OPERATION(d, "Add Stamps", err, {
        fz_try(ctx) {
            if (count < 0 || count > 100000 || (count > 0 && !stamps)) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Too many stamps");
            int pages = pdf_count_pages(ctx, pdf);
            plans = fz_calloc(ctx, (size_t)(count > 0 ? count : 1), sizeof *plans);
            size_t total = 0;
            for (int i = 0; i < count; i++) {
                if (stamps[i].page < 0 || stamps[i].page >= pages) fz_throw(ctx, FZ_ERROR_ARGUMENT, "There is no such page");
                if (stamps[i].kind < 0 || stamps[i].kind > 2) fz_throw(ctx, FZ_ERROR_ARGUMENT, "Not a kind of stamp");
                const char *text = stamps[i].text ? stamps[i].text : "";
                total += strlen(text);
                if (strlen(text) > 1000 || total > (8 << 20)) fz_throw(ctx, FZ_ERROR_LIMIT, "That text is too long to stamp");
                plan_text(ctx, NULL, text, true, &plans[i]);
            }
            helv = fz_new_base14_font(ctx, "Helvetica");
            char font_name[32];
            if (font_data) {
                // One font for every stamp: its plan is every character used.
                int n = 0;
                for (int i = 0; i < count; i++) n += plans[i].count;
                all.unicode = fz_malloc_array(ctx, n + 1, int);
                all.len = fz_calloc(ctx, (size_t)n + 1, sizeof(int));
                all.code = fz_calloc(ctx, (size_t)n + 1, 4);
                all.gid = fz_calloc(ctx, (size_t)n + 1, sizeof(int));
                for (int i = 0; i < count; i++)
                    for (int j = 0; j < plans[i].count; j++) all.unicode[all.count++] = plans[i].unicode[j];
                font_obj = embed_subset_font(ctx, pdf, font_data, font_len, &all);
                fontbuf = fz_new_buffer_from_copied_data(ctx, font_data, font_len);
                embedded = fz_new_font_from_buffer(ctx, NULL, fontbuf, 0, 0);
                for (int i = 0; i < count; i++)
                    for (int j = 0; j < plans[i].count; j++) plans[i].gid[j] = fz_encode_character(ctx, embedded, plans[i].unicode[j]);
                fz_strlcpy(font_name, "OPDFStampFont", sizeof font_name);
            } else {
                font_obj = pdf_add_simple_font(ctx, pdf, helv, PDF_SIMPLE_ENCODING_LATIN);
                fz_strlcpy(font_name, "OPDFHelv", sizeof font_name);
            }
            // Page by page, the stamps for each.
            for (int p = 0; p < pages; p++) {
                int first = -1, n = 0;
                for (int i = 0; i < count; i++) if (stamps[i].page == p) { if (first < 0) first = i; n++; }
                if (n == 0) continue;
                // Stamps for a page are passed together (gathered here if not).
                opdf_stamp *mine = fz_malloc_array(ctx, n, opdf_stamp);
                text_plan *mine_plans = fz_malloc_array(ctx, n, text_plan);
                int k = 0;
                for (int i = 0; i < count; i++) if (stamps[i].page == p) { mine[k] = stamps[i]; mine_plans[k] = plans[i]; k++; }
                page = pdf_load_page(ctx, pdf, p);
                fz_try(ctx)
                    stamp_page(ctx, pdf, page, mine, n, font_obj, font_name, helv, embedded, mine_plans);
                fz_always(ctx) {
                    fz_free(ctx, mine);
                    fz_free(ctx, mine_plans);
                    fz_drop_page(ctx, (fz_page *)page);
                    page = NULL;
                }
                fz_catch(ctx)
                    fz_rethrow(ctx);
            }
        }
        fz_always(ctx) {
            for (int i = 0; plans && i < count; i++) drop_plan(ctx, &plans[i]);
            fz_free(ctx, plans);
            plans = NULL;
            drop_plan(ctx, &all);
            fz_drop_font(ctx, helv);
            fz_drop_font(ctx, embedded);
            fz_drop_buffer(ctx, fontbuf);
            pdf_drop_obj(ctx, font_obj);
            helv = embedded = NULL;
            font_obj = NULL;
            fontbuf = NULL;
        }
        fz_catch(ctx)
            fz_rethrow(ctx);
    });
    unlock_doc(d);
    return !(err && err->code);
}

// Removing: marked content with /OPDFStamp of the chosen kinds is dropped,
// with everything inside it.
typedef struct {
    int kinds;
    int depth;         // marked-content nesting (never below 0)
    bool skipping;     // dropping a stamp...
    int skip_from;     // ...until the EMC at this depth
    bool removed;
    pdf_processor *out;
} stamp_removal;

static bool stamp_kind_matches(fz_context *ctx, pdf_obj *props, int kinds) {
    pdf_obj *kind = pdf_dict_gets(ctx, props, "OPDFStamp");
    if (!pdf_is_name(ctx, kind)) return false;
    if ((kinds & OPDF_STAMPS_HEADERS_FOOTERS) && (!strcmp(pdf_to_name(ctx, kind), "Header") || !strcmp(pdf_to_name(ctx, kind), "Footer"))) return true;
    if ((kinds & OPDF_STAMPS_WATERMARKS) && !strcmp(pdf_to_name(ctx, kind), "Watermark")) return true;
    return false;
}

static void sr_BDC(fz_context *ctx, pdf_processor *proc, const char *tag, pdf_obj *raw, pdf_obj *cooked) {
    content_proc *p = (content_proc *)proc;
    stamp_removal *r = p->arg;
    r->depth++;
    if (!r->skipping && stamp_kind_matches(ctx, raw, r->kinds)) {
        r->skipping = true;
        r->skip_from = r->depth;
        r->removed = true;
        // Everything until the matching EMC goes nowhere.
        p->super.chain = NULL;
        p->out = NULL;
        return;
    }
    if (CHAIN(p)) CHAIN(p)->op_BDC(ctx, CHAIN(p), tag, raw, cooked);
}

static void sr_BMC(fz_context *ctx, pdf_processor *proc, const char *tag) {
    content_proc *p = (content_proc *)proc;
    stamp_removal *r = p->arg;
    r->depth++;
    if (CHAIN(p)) CHAIN(p)->op_BMC(ctx, CHAIN(p), tag);
}

static void sr_EMC(fz_context *ctx, pdf_processor *proc) {
    content_proc *p = (content_proc *)proc;
    stamp_removal *r = p->arg;
    if (r->skipping && r->depth == r->skip_from) {
        r->skipping = false;
        p->super.chain = r->out;
        p->out = r->out;
        r->depth--;
        return;
    }
    // A stray EMC (with no BDC) is passed on but doesn't count.
    if (r->depth > 0) r->depth--;
    if (CHAIN(p)) CHAIN(p)->op_EMC(ctx, CHAIN(p));
}

static void configure_stamp_removal(content_proc *p, void *arg) {
    stamp_removal *r = arg;
    r->out = p->out;
    p->arg = r;
    p->super.op_BDC = sr_BDC;
    p->super.op_BMC = sr_BMC;
    p->super.op_EMC = sr_EMC;
}

bool opdf_stamps_remove(opdf_doc *d, int kinds, int *pages_changed, opdf_error *err) {
    clear_error(err);
    if (pages_changed) *pages_changed = 0;
    pdf_page *page = NULL;
    fz_var(page);
    WITH_DOC_OPERATION(d, "Remove Stamps", err, {
        int pages = pdf_count_pages(ctx, pdf);
        for (int i = 0; i < pages; i++) {
            page = pdf_load_page(ctx, pdf, i);
            fz_try(ctx) {
                // Only pages whose content mentions the tag are rewritten.
                bool mentions = false;
                pdf_obj *contents = pdf_page_contents(ctx, page);
                int n = pdf_is_array(ctx, contents) ? pdf_array_len(ctx, contents) : 1;
                for (int k = 0; k < n && !mentions; k++) {
                    pdf_obj *stm = pdf_is_array(ctx, contents) ? pdf_array_get(ctx, contents, k) : contents;
                    if (!pdf_is_stream(ctx, stm)) continue;
                    fz_buffer *b = pdf_load_stream(ctx, stm);
                    unsigned char *data;
                    size_t len = fz_buffer_storage(ctx, b, &data);
                    for (size_t j = 0; j + 10 <= len && !mentions; j++) mentions = !memcmp(data + j, "OPDFStamp", 9);
                    fz_drop_buffer(ctx, b);
                }
                if (mentions) {
                    stamp_removal r = { .kinds = kinds };
                    rewrite_page_content(ctx, pdf, page, configure_stamp_removal, &r);
                    if (r.removed && pages_changed) (*pages_changed)++;
                }
            }
            fz_always(ctx) {
                fz_drop_page(ctx, (fz_page *)page);
                page = NULL;
            }
            fz_catch(ctx)
                fz_rethrow(ctx);
        }
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

bool opdf_write_blank(const char *path, float width, float height, opdf_error *err) {
    clear_error(err);
    allocator_owner allocator;
    fz_alloc_context alloc;
    fz_context *ctx = new_capped_context(&allocator, &alloc, NULL, NO_HANDLERS);
    if (!ctx) {
        set_no_context_error(err, &allocator);
        release_budget(&allocator);
        return false;
    }
    pdf_document *doc = NULL;
    pdf_obj *page = NULL;
    bool ok = false;
    fz_var(doc);
    fz_var(page);
    fz_var(ok);
    fz_try(ctx) {
        if (!(width >= 72 && width <= 14400 && height >= 72 && height <= 14400))
            fz_throw(ctx, FZ_ERROR_ARGUMENT, "Page size out of range");
        doc = pdf_create_document(ctx);
        page = pdf_add_page(ctx, doc, fz_make_rect(0, 0, width, height), 0, NULL, NULL);
        pdf_insert_page(ctx, doc, -1, page);
        pdf_write_options opts = pdf_default_write_options;
        opts.do_compress = 1;
        pdf_save_document(ctx, doc, path, &opts);
        ok = true;
    }
    fz_always(ctx) {
        pdf_drop_obj(ctx, page);
        pdf_drop_document(ctx, doc);
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
