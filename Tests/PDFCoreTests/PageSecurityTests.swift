import CoreGraphics
import Foundation
import PDFCore
import Testing

/// Regressions for the 0.3.0 security review.
@Suite struct PageSecurityTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    /// Moving pages keeps everything outside the page tree: attachments and
    /// the outline (which follows the pages).
    @Test func moveKeepsTheCatalog() throws {
        let doc = try Corpus.open("attachments.pdf")
        try doc.prepareForEditing(password: nil)
        try doc.insertBlankPage(at: 0, size: CGSize(width: 300, height: 300))
        try doc.reorderPages([1, 0])
        let url = temporaryURL("moved.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        let saved = try EngineDocument(url: url)
        #expect(try saved.attachments().count == 1)
        #expect(try saved.pageBounds()[1].size == CGSize(width: 300, height: 300))

        let text = try Corpus.open("text.pdf")
        try text.reorderPages([2, 0, 1])
        let outline = try text.outline()
        #expect(outline.map(\.title) == ["Chapter One", "Chapter Two", "Chapter Three"])
        #expect(outline.map(\.page) == [1, 2, 0])
        try text.undo()
        #expect(try text.outline().map(\.page) == [0, 1, 2])
    }

    /// A deeply nested outline is left alone when pages move.
    @Test func moveWithDeepOutline() throws {
        let doc = try Corpus.open("deep-outline.pdf")
        try doc.insertBlankPage(at: 0, size: CGSize(width: 300, height: 300))
        let count = try doc.pageCount()
        try doc.reorderPages(Array((0..<count).reversed()))
        #expect(try doc.pageBounds().last?.size == CGSize(width: 300, height: 300))
    }

    /// Rendering on other threads while pages are inserted and undone.
    @Test func renderingDuringInsert() throws {
        let doc = try Corpus.open("text.pdf")
        let source = Corpus.root.appendingPathComponent("mixed.pdf")
        let stop = Flag()
        let group = DispatchGroup()
        for _ in 0..<3 {
            DispatchQueue.global().async(group: group) {
                while !stop.isSet { _ = try? doc.displayList(page: 0) }
            }
        }
        for _ in 0..<300 {
            try doc.insertPages(from: source, at: 0)
            try doc.undo()
        }
        stop.set()
        group.wait()
        #expect(try doc.pageCount() == 3)
    }

    /// Two documents drawing text boxes (HarfBuzz) while a conversion runs:
    /// MuPDF's global HarfBuzz state needs every context to share locks.
    @Test func contextsShareLocks() throws {
        let text = temporaryURL("words.txt")
        let out = temporaryURL("words.pdf")
        defer { [text, out].forEach { try? FileManager.default.removeItem(at: $0) } }
        try String(repeating: "Shaping text in one context while another draws.\n", count: 400).write(to: text, atomically: true, encoding: .utf8)
        let stop = Flag()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            while !stop.isSet { try? PDFFiles.combine([text], into: out, allowDocuments: true) }
        }
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<15 {
                    guard let doc = try? Corpus.open("freetext.pdf") else { return }
                    for page in 0..<3 { _ = try? doc.displayList(page: page) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { stop.set() }
        group.wait()
        let doc = try Corpus.open("freetext.pdf")
        #expect(try doc.annotations(page: 0).first?.kind == .freeText)
    }

    /// With other documents turned off in Settings, only PDFs and images are
    /// read, by content: an HTML file named .png is refused too.
    @Test func documentsCanBeTurnedOff() throws {
        let image = temporaryURL("square.png")
        let html = temporaryURL("page.html")
        let disguised = temporaryURL("page.png")
        let text = temporaryURL("notes.txt")
        let url = temporaryURL("combined.pdf")
        defer { [image, html, disguised, text, url].forEach { try? FileManager.default.removeItem(at: $0) } }
        try PageTests.writePNG(to: image, width: 400, height: 300)
        let page = "<html><body><p>Converted</p><img src=\"square.png\"></body></html>"
        try page.write(to: html, atomically: true, encoding: .utf8)
        try page.write(to: disguised, atomically: true, encoding: .utf8)
        try "Plain text\n".write(to: text, atomically: true, encoding: .utf8)

        try PDFFiles.combine([Corpus.root.appendingPathComponent("text.pdf"), image], into: url, allowDocuments: false)
        #expect(try EngineDocument(url: url).pageCount() == 4)
        for file in [html, disguised, text] {
            #expect(throws: EngineError.self) { try PDFFiles.combine([file], into: url, allowDocuments: false) }
        }
        try PDFFiles.combine([html], into: url, allowDocuments: true)
        #expect(try EngineDocument(url: url).text(page: 0).string.contains("Converted"))
    }

    @Test func conversionCanBeCancelled() throws {
        let big = temporaryURL("big.txt")
        let url = temporaryURL("big.pdf")
        defer { [big, url].forEach { try? FileManager.default.removeItem(at: $0) } }
        let line = String(repeating: "All work and no play makes a long document. ", count: 4) + "\n"
        try String(repeating: line, count: 200_000).write(to: big, atomically: true, encoding: .utf8)

        let cancelledFirst = ConversionCancel()
        cancelledFirst.cancel()
        #expect(throws: EngineError.self) { try PDFFiles.combine([big], into: url, allowDocuments: true, cancel: cancelledFirst) }

        let cancel = ConversionCancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        let start = Date()
        do {
            try PDFFiles.combine([big], into: url, allowDocuments: true, cancel: cancel)
            Issue.record("a 36 MB text file converted in under 0.3 s")
        } catch let error as EngineError {
            #expect(error.message == "Cancelled")
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func absurdRotationIsReduced() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.rotatePages([0], by: 90 * 1_000_001)
        #expect(try doc.pageBounds()[0].size == CGSize(width: 792, height: 612))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
