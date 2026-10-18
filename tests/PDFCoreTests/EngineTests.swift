import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import Testing
import UniformTypeIdentifiers

/// The generated corpus (make corpus) and the golden images beside this file.
enum Corpus {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../build/corpus").standardizedFileURL
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")

    static func open(_ name: String) throws -> EngineDocument {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError(code: -1, message: "\(name) is missing: run make corpus")
        }
        return try EngineDocument(url: url)
    }
}

@Suite struct DocumentTests {
    @Test func pagesAndBounds() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(try doc.pageCount() == 3)
        #expect(doc.isPDF)
        #expect(!doc.needsPassword)
        let bounds = try doc.pageBounds()
        #expect(bounds.count == 3)
        #expect(bounds[0].size == CGSize(width: 612, height: 792))
    }

    @Test func mixedPageSizes() throws {
        let sizes = try Corpus.open("mixed.pdf").pageBounds().map(\.size)
        #expect(sizes == [
            CGSize(width: 612, height: 792),
            CGSize(width: 842, height: 595),
            CGSize(width: 792, height: 612),   // /Rotate 90
            CGSize(width: 200, height: 200),
            CGSize(width: 300, height: 400),
        ])
    }

    @Test func metadata() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(doc.metadata("format")?.hasPrefix("PDF") == true)
        #expect(doc.metadata("info:NoSuchKey") == nil)
    }

    @Test func password() throws {
        let doc = try Corpus.open("encrypted.pdf")
        #expect(doc.needsPassword)
        #expect(!doc.authenticate(password: "wrong"))
        #expect(doc.authenticate(password: "secret"))
        #expect(try doc.text(page: 0).string.contains("quick brown fox"))
        #expect(doc.metadata("encryption")?.contains("AES") == true)
    }

    @Test func brokenFileFailsCleanly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-not-a-pdf.pdf")
        try Data("this is not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: EngineError.self) {
            let doc = try EngineDocument(url: url)
            _ = try doc.pageCount()
            _ = try doc.displayList(page: 0)
        }
    }
}

@Suite struct TextTests {
    @Test func readingOrderAndLines() throws {
        let text = try Corpus.open("text.pdf").text(page: 0)
        #expect(text.string.hasPrefix("Chapter One\nThe quick brown fox"))
        #expect(text.lines.count == 6)
        #expect(text.text(in: text.lines[1].range) == "The quick brown fox jumps over the lazy dog.")
    }

    @Test func search() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(try doc.text(page: 0).search("fox").count == 1)
        #expect(try doc.text(page: 1).search("fox").count == 3)            // fox, Foxes, FOX
        #expect(try doc.text(page: 1).search("fox", options: .wholeWords).count == 2)
        #expect(try doc.text(page: 1).search("FOX", options: .matchCase).count == 1)
        #expect(try doc.text(page: 0).search("cafe resume").count == 1)     // accents ignored
        #expect(try doc.text(page: 0).search("end of the line").count == 1) // across a line break
        #expect(try doc.text(page: 0).search("   ").isEmpty)
    }

    @Test func hitTestingAndWords() throws {
        let text = try Corpus.open("text.pdf").text(page: 0)
        let quick = try #require(text.search("quick").first)
        let center = text.chars[quick.lowerBound + 1].quad.center
        #expect(text.charIndex(at: center) == quick.lowerBound + 1)
        #expect(text.wordRange(at: quick.lowerBound + 2) == quick)
        // Left of the first character on its line: caret before it.
        let line = text.lines[1]
        let left = CGPoint(x: line.bounds.minX - 20, y: line.bounds.midY)
        #expect(text.caret(at: left) == line.range.lowerBound)
        // Right of the line: caret after its last character.
        let right = CGPoint(x: line.bounds.maxX + 50, y: line.bounds.midY)
        #expect(text.caret(at: right) == line.range.upperBound)
        #expect(text.rects(for: quick).count == 1)
        #expect(text.rects(for: text.lines[1].range.lowerBound..<text.lines[2].range.upperBound).count == 2)
    }

    @Test func copyTextAcrossLines() throws {
        let text = try Corpus.open("text.pdf").text(page: 0)
        let range = text.lines[2].range.lowerBound..<text.lines[3].range.upperBound
        #expect(text.text(in: range) == "Search should find this phrase at the end of\nthe line, and a Café résumé with accents.")
    }
}

@Suite struct NavigationTests {
    @Test func outline() throws {
        let outline = try Corpus.open("text.pdf").outline()
        #expect(outline.map(\.title) == ["Chapter One", "Chapter Two", "Chapter Three"])
        #expect(outline.map(\.page) == [0, 1, 2])
        #expect(outline[1].children.map(\.title) == ["Foxes and dogs"])
        #expect(outline[1].children.first?.point != nil)
        #expect(outline[1].isOpen)  // only items with children can be open
    }

    @Test func links() throws {
        let links = try Corpus.open("text.pdf").links(page: 0)
        #expect(links.count == 2)
        let inside = try #require(links.first { !$0.isExternal })
        #expect(inside.targetPage == 2)
        let external = try #require(links.first { $0.isExternal })
        #expect(external.uri == "https://example.com/")
        // Link rectangles are in page space (y down): the internal link is on the "Go to page three" line.
        let text = try Corpus.open("text.pdf").text(page: 0)
        let line = try #require(text.search("Go to page three").first)
        #expect(inside.rect.intersects(text.rects(for: line)[0]))
    }
}

