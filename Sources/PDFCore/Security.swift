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
                       now: Date = Date()) throws {
        var error = opdf_error()
        var user = "", owner = ""
        var options = opdf_rebase_options()
        options.scrub = scrub
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
