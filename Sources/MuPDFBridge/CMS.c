#include "cms.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct cms_signer {
    SecIdentityRef identity;
    size_t max_size;
    char name[256];
    char email[256];
};

struct cms_session {
    CMSEncoderRef encoder;
};

static void message(char *err, size_t errlen, const char *text, OSStatus status) {
    if (!err || !errlen) return;
    CFStringRef reason = status ? SecCopyErrorMessageString(status, NULL) : NULL;
    char detail[256] = "";
    if (reason) CFStringGetCString(reason, detail, sizeof detail, kCFStringEncodingUTF8);
    if (reason) CFRelease(reason);
    if (detail[0]) snprintf(err, errlen, "%s (%s)", text, detail);
    else snprintf(err, errlen, "%s", text);
}

static void copy_string(CFStringRef s, char *out, size_t size) {
    out[0] = 0;
    if (s && !CFStringGetCString(s, out, (CFIndex)size, kCFStringEncodingUTF8)) out[0] = 0;
}

static void certificate_names(SecCertificateRef cert, char *name, size_t name_size, char *email, size_t email_size) {
    name[0] = email[0] = 0;
    CFStringRef cn = NULL;
    if (SecCertificateCopyCommonName(cert, &cn) == errSecSuccess && cn) {
        copy_string(cn, name, name_size);
        CFRelease(cn);
    }
    if (!name[0]) {
        CFStringRef summary = SecCertificateCopySubjectSummary(cert);
        copy_string(summary, name, name_size);
        if (summary) CFRelease(summary);
    }
    CFArrayRef emails = NULL;
    if (SecCertificateCopyEmailAddresses(cert, &emails) == errSecSuccess && emails) {
        if (CFArrayGetCount(emails) > 0) copy_string(CFArrayGetValueAtIndex(emails, 0), email, email_size);
        CFRelease(emails);
    }
}

// The certificate chain the signature will carry, built offline.
static CFArrayRef copy_chain(SecCertificateRef cert) {
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    CFArrayRef chain = NULL;
    if (SecTrustCreateWithCertificates(cert, policy, &trust) == errSecSuccess) {
        SecTrustSetNetworkFetchAllowed(trust, false);
        (void)SecTrustEvaluateWithError(trust, NULL);   // builds the chain, trusted or not
        chain = SecTrustCopyCertificateChain(trust);
        CFRelease(trust);
    }
    CFRelease(policy);
    return chain;
}

cms_signer *cms_signer_new(const void *identity, char *err, size_t errlen) {
    if (!identity || CFGetTypeID(identity) != SecIdentityGetTypeID()) {
        message(err, errlen, "That isn't a signing identity.", 0);
        return NULL;
    }
    SecCertificateRef cert = NULL;
    OSStatus status = SecIdentityCopyCertificate((SecIdentityRef)identity, &cert);
    if (status != errSecSuccess || !cert) {
        message(err, errlen, "The identity's certificate couldn't be read.", status);
        return NULL;
    }
    cms_signer *s = calloc(1, sizeof *s);
    if (!s) {
        CFRelease(cert);
        message(err, errlen, "Out of memory.", 0);
        return NULL;
    }
    s->identity = (SecIdentityRef)CFRetain(identity);
    certificate_names(cert, s->name, sizeof s->name, s->email, sizeof s->email);
    // The chain's certificates, plus room for the signature (up to RSA
    // 16384) and its attributes.
    size_t certs = 0;
    CFArrayRef chain = copy_chain(cert);
    if (chain) {
        for (CFIndex i = 0; i < CFArrayGetCount(chain); i++) {
            CFDataRef der = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(chain, i));
            if (der) {
                certs += (size_t)CFDataGetLength(der);
                CFRelease(der);
            }
        }
        CFRelease(chain);
    } else {
        CFDataRef der = SecCertificateCopyData(cert);
        if (der) {
            certs = (size_t)CFDataGetLength(der);
            CFRelease(der);
        }
    }
    s->max_size = certs + 8192;
    CFRelease(cert);
    return s;
}

void cms_signer_free(cms_signer *s) {
    if (!s) return;
    if (s->identity) CFRelease(s->identity);
    free(s);
}

size_t cms_signer_max_size(const cms_signer *s) { return s->max_size; }
const char *cms_signer_name(const cms_signer *s) { return s->name; }
const char *cms_signer_email(const cms_signer *s) { return s->email; }

