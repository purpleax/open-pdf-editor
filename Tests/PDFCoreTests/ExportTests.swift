import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import Testing

@Suite struct ExportTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    private func corpus(_ name: String) -> URL { Corpus.root.appendingPathComponent(name) }

    /// A file inside a .docx (a zip), read with unzip.
    private func unzip(_ docx: URL, _ member: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = member.map { ["-p", docx.path, $0] } ?? ["-l", docx.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// scanned.pdf with a made-up text layer on its first page, saved.
    private func recognisedScan() throws -> URL {
        let doc = try Corpus.open("scanned.pdf")
        try doc.setTextLayers([RecognizedPage(page: 0, words: [
            RecognizedWord(text: "Recognised ", rect: CGRect(x: 72, y: 136, width: 90, height: 18), spaceWidth: 5),
            RecognizedWord(text: "words", rect: CGRect(x: 167, y: 136, width: 50, height: 18)),
        ])])
        let url = temporaryURL("ocr.pdf")
        try doc.save(to: url)
        return url
    }

    @Test func word() throws {
        let out = temporaryURL("text.docx")
        defer { try? FileManager.default.removeItem(at: out) }
        try PDFExporter(url: corpus("text.pdf")).export(.word, pages: 0...2, to: out)
        let xml = try unzip(out, "word/document.xml")
        #expect(xml.contains("quick brown fox") && xml.contains("Chapter Two"))
    }

    @Test func wordFromARecognisedScanHasTheTextNotThePicture() throws {
        let source = try recognisedScan()
        let out = temporaryURL("ocr.docx")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: source)
        }
        try PDFExporter(url: source).export(.word, pages: 0...0, to: out)
        let xml = try unzip(out, "word/document.xml")
        #expect(xml.contains(">Recognised<") && xml.contains(">words<"))
        #expect(try !unzip(out).contains("media/"))
        // A scan without recognised text keeps its picture.
        let plain = temporaryURL("scan.docx")
        defer { try? FileManager.default.removeItem(at: plain) }
        try PDFExporter(url: corpus("scanned.pdf")).export(.word, pages: 1...1, to: plain)
        #expect(try unzip(plain).contains("media/"))
    }

    @Test func wordKeepsAnImageDrawnTwice() throws {
        // content.pdf's page 0 draws one image twice.
        let out = temporaryURL("content.docx")
        defer { try? FileManager.default.removeItem(at: out) }
        try PDFExporter(url: corpus("content.pdf")).export(.word, pages: 0...0, to: out)
        let media = try unzip(out).split(separator: "\n").filter { $0.contains("media/") }
        #expect(media.count >= 2, "\(media)")
        for line in media {
            let size = Int(line.split(separator: " ").first ?? "") ?? 0
            #expect(size > 0, "\(line)")
        }
    }

    @Test func webPageAndText() throws {
        let html = temporaryURL("text.html"), txt = temporaryURL("text.txt")
        defer {
            try? FileManager.default.removeItem(at: html)
            try? FileManager.default.removeItem(at: txt)
        }
        let exporter = try PDFExporter(url: corpus("text.pdf"))
        var progress: [Int] = []
        try exporter.export(.html, pages: 0...2, to: html) { progress.append($0) }
        #expect(progress == [1, 2, 3])
        #expect(try String(contentsOf: html, encoding: .utf8).contains("Chapter Two"))
        try exporter.export(.text, pages: 1...1, to: txt)
        let text = try String(contentsOf: txt, encoding: .utf8)
        #expect(text.contains("Chapter Two") && !text.contains("Chapter One"))

        // A recognised scan: its text, without the page's picture.
        let source = try recognisedScan()
        defer { try? FileManager.default.removeItem(at: source) }
        try PDFExporter(url: source).export(.html, pages: 0...1, to: html)
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("Recognised") && page.components(separatedBy: "data:image").count == 2)
    }

    @Test func images() throws {
        let exporter = try PDFExporter(url: corpus("text.pdf"))
        let png = temporaryURL("p.png"), high = temporaryURL("high.jpg"), low = temporaryURL("low.jpg")
        defer { for u in [png, high, low] { try? FileManager.default.removeItem(at: u) } }
        #expect(try exporter.exportImage(page: 0, dpi: 150, to: png) == 150)
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1275 && props[kCGImagePropertyPixelHeight] as? Int == 1650)
        #expect((props[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 150) < 1 } == true, "\(props)")
        try exporter.exportImage(page: 0, dpi: 150, jpeg: true, quality: 0.95, to: high)
        try exporter.exportImage(page: 0, dpi: 150, jpeg: true, quality: 0.2, to: low)
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        #expect(size(low) > 0 && size(low) < size(high))
        // A large page is drawn smaller; absurd ones not at all.
        let blank = temporaryURL("big.pdf")
        defer { try? FileManager.default.removeItem(at: blank) }
        try PDFFiles.writeBlank(to: blank, pageSize: CGSize(width: 14_400, height: 14_400))
        let used = try PDFExporter(url: blank).exportImage(page: 0, dpi: 600, to: png)
        #expect(used < 600 && used * 200 <= 16_384)
        let huge = try PDFExporter(url: corpus("huge.pdf"))
        for page in 0..<2 { #expect(throws: EngineError.self) { try huge.exportImage(page: page, dpi: 600, to: png) } }
        #expect(throws: EngineError.self) { try exporter.exportImage(page: 0, dpi: 0, to: png) }
    }

    @Test func tiff() throws {
        let exporter = try PDFExporter(url: corpus("text.pdf"))
        let out = temporaryURL("all.tiff")
        defer { try? FileManager.default.removeItem(at: out) }
        var progress: [Int] = []
        #expect(try exporter.exportTIFF(pages: 0...2, dpi: 100, to: out) { progress.append($0) } == 100)
        #expect(progress == [1, 2, 3])
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 2, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 100) < 1 } == true, "\(props)")
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 850 && props[kCGImagePropertyPixelHeight] as? Int == 1100)
        // The pixels are the page's: the same as the PNG of it.
        let png = temporaryURL("p.png")
        defer { try? FileManager.default.removeItem(at: png) }
        try exporter.exportImage(page: 2, dpi: 100, to: png)
        let a = try #require(CGImageSourceCreateImageAtIndex(source, 2, nil))
        let pngSource = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let b = try #require(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))
        let pa = pixels(a), pb = pixels(b)
        let worst = zip(pa, pb).map { abs(Int($0) - Int($1)) }.max() ?? 255
        let differing = zip(pa, pb).filter { $0 != $1 }.count
        #expect(worst <= 2, "worst \(worst), differing \(differing) of \(pa.count)")
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    @Test func passwordsCancellingAndBadRequests() throws {
        #expect(throws: EngineError.self) { try PDFExporter(url: corpus("encrypted.pdf")) }
        let out = temporaryURL("enc.txt")
        defer { try? FileManager.default.removeItem(at: out) }
        try PDFExporter(url: corpus("encrypted.pdf"), password: "secret").export(.text, pages: 0...0, to: out)
        #expect(try String(contentsOf: out, encoding: .utf8).contains("quick brown fox"))

        let cancel = ConversionCancel()
        let exporter = try PDFExporter(url: corpus("long.pdf"), cancel: cancel)
        let docx = temporaryURL("long.docx")
        defer { try? FileManager.default.removeItem(at: docx) }
        let count = try exporter.pageCount()
        let error = #expect(throws: EngineError.self) {
            try exporter.export(.word, pages: 0...(count - 1), to: docx) { done in if done == 2 { cancel.cancel() } }
        }
        #expect(error?.message == "Cancelled")
        #expect(throws: EngineError.self) { try exporter.exportImage(page: 0, dpi: 72, to: out) }

        let text = try PDFExporter(url: corpus("text.pdf"))
        #expect(throws: EngineError.self) { try text.export(.text, pages: 2...5, to: out) }
        #expect(throws: EngineError.self) { try text.export(.png, pages: 0...0, to: out) }
        #expect(throws: EngineError.self) { try PDFExporter(url: corpus("not-a-pdf.pdf")) }
    }

    @Test func fontNamesCantInjectMarkup() throws {
        let html = temporaryURL("evil.html"), docx = temporaryURL("evil.docx")
        defer { for u in [html, docx] { try? FileManager.default.removeItem(at: u) } }
        let exporter = try PDFExporter(url: corpus("exportbomb.pdf"))
        try exporter.export(.html, pages: 0...0, to: html)
        let page = try String(contentsOf: html, encoding: .utf8)
        #expect(page.contains("Hello") && !page.contains("<script") && !page.contains("x\">"))
        try exporter.export(.word, pages: 0...0, to: docx)
        let xml = try unzip(docx, "word/document.xml")
        #expect(xml.contains("Hello") && !xml.contains("<script"))
        #expect(try XMLDocument(xmlString: xml).rootElement() != nil)
    }

    @Test func crowdedPagesStayQuickInWord() throws {
        let docx = temporaryURL("crowded.docx")
        defer { try? FileManager.default.removeItem(at: docx) }
        let started = Date()
        try PDFExporter(url: corpus("exportbomb.pdf")).export(.word, pages: 1...1, to: docx)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    /// Every corpus file through every format: errors are fine, crashes and
    /// hangs are not.
    @Test func hostileFiles() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Corpus.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
        let out = temporaryURL("out")
        defer { try? FileManager.default.removeItem(at: out) }
        for file in files {
            let started = Date()
            guard let exporter = try? PDFExporter(url: file), let count = try? exporter.pageCount(), count > 0 else { continue }
            let last = min(count, 3) - 1
            for format in [ExportFormat.word, .html, .text] {
                _ = try? exporter.export(format, pages: 0...last, to: out)
            }
            _ = try? exporter.exportImage(page: 0, dpi: 72, to: out)
            #expect(Date().timeIntervalSince(started) < 60, "\(file.lastPathComponent) took too long")
        }
    }
}
