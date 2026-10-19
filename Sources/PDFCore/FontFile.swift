import CoreGraphics
import CoreText
import Foundation

/// System fonts for edited text: choosing one close to a run's font, and
/// turning it into a standalone font file (one face, even from a
/// collection) that the engine subsets and embeds.
public enum FontFile {
    /// The font's tables assembled as an sfnt (TrueType or OpenType) file.
    public static func data(for font: CTFont) throws -> Data {
        guard let array = CTFontCopyAvailableTables(font, []) else { throw failure() }
        var tables: [(tag: UInt32, data: Data)] = []
        for i in 0..<CFArrayGetCount(array) {
            // The array holds the tags themselves, not objects.
            let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(array, i)))
            guard let table = CTFontCopyTable(font, tag, []) as Data? else { continue }
            tables.append((tag, table))
        }
        tables.sort { $0.tag < $1.tag }
        guard !tables.isEmpty else { throw failure() }
        func be32(_ v: UInt32, into d: inout Data) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func be16(_ v: UInt16, into d: inout Data) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func checksum(_ d: Data) -> UInt32 {
            var sum: UInt32 = 0
            var padded = d
            while padded.count % 4 != 0 { padded.append(0) }
            padded.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count, by: 4) {
                    sum = sum &+ (UInt32(raw[i]) << 24 | UInt32(raw[i + 1]) << 16 | UInt32(raw[i + 2]) << 8 | UInt32(raw[i + 3]))
                }
            }
            return sum
        }
        let cff = UInt32(0x4346_4620)   // 'CFF '
        var out = Data()
        be32(tables.contains { $0.tag == cff } ? 0x4F54_544F : 0x0001_0000, into: &out)
        let n = tables.count
        var power = 1, log = 0
        while power * 2 <= n { power *= 2; log += 1 }
        be16(UInt16(n), into: &out)
        be16(UInt16(power * 16), into: &out)
        be16(UInt16(log), into: &out)
        be16(UInt16(n * 16 - power * 16), into: &out)
        var offset = 12 + 16 * n
        for table in tables {
            be32(table.tag, into: &out)
            be32(checksum(table.data), into: &out)
            be32(UInt32(offset), into: &out)
            be32(UInt32(table.data.count), into: &out)
            offset += (table.data.count + 3) & ~3
        }
        for table in tables {
            out.append(table.data)
            while out.count % 4 != 0 { out.append(0) }
        }
        return out
    }

    /// A system font for text that a run's own font can't draw: the run's
    /// font if it is installed, else one of the same style, else whatever
    /// system font covers `text`. Nil if none covers it all.
    public static func fallback(for run: TextRun, covering text: String) -> CTFont? {
        let size = max(run.size, 1)
        var font: CTFont
        let name = run.fontName.split(separator: "+").last.map(String.init) ?? run.fontName
        let installed = CTFontCreateWithName(name as CFString, size, nil)
        if (CTFontCopyPostScriptName(installed) as String).caseInsensitiveCompare(name) == .orderedSame {
            font = installed
        } else {
            let family = run.isMonospaced ? "Menlo" : run.isSerif ? "Times New Roman" : "Helvetica Neue"
            font = CTFontCreateWithName(family as CFString, size, nil)
            var traits = CTFontSymbolicTraits()
            if run.isBold { traits.insert(.traitBold) }
            if run.isItalic { traits.insert(.traitItalic) }
            if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) { font = styled }
        }
        if covers(font, text) { return font }
        let utf16 = text as NSString
        let other = CTFontCreateForString(font, utf16, CFRange(location: 0, length: utf16.length))
        return covers(other, text) ? other : nil
    }

    /// The font has a glyph for every character of the text.
    public static func covers(_ font: CTFont, _ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return true }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
    }

    private static func failure() -> EngineError {
        EngineError(code: -1, message: "That font couldn't be read.")
    }
}
