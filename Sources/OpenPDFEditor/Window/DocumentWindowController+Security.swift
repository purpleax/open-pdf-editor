import AppKit
import PDFCore

/// File › Security…: passwords and permissions; and the notice shown when
/// the document's owner has limited what can be done with it.
extension DocumentWindowController {
    // MARK: Restrictions notice

    func setUpRestrictionBanner() {
        if restrictionAccessory != nil { return updateRestrictionBanner() }
        guard let window else { return }
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: "Enter Owner Password…", target: self, action: #selector(enterOwnerPassword(_:)))
        button.controlSize = .small
        let stack = NSStackView(views: [NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil) ?? NSImage()), label, button])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.heightAnchor.constraint(equalToConstant: 28),
        ])
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = root
        window.addTitlebarAccessoryViewController(accessory)
        restrictionAccessory = accessory
        restrictionLabel = label
        updateRestrictionBanner()
    }

    /// Shows what the owner doesn't allow, or hides the notice (and brings
    /// the inspector up to date with the document's security).
    func updateRestrictionBanner() {
        guard let viewer, let accessory = restrictionAccessory else { return }
        inspector?.refresh()
        let allowed = viewer.model.allowed
        let missing: [(Allowed, String)] = [(.print, "printing"), (.copy, "copying"), (.edit, "editing"),
                                            (.annotate, "comments"), (.fillForms, "filling in forms"), (.assemble, "changing pages")]
        let denied = missing.filter { !allowed.contains($0.0) }.map(\.1)
        accessory.isHidden = denied.isEmpty
        let text = "The document’s owner doesn’t allow " + ListFormatter.localizedString(byJoining: denied) + "."
        restrictionLabel?.stringValue = text
        accessory.view.setAccessibilityLabel(text)
    }

    /// Asks for the owner password; full access if it's right.
    @objc func enterOwnerPassword(_ sender: Any?) {
        askForOwnerPassword { _ in }
    }

    private func askForOwnerPassword(then: @escaping (Bool) -> Void) {
        guard let viewer, let window else { return }
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let alert = NSAlert()
        alert.messageText = "Enter the owner password"
        alert.informativeText = "With the owner password, everything can be done with this document, including changing its security."
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return then(false) }
            let engine = viewer.model.engine
            if engine.authenticate(password: field.stringValue), engine.isOwner {
                self.editorDocument?.password = field.stringValue
                viewer.model.refreshPermissions()
                self.updateRestrictionBanner()
                then(true)
            } else {
                // A wrong (or the user) password leaves access as it was.
                if let current = self.editorDocument?.password { _ = engine.authenticate(password: current) }
                let wrong = NSAlert()
                wrong.messageText = "That isn’t the owner password."
                wrong.beginSheetModal(for: window) { _ in then(false) }
            }
        }
    }

    // MARK: Security sheet

    @objc func showSecurity(_ sender: Any?) {
        guard let viewer else { return }
        if !viewer.model.engine.isOwner {
            askForOwnerPassword { [weak self] ok in if ok { self?.presentSecuritySheet() } }
        } else {
            presentSecuritySheet()
        }
    }

    private func presentSecuritySheet() {
        guard let viewer, let window, let document = editorDocument else { return }
        let engine = viewer.model.engine
        let requireOpen = NSButton(checkboxWithTitle: "Require a password to open the document", target: nil, action: nil)
        let openPassword = NSSecureTextField(), openAgain = NSSecureTextField()
        let restrict = NSButton(checkboxWithTitle: "Require a password to change security and to:", target: nil, action: nil)
        let ownerPassword = NSSecureTextField(), ownerAgain = NSSecureTextField()
        let printing = NSButton(checkboxWithTitle: "Print", target: nil, action: nil)
        let copying = NSButton(checkboxWithTitle: "Copy text and images", target: nil, action: nil)
        let editing = NSButton(checkboxWithTitle: "Edit content and pages", target: nil, action: nil)
        let commenting = NSButton(checkboxWithTitle: "Add comments", target: nil, action: nil)
        let forms = NSButton(checkboxWithTitle: "Fill in forms", target: nil, action: nil)
        let allowLabel = NSTextField(labelWithString: "Without that password, people may:")
        for field in [openPassword, openAgain, ownerPassword, ownerAgain] { field.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        openPassword.placeholderString = "Password"
        openAgain.placeholderString = "Again"
        ownerPassword.placeholderString = "Owner password"
        ownerAgain.placeholderString = "Again"
        let encrypted = engine.isEncrypted
        requireOpen.state = encrypted && engine.needsPasswordToOpen ? .on : .off
        restrict.state = encrypted && engine.ownerAllowedToUser != .all ? .on : .off
        let granted = engine.ownerAllowedToUser
        printing.state = granted.contains(.print) ? .on : .off
        copying.state = granted.contains(.copy) ? .on : .off
        editing.state = granted.contains(.modify) ? .on : .off
        commenting.state = granted.contains(.annotate) ? .on : .off
        forms.state = granted.contains(.fillForms) ? .on : .off
        let grid = NSGridView(views: [
            [requireOpen], [NSStackView(views: [openPassword, openAgain])],
            [restrict], [NSStackView(views: [ownerPassword, ownerAgain])],
            [allowLabel], [NSStackView(views: [printing, copying, editing])], [NSStackView(views: [commenting, forms])],
        ])
        grid.rowSpacing = 8
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let signed = (try? engine.formInfo().isSigned) ?? false
        let alert = NSAlert()
        alert.messageText = "Security"
        alert.informativeText = "Passwords use 256-bit AES encryption. Changing security writes the document again and can’t be undone."
            + (signed ? "\n\nThis document is signed: its signatures will no longer be valid." : "")
        alert.accessoryView = grid
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let wantsOpen = requireOpen.state == .on, wantsRestrict = restrict.state == .on
            @MainActor func problem(_ message: String) {
                let alert = NSAlert()
                alert.messageText = message
                alert.beginSheetModal(for: window)
            }
            if wantsOpen && (openPassword.stringValue.isEmpty || openPassword.stringValue != openAgain.stringValue) {
                return problem("The two passwords to open the document don’t match, or are empty.")
            }
            if wantsRestrict && (ownerPassword.stringValue.isEmpty || ownerPassword.stringValue != ownerAgain.stringValue) {
                return problem("The two owner passwords don’t match, or are empty.")
            }
            if wantsOpen && wantsRestrict && openPassword.stringValue == ownerPassword.stringValue {
                return problem("The owner password must differ from the password to open the document.")
            }
            let encryption: Encryption
            let unlock: String?
            if !wantsOpen && !wantsRestrict {
                encryption = .none
                unlock = nil
            } else {
                var permissions: Permissions = [.accessibility]
                if !wantsRestrict { permissions = .all }
                if printing.state == .on { permissions.formUnion([.print, .printHighQuality]) }
                if copying.state == .on { permissions.insert(.copy) }
                if editing.state == .on { permissions.formUnion([.modify, .assemble]) }
                if commenting.state == .on { permissions.insert(.annotate) }
                if forms.state == .on { permissions.insert(.fillForms) }
                let owner = wantsRestrict ? ownerPassword.stringValue : openPassword.stringValue
                encryption = .aes256(user: wantsOpen ? openPassword.stringValue : "", owner: owner, permissions: permissions)
                unlock = owner
            }
            do {
                try document.changeSecurity(encryption, unlock: unlock)
                self.updateRestrictionBanner()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    // MARK: Redaction

    /// Redaction marks in the whole document.
    func redactionMarkCount() -> Int {
        guard let viewer else { return 0 }
        let engine = viewer.model.engine
        return (0..<viewer.model.pageCount).reduce(0) { count, page in
            count + ((try? engine.annotations(page: page))?.filter { $0.kind == .redact }.count ?? 0)
        }
    }

    /// Tools › Apply Redactions…: removes what is under every mark, for good,
    /// then saves, and (if asked) deletes the file's earlier versions.
    @objc func applyRedactions(_ sender: Any?) {
        guard let viewer, let window, let document = editorDocument else { return }
        let marks = redactionMarkCount()
        guard marks > 0 else {
            let alert = NSAlert()
            alert.messageText = "There’s nothing marked for redaction."
            alert.informativeText = "Mark text or areas with Tools › Redact first."
            alert.beginSheetModal(for: window)
            return
        }
        let signed = (try? viewer.model.engine.formInfo().isSigned) ?? false
        let alert = NSAlert()
        alert.messageText = marks == 1 ? "Apply 1 redaction?" : "Apply \(marks) redactions?"
        alert.informativeText = "Everything under the marks is removed for good: text, images, drawings, comments, links and form fields. Black boxes are drawn in its place, hidden leftovers such as thumbnails and document scripts are removed, and the document is saved. This can’t be undone."
            + (signed ? "\n\nThis document is signed: its signatures will no longer be valid." : "")
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Apply Redactions")
        alert.addButton(withTitle: "Cancel")
        let versions = document.fileURL != nil
        if versions {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Also delete earlier versions of this file"
            alert.suppressionButton?.state = .on
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let deleteVersions = versions && alert.suppressionButton?.state == .on
            do {
                try document.applyRedactions()
                viewer.pagesView.selectedAnnotation = nil
                self.updateRestrictionBanner()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }
            self.saveAfterRedacting(document, deleteVersions: deleteVersions)
        }
    }

    /// Saves the redacted document (asking where, if it has never been
    /// saved), then deletes the file's other versions if asked.
    private func saveAfterRedacting(_ document: EditorDocument, deleteVersions: Bool) {
        guard let url = document.fileURL, let type = document.fileType else {
            document.save(nil)
            return
        }
        document.save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
            guard let window = self?.window else { return }
            if let error {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }
            guard deleteVersions else { return }
            do {
                try NSFileVersion.removeOtherVersionsOfItem(at: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The redacted document is saved, but its earlier versions couldn’t be deleted."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }
}
