import CoreGraphics
import Foundation
import MuPDFBridge

/// A paragraph of a page's text, as MuPDF groups it, with each character
/// tied to the glyph that draws it, so it can be edited as a whole.
public struct Paragraph: Equatable, Sendable {
    public enum Restriction: Int, Sendable {
        case none = 0, type3, vertical, rotated, invisible, clipping, unmatched, rightToLeft, tooLong
    }

    public enum Alignment: Int, Sendable {
        case left = 0, center, right, justified
    }

    /// Which glyph draws a character: a text operation and its place in it.
    public struct Glyph: Hashable, Sendable {
        public let op: Int
        public let index: Int
    }

    public struct Character: Equatable, Sendable {
        public let scalar: Unicode.Scalar
        /// Into `PageParagraphs.fonts`; nil for a space added by text extraction.
        public let font: Int?
        public let glyph: Glyph?
        /// Page space, y down.
        public let origin: CGPoint
        /// Along the baseline, in points.
        public let advance: CGFloat
        public let size: CGFloat
        /// The fill as drawn: 1 (grey), 3 (RGB) or 4 (CMYK) components; empty for anything else.
        public let fill: [CGFloat]
        public let rect: CGRect

        public var color: PDFColor? {
            switch fill.count {
            case 1: PDFColor(red: fill[0], green: fill[0], blue: fill[0])
            case 3: PDFColor(red: fill[0], green: fill[1], blue: fill[2])
            case 4: PDFColor(red: (1 - fill[0]) * (1 - fill[3]), green: (1 - fill[1]) * (1 - fill[3]), blue: (1 - fill[2]) * (1 - fill[3]))
            default: nil
            }
        }
    }

    public struct Line: Equatable, Sendable {
        public let rect: CGRect
        public let baseline: CGFloat
        /// Its characters, in the paragraph's.
        public let range: Range<Int>
        /// Ended on purpose rather than wrapped: the next line's first word
        /// would have fitted on it.
        public let hardBreak: Bool
    }

    public let page: Int
    /// Its place on the page, in reading order.
    public let index: Int
    public let rect: CGRect
    public let lines: [Line]
    public let characters: [Character]
    public let alignment: Alignment
    /// Baseline to baseline; 0 for one line.
    public let lineSpacing: CGFloat
    /// How far the first line starts beyond the others.
    public let indent: CGFloat
    public let restriction: Restriction

    public var isEditable: Bool { restriction == .none }

    public var text: String {
        lines.map { line in String(String.UnicodeScalarView(characters[line.range].map(\.scalar))) }.joined(separator: "\n")
    }

    /// The glyphs drawing it.
    public var glyphs: Set<Glyph> { Set(characters.compactMap(\.glyph)) }
}

/// A font drawing some of a page's paragraphs.
public struct ParagraphFont: Equatable, Sendable {
    /// Its name in the page's /Font resources ("" when set another way).
    public let resource: String
    /// The font's own name (no subset prefix).
    public let name: String
    public let isSerif, isBold, isItalic, isMonospaced: Bool
}

public struct PageParagraphs: Equatable, Sendable {
    public let paragraphs: [Paragraph]
    public let fonts: [ParagraphFont]

    /// The paragraph at the point (page space), if any: on one of its lines,
    /// or anywhere in its box (between its lines, beside a short one).
    public func paragraph(at point: CGPoint, tolerance: CGFloat = 2) -> Paragraph? {
        paragraphs.first { p in p.lines.contains { $0.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) } }
            ?? paragraphs.first { $0.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }
}

/// How a character is drawn in one of a page's fonts.
public struct FontCode: Equatable, Sendable {
    /// The code's bytes; empty when the font has no glyph for the character.
    public let code: [UInt8]
    /// In em.
    public let advance: CGFloat

    public var exists: Bool { !code.isEmpty }
}

extension EngineDocument {
    public func paragraphs(page: Int) throws -> PageParagraphs {
        var o = opdf_paragraphs()
        var error = opdf_error()
        guard opdf_paragraphs_load(handle, Int32(page), &o, &error) else { throw EngineError(error) }
        defer { opdf_paragraphs_free(&o) }
        let fonts = UnsafeBufferPointer(start: o.fonts, count: Int(o.font_count)).map { f in
            ParagraphFont(resource: f.resource.map { String(cString: $0) } ?? "", name: f.name.map { String(cString: $0) } ?? "",
                          isSerif: f.serif, isBold: f.bold, isItalic: f.italic, isMonospaced: f.monospaced)
        }
        let paragraphs = UnsafeBufferPointer(start: o.items, count: Int(o.count)).enumerated().map { index, p in
            let characters = UnsafeBufferPointer(start: p.chars, count: Int(p.char_count)).map { c in
                let n = Int(c.color_n)
                let all = [c.color.0, c.color.1, c.color.2, c.color.3].map { CGFloat($0) }
                return Paragraph.Character(
                    scalar: Unicode.Scalar(UInt32(bitPattern: c.c)) ?? "\u{FFFD}",
                    font: c.font >= 0 && Int(c.font) < fonts.count ? Int(c.font) : nil,
                    glyph: c.op >= 0 ? Paragraph.Glyph(op: Int(c.op), index: Int(c.glyph)) : nil,
                    origin: CGPoint(x: CGFloat(c.x), y: CGFloat(c.y)), advance: CGFloat(c.advance), size: CGFloat(c.size),
                    fill: [1, 3, 4].contains(n) ? Array(all.prefix(n)) : [], rect: CGRect(c.rect))
            }
            let lines = UnsafeBufferPointer(start: p.lines, count: Int(p.line_count)).map { l in
                Paragraph.Line(rect: CGRect(l.rect), baseline: CGFloat(l.baseline), range: Int(l.first)..<Int(l.first + l.count),
                               hardBreak: l.hard_break)
            }
            return Paragraph(page: page, index: index, rect: CGRect(p.rect), lines: lines, characters: characters,
                             alignment: Paragraph.Alignment(rawValue: Int(p.align)) ?? .left,
                             lineSpacing: CGFloat(p.line_spacing), indent: CGFloat(p.indent),
                             restriction: Paragraph.Restriction(rawValue: Int(p.not_editable)) ?? .tooLong)
        }
        return PageParagraphs(paragraphs: paragraphs, fonts: fonts)
    }

