import AppKit
import PDFCore

/// One open PDF. Phase 0 shows only the first page, to prove the engine
/// works inside the app; the real page view comes in phase 1.
@objc(EditorDocument)
final class EditorDocument: NSDocument {
    // Set once in read(from:ofType:), which NSDocument calls on the main
    // thread (documents aren't read concurrently). Phase 1 moves the engine
    // behind an actor.
    nonisolated(unsafe) private(set) var engine: EngineDocument?

    override nonisolated class var readableTypes: [String] { ["com.adobe.pdf"] }
    override nonisolated class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        do {
            engine = try EngineDocument(url: url)
        } catch {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                NSLocalizedDescriptionKey: "The document “\(url.lastPathComponent)” could not be opened.",
                NSLocalizedFailureReasonErrorKey: "\(error)",
            ])
        }
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
    }
}
