import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite struct ScanDetectionTests {
    @Test func scansAreFound() throws {
        let doc = try Corpus.open("scanned.pdf")
        for page in 0..<5 {
            let info = try doc.textInfo(page: page)
            #expect(info.isScan, "page \(page): \(info)")
            #expect(info.imageCoverage <= 1)
        }
        // Strips over a layered image aren't counted twice.
        #expect(try doc.textInfo(page: 3).imageCoverage > 0.9)
        // A stamped page number is visible text, but not enough to count.
        #expect(try doc.textInfo(page: 4).visibleCharacters == 6)
        // A scan with a text layer already isn't one to recognise.
        let layered = try doc.textInfo(page: 5)
        #expect(layered.invisibleCharacters > 0 && !layered.isScan && !layered.lacksText)
    }

    @Test func textPagesAreNotScans() throws {
        let doc = try Corpus.open("text.pdf")
        let info = try doc.textInfo(page: 0)
        #expect(!info.isScan && !info.lacksText && info.visibleCharacters > 100)
        // content.pdf has small images and a hidden word.
        let content = try Corpus.open("content.pdf").textInfo(page: 0)
        #expect(!content.isScan && content.invisibleCharacters == 6)
    }

    @Test func contentsOnlyLeavesOutAnnotations() throws {
        // freetext.pdf: a page with a FreeText comment over otherwise blank contents.
        let doc = try Corpus.open("freetext.pdf")
        let bounds = try doc.pageBounds()[0]
        func inked(_ image: CGImage) -> Int {
            let w = image.width, h = image.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 128 }.count
        }
        let all = try doc.renderPage(0, bounds: bounds, scale: 0.5)
        let contents = try doc.renderPage(0, bounds: bounds, scale: 0.5, contentsOnly: true)
        #expect(inked(all) > inked(contents))
    }
}

