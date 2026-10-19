import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite struct MetadataTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    @Test func setSaveAndUndo() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.setMetadata(title: "Le café", author: "Ada", subject: "Notes", keywords: "one, two",
                            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(doc.metadata("info:Title") == "Le café")
        #expect(doc.metadata("info:Keywords") == "one, two")
        #expect(doc.metadata("info:ModDate")?.hasPrefix("D:2027") == true)
        let out = temporaryURL("info.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let saved = try EngineDocument(url: out)
        #expect(saved.metadata("info:Title") == "Le café" && saved.metadata("info:Author") == "Ada")
        try doc.setMetadata(author: "")
        #expect(doc.metadata("info:Author") == nil && doc.metadata("info:Title") == "Le café")
        try doc.undo()
        try doc.undo()
        #expect(doc.metadata("info:Title") == nil)
        #expect(throws: EngineError.self) { try doc.setMetadata(title: String(repeating: "x", count: 70_000)) }
    }

    /// XMP is rewritten to match, keeping the PDF/A identification.
    @Test func xmpFollowsInfo() throws {
        let doc = try Corpus.open("xmp.pdf")
        try doc.setMetadata(title: "New <title> & more", keywords: "pdf")
        let out = temporaryURL("xmp.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        // The last packet in the file is the new one.
        let packet = try #require(text.components(separatedBy: "<x:xmpmeta").last)
        #expect(packet.contains("New &lt;title&gt; &amp; more"))
        #expect(packet.contains("<pdf:Keywords>pdf</pdf:Keywords>"))
        #expect(packet.contains("<pdfaid:part>2</pdfaid:part>") && packet.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
        #expect(packet.contains("<dc:creator><rdf:Seq><rdf:li>Old author"))
        #expect(!packet.contains("Old title"))
    }
}

@Suite struct LinkEditingTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    @Test func createMoveRetargetDelete() throws {
        let doc = try Corpus.open("text.pdf")
        let before = try doc.links(page: 0).count
        let rect = CGRect(x: 72, y: 300, width: 120, height: 20)
        let web = try doc.createLink(page: 0, rect: rect, to: .web("https://example.com/a?b=c"))
        let toPage = try doc.createLink(page: 0, rect: CGRect(x: 72, y: 340, width: 120, height: 20), to: .page(2))
        var links = try doc.links(page: 0)
        #expect(links.count == before + 2)
        let made = try #require(links.first { $0.id == web })
        #expect(made.uri == "https://example.com/a?b=c" && made.isExternal)
        #expect(abs(made.rect.minY - 300) < 0.5 && abs(made.rect.width - 120) < 0.5)
        #expect(links.first { $0.id == toPage }?.targetPage == 2)

        try doc.updateLink(page: 0, id: web, rect: rect.offsetBy(dx: 10, dy: 50), to: .page(1))
        links = try doc.links(page: 0)
        let moved = try #require(links.first { $0.id == web })
        #expect(abs(moved.rect.minY - 350) < 0.5 && moved.targetPage == 1)

        let out = temporaryURL("links.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(try EngineDocument(url: out).links(page: 0).count == before + 2)

        try doc.deleteLink(page: 0, id: toPage)
        #expect(try doc.links(page: 0).count == before + 1)
        try doc.undo()
        #expect(try doc.links(page: 0).count == before + 2)
    }

    @Test func onlyWebAndPageTargets() throws {
        let doc = try Corpus.open("text.pdf")
        let rect = CGRect(x: 72, y: 300, width: 120, height: 20)
        for uri in ["javascript:alert(1)", "file:///etc/passwd", "ftp://x", "http://a b", "", "https://\u{7f}", "https://", "mailto:"] {
            #expect(throws: EngineError.self) { try doc.createLink(page: 0, rect: rect, to: .web(uri)) }
        }
        #expect(throws: EngineError.self) { try doc.createLink(page: 0, rect: rect, to: .page(99)) }
        #expect(throws: EngineError.self) { try doc.createLink(page: 0, rect: .zero, to: .page(0)) }
        try doc.createLink(page: 0, rect: rect, to: .web("mailto:someone@example.com"))
    }

    /// Rectangles stay where they were drawn on a rotated, cropped page.
    @Test func rotatedAndCroppedPages() throws {
        let doc = try Corpus.open("mixed.pdf")
        for page in 0..<(try doc.pageCount()) {
            let bounds = try doc.pageBounds()[page]
            let rect = CGRect(x: bounds.minX + 20, y: bounds.minY + 30, width: 60, height: 15)
            let id = try doc.createLink(page: page, rect: rect, to: .page(0))
            let link = try #require(try doc.links(page: page).first { $0.id == id })
            #expect(abs(link.rect.minX - rect.minX) < 0.5 && abs(link.rect.minY - rect.minY) < 0.5, "page \(page): \(link.rect) vs \(rect)")
            try doc.updateLink(page: page, id: id, rect: rect.offsetBy(dx: 5, dy: 5))
            let moved = try #require(try doc.links(page: page).first { $0.id == id })
            #expect(abs(moved.rect.minX - rect.minX - 5) < 0.5 && abs(moved.rect.minY - rect.minY - 5) < 0.5, "page \(page) moved: \(moved.rect)")
        }
    }
}

@Suite struct PageContentTests {
    @Test func listsTextAndImages() throws {
        let doc = try Corpus.open("content.pdf")
        let content = try doc.content(page: 0)
        let texts = content.runs.map(\.text)
        #expect(texts.contains("Hello world") && texts.contains("Kerning") && texts.contains("Wide text"))
        #expect(!texts.contains("In a form"))   // inside a Form XObject
        let hello = try #require(content.runs.first { $0.text == "Hello world" })
        #expect(hello.isEditable && abs(hello.size - 24) < 0.1 && hello.isSerif)
        #expect(hello.quads.count == 11)
        let kerning = try #require(content.runs.first { $0.text == "Kerning" })
        #expect(kerning.color == PDFColor(red: 1, green: 0, blue: 0))
        #expect(content.runs.first { $0.text == "aaa" }?.restriction == .type3)
        #expect(content.runs.first { $0.text == "hidden" }?.restriction == .invisible)
        // The run's box is where the page's text says the words are.
        let pageText = try doc.text(page: 0)
        let range = try #require(pageText.search("Hello world").first)
        let words = pageText.rects(for: range).reduce(CGRect.null) { $0.union($1) }
        #expect(hello.rect.insetBy(dx: -2, dy: -2).contains(words.insetBy(dx: 1, dy: 1)), "\(hello.rect) vs \(words)")

        // One image drawn twice; the inline image isn't listed.
        #expect(content.images.count == 2)
        let first = content.images[0]
        #expect(abs(first.rect.minX - 72) < 0.5 && abs(first.rect.minY - (792 - 450)) < 0.5)
        #expect(abs(first.rect.width - 100) < 0.5 && first.pixelWidth == 4)
    }

    @Test func rotatedAndCroppedPages() throws {
        let doc = try Corpus.open("content.pdf")
        for page in 1...2 {
            let content = try doc.content(page: page)
            let run = try #require(content.runs.first)
            let pageText = try doc.text(page: page)
            let range = try #require(pageText.search(run.text).first)
            let words = pageText.rects(for: range).reduce(CGRect.null) { $0.union($1) }
            #expect(run.rect.insetBy(dx: -2, dy: -2).contains(words.insetBy(dx: 1, dy: 1)), "page \(page): \(run.rect) vs \(words)")
        }
        let image = try #require(try doc.content(page: 1).images.first)
        #expect(abs(image.rect.width - 50) < 0.5 && abs(image.rect.height - 100) < 0.5)   // turned a quarter
    }

    /// Writing the content again changes nothing that is drawn.
    @Test func rewriteDrawsTheSame() throws {
        let doc = try Corpus.open("content.pdf")
        for page in 0..<3 {
            let bounds = try doc.pageBounds()[page]
            let before = try Pixels(doc.renderPage(page, bounds: bounds, scale: 1))
            try doc.rewritePageContent(page: page)
            let after = try Pixels(doc.renderPage(page, bounds: bounds, scale: 1))
            var different = 0
            for y in stride(from: 0, to: before.height, by: 2) {
                for x in stride(from: 0, to: before.width, by: 2) where before.rgb(x, y) != after.rgb(x, y) { different += 1 }
            }
            #expect(different == 0, "page \(page): \(different) pixels changed")
            #expect(try doc.content(page: page).runs.map(\.text) == (try Corpus.open("content.pdf").content(page: page).runs.map(\.text)))
        }
        try doc.undo()
        #expect(doc.canUndo)
    }

    @Test func limits() throws {
        let doc = try Corpus.open("contentbomb.pdf")
        let start = Date()
        let content = try doc.content(page: 0)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(content.runs.count <= 200_001)
        // Past 256 nested q's the state is still followed.
        let deep = try #require(content.runs.first)
        #expect(deep.text == "deep" && abs(deep.rect.minX - 72) < 1)
    }
}
