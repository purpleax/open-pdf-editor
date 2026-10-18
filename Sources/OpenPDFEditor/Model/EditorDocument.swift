import AppKit
import PDFCore
import PDFKit

/// One open PDF.
@objc(EditorDocument)
final class EditorDocument: NSDocument {
    // Set once in read(from:ofType:), which NSDocument calls before any
    // window exists; EngineDocument itself is thread-safe.
    nonisolated(unsafe) private(set) var engine: EngineDocument?
    /// The password that unlocked the document, for printing.
    var password: String?

    override nonisolated class var readableTypes: [String] { ["com.adobe.pdf"] }
    override nonisolated class var autosavesInPlace: Bool { false }
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

    /// Printing goes through PDFKit for the standard print panel, page
    /// ranges and scaling. Nothing is edited yet, so the file on disk is
    /// what is shown.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let url = fileURL, let pdf = PDFDocument(url: url) else {
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