    /// How each character is drawn in the page's font `resource`.
    public func encode(_ scalars: [Unicode.Scalar], inFont resource: String, page: Int) throws -> [FontCode] {
        var codes = [opdf_font_code](repeating: opdf_font_code(), count: scalars.count)
        var error = opdf_error()
        let chars = scalars.map { Int32(bitPattern: $0.value) }
        guard opdf_font_encode(handle, Int32(page), resource, chars, Int32(chars.count), &codes, &error) else { throw EngineError(error) }
        return codes.map { c in
            let bytes = [c.code.0, c.code.1, c.code.2, c.code.3]
            return FontCode(code: Array(bytes.prefix(Int(max(0, min(4, c.len))))), advance: CGFloat(c.advance))
        }
    }
}

/// A font for new text.
public enum TextFont: Equatable, Sendable {
    /// One of the page's fonts, by its resource name: glyphs are its codes.
    case page(resource: String)
    /// An sfnt to embed (subset): glyphs are glyph ids.
    case embedded(Data)
}

/// Text laid out already: glyphs on one baseline in one font, size and colour.
public struct GlyphRun: Equatable, Sendable {
    public struct Glyph: Equatable, Sendable {
        /// The code in a page font, or the glyph id in an embedded one.
        public var code: UInt32
        /// Bytes of the code (page fonts).
        public var length: Int
        /// The glyph's origin across the page (page space).
        public var x: CGFloat
        /// The character it stands for.
        public var scalar: Unicode.Scalar

        public init(code: UInt32, length: Int = 2, x: CGFloat, scalar: Unicode.Scalar) {
            self.code = code
            self.length = length
            self.x = x
            self.scalar = scalar
        }
    }

    public var font: Int
    public var size: CGFloat
    /// 1 (grey), 3 (RGB) or 4 (CMYK) components.
    public var fill: [CGFloat]
    /// The baseline, page space (y down).
    public var baseline: CGFloat
    public var glyphs: [Glyph]
    public var underline: Bool

    public init(font: Int, size: CGFloat, fill: [CGFloat], baseline: CGFloat, glyphs: [Glyph], underline: Bool = false) {
        self.font = font
        self.size = size
        self.fill = fill
        self.baseline = baseline
        self.glyphs = glyphs
        self.underline = underline
    }
}

extension EngineDocument {
    /// Takes the glyphs out of the page (with any copies drawn on them, such
    /// as fake bold), leaving the rest where it was, and draws the runs: one
    /// undoable step.
    public func replaceText(page: Int, dropping: Set<Paragraph.Glyph>, fonts: [TextFont], runs: [GlyphRun], actionName: String) throws {
        let drops = dropping.map { opdf_glyph_ref(op: Int32($0.op), glyph: Int32($0.index)) }
        var codes: [UInt32] = [], lens: [UInt8] = [], xs: [Float] = [], unicode: [Int32] = []
        var cRuns: [opdf_glyph_run] = []
        for run in runs {
            var r = opdf_glyph_run()
            r.font = Int32(run.font)
            r.size = Float(run.size)
            r.color_n = Int32(run.fill.count)
            let fill = run.fill.map(Float.init) + [0, 0, 0, 0]
            r.color = (fill[0], fill[1], fill[2], fill[3])
            r.y = Float(run.baseline)
            r.first = Int32(codes.count)
            r.count = Int32(run.glyphs.count)
            r.underline = run.underline
            for g in run.glyphs {
                codes.append(g.code)
                lens.append(UInt8(clamping: g.length))
                xs.append(Float(g.x))
                unicode.append(Int32(bitPattern: g.scalar.value))
            }
            cRuns.append(r)
        }
        // Font names and data, kept alive for the call.
        let names: [UnsafeMutablePointer<CChar>?] = fonts.map { if case let .page(resource) = $0 { strdup(resource) } else { nil } }
        let datas: [Data?] = fonts.map { if case let .embedded(data) = $0 { data } else { nil } }
        defer { names.forEach { free($0) } }
        var error = opdf_error()
        let ok = withEmbeddedFonts(datas) { pointers in
            var cFonts = fonts.indices.map { i in
                opdf_text_font(resource: names[i].map { UnsafePointer($0) }, data: pointers[i].0, len: pointers[i].1)
            }
            return opdf_paragraph_replace(handle, Int32(page), drops, Int32(drops.count), &cFonts, Int32(cFonts.count),
                                          cRuns, Int32(cRuns.count), codes, lens, xs, unicode, Int32(codes.count), actionName, &error)
        }
        guard ok else { throw EngineError(error) }
    }

    /// Pointers to each font's bytes (nil for page fonts) for the call.
    private func withEmbeddedFonts<T>(_ datas: [Data?], _ body: ([(UnsafePointer<UInt8>?, Int)]) -> T) -> T {
        func next(_ i: Int, _ acc: [(UnsafePointer<UInt8>?, Int)]) -> T {
            if i == datas.count { return body(acc) }
            guard let data = datas[i] else { return next(i + 1, acc + [(nil, 0)]) }
            return data.withUnsafeBytes { bytes in
                next(i + 1, acc + [(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)])
            }
        }
        return next(0, [])
    }
}
