import Foundation
import MuPDFBridge

/// How a rewritten document is encrypted.
public enum Encryption: Sendable, Equatable {
    /// As it is now.
    case keep
    /// No password.
    case none
    /// AES-256: `user` opens it ("" for none); `owner` gives full access.
    case aes256(user: String, owner: String, permissions: Permissions)
}

/// What someone with only the user password may do (PDF 32000 table 22).
public struct Permissions: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let print = Permissions(rawValue: 1 << 2)
    public static let modify = Permissions(rawValue: 1 << 3)
    public static let copy = Permissions(rawValue: 1 << 4)
    public static let annotate = Permissions(rawValue: 1 << 5)
    public static let fillForms = Permissions(rawValue: 1 << 8)
    public static let accessibility = Permissions(rawValue: 1 << 9)
    public static let assemble = Permissions(rawValue: 1 << 10)
    public static let printHighQuality = Permissions(rawValue: 1 << 11)
    public static let all: Permissions = [.print, .modify, .copy, .annotate, .fillForms, .accessibility, .assemble, .printHighQuality]
}

extension EngineDocument {
    /// Writes the document whole and goes on from the new bytes: earlier
    /// revisions and unused objects are dropped, encryption is set, and with
    /// `scrub` thumbnails, PieceInfo and document JavaScript go and XMP is
    /// rebuilt. Undo history is cleared.
    public func rebase(encryption: Encryption = .keep, openPassword: String? = nil, scrub: Bool = false,
                       redact: Bool = false, now: Date = Date()) throws {
        var error = opdf_error()
        var user = "", owner = ""
        var options = opdf_rebase_options()
        options.scrub = scrub
        options.redact = redact
        options.now = Int64(now.timeIntervalSince1970)
        switch encryption {
        case .keep: options.encryption = Int32(OPDF_ENCRYPT_KEEP)
        case .none: options.encryption = Int32(OPDF_ENCRYPT_NONE)
        case let .aes256(u, o, permissions):
            options.encryption = Int32(OPDF_ENCRYPT_AES256)
            options.permissions = permissions.rawValue
            user = u
            owner = o
        }
        let ok = withOptionalCString(openPassword) { open in
            user.withCString { u in
                owner.withCString { o in
                    options.open_password = open
                    options.user_password = u
                    options.owner_password = o
                    return opdf_rebase(handle, &options, &error)
                }
            }
        }
        guard ok else { throw EngineError(error) }
    }
}

extension EngineDocument {
    /// Applies every redaction mark: removes what is under them (text, image
    /// pixels, line art, links, annotations, form fields and their values),
    /// draws black boxes, and writes the document whole, scrubbed of hidden
    /// leftovers, as `rebase` does. Undo history goes.
    public func applyRedactions(openPassword: String? = nil, now: Date = Date()) throws {
        try rebase(openPassword: openPassword, scrub: true, redact: true, now: now)
    }
}

/// What may be done with an open document.
public struct Allowed: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let print = Allowed(rawValue: 1 << 0)
    public static let copy = Allowed(rawValue: 1 << 1)
    public static let edit = Allowed(rawValue: 1 << 2)
    public static let annotate = Allowed(rawValue: 1 << 3)
    public static let fillForms = Allowed(rawValue: 1 << 4)
    public static let assemble = Allowed(rawValue: 1 << 5)
    public static let everything: Allowed = [.print, .copy, .edit, .annotate, .fillForms, .assemble]
}

extension EngineDocument {
    /// Unlocked with the owner password, or not encrypted.
    public var isOwner: Bool { opdf_is_owner(handle) }

    /// Everything for the owner; otherwise what the document's permissions grant.
    public var allowed: Allowed { Allowed(rawValue: opdf_allowed(handle)) }

    /// Whether opening the document takes a password.
    public var needsPasswordToOpen: Bool { opdf_needs_open_password(handle) }

    /// What the document grants to people without the owner password.
    public var ownerAllowedToUser: Permissions {
        Permissions(rawValue: opdf_permission_bits(handle)).intersection(.all)
    }

    /// Whether the document is encrypted.
    public var isEncrypted: Bool { metadata("encryption").map { $0 != "None" } ?? false }
}
