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
        didSet { isUnlocked = model != nil }
    }
    /// `model != nil`, readable from write(to:ofType:).
    nonisolated(unsafe) private var isUnlocked = false

    override nonisolated class var readableTypes: [String] { ["com.adobe.pdf"] }
    override nonisolated class var writableTypes: [String] { ["com.adobe.pdf"] }
    override nonisolated class var autosavesInPlace: Bool { true }
    override nonisolated class var preservesVersions: Bool { true }
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
    }

    /// The model, made once the document is unlocked.
    func makeModel() throws -> DocumentModel {
        if let model { return model }
        guard let engine else { throw CocoaError(.fileReadUnknown) }
        let model = try DocumentModel(engine: engine)
        model.editRecorder = self
        self.model = model
        return model
    }

    // MARK: Undo

    func didEdit(actionName: String, pages: Set<Int>) {
        registerUndo(actionName: actionName, pages: pages, redo: false)
    }

    /// Each step undone or redone registers its opposite, as NSUndoManager expects.
    private func registerUndo(actionName: String, pages: Set<Int>, redo: Bool) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.step(redo: redo, actionName: actionName, pages: pages)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func step(redo: Bool, actionName: String, pages: Set<Int>) {
        guard let engine, let model else { return }
        do {
            if redo { try engine.redo() } else { try engine.undo() }
        } catch {
            NSSound.beep()
            return
        }
        model.pagesChanged(pages)
        registerUndo(actionName: actionName, pages: pages, redo: !redo)
    }

    // MARK: Saving

    override func write(to url: URL, ofType typeName: String) throws {
        // Locked and never unlocked: nothing can have changed; copy the file.
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
        if model != nil, let engine, hasUnautosavedChanges || isDocumentEdited {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString).pdf")
            try engine.save(to: copy)
            url = copy
        }
        guard let url, let pdf = PDFDocument(url: url) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                NSLocalizedDescriptionKey: "The document couldn’t be prepared for printing.",
            ])
        }
        if url != fileURL { try? FileManager.default.removeItem(at: url) }   // PDFKit has read it
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
