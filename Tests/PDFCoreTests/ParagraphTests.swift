import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite struct ParagraphTests {
    private func texts(_ p: PageParagraphs) -> [String] { p.paragraphs.map(\.text) }

    @Test func paragraphsAndTheirShape() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let page = try doc.paragraphs(page: 0)
        #expect(texts(page) == [
            "A Heading in the Middle",
            "Set against the right margin",
            "The first paragraph has three lines, each drawn with\nits own text object, as many programs write them, and\nit ends here on the third line.",
            "2",
            "Justified text fills the whole width of the column by\nspreading out the spaces between its words, so that\nboth edges line up neatly down the page from top to\nthe bottom.",
            "A paragraph after it, in the same text\nobject as the justified one above.",
        ])
        let p = page.paragraphs
        #expect(p.map(\.alignment) == [.center, .right, .left, .left, .justified, .left])
        #expect(abs(p[2].lineSpacing - 14.4) < 0.1 && abs(p[4].lineSpacing - 14.4) < 0.1 && p[0].lineSpacing == 0)
        let editable = p.allSatisfy { $0.isEditable }
        #expect(editable)
        #expect(p[2].lines.allSatisfy { !$0.hardBreak })
        // Every character but the spaces text extraction adds is tied to its glyph,
        // and no glyph to two characters.
        for para in p {
            let tied = para.characters.allSatisfy { $0.glyph != nil || $0.scalar == " " }
            #expect(tied)
            let glyphs = para.characters.compactMap(\.glyph)
            #expect(Set(glyphs).count == glyphs.count)
        }
        // The justified paragraph and the one after it share a text object, but not glyphs.
        #expect(p[4].glyphs.isDisjoint(with: p[5].glyphs))
        // Fonts: Times, by its resource name.
        let font = try #require(p[2].characters.first?.font)
        #expect(page.fonts[font].resource == "F1" && page.fonts[font].isSerif)
    }

    @Test func columnsListsAndLeftovers() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let page = try doc.paragraphs(page: 1)
        let t = texts(page)
        // Columns side by side stay apart.
        #expect(t.contains("The left column has\nthree short lines of\nits own text here."))
        #expect(t.contains("The right column sits\non the same baselines\nas the left one does."))
        // A list item's lines join, though MuPDF puts them in separate blocks.
        #expect(t.contains("A bulleted item whose text wraps\nonto a second, indented line."))
        // Fake bold (drawn twice) is one paragraph.
        #expect(t.filter { $0 == "Fake bold drawn twice" }.count == 1)
        #expect(t.contains("Wide text in a CID font,\nover two lines."))
        // Short lines ended on purpose keep their breaks.
        let address = try #require(page.paragraphs.first { $0.text.hasPrefix("Ada Lovelace") })
        #expect(address.lines.first?.hardBreak == true)
    }

    @Test func whatCantBeEdited() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let page = try doc.paragraphs(page: 2)
        let reasons = Dictionary(uniqueKeysWithValues: page.paragraphs.map { ($0.text, $0.restriction) })
        #expect(reasons["Text inside a form"] == .unmatched)
        #expect(reasons["aaa"] == .type3)
        #expect(reasons["Invisible text"] == .invisible)
        #expect(reasons["Clipping text"] == .clipping)
        #expect(reasons["Turned text"] == .rotated)
    }

    @Test func rotatedAndCroppedPages() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        // Text drawn upright on a turned page is level, and editable.
        let turned = try doc.paragraphs(page: 3).paragraphs
        #expect(turned.map(\.text) == ["On a page turned a quarter,\nthis paragraph has two lines."])
        #expect(turned.first?.isEditable == true)
        let cropped = try doc.paragraphs(page: 4).paragraphs
        #expect(cropped.map(\.text) == ["On a cropped page, this\nparagraph has two lines."])
        // In page space, as everything else is (the crop box starts at 100, 92).
        #expect(abs((cropped.first?.rect.minX ?? 0) - 72) < 1)
    }

    @Test func fontCodes() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        // Times in WinAnsi: "A" is code 65, "é" 233; Greek isn't there.
        let codes = try doc.encode(["A", "é", "Ω", " "], inFont: "F1", page: 0)
        #expect(codes[0].code == [65] && codes[1].code == [233] && !codes[2].exists && codes[3].code == [32])
        #expect(abs(codes[0].advance - 0.722) < 0.01)
        // The CID font: two-byte codes.
        #expect(try doc.encode(["W"], inFont: "F2", page: 1).first?.code.count == 2)
        // No such font, or a Type3 one: nothing.
        #expect(try doc.encode(["A"], inFont: "F9", page: 0).allSatisfy { !$0.exists })
    }

    @Test func hostilePagesStayQuickAndNamesStayWhole() throws {
        let doc = try Corpus.open("parabomb.pdf")
        for page in [0, 1, 3] {
            let start = Date()
            _ = try doc.paragraphs(page: page)
            #expect(Date().timeIntervalSince(start) < 5, "page \(page) took too long")
        }
        let page = try doc.paragraphs(page: 2)
        // A 40-character font name is kept whole; one too long to keep isn't kept at all.
        #expect(page.fonts.map(\.resource).contains("F" + String(repeating: "x", count: 39)))
        #expect(page.fonts.contains { $0.resource.isEmpty })
        #expect(!page.fonts.contains { $0.resource.count > 100 })
        // Text drawn absurdly far away isn't a paragraph.
        #expect(!page.paragraphs.contains { $0.text.contains("Far away") })
        // Editing the paragraph in the long-named font draws it in that font, by its whole name.
        let para = try #require(page.paragraphs.first { $0.text == "A long font name" })
        let resource = "F" + String(repeating: "x", count: 39)
        let codes = try doc.encode(Array(para.text.unicodeScalars), inFont: resource, page: 2)
        let run = GlyphRun(font: 0, size: 12, fill: [0], baseline: para.lines[0].baseline,
                           glyphs: zip(para.characters, codes).map { GlyphRun.Glyph(code: UInt32($1.code.first ?? 32), length: 1, x: $0.origin.x, scalar: $0.scalar) })
        try doc.replaceText(page: 2, dropping: para.glyphs, fonts: [.page(resource: resource)], runs: [run], actionName: "Edit Text")
        #expect(try doc.paragraphs(page: 2).paragraphs.contains { $0.text == "A long font name" })
        // A name too long is refused rather than cut short.
        #expect(throws: EngineError.self) {
            try doc.replaceText(page: 2, dropping: [], fonts: [.page(resource: "F" + String(repeating: "y", count: 129))], runs: [run], actionName: "x")
        }
    }

    @Test func limits() throws {
        // Hundreds of thousands of operations: listed within the limits, quickly.
        let bomb = try Corpus.open("contentbomb.pdf")
        let start = Date()
        let page = try bomb.paragraphs(page: 0)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(page.paragraphs.count <= 10_000)
        // Content that inflates past the limit is refused, as for the rest of Edit Content.
        let zip = try Corpus.open("contentzip.pdf")
        #expect(throws: EngineError.self) { try zip.paragraphs(page: 0) }
    }
}
