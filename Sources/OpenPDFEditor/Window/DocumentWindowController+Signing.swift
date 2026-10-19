import AppKit
import PDFCore

/// Signing a signature field with a certificate from the Keychain, and the
/// saved handwritten signatures.
extension DocumentWindowController {
    @objc func manageSignatures(_ sender: Any?) {
        guard let window else { return }
        SignatureManager.present(on: window)
    }

    /// A signature field was clicked: offer to sign it, or show its signature.
    func signField(_ field: FormField) {
        guard let viewer, let window, let document = editorDocument else { return }
        if inspectorItem?.isCollapsed == true { inspectorItem?.animator().isCollapsed = false }
        if inspector?.signatures.signatures.first(where: { $0.id == field.id && $0.page == field.page })?.isSigned == true { return }
        guard viewer.model.isEditable, viewer.model.allows(.fillForms) else { return NSSound.beep() }
        let identities = SigningIdentity.all()
        guard !identities.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There’s no certificate to sign with."
            alert.informativeText = "Signing digitally needs a certificate with its private key in your keychain, such as a .p12 file from your organisation or a certificate authority, added with Keychain Access."
            alert.beginSheetModal(for: window)
            return
        }
        let popup = NSPopUpButton()
        for identity in identities {
            var title = identity.name
            if !identity.email.isEmpty { title += " <\(identity.email)>" }
            if let expires = identity.expires { title += " — until " + expires.formatted(date: .abbreviated, time: .omitted) }
            popup.addItem(withTitle: title)
        }
        let pictures = SavedSignatures.all
        let picture = NSPopUpButton()
        picture.addItem(withTitle: "None")
        for saved in pictures { picture.addItem(withTitle: saved.name) }
        let reason = NSTextField(), location = NSTextField()
        reason.placeholderString = "Reason (optional)"
        location.placeholderString = "Location (optional)"
        for control in [popup, picture, reason, location] as [NSView] { control.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Certificate:"), popup],
            [NSTextField(labelWithString: "Picture:"), picture],
            [NSTextField(labelWithString: "Reason:"), reason],
            [NSTextField(labelWithString: "Location:"), location],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let alert = NSAlert()
        alert.messageText = "Sign “\(field.name)”?"
        alert.informativeText = "The document, with your changes, is signed and saved. Changes saved afterwards show as made after signing. This can’t be undone. The Keychain may ask to let this app use the certificate’s key."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Sign")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = popup
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let identity = identities[max(popup.indexOfSelectedItem, 0)].identity
            let image = picture.indexOfSelectedItem > 0 ? pictures[picture.indexOfSelectedItem - 1].image : nil
            do {
                try document.sign(field, identity: identity, reason: reason.stringValue, location: location.stringValue, picture: image)
                self.updateRestrictionBanner()
            } catch {
                let failed = NSAlert()
                failed.messageText = "The document couldn’t be signed."
                failed.informativeText = "\(error)"
                failed.beginSheetModal(for: window)
                return
            }
            self.saveRewritten(document)
        }
    }
}
