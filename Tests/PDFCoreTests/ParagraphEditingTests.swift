import CoreGraphics
import CoreText
import Foundation
import PDFCore
import Testing

@Suite struct ParagraphEditingTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    /// The paragraph drawn again exactly as it was, in its own fonts: one run
    /// per line and font (spaces text extraction added aren't glyphs).
    private func sameRuns(_ doc: EngineDocument, _ para: Paragraph, in page: PageParagraphs) throws -> ([TextFont], [GlyphRun]) {
        var fonts: [TextFont] = [], index: [Int: Int] = [:], runs: [GlyphRun] = []
        for line in para.lines {
            var run: GlyphRun?
            for c in para.characters[line.range] {
                guard let f = c.font else { continue }
                let resource = page.fonts[f].resource
                let code = try #require(try doc.encode([c.scalar], inFont: resource, page: para.page).first)
                let font = index[f] ?? {
                    fonts.append(.page(resource: resource))
                    index[f] = fonts.count - 1
                    return fonts.count - 1
                }()
                let value = code.code.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let glyph = GlyphRun.Glyph(code: value, length: code.code.count, x: c.origin.x, scalar: c.scalar)
                if run?.font == font, run?.size == c.size {
                    run?.glyphs.append(glyph)
                } else {
                    if let run { runs.append(run) }
                    run = GlyphRun(font: font, size: c.size, fill: c.fill, baseline: c.origin.y, glyphs: [glyph])
                }
            }
            if let run { runs.append(run) }
        }
        return (fonts, runs)
    }

    /// Every character's origin on the page, by text.
    private func origins(_ page: PageParagraphs) -> [String: [CGPoint]] {
        Dictionary(page.paragraphs.map { ($0.text, $0.characters.map(\.origin)) }, uniquingKeysWith: { a, _ in a })
    }

    private func close(_ a: [CGPoint]?, _ b: [CGPoint]?, within: CGFloat = 0.01) -> Bool {
        guard let a, let b, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0.x - $1.x) <= within && abs($0.y - $1.y) <= within }
    }

    @Test func sameTextInSameTextOut() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let before = try doc.paragraphs(page: 0)
        // The 3-line paragraph, and the justified one sharing a text object with the next.
        for index in [2, 4] {
            let page = try doc.paragraphs(page: 0)
            let para = try #require(page.paragraphs.first { $0.text == before.paragraphs[index].text })
            let (fonts, runs) = try sameRuns(doc, para, in: page)
            try doc.replaceText(page: 0, dropping: para.glyphs, fonts: fonts, runs: runs, actionName: "Edit Text")
        }
        let after = try doc.paragraphs(page: 0)
        #expect(Set(after.paragraphs.map(\.text)) == Set(before.paragraphs.map(\.text)))
        let was = origins(before), now = origins(after)
        for (text, points) in was { #expect(close(points, now[text]), "\(text) moved") }
        // Still drawn in the page's own font: no font was added.
        #expect(after.fonts.map(\.resource).allSatisfy { $0 == "F1" })
        #expect(doc.canUndo)
    }

    @Test func fakeBoldLeavesNoGhost() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let page = try doc.paragraphs(page: 1)
        let bold = try #require(page.paragraphs.first { $0.text == "Fake bold drawn twice" })
        try doc.replaceText(page: 1, dropping: bold.glyphs, fonts: [], runs: [], actionName: "Delete Text")
        let text = try doc.text(page: 1).string
        #expect(!text.contains("Fake bold"))
        #expect(text.contains("An underlined line") && text.contains("The left column has"))
    }

    @Test func newCharactersEmbedOneSubset() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let page = try doc.paragraphs(page: 0)
        let para = page.paragraphs[2]
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let text = "Ωmega and Ψ"
        var unichars = Array(text.utf16), glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        #expect(CTFontGetGlyphsForCharacters(helvetica, &unichars, &glyphs, unichars.count))
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(helvetica, .horizontal, glyphs, &advances, glyphs.count)
        var x = para.lines[0].rect.minX
        let run = GlyphRun(font: 0, size: 12, fill: [0], baseline: para.lines[0].baseline,
                           glyphs: zip(zip(glyphs, text.unicodeScalars), advances).map { pair in
                               defer { x += pair.1.width }
                               return GlyphRun.Glyph(code: UInt32(pair.0.0), x: x, scalar: pair.0.1)
                           })
        let before = try Data(contentsOf: Corpus.root.appendingPathComponent("paragraphs.pdf")).count
        try doc.replaceText(page: 0, dropping: para.glyphs, fonts: [.embedded(FontFile.data(for: helvetica))], runs: [run], actionName: "Edit Text")
        let after = try doc.text(page: 0).string
        #expect(after.contains("Ωmega and Ψ") && !after.contains("The first paragraph"))
        #expect(after.contains("Justified text fills"))
        let out = temporaryURL("embedded.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(try EngineDocument(url: out).text(page: 0).string.contains("Ωmega and Ψ"))
        // A subset of Helvetica, not the whole of it.
        #expect(try Data(contentsOf: out).count - before < 60_000)
    }

    private func installed(_ name: String) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == name ? font : nil
    }

    private func run(_ font: CTFont, _ text: String, x: CGFloat, baseline: CGFloat) -> GlyphRun {
        var unichars = Array(text.utf16), glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        CTFontGetGlyphsForCharacters(font, &unichars, &glyphs, unichars.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var at = x
        return GlyphRun(font: 0, size: 12, fill: [0], baseline: baseline, glyphs: zip(zip(glyphs, text.unicodeScalars), advances).map { pair in
            defer { at += pair.1.width }
            return GlyphRun.Glyph(code: UInt32(pair.0.0), x: at, scalar: pair.0.1)
        })
    }

    @Test func cffFontsRoundTripAndCIDKeyedOnesAreRefused() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let para = try doc.paragraphs(page: 0).paragraphs[2]
        if let cff = installed("AdelleSansDevanagari-Regular") {
            try doc.replaceText(page: 0, dropping: para.glyphs, fonts: [.embedded(FontFile.data(for: cff))],
                                runs: [run(cff, "Hello from CFF", x: 72, baseline: para.lines[0].baseline)], actionName: "Edit Text")
            #expect(try doc.text(page: 0).string.contains("Hello from CFF"))
        }
        if let cid = installed("AppleSDGothicNeo-Regular") {
            #expect(throws: EngineError.self) {
                try doc.replaceText(page: 0, dropping: [], fonts: [.embedded(FontFile.data(for: cid))],
                                    runs: [run(cid, "Hello", x: 72, baseline: 500)], actionName: "Edit Text")
            }
        }
    }

    @Test func turnedAndCroppedPagesStayUpright() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        for pageIndex in [3, 4] {
            let page = try doc.paragraphs(page: pageIndex)
            let para = try #require(page.paragraphs.first)
            let (fonts, runs) = try sameRuns(doc, para, in: page)
            try doc.replaceText(page: pageIndex, dropping: para.glyphs, fonts: fonts, runs: runs, actionName: "Edit Text")
            let again = try #require(try doc.paragraphs(page: pageIndex).paragraphs.first)
            #expect(again.text == para.text && again.isEditable)
            #expect(close(again.characters.map(\.origin), para.characters.map(\.origin)))
        }
    }

    @Test func undoAndRedo() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        try doc.prepareForEditing(password: nil)
        let page = try doc.paragraphs(page: 0)
        let para = page.paragraphs[2]
        try doc.replaceText(page: 0, dropping: para.glyphs, fonts: [], runs: [], actionName: "Delete Text")
        #expect(try !doc.text(page: 0).string.contains("The first paragraph"))
        try doc.undo()
        let back = try doc.paragraphs(page: 0)
        #expect(back.paragraphs.map(\.text) == page.paragraphs.map(\.text))
        #expect(close(back.paragraphs[2].characters.map(\.origin), para.characters.map(\.origin)))
        try doc.redo()
        #expect(try !doc.text(page: 0).string.contains("The first paragraph"))
    }

    @Test func savesStayIncremental() throws {
        let source = Corpus.root.appendingPathComponent("paragraphs.pdf")
        let doc = try EngineDocument(url: source)
        let page = try doc.paragraphs(page: 0)
        let (fonts, runs) = try sameRuns(doc, page.paragraphs[2], in: page)
        try doc.replaceText(page: 0, dropping: page.paragraphs[2].glyphs, fonts: fonts, runs: runs, actionName: "Edit Text")
        let out = temporaryURL("incremental.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let original = try Data(contentsOf: source), saved = try Data(contentsOf: out)
        #expect(saved.starts(with: original))
    }

    @Test func badInputIsRefused() throws {
        let doc = try Corpus.open("paragraphs.pdf")
        let glyph = GlyphRun.Glyph(code: 65, length: 1, x: 72, scalar: "A")
        // A run naming a font that wasn't given, or a page font that isn't there.
        #expect(throws: EngineError.self) {
            try doc.replaceText(page: 0, dropping: [], fonts: [], runs: [GlyphRun(font: 0, size: 12, fill: [0], baseline: 100, glyphs: [glyph])], actionName: "x")
        }
        #expect(throws: EngineError.self) {
            try doc.replaceText(page: 0, dropping: [], fonts: [.page(resource: "Nope")], runs: [GlyphRun(font: 0, size: 12, fill: [0], baseline: 100, glyphs: [glyph])], actionName: "x")
        }
        // Not a font at all.
        #expect(throws: EngineError.self) {
            try doc.replaceText(page: 0, dropping: [], fonts: [.embedded(Data(repeating: 7, count: 400))], runs: [GlyphRun(font: 0, size: 12, fill: [0], baseline: 100, glyphs: [glyph])], actionName: "x")
        }
        // Too many glyphs.
        let many = GlyphRun(font: 0, size: 12, fill: [0], baseline: 100, glyphs: Array(repeating: glyph, count: 100_001))
        #expect(throws: EngineError.self) {
            try doc.replaceText(page: 0, dropping: [], fonts: [.page(resource: "F1")], runs: [many], actionName: "x")
        }
    }
}