@Suite struct TextLayerTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    /// Two made-up words on a line, 72 points in and 100 down from the page's corner.
    private func words(_ bounds: CGRect, first: String = "Hello ", second: String = "world") -> [RecognizedWord] {
        let x = bounds.minX + 72, y = bounds.minY + 100
        return [RecognizedWord(text: first, rect: CGRect(x: x, y: y, width: 50, height: 14)),
                RecognizedWord(text: second, rect: CGRect(x: x + 50, y: y, width: 40, height: 14))]
    }

    private func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func wordsLandWhereTheyWereFoundAndStayUpright() throws {
        let doc = try Corpus.open("scanned.pdf")
        let bounds = try doc.pageBounds()
        // Plain, turned (/Rotate 90) and cropped pages.
        for page in 0..<3 {
            let added = try doc.setTextLayers([RecognizedPage(page: page, words: words(bounds[page]))])
            #expect(added == 2)
            let text = try doc.text(page: page)
            #expect(text.string.contains("Hello world"), "page \(page): \(text.string)")
            #expect(!text.search("world").isEmpty)
            let h = try #require(text.chars.first { $0.scalar == "H" })
            let x = bounds[page].minX + 72, y = bounds[page].minY + 100
            #expect(abs(h.quad.upperLeft.x - x) < 1 && abs(h.quad.upperLeft.y - y) < 1, "page \(page): \(h.quad)")
            #expect(abs(h.quad.lowerLeft.y - (y + 14)) < 1)
            // Upright: the top is above the baseline.
            #expect(h.quad.upperLeft.y < h.quad.lowerLeft.y)
            let d = try #require(text.chars.last { $0.scalar == "d" })
            #expect(abs(d.quad.upperRight.x - (x + 90)) < 1)
            // Still invisible: no visible text was added.
            #expect(try doc.textInfo(page: page).visibleCharacters == (page == 4 ? 6 : 0))
        }
    }

    @Test func turnedWordsFollowTheirBaseline() throws {
        let doc = try Corpus.open("scanned.pdf")
        // A word running up the page (rotated 90° counter-clockwise).
        let word = RecognizedWord(text: "Up", upperLeft: CGPoint(x: 86, y: 300), upperRight: CGPoint(x: 86, y: 270),
                                  lowerLeft: CGPoint(x: 100, y: 300), lowerRight: CGPoint(x: 100, y: 270))
        try doc.setTextLayers([RecognizedPage(page: 0, words: [word])])
        let u = try #require(try doc.text(page: 0).chars.first { $0.scalar == "U" })
        #expect(abs(u.quad.lowerLeft.x - 100) < 1 && abs(u.quad.lowerLeft.y - 300) < 1, "\(u.quad)")
        #expect(abs(u.quad.lowerRight.y - 285) < 1)
    }

    @Test func undoRemovesTheLayerAndRerunningReplacesIt() throws {
        let doc = try Corpus.open("scanned.pdf")
        try doc.prepareForEditing(password: nil)
        let bounds = try doc.pageBounds()
        try doc.setTextLayers([RecognizedPage(page: 0, words: words(bounds[0])), RecognizedPage(page: 2, words: words(bounds[2]))])
        try doc.undo()
        #expect(try doc.text(page: 0).string.isEmpty && doc.text(page: 2).string.isEmpty)
        try doc.redo()
        #expect(try doc.text(page: 2).string.contains("Hello world"))
        // Again, with other words: replaced, not added to.
        try doc.setTextLayers([RecognizedPage(page: 0, words: words(bounds[0], first: "Second ", second: "run"))])
        try doc.setTextLayers([RecognizedPage(page: 0, words: words(bounds[0], first: "Third ", second: "run"))])
        let text = try doc.text(page: 0).string
        #expect(!text.contains("Hello") && !text.contains("Second") && occurrences("Third run", in: text) == 1)
        // An empty layer removes it.
        try doc.setTextLayers([RecognizedPage(page: 0, words: [])])
        #expect(try doc.text(page: 0).string.isEmpty)
        // It survives saving.
        let out = temporaryURL("layer.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let saved = try EngineDocument(url: out)
        #expect(try saved.text(page: 2).string.contains("Hello world"))
        #expect(try saved.textInfo(page: 2).invisibleCharacters > 0)
    }

    @Test func textThePageHasIsNotAddedTwice() throws {
        // Page 4 has "Page 5" stamped on as real text; recognition finds it too.
        let doc = try Corpus.open("scanned.pdf")
        let chars = try doc.text(page: 4).chars
        let page = chars.prefix { $0.scalar != "5" }.map(\.quad.bounds).reduce(CGRect.null) { $0.union($1) }
        let five = try #require(chars.first { $0.scalar == "5" }).quad.bounds
        let added = try doc.setTextLayers([RecognizedPage(page: 4, words: [
            RecognizedWord(text: "Page ", rect: page.insetBy(dx: -1, dy: -1)),
            RecognizedWord(text: "5", rect: five.insetBy(dx: -1, dy: -1)),
            RecognizedWord(text: "Elsewhere", rect: CGRect(x: 72, y: 300, width: 80, height: 14)),
        ])])
        #expect(added == 1)
        let text = try doc.text(page: 4).string
        #expect(occurrences("Page", in: text) == 1 && occurrences("5", in: text) == 1 && text.contains("Elsewhere"))
    }

    @Test func awkwardTextAndBoxes() throws {
        let doc = try Corpus.open("scanned.pdf")
        let added = try doc.setTextLayers([RecognizedPage(page: 0, words: [
            // Beyond the Basic Multilingual Plane, and controls.
            RecognizedWord(text: "smile😀\u{7}", rect: CGRect(x: 72, y: 100, width: 60, height: 14)),
            // Decomposed: stored composed.
            RecognizedWord(text: "Cafe\u{301}", rect: CGRect(x: 72, y: 130, width: 40, height: 14)),
            // Degenerate and absurd boxes are skipped.
            RecognizedWord(text: "flat", rect: CGRect(x: 72, y: 160, width: 40, height: 0)),
            RecognizedWord(text: "squashed", rect: CGRect(x: 72, y: 190, width: 0.001, height: 14)),
            RecognizedWord(text: "far", rect: CGRect(x: 1e9, y: 100, width: 40, height: 14)),
            RecognizedWord(text: "nan", rect: CGRect(x: CGFloat.nan, y: 100, width: 40, height: 14)),
            RecognizedWord(text: "\u{7}", rect: CGRect(x: 72, y: 220, width: 40, height: 14)),
            // Right to left: kept in reading order.
            RecognizedWord(text: "שלום", rect: CGRect(x: 72, y: 250, width: 40, height: 14)),
        ])])
        #expect(added == 3)
        let text = try doc.text(page: 0).string
        #expect(text.contains("smile\u{FFFD}") && !text.contains("\u{7}"))
        #expect(text.contains("Café"))
        #expect(!text.contains("flat") && !text.contains("squashed") && !text.contains("far"))
        #expect(text.contains("שלום"))
        // Too many words on a page is refused.
        let many = Array(repeating: RecognizedWord(text: "w", rect: CGRect(x: 72, y: 100, width: 10, height: 10)),
                         count: RecognizedPage.maxWords + 1)
        #expect(throws: EngineError.self) { try doc.setTextLayers([RecognizedPage(page: 0, words: many)]) }
        #expect(throws: EngineError.self) { try doc.setTextLayers([RecognizedPage(page: 99, words: [])]) }
    }

    @Test func removedEvenAfterEditingMergesTheContent() throws {
        let doc = try Corpus.open("scanned.pdf")
        try doc.setTextLayers([RecognizedPage(page: 4, words: [RecognizedWord(text: "Layer", rect: CGRect(x: 72, y: 300, width: 40, height: 14))])])
        // Editing the stamped text rewrites the page's content as one stream.
        let page = try doc.paragraphs(page: 4)
        let para = try #require(page.paragraphs.first { $0.text.contains("Page 5") })
        try doc.replaceText(page: 4, dropping: para.glyphs, fonts: [], runs: [], actionName: "Delete Text")
        #expect(try doc.text(page: 4).string.contains("Layer"))
        try doc.setTextLayers([RecognizedPage(page: 4, words: [RecognizedWord(text: "Again", rect: CGRect(x: 72, y: 300, width: 40, height: 14))])])
        let text = try doc.text(page: 4).string
        #expect(!text.contains("Layer") && text.contains("Again"), "\(text)")
    }
}
