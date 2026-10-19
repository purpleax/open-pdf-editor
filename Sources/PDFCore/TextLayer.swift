import CoreGraphics
import Foundation
import MuPDFBridge

/// What a page's contents draw (not its comments or fields): how much text,
/// seen and unseen, and how much of the page images cover.
public struct PageTextInfo: Sendable, Equatable {
    /// Characters drawn so they can be seen.
    public let visibleCharacters: Int
    /// Characters drawn invisibly, as a text layer from OCR is.
    public let invisibleCharacters: Int
    /// The share of the page (0–1) covered by images.
    public let imageCoverage: Double

    public init(visibleCharacters: Int, invisibleCharacters: Int, imageCoverage: Double) {
        self.visibleCharacters = visibleCharacters
        self.invisibleCharacters = invisibleCharacters
        self.imageCoverage = imageCoverage
    }

    /// No text worth the name: almost none visible (a stamped page number is
    /// allowed) and none recognised already. What "pages without text" means.
    public var lacksText: Bool { visibleCharacters < 20 && invisibleCharacters == 0 }

    /// A picture of a page with no text to search or copy: mostly image.
    public var isScan: Bool { lacksText && imageCoverage > 0.5 }
}

extension EngineDocument {
    public func textInfo(page: Int) throws -> PageTextInfo {
        var info = opdf_text_info()
        var error = opdf_error()
        guard opdf_page_text_info(handle, Int32(page), &info, &error) else { throw EngineError(error) }
        return PageTextInfo(visibleCharacters: Int(info.visible), invisibleCharacters: Int(info.invisible),
                            imageCoverage: Double(info.image_coverage))
    }
}

/// A word recognised on a page: its text and its box in page space (points,
/// y down). The baseline runs along the bottom edge, from `lowerLeft` to
/// `lowerRight`; a word followed by another on its line ends with a space,
/// its box reaching to the next word.
public struct RecognizedWord: Sendable, Equatable {
    public var text: String
    public var upperLeft: CGPoint
    public var upperRight: CGPoint
    public var lowerLeft: CGPoint
    public var lowerRight: CGPoint

    public init(text: String, upperLeft: CGPoint, upperRight: CGPoint, lowerLeft: CGPoint, lowerRight: CGPoint) {
        self.text = text
        self.upperLeft = upperLeft
        self.upperRight = upperRight
        self.lowerLeft = lowerLeft
        self.lowerRight = lowerRight
    }

    /// An upright word filling `rect`.
    public init(text: String, rect: CGRect) {
        self.init(text: text, upperLeft: CGPoint(x: rect.minX, y: rect.minY), upperRight: CGPoint(x: rect.maxX, y: rect.minY),
                  lowerLeft: CGPoint(x: rect.minX, y: rect.maxY), lowerRight: CGPoint(x: rect.maxX, y: rect.maxY))
    }

    /// The text as the layer's font can carry it: NFC, characters beyond
    /// the Basic Multilingual Plane as U+FFFD, controls left out.
    var layerCodes: [UInt16] {
        var codes: [UInt16] = []
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || (0x7F..<0xA0).contains(v) || v == 0xFFFE || v == 0xFFFF { continue }
            codes.append(v > 0xFFFF ? 0xFFFD : UInt16(v))
        }
        return codes
    }

    /// True when most of its letters are Hebrew or Arabic (read right to left).
    var isRightToLeft: Bool {
        var rtl = 0, ltr = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            default: ltr += 1
            }
        }
        return rtl > ltr
    }
}

/// The words recognised on one page.
public struct RecognizedPage: Sendable, Equatable {
    public var page: Int
    public var words: [RecognizedWord]

    public init(page: Int, words: [RecognizedWord]) {
        self.page = page
        self.words = words
    }

    /// The most words put on one page.
    public static let maxWords = 20_000
}

extension EngineDocument {
    /// Puts recognised text on pages as invisible text that can be searched,
    /// selected and copied, replacing each page's earlier recognised text.
    /// Words the page already has as real text are left out. One undoable
    /// step; returns the number of words added.
    @discardableResult
    public func setTextLayers(_ pages: [RecognizedPage]) throws -> Int {
        var codes: [[UInt16]] = []
        for page in pages {
            guard page.words.count <= RecognizedPage.maxWords else {
                throw EngineError(code: -1, message: "Too many words on page \(page.page + 1)")
            }
            codes.append(contentsOf: page.words.map(\.layerCodes))
        }
        // All the text in one buffer, and all the words in another.
        let text = UnsafeMutablePointer<UInt16>.allocate(capacity: max(1, codes.reduce(0) { $0 + $1.count }))
        let words = UnsafeMutablePointer<opdf_ocr_word>.allocate(capacity: max(1, codes.count))
        defer {
            text.deallocate()
            words.deallocate()
        }
        var layers: [opdf_text_layer] = []
        var offset = 0, index = 0, word = 0
        for page in pages {
            let first = word
            for w in page.words {
                let c = codes[index]
                index += 1
                guard !c.isEmpty else { continue }
                (text + offset).initialize(from: c, count: c.count)
                var out = opdf_ocr_word()
                out.text = UnsafePointer(text + offset)
                out.length = Int32(c.count)
                out.quad = (Float(w.upperLeft.x), Float(w.upperLeft.y), Float(w.upperRight.x), Float(w.upperRight.y),
                            Float(w.lowerLeft.x), Float(w.lowerLeft.y), Float(w.lowerRight.x), Float(w.lowerRight.y))
                out.right_to_left = w.isRightToLeft
                (words + word).initialize(to: out)
                offset += c.count
                word += 1
            }
            layers.append(opdf_text_layer(page: Int32(page.page), words: UnsafePointer(words + first), count: Int32(word - first)))
        }
        var added: Int32 = 0
        var error = opdf_error()
        guard opdf_text_layers_set(handle, layers, Int32(layers.count), &added, &error) else { throw EngineError(error) }
        return Int(added)
    }
}
