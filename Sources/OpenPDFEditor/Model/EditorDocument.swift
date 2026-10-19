import AppKit
import PDFCore
import PDFKit

/// One open PDF.
///
/// Edits go through `model.edit`, which records each one with the undo
/// manager; undo and redo step MuPDF's journal. Saving writes the original
/// file plus the changes (see EngineDocument.save) and autosaves in place,
/// with Versions.
@objc(EditorDocument)
final class EditorDocument: NSDocument, EditRecorder {
    // Set in read(from:ofType:), which NSDocument calls before any window
    // exists (and again on revert); EngineDocument itself is thread-safe.
    nonisolated(unsafe) private(set) var engine: EngineDocument?
    /// The password that unlocked the document, for printing and reverting.
    var password: String?
    /// The document once unlocked; nil while a password is needed.
    private(set) var model: DocumentModel? {
        didSet { isUnlocked = model?.isEditable ?? false }
    }
    /// Unlocked and editable, readable from write(to:ofType:).
    nonisolated(unsafe) private var isUnlocked = false

    override nonisolated class var readableTypes: [String] { ["com.adobe.pdf"] }
    override nonisolated class var writableTypes: [String] { ["com.adobe.pdf"] }
    // Settings › Save changes automatically (off by default).
    override nonisolated class var autosavesInPlace: Bool { Settings.savesAutomatically }
    override nonisolated class var preservesVersions: Bool { Settings.savesAutomatically }
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        do {
            engine = try EngineDocument(url: url)
        } catch {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                NSLocalizedDescriptionKey: "The document “\(url.lastPathComponent)” could not be opened.",
                NSLocalizedFailureReasonErrorKey: "It may be damaged or not a PDF. (\(error))",
            ])
        }
    }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
        WelcomeWindowController.dismiss()
    }

    /// The model, made once the document is unlocked.
    func makeModel() throws -> DocumentModel {
        if let model { return model }
        guard let engine else { throw CocoaError(.fileReadUnknown) }
        // Before any change: a damaged file is repaired (and copied) now. If
        // even that fails, the document opens for viewing only.
        var editable = engine.isPDF
        if editable {
            do {
                try engine.prepareForEditing(password: password)
            } catch {
                editable = false
            }
        }
        let model = try DocumentModel(engine: engine, isEditable: editable)
        model.editRecorder = self
        self.model = model
        return model
    }

    // MARK: Undo

    // The change count is kept here as well as from the undo manager: with
    // autosave off, closing must know of every change. (Each edit, undo and
    // redo counts the same either way, so the edited state stays right.)
    func didEdit(actionName: String, change: ModelChange) {
        registerUndo(actionName: actionName, change: change, redo: false)
        updateChangeCount(.changeDone)
    }

    /// Each step undone or redone registers its opposite, as NSUndoManager expects.
    private func registerUndo(actionName: String, change: ModelChange, redo: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.step(redo: redo, actionName: actionName, change: change)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func step(redo: Bool, actionName: String, change: ModelChange) {
        guard let engine, let model else { return }
        do {
            if redo { try engine.redo() } else { try engine.undo() }
        } catch {
            NSSound.beep()
            return
        }
        model.changed(change)
        registerUndo(actionName: actionName, change: change, redo: !redo)
        updateChangeCount(redo ? .changeRedone : .changeUndone)
    }

    // MARK: Saving

    override func write(to url: URL, ofType typeName: String) throws {
        // Locked, or view-only: nothing can have changed; copy the file.
        guard isUnlocked, let engine else {
            guard let source = fileURL else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.copyItem(at: source, to: url)
            return
        }
        do {
            try engine.save(to: url)
        } catch {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The document couldn’t be saved.",
                NSLocalizedFailureReasonErrorKey: "\(error)",
            ])
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        model = nil
        undoManager?.removeAllActions()
        if let password, let engine, engine.needsPassword { _ = engine.authenticate(password: password) }
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.documentDidRevert()
        }
    }

    // MARK: Printing

    /// Printing goes through PDFKit for the standard print panel, page
    /// ranges and scaling, from a copy that includes unsaved changes.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        var url = fileURL
        var copy: URL?
        // Removed on every way out; PDFKit has read it by then.
        defer { if let copy { try? FileManager.default.removeItem(at: copy) } }
        if model != nil, let engine, hasUnautosavedChanges || isDocumentEdited {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString).pdf")
            copy = temporary
            try engine.save(to: temporary)
            url = temporary
        }
        guard let url, let pdf = PDFDocument(url: url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The document couldn’t be prepared for printing.",
            ])
        }
        if pdf.isLocked, let password { pdf.unlock(withPassword: password) }
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        guard let operation = pdf.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "This document can’t be printed.",
            ])
        }
        operation.jobTitle = displayName
        operation.printPanel.options.insert([.showsPageSetupAccessory, .showsPreview])
        return operation
    }
}
