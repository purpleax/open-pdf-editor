import Foundation
import MuPDFBridge
import Security

/// A signature field and, once signed, what checking its signature found.
public struct Signature: Equatable, Sendable {
    public enum Integrity: Int, Sendable {
        /// The signed part of the file is exactly as it was signed.
        case valid = 0
        /// Changed since it was signed, or the signature doesn't match it.
        case invalid
        /// Not a signature this app can check.
        case malformed
        /// Too large (or too many) to check.
        case unchecked
    }

    public enum Trust: Int, Sendable {
        case trusted = 0, selfSigned, untrusted, expired, revoked, unknown
        /// A certificate for something else (a website, code, ...).
        case notForSigning
    }

    public let page: Int
    /// The widget's object number.
    public let id: Int
    public let name: String
    public let isSigned: Bool
    public let integrity: Integrity
    public let trust: Trust
    /// Later revisions were saved after this one was signed.
    public let changedAfter: Bool
    public let signer: String
    public let email: String
    /// By the signer's clock.
    public let signingTime: Date?
    public let reason: String
    public let location: String

    init(_ s: opdf_signature) {
        page = Int(s.page)
        id = Int(s.id)
        name = s.name.map { String(cString: $0) } ?? ""
        isSigned = s.is_signed
        integrity = Integrity(rawValue: Int(s.integrity)) ?? .malformed
        trust = Trust(rawValue: Int(s.trust)) ?? .unknown
        changedAfter = s.changed_after
        signer = s.signer.map { String(cString: $0) } ?? ""
        email = s.email.map { String(cString: $0) } ?? ""
        signingTime = s.signing_time > 0 ? Date(timeIntervalSince1970: s.signing_time) : nil
        reason = s.reason.map { String(cString: $0) } ?? ""
        location = s.location.map { String(cString: $0) } ?? ""
    }
}

extension EngineDocument {
    /// Every signature field, with each signature checked against the bytes
    /// the document was opened from. Certificates are checked online
    /// (missing intermediates, revocation) only when `online` is true.
    public func signatures(online: Bool = false) throws -> [Signature] {
        var count: Int32 = 0
        var error = opdf_error()
        let items = opdf_signatures(handle, online, &count, &error)
        if items == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_signatures_free(items, count) }
        return UnsafeBufferPointer(start: items, count: Int(count)).map(Signature.init)
    }

    /// Signs an empty signature field with a Keychain identity and goes on
    /// from the signed bytes (undo history is cleared); save the document
    /// afterwards to keep it. The Keychain may ask to allow the key's use.
    /// `picture` (PNG or JPEG) is drawn in the signature's appearance.
    public func sign(page: Int, field id: Int, identity: SecIdentity, reason: String = "", location: String = "",
                     picture: Data? = nil, openPassword: String? = nil) throws {
        var error = opdf_error()
        let ok = withOptionalCString(openPassword) { password in
            (picture ?? Data()).withUnsafeBytes { bytes in
                opdf_sign_field(handle, Int32(page), Int32(id), Unmanaged.passUnretained(identity).toOpaque(),
                                reason, location, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, password, &error)
            }
        }
        guard ok else { throw EngineError(error) }
    }
}

extension EngineDocument {
    /// A stamp annotation showing a picture (PNG or JPEG), filling `rect`;
    /// returns its id.
    public func createImageStamp(page: Int, rect: CGRect, image: Data, author: String?, actionName: String) throws -> Int {
        var error = opdf_error()
        let r = opdf_rect(x0: Float(rect.minX), y0: Float(rect.minY), x1: Float(rect.maxX), y1: Float(rect.maxY))
        let id = image.withUnsafeBytes { bytes in
            withOptionalCString(author) { author in
                opdf_annot_create_image_stamp(handle, Int32(page), r, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                              author, actionName, &error)
            }
        }
        guard id > 0 else { throw EngineError(error) }
        return Int(id)
    }
}

/// A Keychain identity (certificate and private key) that can sign.
public struct SigningIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let name: String
    public let email: String
    public let expires: Date?

    /// The identities in the user's keychains whose certificates are valid
    /// today, by name.
    public static func all() -> [SigningIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return [] }
        return identities.compactMap(SigningIdentity.init).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public init?(_ identity: SecIdentity) {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        self.identity = identity
        var cn: CFString?
        SecCertificateCopyCommonName(certificate, &cn)
        name = (cn as String?) ?? (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unnamed certificate"
        var emails: CFArray?
        SecCertificateCopyEmailAddresses(certificate, &emails)
        email = (emails as? [String])?.first ?? ""
        expires = Self.notAfter(certificate)
        if let expires, expires < Date() { return nil }
    }

    private static func notAfter(_ certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}
