import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite struct AnnotationTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    private func highlight(_ doc: EngineDocument, phrase: String) throws -> Int {
        let text = try doc.text(page: 0)
        let range = try #require(text.search(phrase).first)
        var change = AnnotationChange(kind: .highlight)
        change.quads = text.rects(for: range).map {
            Quad(upperLeft: CGPoint(x: $0.minX, y: $0.minY), upperRight: CGPoint(x: $0.maxX, y: $0.minY),
                 lowerLeft: CGPoint(x: $0.minX, y: $0.maxY), lowerRight: CGPoint(x: $0.maxX, y: $0.maxY))
        }
        change.color = .some(.yellow)
        change.author = "Tester"
        change.contents = "Look at this"
        return try doc.createAnnotation(page: 0, change, actionName: "Highlight")
    }

    @Test func createEveryKind() throws {
        let doc = try Corpus.open("text.pdf")
        let highlightID = try highlight(doc, phrase: "quick brown fox")

        var note = AnnotationChange(kind: .text)
        note.rect = CGRect(x: 400, y: 100, width: 20, height: 20)
        note.contents = "A sticky note"
        note.iconName = "Comment"
        try doc.createAnnotation(page: 0, note, actionName: "Note")

        var box = AnnotationChange(kind: .freeText)
        box.rect = CGRect(x: 72, y: 300, width: 200, height: 40)
        box.contents = "Text box"
        box.font = (size: 14, color: .blue)
        try doc.createAnnotation(page: 0, box, actionName: "Text Box")

        var square = AnnotationChange(kind: .square)
        square.rect = CGRect(x: 72, y: 400, width: 100, height: 60)
        square.color = .some(.red)
        square.borderWidth = 3
        try doc.createAnnotation(page: 0, square, actionName: "Rectangle")

        var arrow = AnnotationChange(kind: .line)
        arrow.line = (CGPoint(x: 300, y: 400), CGPoint(x: 400, y: 460))
        arrow.lineEndings = (.none, .openArrow)
        arrow.color = .some(.blue)
        try doc.createAnnotation(page: 0, arrow, actionName: "Arrow")

        var ink = AnnotationChange(kind: .ink)
        ink.ink = [[CGPoint(x: 100, y: 600), CGPoint(x: 150, y: 620), CGPoint(x: 200, y: 600)]]
        ink.color = .some(.green)
        ink.borderWidth = 2
        try doc.createAnnotation(page: 0, ink, actionName: "Drawing")

        var stamp = AnnotationChange(kind: .stamp)
        stamp.rect = CGRect(x: 350, y: 650, width: 180, height: 50)
        stamp.iconName = "Approved"
        try doc.createAnnotation(page: 0, stamp, actionName: "Stamp")

        let all = try doc.annotations(page: 0)
        #expect(all.map(\.kind) == [.highlight, .text, .freeText, .square, .line, .ink, .stamp])
        let h = try #require(all.first { $0.id == highlightID })
        #expect(h.quads.count == 1 && h.color == .yellow && h.author == "Tester" && h.contents == "Look at this")
        #expect(all[1].iconName == "Comment")
        #expect(all[2].contents == "Text box" && abs(all[2].fontSize - 14) < 0.01)
        #expect(all[3].borderWidth == 3 && all[3].color == .red)
        #expect(all[4].lineEndings.end == .openArrow && all[4].line != nil)
        #expect(all[5].ink.first?.count == 3)
        #expect(all[6].iconName == "Approved")
        #expect(all.allSatisfy { $0.modified != nil })
    }

    @Test func updateMoveAndDelete() throws {
        let doc = try Corpus.open("text.pdf")
        var square = AnnotationChange(kind: .square)
        square.rect = CGRect(x: 100, y: 100, width: 50, height: 50)
        let id = try doc.createAnnotation(page: 0, square, actionName: "Rectangle")

        var change = AnnotationChange(kind: .square)
        change.color = .some(.green)
        change.contents = "Changed"
        change.opacity = 0.5
        try doc.updateAnnotation(page: 0, id: id, change, actionName: "Change")
        var annot = try #require(try doc.annotations(page: 0).first)
        #expect(annot.color == .green && annot.contents == "Changed" && abs(annot.opacity - 0.5) < 0.01)

        try doc.transformAnnotation(page: 0, id: id, by: CGAffineTransform(translationX: 30, y: 40), actionName: "Move")
        annot = try #require(try doc.annotations(page: 0).first)
        #expect(abs(annot.rect.minX - 130) < 1 && abs(annot.rect.minY - 140) < 1)

        try doc.reply(page: 0, to: id, author: "Ann", contents: "Agreed")
        try doc.setStatus(page: 0, of: id, author: "Ann", state: "Accepted")
        let list = try doc.annotations(page: 0)
        #expect(list.count == 3)
        #expect(list.filter { $0.inReplyTo == id }.count == 2)
        #expect(list.first { $0.isStatus }?.state == "Accepted")
        // Changing the status updates the same reply.
        try doc.setStatus(page: 0, of: id, author: "Ann", state: "Rejected")
        #expect(try doc.annotations(page: 0).filter(\.isStatus).map(\.state) == ["Rejected"])

        try doc.deleteAnnotation(page: 0, id: id, actionName: "Delete")
        #expect(try doc.annotations(page: 0).isEmpty)   // replies went with it
    }

    @Test func undoAndRedo() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(!doc.canUndo && !doc.hasUnsavedChanges)
        _ = try highlight(doc, phrase: "lazy dog")
        #expect(doc.canUndo && doc.hasUnsavedChanges)
        try doc.undo()
        #expect(try doc.annotations(page: 0).isEmpty)
        #expect(doc.canRedo)
        try doc.redo()
        #expect(try doc.annotations(page: 0).count == 1)
    }

    @Test func saveKeepsUndo() throws {
        let source = Corpus.root.appendingPathComponent("text.pdf")
        let doc = try EngineDocument(url: source)
        _ = try highlight(doc, phrase: "quick brown fox")
        let first = temporaryURL("first.pdf")
        let second = temporaryURL("second.pdf")
        defer { [first, second].forEach { try? FileManager.default.removeItem(at: $0) } }
        try doc.save(to: first)
        try doc.save(to: second)
        // The open document keeps its undo history after saving.
        #expect(doc.canUndo)
        for url in [first, second] {
            let annots = try EngineDocument(url: url).annotations(page: 0)
            #expect(annots.count == 1 && annots[0].kind == .highlight && annots[0].contents == "Look at this")
        }
        // The original file is untouched.
        #expect(try Data(contentsOf: source) == Data(contentsOf: Corpus.root.appendingPathComponent("text.pdf")))
    }

    /// Signed documents: the original bytes are kept and the changes appended.
    @Test func signedDocumentsSaveIncrementally() throws {
        let source = Corpus.root.appendingPathComponent("signed.pdf")
        let original = try Data(contentsOf: source)
        let doc = try EngineDocument(url: source)
        var note = AnnotationChange(kind: .text)
        note.rect = CGRect(x: 300, y: 300, width: 20, height: 20)
        note.contents = "Comment on a signed file"
        try doc.createAnnotation(page: 0, note, actionName: "Note")
        let out = temporaryURL("signed.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let saved = try Data(contentsOf: out)
        #expect(saved.count > original.count && saved.prefix(original.count) == original)
        #expect(try EngineDocument(url: out).annotations(page: 0).count == 1)
    }

    /// Each save must hold everything on screen, whatever happened between.
    @Test func editSaveEditSaveUndoSave() throws {
        let source = Corpus.root.appendingPathComponent("text.pdf")
        let original = try Data(contentsOf: source)
        let doc = try EngineDocument(url: source)
        let urls = (1...3).map { temporaryURL("chain\($0).pdf") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        func count(_ url: URL) throws -> Int { try EngineDocument(url: url).annotations(page: 0).count }

        _ = try highlight(doc, phrase: "quick brown fox")
        try doc.save(to: urls[0])
        _ = try highlight(doc, phrase: "lazy dog")
        try doc.save(to: urls[1])
        #expect(try count(urls[0]) == 1)
        #expect(try count(urls[1]) == 2)
        // Incremental: the original bytes come first in every save.
        #expect(try Data(contentsOf: urls[1]).prefix(original.count) == original)

        try doc.undo()
        try doc.undo()
        try doc.save(to: urls[2])
        #expect(try count(urls[2]) == 0)
        try doc.redo()
        #expect(try doc.annotations(page: 0).count == 1)
    }

    @Test func savingWithoutChangesKeepsTheContent() throws {
        let source = Corpus.root.appendingPathComponent("text.pdf")
        let doc = try EngineDocument(url: source)
        let out = temporaryURL("same.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let copy = try EngineDocument(url: out)
        #expect(try copy.pageCount() == 3)
        #expect(try copy.text(page: 0).string == doc.text(page: 0).string)
        #expect(try copy.outline().count == 3 && copy.links(page: 0).count == 2)
    }

    @Test func encryptedDocumentsStayEncrypted() throws {
        let doc = try Corpus.open("encrypted.pdf")
        #expect(doc.authenticate(password: "secret"))
        _ = try highlight(doc, phrase: "quick brown fox")
        let out = temporaryURL("encrypted.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        #expect(reopened.needsPassword)
        #expect(reopened.authenticate(password: "secret"))
        #expect(try reopened.annotations(page: 0).count == 1)
    }

    @Test func flattenDrawsAnnotationsIntoThePage() throws {
        let doc = try Corpus.open("text.pdf")
        var square = AnnotationChange(kind: .square)
        square.rect = CGRect(x: 300, y: 500, width: 100, height: 100)
        square.color = .some(.red)
        square.interiorColor = .some(.red)
        square.borderWidth = 2
        let id = try doc.createAnnotation(page: 0, square, actionName: "Rectangle")
        try doc.reply(page: 0, to: id, author: "A", contents: "Reply")
        try doc.flattenAnnotations()
        #expect(try doc.annotations(page: 0).isEmpty)
        let bounds = try doc.pageBounds()[0]
        let pixels = try Pixels(doc.renderPage(0, bounds: bounds, scale: 1))
        let centre = pixels.rgb(350, 550)
        #expect(centre[0] > 200 && centre[1] < 60, "the square is now part of the page: \(centre)")
        // Links survive flattening.
        #expect(try doc.links(page: 0).count == 2)
        try doc.undo()
        #expect(try doc.annotations(page: 0).count == 2)
    }

    @Test func repliesAreNotDrawn() throws {
        let doc = try Corpus.open("text.pdf")
        var square = AnnotationChange(kind: .square)
        square.rect = CGRect(x: 300, y: 500, width: 10, height: 10)
        square.color = .some(.red)
        let id = try doc.createAnnotation(page: 0, square, actionName: "Rectangle")
        let bounds = try doc.pageBounds()[0]
        let before = try Pixels(doc.renderPage(0, bounds: bounds, scale: 1))
        try doc.reply(page: 0, to: id, author: "A", contents: "Reply")
        let after = try Pixels(doc.renderPage(0, bounds: bounds, scale: 1))
        // The reply note would sit at the square's corner; nothing new appears.
        for y in 495..<530 {
            for x in 295..<330 { #expect(before.rgb(x, y) == after.rgb(x, y)) }
        }
    }
}
