#ifndef OPDF_CMS_H
#define OPDF_CMS_H

// Detached CMS signatures (adbe.pkcs7.detached, SHA-256) with Security.framework:
// the signer and verifier the bridge hands MuPDF. Kept apart from MuPDF's
// headers; nothing here throws.

#include <stdbool.h>
#include <stddef.h>

typedef struct cms_signer cms_signer;
typedef struct cms_session cms_session;

// A signer for a Keychain identity (a SecIdentityRef), which it retains.
cms_signer *cms_signer_new(const void *identity, char *err, size_t errlen);
void cms_signer_free(cms_signer *signer);
// The most bytes a signature can take: the same every time it's asked.
size_t cms_signer_max_size(const cms_signer *signer);
// The certificate's common name and first email address ("" if none).
const char *cms_signer_name(const cms_signer *signer);
const char *cms_signer_email(const cms_signer *signer);

// Signing streams the signed bytes in, then writes the DER signature.
cms_session *cms_sign_begin(cms_signer *signer, char *err, size_t errlen);
bool cms_sign_update(cms_session *session, const void *data, size_t len);
// Gives up a signature without making it (nor using the key).
void cms_sign_abort(cms_session *session);
// The signature's length, or 0 (and a message) if it couldn't be made or is
// longer than `size`. Frees the session either way.
size_t cms_sign_finish(cms_session *session, unsigned char *out, size_t size, char *err, size_t errlen);

enum {
    CMS_INTEGRITY_VALID = 0,     // the signature matches the signed bytes
    CMS_INTEGRITY_INVALID = 1,   // the bytes were changed, or the signature is wrong
    CMS_INTEGRITY_MALFORMED = 2, // not a signature this app can read
};

enum {
    CMS_TRUST_TRUSTED = 0,       // chains to a certificate the Mac trusts
    CMS_TRUST_SELF_SIGNED = 1,
    CMS_TRUST_UNTRUSTED = 2,
    CMS_TRUST_EXPIRED = 3,       // or not valid yet
    CMS_TRUST_REVOKED = 4,
    CMS_TRUST_UNKNOWN = 5,
    CMS_TRUST_NOT_FOR_SIGNING = 6, // a certificate for something else (a website, code, ...)
};

typedef struct {
    int integrity;
    int trust;
    char signer[256];            // the certificate's subject summary
    char email[256];
    double signing_time;         // seconds since 1970, from the signer's clock; 0 if none
} cms_result;

// Checks a detached signature over `data`. Certificates are fetched and
// revocation checked over the network only when `network` is true.
void cms_verify(const unsigned char *signature, size_t signature_len,
                const unsigned char *data, size_t data_len, bool network, cms_result *result);

// The length of the signature (a BER SEQUENCE, definite or indefinite) at
// the start of `der`, padded with zeros, or 0 if it isn't one that fits in
// `len` bytes.
size_t cms_der_length(const unsigned char *der, size_t len);

#endif