cms_session *cms_sign_begin(cms_signer *s, char *err, size_t errlen) {
    CMSEncoderRef encoder = NULL;
    OSStatus status = CMSEncoderCreate(&encoder);
    if (status == errSecSuccess) status = CMSEncoderAddSigners(encoder, s->identity);
    if (status == errSecSuccess) status = CMSEncoderSetHasDetachedContent(encoder, true);
    if (status == errSecSuccess) status = CMSEncoderSetSignerAlgorithm(encoder, kCMSEncoderDigestAlgorithmSHA256);
    if (status == errSecSuccess) status = CMSEncoderAddSignedAttributes(encoder, kCMSAttrSigningTime);
    if (status == errSecSuccess) status = CMSEncoderSetCertificateChainMode(encoder, kCMSCertificateChain);
    if (status != errSecSuccess) {
        if (encoder) CFRelease(encoder);
        message(err, errlen, "The signature couldn't be started.", status);
        return NULL;
    }
    cms_session *session = calloc(1, sizeof *session);
    if (!session) {
        CFRelease(encoder);
        message(err, errlen, "Out of memory.", 0);
        return NULL;
    }
    session->encoder = encoder;
    return session;
}

bool cms_sign_update(cms_session *session, const void *data, size_t len) {
    return CMSEncoderUpdateContent(session->encoder, data, len) == errSecSuccess;
}

void cms_sign_abort(cms_session *session) {
    if (!session) return;
    CFRelease(session->encoder);
    free(session);
}

size_t cms_sign_finish(cms_session *session, unsigned char *out, size_t size, char *err, size_t errlen) {
    size_t length = 0;
    CFDataRef der = NULL;
    // Signing uses the private key: the Keychain may ask to allow it.
    OSStatus status = CMSEncoderCopyEncodedContent(session->encoder, &der);
    if (status != errSecSuccess || !der) {
        message(err, errlen, "The document couldn't be signed.", status);
    } else if ((size_t)CFDataGetLength(der) > size) {
        message(err, errlen, "The signature is larger than expected.", 0);
    } else {
        length = (size_t)CFDataGetLength(der);
        memcpy(out, CFDataGetBytePtr(der), length);
    }
    if (der) CFRelease(der);
    CFRelease(session->encoder);
    free(session);
    return length;
}

// The length of one BER element at `p` (at most `len` bytes), definite or
// indefinite (ended by 00 00), or 0 if it isn't a whole one.
static size_t ber_length(const unsigned char *p, size_t len, int depth) {
    if (depth > 64 || len < 2) return 0;
    size_t i = 1;
    if ((p[0] & 0x1f) == 0x1f) {   // a tag number in more bytes
        while (i < len && (p[i] & 0x80)) i++;
        if (++i >= len || i > 6) return 0;
    }
    unsigned char first = p[i++];
    if (first == 0x80) {
        if (!(p[0] & 0x20)) return 0;   // only constructed elements may be indefinite
        while (i + 2 <= len) {
            if (p[i] == 0 && p[i + 1] == 0) return i + 2;
            size_t child = ber_length(p + i, len - i, depth + 1);
            if (child == 0) return 0;
            i += child;
        }
        return 0;
    }
    size_t body = first;
    if (first & 0x80) {
        size_t bytes = first & 0x7f;
        if (bytes == 0 || bytes > 4 || len - i < bytes) return 0;
        body = 0;
        for (size_t k = 0; k < bytes; k++) body = (body << 8) | p[i++];
    }
    if (body > len - i) return 0;
    return i + body;
}

// The element at `p`: its first tag byte, the length of its header, of its
// contents (before 00 00 if indefinite) and of all of it.
static bool ber_element(const unsigned char *p, size_t len, unsigned char *tag, size_t *header, size_t *content, size_t *total) {
    size_t all = ber_length(p, len, 0);
    if (all == 0) return false;
    size_t i = 1;
    if ((p[0] & 0x1f) == 0x1f) {
        while (i < len && (p[i] & 0x80)) i++;
        i++;
    }
    unsigned char first = p[i++];
    if (first & 0x80) i += first & 0x7f;
    if (i > all) return false;
    *tag = p[0];
    *header = i;
    *content = all - i - (first == 0x80 ? 2 : 0);
    *total = all;
    return true;
}

static const unsigned char OID_SIGNED_DATA[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02 };
static const unsigned char OID_DATA[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };

