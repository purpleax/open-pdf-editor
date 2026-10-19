import AppKit
import PDFCore

/// The inspector's section for digital signatures: each signature field,
/// and what checking its signature found, in plain words. Signatures are
/// checked against the file's bytes, so only when those change (`recheck`).
@MainActor
final class SignaturesViewController: NSViewController {
    let viewer: ViewerController
    private(set) var signatures: [Signature] = []
    private let stack = NSStackView()

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 8, right: 16)
        view = stack
        reload()
    }

    /// Checks every signature again (after opening, signing or rewriting).
    func recheck() {
        signatures = (try? viewer.model.engine.signatures(online: Settings.checksCertificatesOnline)) ?? []
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        view.isHidden = signatures.isEmpty
        guard !signatures.isEmpty else { return }
        let title = NSTextField(labelWithString: "Signatures")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        stack.addArrangedSubview(title)
        for signature in signatures {
            let (symbol, color) = Self.badge(signature)
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = color
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let text = NSTextField(wrappingLabelWithString: Self.describe(signature))
            text.isSelectable = true
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let row = NSStackView(views: [icon, text])
            row.alignment = .top
            row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        if viewer.model.engine.hasUnsavedChanges, signatures.contains(where: \.isSigned) {
            let note = NSTextField(wrappingLabelWithString: "Changes you save now will show as made after signing.")
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
    }

    static func badge(_ s: Signature) -> (String, NSColor) {
        guard s.isSigned else { return ("signature", .secondaryLabelColor) }
        switch s.integrity {
        case .invalid, .malformed: return ("xmark.seal.fill", .systemRed)
        case .unchecked: return ("questionmark.diamond", .secondaryLabelColor)
        case .valid: return s.trust == .trusted && !s.changedAfter ? ("checkmark.seal.fill", .systemGreen) : ("exclamationmark.triangle.fill", .systemYellow)
        }
    }

    static func describe(_ s: Signature) -> String {
        let field = s.name.isEmpty ? "Signature field" : "“\(s.name)”"
        guard s.isSigned else {
            return "\(field), page \(s.page + 1): not signed. Click the field to sign it."
        }
        var lines: [String] = []
        var who = s.signer.isEmpty ? "Signed" : "Signed by \(s.signer)"
        if !s.email.isEmpty { who += " <\(s.email)>" }
        if let time = s.signingTime {
            who += " on " + time.formatted(date: .abbreviated, time: .shortened) + " (by the signer’s clock)"
        }
        lines.append("\(field), page \(s.page + 1). \(who).")
        if !s.reason.isEmpty { lines.append("Reason: \(s.reason)") }
        if !s.location.isEmpty { lines.append("Location: \(s.location)") }
        switch s.integrity {
        case .valid:
            lines.append(s.changedAfter
                ? "The signed version is intact, but changes were saved after it was signed."
                : "The document hasn’t changed since it was signed.")
        case .invalid:
            lines.append("Not valid: the document was changed in a way the signature doesn’t cover, or the signature is wrong.")
        case .malformed:
            lines.append("This signature can’t be checked: it isn’t one this app understands, or it’s damaged.")
        case .unchecked:
            lines.append("Not checked: the document is too large, or has too many signatures.")
        }
        guard s.integrity == .valid else { return lines.joined(separator: "\n") }
        switch s.trust {
        case .trusted: lines.append("The certificate is trusted by this Mac.")
        case .selfSigned: lines.append("The signer made their own (self-signed) certificate, so who they are isn’t confirmed by anyone else.")
        case .untrusted: lines.append("The certificate isn’t trusted by this Mac, so who signed isn’t confirmed.")
        case .expired: lines.append("The certificate has expired, or isn’t valid yet.")
        case .revoked: lines.append("The certificate has been revoked.")
        case .unknown: lines.append("The certificate couldn’t be checked.")
        case .notForSigning: lines.append("The certificate isn’t one for signing documents (it’s for a website, or another use), so who signed isn’t confirmed.")
        }
        if [.untrusted, .unknown].contains(s.trust), !Settings.checksCertificatesOnline {
            lines.append("Checked offline. Turning on Check certificates online in Settings may fetch the certificates it needs.")
        }
        return lines.joined(separator: "\n")
    }
}
