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

size_t cms_der_length(const unsigned char *der, size_t len) {
    if (len < 2 || der[0] != 0x30) return 0;
    return ber_length(der, len, 0);
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
    if (trust) r->trust = evaluate_trust(trust, network);
done:
    if (cert) CFRelease(cert);
    if (trust) CFRelease(trust);
    if (policy) CFRelease(policy);
    if (content) CFRelease(content);
    if (decoder) CFRelease(decoder);
}