// Whether the signature is a detached SignedData over id-data: a signature
// that carries its own content would be checked against that, not the PDF.
static bool is_detached_signature(const unsigned char *der, size_t len) {
    unsigned char tag;
    size_t header, content, total;
    // ContentInfo: contentType signedData, [0] content.
    if (!ber_element(der, len, &tag, &header, &content, &total) || tag != 0x30) return false;
    const unsigned char *p = der + header;
    size_t n = content;
    if (!ber_element(p, n, &tag, &header, &content, &total) || tag != 0x06 || content != sizeof OID_SIGNED_DATA
        || memcmp(p + header, OID_SIGNED_DATA, sizeof OID_SIGNED_DATA)) return false;
    p += total; n -= total;
    if (!ber_element(p, n, &tag, &header, &content, &total) || tag != 0xa0) return false;
    p += header; n = content;
    // SignedData: version, digestAlgorithms, encapContentInfo, ...
    if (!ber_element(p, n, &tag, &header, &content, &total) || tag != 0x30) return false;
    p += header; n = content;
    if (!ber_element(p, n, &tag, &header, &content, &total) || tag != 0x02) return false;
    p += total; n -= total;
    if (!ber_element(p, n, &tag, &header, &content, &total) || tag != 0x31) return false;
    p += total; n -= total;
    if (!ber_element(p, n, &tag, &header, &content, &total) || tag != 0x30) return false;
    // encapContentInfo: id-data, and no eContent.
    const unsigned char *e = p + header;
    size_t en = content;
    if (!ber_element(e, en, &tag, &header, &content, &total) || tag != 0x06 || content != sizeof OID_DATA
        || memcmp(e + header, OID_DATA, sizeof OID_DATA)) return false;
    return total == en;
}

size_t cms_der_length(const unsigned char *der, size_t len) {
    if (len < 2 || der[0] != 0x30) return 0;
    return ber_length(der, len, 0);
}

// Extended key usages that allow signing documents: email protection,
// document signing (IETF, Adobe, Microsoft) and any purpose.
static const char *const SIGNING_USAGES[] = {
    "1.3.6.1.5.5.7.3.4", "1.3.6.1.5.5.7.3.36", "1.2.840.113583.1.1.5", "1.3.6.1.4.1.311.10.3.12", "2.5.29.37.0",
};

// An OID's content bytes in dotted form.
static void oid_string(const unsigned char *p, size_t len, char *out, size_t size) {
    out[0] = 0;
    if (len == 0 || size < 16) return;
    unsigned long value = 0;
    size_t used = (size_t)snprintf(out, size, "%u.%u", p[0] / 40 > 2 ? 2 : p[0] / 40, p[0] / 40 > 2 ? p[0] - 80 : p[0] % 40);
    for (size_t i = 1; i < len && used < size - 12; i++) {
        value = (value << 7) | (p[i] & 0x7f);
        if (!(p[i] & 0x80)) {
            used += (size_t)snprintf(out + used, size - used, ".%lu", value);
            value = 0;
        }
    }
}

static bool usage_allows_signing(CFTypeRef item) {
    char oid[128] = "";
    if (CFGetTypeID(item) == CFDataGetTypeID()) {
        CFDataRef data = item;
        oid_string(CFDataGetBytePtr(data), (size_t)CFDataGetLength(data), oid, sizeof oid);
    } else if (CFGetTypeID(item) == CFStringGetTypeID()) {
        copy_string(item, oid, sizeof oid);
    }
    for (size_t i = 0; i < sizeof SIGNING_USAGES / sizeof *SIGNING_USAGES; i++)
        if (!strcmp(oid, SIGNING_USAGES[i])) return true;
    return false;
}

// Whether the certificate may sign documents: no extended key usage or one
// that allows it, and (if it limits key usage) digital signature or
// non-repudiation.
static bool usable_for_signing(SecCertificateRef cert) {
    const void *keys[] = { kSecOIDExtendedKeyUsage, kSecOIDKeyUsage };
    CFArrayRef wanted = CFArrayCreate(NULL, keys, 2, &kCFTypeArrayCallBacks);
    CFDictionaryRef values = wanted ? SecCertificateCopyValues(cert, wanted, NULL) : NULL;
    if (wanted) CFRelease(wanted);
    if (!values) return true;   // neither extension: no limits
    bool usable = true;
    CFDictionaryRef eku = CFDictionaryGetValue(values, kSecOIDExtendedKeyUsage);
    if (eku && CFGetTypeID(eku) == CFDictionaryGetTypeID()) {
        CFTypeRef list = CFDictionaryGetValue(eku, kSecPropertyKeyValue);
        usable = false;
        if (list && CFGetTypeID(list) == CFArrayGetTypeID())
            for (CFIndex i = 0; i < CFArrayGetCount(list) && !usable; i++)
                usable = usage_allows_signing(CFArrayGetValueAtIndex(list, i));
    }
    CFDictionaryRef ku = CFDictionaryGetValue(values, kSecOIDKeyUsage);
    if (usable && ku && CFGetTypeID(ku) == CFDictionaryGetTypeID()) {
        CFTypeRef bits = CFDictionaryGetValue(ku, kSecPropertyKeyValue);
        int value = 0;
        if (bits && CFGetTypeID(bits) == CFNumberGetTypeID() && CFNumberGetValue(bits, kCFNumberIntType, &value))
            // Security.framework reports a missing extension as 0 (a real one
            // has at least one bit).
            usable = value == 0 || (value & (kSecKeyUsageDigitalSignature | kSecKeyUsageNonRepudiation)) != 0;
        else
            usable = false;
    }
    CFRelease(values);
    return usable;
}