@Suite struct AttachmentAndLayerTests {
    @Test func attachments() throws {
        let doc = try Corpus.open("attachments.pdf")
        let files = try doc.attachments()
        #expect(files.map(\.filename) == ["notes.txt"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-notes.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try doc.saveAttachment(named: files[0].name, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello attachment\n")
        #expect(try Corpus.open("text.pdf").attachments().isEmpty)
    }

    @Test func layers() throws {
        let doc = try Corpus.open("layers.pdf")
        let layers = try doc.layers()
        #expect(layers.map(\.text) == ["Red square", "Blue square"])
        #expect(layers.map(\.isOn) == [true, false])
        let bounds = try doc.pageBounds()[0]
        // The blue square (x 320-520, y 500-600 from the bottom) is hidden at first.
        let probe = CGPoint(x: 420, y: 792 - 550)
        #expect(try Pixels(doc.renderPage(0, bounds: bounds, scale: 1)).rgb(at: probe) == [255, 255, 255])
        try doc.toggleLayer(1)
        #expect(try doc.layers().map(\.isOn) == [true, true])
        #expect(try Pixels(doc.renderPage(0, bounds: bounds, scale: 1)).rgb(at: probe) == [0, 0, 255])
    }
}

@Suite struct RenderTests {
    @Test func tilesMatchWholePage() throws {
        let doc = try Corpus.open("text.pdf")
        let bounds = try doc.pageBounds()[0]
        let list = try doc.displayList(page: 0)
        let scale: CGFloat = 1.5
        let size = bounds.applying(EngineDocument.pageTransform(bounds: bounds, scale: scale, rotation: 0)).size
        let whole = try Pixels(doc.render(list, bounds: bounds, scale: scale, rotation: 0,
                                          rect: CGRect(origin: .zero, size: size)))
        let tile = 256
        for ty in stride(from: 0, to: Int(size.height), by: tile) {
            for tx in stride(from: 0, to: Int(size.width), by: tile) {
                let rect = CGRect(x: tx, y: ty, width: min(tile, Int(size.width) - tx), height: min(tile, Int(size.height) - ty))
                let part = try Pixels(doc.render(list, bounds: bounds, scale: scale, rotation: 0, rect: rect))
                for y in 0..<part.height {
                    for x in 0..<part.width where part.rgb(x, y) != whole.rgb(tx + x, ty + y) {
                        Issue.record("tile \(tx),\(ty) differs at \(x),\(y)")
                        return
                    }
                }
            }
        }
    }

    @Test func viewRotation() throws {
        let doc = try Corpus.open("mixed.pdf")
        let bounds = try doc.pageBounds()[0]
        for rotation in [0, 90, 180, 270] {
            let t = EngineDocument.pageTransform(bounds: bounds, scale: 2, rotation: rotation)
            let box = bounds.applying(t)
            #expect(abs(box.minX) < 0.001 && abs(box.minY) < 0.001)
            #expect(box.size == (rotation % 180 == 0 ? CGSize(width: 1224, height: 1584) : CGSize(width: 1584, height: 1224)))
        }
    }

    @Test(arguments: [("text.pdf", 0, 0), ("mixed.pdf", 2, 0), ("mixed.pdf", 4, 0), ("mixed.pdf", 1, 90)])
    func golden(file: String, page: Int, rotation: Int) throws {
        let doc = try Corpus.open(file)
        let bounds = try doc.pageBounds()[page]
        let image = try doc.renderPage(page, bounds: bounds, scale: 0.75, rotation: rotation)
        let name = "\(file.replacingOccurrences(of: ".pdf", with: ""))-p\(page + 1)-r\(rotation).png"
        let url = Corpus.golden.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" || !FileManager.default.fileExists(atPath: url.path) {
            try Pixels.writePNG(image, to: url)
            if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] != "1" {
                Issue.record("wrote missing golden image \(name); check it and run again")
            }
            return
        }
        let expected = try Pixels(contentsOf: url)
        let actual = try Pixels(image)
        #expect(actual.width == expected.width && actual.height == expected.height)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        var worst = 0
        for y in 0..<actual.height {
            for x in 0..<actual.width {
                for (a, e) in zip(actual.rgb(x, y), expected.rgb(x, y)) { worst = max(worst, abs(Int(a) - Int(e))) }
            }
        }
        #expect(worst <= 8, "\(name) differs from its golden image by up to \(worst)")
    }
}

/// RGBA pixels of an image, for comparisons.
struct Pixels {
    let width: Int
    let height: Int
    private let data: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EngineError(code: -1, message: "no bitmap context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = bytes
    }

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw EngineError(code: -1, message: "cannot read \(url.lastPathComponent)")
        }
        try self.init(image)
    }

    func rgb(_ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return [data[i], data[i + 1], data[i + 2]]
    }

    /// The colour at a point in page space at scale 1 (y down).
    func rgb(at point: CGPoint) -> [UInt8] { rgb(Int(point.x), Int(point.y)) }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw EngineError(code: -1, message: "cannot write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EngineError(code: -1, message: "cannot write PNG") }
    }
}
