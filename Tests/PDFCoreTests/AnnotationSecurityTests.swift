import CoreGraphics
import Foundation
import PDFCore
import Testing

/// Regression tests for the 0.2.0 security review.
@Suite struct AnnotationSecurityTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    private func note(_ doc: EngineDocument, page: Int = 0, y: CGFloat) throws -> Int {
        var change = AnnotationChange(kind: .square)
        change.rect = CGRect(x: 100, y: y, width: 60, height: 40)
        change.color = .some(.red)
        return try doc.createAnnotation(page: page, change, actionName: "Rectangle")
    }

    /// A damaged file is repaired before editing, so a later look at the
    /// damaged page can't throw away changes.
    @Test func damagedFileKeepsEdits() throws {
        let doc = try Corpus.open("lazy.pdf")
        #expect(try doc.prepareForEditing(password: nil) == true)
        _ = try note(doc, y: 200)
        _ = try note(doc, y: 300)
        let pages = try doc.pageCount()
        for page in 0..<pages { _ = try? doc.displayList(page: page); _ = try? doc.text(page: page) }
        #expect(try doc.annotations(page: 0).count == 2)
        let out = temporaryURL("lazy.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(try EngineDocument(url: out).annotations(page: 0).count == 2)
        try doc.undo()
        #expect(try doc.annotations(page: 0).count == 1)
    }

    /// Saving doesn't add steps to the undo journal, for xref-stream files too.
    @Test func savingLeavesUndoAlone() throws {
        let doc = try Corpus.open("xrefstream.pdf")
        try doc.prepareForEditing(password: nil)
        let urls = (1...3).map { temporaryURL("x\($0).pdf") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try note(doc, y: 200)                      // A
        try doc.save(to: urls[0])
        _ = try note(doc, y: 300)                      // B
        try doc.save(to: urls[1])
        try doc.undo()                                 // undoes B, not the save
        #expect(try doc.annotations(page: 0).count == 1)
        try doc.save(to: urls[2])
        #expect(doc.canRedo)                           // saving kept the redo
        try doc.redo()
        #expect(try doc.annotations(page: 0).count == 2)
        #expect(try EngineDocument(url: urls[1]).annotations(page: 0).count == 2)
        #expect(try EngineDocument(url: urls[2]).annotations(page: 0).count == 1)
    }

    /// Geometry shared many times over is cut short, quickly, and read-only.
    @Test func sharedGeometryIsCapped() throws {
        let doc = try Corpus.open("inkbomb.pdf")
        let start = Date()
        let annots = try doc.annotations(page: 0)
        #expect(Date().timeIntervalSince(start) < 2)
        let ink = try #require(annots.first)
        #expect(ink.isReadOnly)
        #expect(ink.ink.reduce(0) { $0 + $1.count } <= 100_000)
        #expect(throws: EngineError.self) {
            try doc.transformAnnotation(page: 0, id: ink.id, by: CGAffineTransform(translationX: 1, y: 1), actionName: "Move")
        }
    }

    /// A direct annotation (no object number) is read-only; one listed twice
    /// appears once.
    @Test func duplicatesAndDirectAnnotations() throws {
        let doc = try Corpus.open("dupes.pdf")
        let annots = try doc.annotations(page: 0)
        #expect(annots.count == 2)
        let direct = try #require(annots.first { $0.id == 0 })
        #expect(direct.isReadOnly)
        #expect(throws: EngineError.self) { try doc.deleteAnnotation(page: 0, id: 0, actionName: "Delete") }
        #expect(try doc.annotations(page: 0).count == 2)
    }

    /// Deleting the root of a long reply chain takes the chain with it, fast.
    @Test func longReplyChainDeletesQuickly() throws {
        let doc = try Corpus.open("chain.pdf")
        let annots = try doc.annotations(page: 0)
        let root = try #require(annots.first { $0.inReplyTo == nil })
        let start = Date()
        try doc.deleteAnnotation(page: 0, id: root.id, actionName: "Delete")
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(try doc.annotations(page: 0).isEmpty)
    }

    /// A file changed on disk while open is not saved over.
    @Test func fileChangedOnDiskIsNotSaved() throws {
        let copy = temporaryURL("changing.pdf")
        let out = temporaryURL("out.pdf")
        defer { [copy, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.copyItem(at: Corpus.root.appendingPathComponent("text.pdf"), to: copy)
        let doc = try EngineDocument(url: copy)
        try doc.prepareForEditing(password: nil)
        _ = try note(doc, y: 200)
        // Another app appends to the same file (same inode).
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n% changed elsewhere\n".utf8))
        try handle.close()
        #expect(throws: EngineError.self) { try doc.save(to: out) }
    }
}