static bool self_issued(SecCertificateRef cert) {
    CFDataRef issuer = SecCertificateCopyNormalizedIssuerSequence(cert);
    CFDataRef subject = SecCertificateCopyNormalizedSubjectSequence(cert);
    bool same = issuer && subject && CFEqual(issuer, subject);
    if (issuer) CFRelease(issuer);
    if (subject) CFRelease(subject);
    return same;
}

static int evaluate_trust(SecTrustRef trust, bool network) {
    SecTrustSetNetworkFetchAllowed(trust, network);
    if (network) {
        SecPolicyRef basic = SecPolicyCreateBasicX509();
        SecPolicyRef revocation = SecPolicyCreateRevocation(kSecRevocationUseAnyAvailableMethod);
        if (basic && revocation) {
            const void *values[] = { basic, revocation };
            CFArrayRef policies = CFArrayCreate(NULL, values, 2, &kCFTypeArrayCallBacks);
            if (policies) {
                SecTrustSetPolicies(trust, policies);
                CFRelease(policies);
            }
        }
        if (basic) CFRelease(basic);
        if (revocation) CFRelease(revocation);
    }
    CFErrorRef error = NULL;
    if (SecTrustEvaluateWithError(trust, &error)) return CMS_TRUST_TRUSTED;
    CFIndex code = error ? CFErrorGetCode(error) : 0;
    if (error) CFRelease(error);
    if (code == errSecCertificateExpired || code == errSecCertificateNotValidYet) return CMS_TRUST_EXPIRED;
    if (code == errSecCertificateRevoked) return CMS_TRUST_REVOKED;
    int result = CMS_TRUST_UNTRUSTED;
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    if (chain) {
        CFIndex n = CFArrayGetCount(chain);
        if (n > 0 && self_issued((SecCertificateRef)CFArrayGetValueAtIndex(chain, n - 1)))
            result = n == 1 ? CMS_TRUST_SELF_SIGNED : CMS_TRUST_UNTRUSTED;
        CFRelease(chain);
    }
    return result;
}

void cms_verify(const unsigned char *signature, size_t signature_len,
                const unsigned char *data, size_t data_len, bool network, cms_result *r) {
    memset(r, 0, sizeof *r);
    r->integrity = CMS_INTEGRITY_MALFORMED;
    r->trust = CMS_TRUST_UNKNOWN;
    CMSDecoderRef decoder = NULL;
    CFDataRef content = NULL;
    SecPolicyRef policy = NULL;
    SecTrustRef trust = NULL;
    SecCertificateRef cert = NULL;
    if (!is_detached_signature(signature, signature_len)) goto done;
    if (CMSDecoderCreate(&decoder) != errSecSuccess) goto done;
    if (CMSDecoderUpdateMessage(decoder, signature, signature_len) != errSecSuccess) goto done;
    content = CFDataCreateWithBytesNoCopy(NULL, data, (CFIndex)data_len, kCFAllocatorNull);
    if (!content || CMSDecoderSetDetachedContent(decoder, content) != errSecSuccess) goto done;
    if (CMSDecoderFinalizeMessage(decoder) != errSecSuccess) goto done;
    size_t signers = 0;
    if (CMSDecoderGetNumSigners(decoder, &signers) != errSecSuccess || signers != 1) goto done;

    policy = SecPolicyCreateBasicX509();
    CMSSignerStatus status = kCMSSignerUnsigned;
    OSStatus certificate = 0;
    // Trust is evaluated below, with the network as Settings allows.
    if (CMSDecoderCopySignerStatus(decoder, 0, policy, false, &status, &trust, &certificate) != errSecSuccess) goto done;
    if (status == kCMSSignerInvalidSignature) r->integrity = CMS_INTEGRITY_INVALID;
    else if (status == kCMSSignerValid || status == kCMSSignerInvalidCert) r->integrity = CMS_INTEGRITY_VALID;
    else goto done;

    if (CMSDecoderCopySignerCert(decoder, 0, &cert) == errSecSuccess && cert)
        certificate_names(cert, r->signer, sizeof r->signer, r->email, sizeof r->email);
    CFAbsoluteTime when = 0;
    if (CMSDecoderCopySignerSigningTime(decoder, 0, &when) == errSecSuccess)
        r->signing_time = when + kCFAbsoluteTimeIntervalSince1970;
    if (cert && !usable_for_signing(cert)) r->trust = CMS_TRUST_NOT_FOR_SIGNING;
    else if (trust) r->trust = evaluate_trust(trust, network);
done:
    if (cert) CFRelease(cert);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (content) CFRelease(content);
    if (decoder) CFRelease(decoder);
}
