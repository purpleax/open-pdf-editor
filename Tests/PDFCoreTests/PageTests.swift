import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import Testing
import UniformTypeIdentifiers

@Suite struct PageTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    /// The first line of each page's text, to tell pages apart.
    private func titles(_ doc: EngineDocument) throws -> [String] {
        try (0..<doc.pageCount()).map { try doc.text(page: $0).string.split(separator: "\n").first.map(String.init) ?? "" }
    }

    @Test func deleteAndUndo() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.deletePages([1])
        #expect(try titles(doc) == ["Chapter One", "Chapter Three"])
        try doc.undo()
        #expect(try titles(doc) == ["Chapter One", "Chapter Two", "Chapter Three"])
        try doc.redo()
        #expect(try doc.pageCount() == 2)
    }

    @Test func cannotDeleteEveryPage() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(throws: EngineError.self) { try doc.deletePages([0, 1, 2]) }
        #expect(try doc.pageCount() == 3)
        #expect(!doc.canUndo)
    }

    @Test func reorder() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.reorderPages([2, 0, 1])
        #expect(try titles(doc) == ["Chapter Three", "Chapter One", "Chapter Two"])
        // Not a permutation: refused, nothing changes.
        #expect(throws: EngineError.self) { try doc.reorderPages([0, 0, 1]) }
        #expect(throws: EngineError.self) { try doc.reorderPages([0, 1]) }
        #expect(throws: EngineError.self) { try doc.reorderPages([0, 1, 7]) }
        try doc.undo()
        #expect(try titles(doc) == ["Chapter One", "Chapter Two", "Chapter Three"])
    }

    @Test func insertBlank() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.insertBlankPage(at: 1, size: CGSize(width: 300, height: 400))
        #expect(try doc.pageCount() == 4)
        let bounds = try doc.pageBounds()
        #expect(bounds[1].size == CGSize(width: 300, height: 400))
        #expect(try titles(doc)[2] == "Chapter Two")
        try doc.insertBlankPage(at: 99, size: CGSize(width: 612, height: 792))
        #expect(try doc.pageCount() == 5)
        #expect(throws: EngineError.self) { try doc.insertBlankPage(at: 0, size: CGSize(width: 1e9, height: 10)) }
    }

    @Test func rotate() throws {
        let doc = try Corpus.open("mixed.pdf")
        let before = try doc.pageBounds()
        try doc.rotatePages([0, 2], by: 90)
        let after = try doc.pageBounds()
        #expect(after[0].size == CGSize(width: before[0].height, height: before[0].width))
        // Page 3 already had /Rotate 90; another quarter turn makes it upright.
        #expect(after[2].size == CGSize(width: before[2].height, height: before[2].width))
        #expect(after[1] == before[1])
        try doc.rotatePages([0], by: -90)
        #expect(try doc.pageBounds()[0].size == before[0].size)
        #expect(throws: EngineError.self) { try doc.rotatePages([0], by: 45) }
    }

    @Test func crop() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.cropPages([0], to: CGRect(x: 50, y: 50, width: 300, height: 150))
        #expect(try doc.pageBounds()[0].size == CGSize(width: 300, height: 150))
        let text = try doc.text(page: 0).string
        #expect(text.contains("Chapter One"))
        #expect(!text.contains("example.com"))
        // Outside the page: limited to it.
        try doc.cropPages([1], to: CGRect(x: -100, y: -100, width: 2000, height: 2000))
        #expect(try doc.pageBounds()[1].size == CGSize(width: 612, height: 792))
        #expect(throws: EngineError.self) { try doc.cropPages([2], to: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        try doc.undo()
        try doc.undo()
        #expect(try doc.pageBounds()[0].size == CGSize(width: 612, height: 792))
    }

    @Test func cropRotatedPage() throws {
        let doc = try Corpus.open("mixed.pdf")
        // Page 3 is Letter with /Rotate 90: 792 wide, 612 tall on screen.
        try doc.cropPages([2], to: CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(try doc.pageBounds()[2].size == CGSize(width: 400, height: 300))
        // The offset media box keeps working too.
        let offset = try doc.pageBounds()[4]
        try doc.cropPages([4], to: CGRect(x: offset.minX + 10, y: offset.minY + 10, width: 100, height: 100))
        #expect(try doc.pageBounds()[4].size == CGSize(width: 100, height: 100))
    }

    @Test func insertFromFileAndSave() throws {
        let doc = try Corpus.open("text.pdf")
        let inserted = try doc.insertPages(from: Corpus.root.appendingPathComponent("mixed.pdf"), at: 1)
        #expect(inserted == 5)
        #expect(try doc.pageCount() == 8)
        #expect(try titles(doc)[1] == "Letter portrait")
        #expect(try titles(doc)[6] == "Chapter Two")
        let url = temporaryURL("merged.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.save(to: url)
        let reopened = try EngineDocument(url: url)
        #expect(try titles(reopened) == titles(doc))
        try doc.undo()
        #expect(try doc.pageCount() == 3)
    }

    @Test func insertLockedFile() throws {
        let doc = try Corpus.open("text.pdf")
        let locked = Corpus.root.appendingPathComponent("encrypted.pdf")
        #expect(throws: EngineError.self) { try doc.insertPages(from: locked, at: 0) }
        #expect(try doc.insertPages(from: locked, at: 0, password: "secret") == 3)
        #expect(throws: EngineError.self) { try doc.insertPages(from: Corpus.root.appendingPathComponent("not-a-pdf.pdf"), at: 0) }
        #expect(try doc.pageCount() == 6)
    }

    @Test func extract() throws {
        let doc = try Corpus.open("text.pdf")
        let url = temporaryURL("extract.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.extractPages([2, 0], to: url)
        let extracted = try EngineDocument(url: url)
        #expect(try titles(extracted) == ["Chapter Three", "Chapter One"])
        #expect(try doc.pageCount() == 3)
        #expect(!doc.canUndo)
        #expect(throws: EngineError.self) { try doc.extractPages([9], to: url) }
    }

    @Test func combineFiles() throws {
        let image = temporaryURL("square.png")
        let text = temporaryURL("notes.txt")
        let url = temporaryURL("combined.pdf")
        defer { [image, text, url].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writePNG(to: image, width: 400, height: 300)
        try "Plain text becomes a page.\n".write(to: text, atomically: true, encoding: .utf8)
        try PDFFiles.combine([Corpus.root.appendingPathComponent("text.pdf"), image, text], into: url)
        let combined = try EngineDocument(url: url)
        #expect(try combined.pageCount() == 5)
        #expect(try titles(combined).prefix(3) == ["Chapter One", "Chapter Two", "Chapter Three"])
        #expect(try combined.text(page: 4).string.contains("Plain text becomes a page."))
        #expect(throws: EngineError.self) { try PDFFiles.combine([Corpus.root.appendingPathComponent("encrypted.pdf")], into: url) }
        #expect(throws: EngineError.self) { try PDFFiles.combine([], into: url) }
    }

    @Test func reduce() throws {
        let image = temporaryURL("big.png")
        let source = temporaryURL("big.pdf")
        let small = temporaryURL("small.pdf")
        defer { [image, source, small].forEach { try? FileManager.default.removeItem(at: $0) } }
        try writePNG(to: image, width: 3000, height: 3000, noisy: true)
        try PDFFiles.combine([image], into: source)
        try PDFFiles.reduce(source, quality: .medium, into: small)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let after = try FileManager.default.attributesOfItem(atPath: small.path)[.size] as? Int ?? 0
        #expect(after > 0 && after < before / 2)
        #expect(try EngineDocument(url: small).pageCount() == 1)
        #expect(throws: EngineError.self) { try PDFFiles.reduce(Corpus.root.appendingPathComponent("encrypted.pdf"), quality: .high, into: small) }
    }

    private func writePNG(to url: URL, width: Int, height: Int, noisy: Bool = false) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noisy, let data = context.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            var seed: UInt32 = 12345
            for i in 0..<(context.bytesPerRow * height) {
                seed = seed &* 1_103_515_245 &+ 12345
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        let cgImage = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        // 300 dpi, so the reduced copy has resolution to give up.
        let properties = [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
        #expect(CGImageDestinationFinalize(destination))
    }
}

@Suite struct PageSplitTests {
    @Test func everyN() {
        #expect(PageSplit.every(2, pageCount: 5) == [[0, 1], [2, 3], [4]])
        #expect(PageSplit.every(10, pageCount: 3) == [[0, 1, 2]])
        #expect(PageSplit.every(0, pageCount: 3).isEmpty)
        #expect(PageSplit.every(1, pageCount: 0).isEmpty)
    }

    @Test func atBookmarks() {
        #expect(PageSplit.starting(at: [0, 2, 4], pageCount: 6) == [[0, 1], [2, 3], [4, 5]])
        // Front matter before the first bookmark, duplicates and strays.
        #expect(PageSplit.starting(at: [3, 1, 3, 99, -1], pageCount: 5) == [[0], [1, 2], [3, 4]])
        #expect(PageSplit.starting(at: [], pageCount: 2) == [[0, 1]])
    }
}
