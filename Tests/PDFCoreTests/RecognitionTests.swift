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
