import CoreGraphics
import Foundation
import MuPDFBridge

/// A character's outline on the page, in page space.
public struct Quad: Sendable, Equatable {
    public var upperLeft, upperRight, lowerLeft, lowerRight: CGPoint

    public var bounds: CGRect {
        let xs = [upperLeft.x, upperRight.x, lowerLeft.x, lowerRight.x]
        let ys = [upperLeft.y, upperRight.y, lowerLeft.y, lowerRight.y]
        let minX = xs.min()!, minY = ys.min()!
        return CGRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
    }

    public var center: CGPoint {
        CGPoint(x: (upperLeft.x + upperRight.x + lowerLeft.x + lowerRight.x) / 4,
                y: (upperLeft.y + upperRight.y + lowerLeft.y + lowerRight.y) / 4)
    }

    public func contains(_ p: CGPoint) -> Bool {
        // Inside when on the same side of all four edges (corners in order ul, ur, lr, ll).
        let corners = [upperLeft, upperRight, lowerRight, lowerLeft]
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross != 0 {
                if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
            }
        }
        return sign != 0
    }
}

public struct TextChar: Sendable {
    public let scalar: Unicode.Scalar
    public let line: Int
    public let block: Int
    public let quad: Quad

    init(_ c: opdf_char) {
        scalar = Unicode.Scalar(UInt32(bitPattern: c.c)) ?? "\u{FFFD}"
        line = Int(c.line)
        block = Int(c.block)
        let q = c.quad
        quad = Quad(upperLeft: CGPoint(x: CGFloat(q.0), y: CGFloat(q.1)),
                    upperRight: CGPoint(x: CGFloat(q.2), y: CGFloat(q.3)),
                    lowerLeft: CGPoint(x: CGFloat(q.4), y: CGFloat(q.5)),
                    lowerRight: CGPoint(x: CGFloat(q.6), y: CGFloat(q.7)))
    }

    public init(scalar: Unicode.Scalar, line: Int, block: Int, quad: Quad) {
        self.scalar = scalar
        self.line = line
        self.block = block
        self.quad = quad
    }
}

public struct TextLine: Sendable {
    /// Character indices of the line.
    public let range: Range<Int>
    public let bounds: CGRect
    public let block: Int
}

/// Search options for `PageText.search`.
public struct SearchOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let matchCase = SearchOptions(rawValue: 1)
    public static let wholeWords = SearchOptions(rawValue: 2)
}

/// A page's text in reading order, with where each character is.
///
/// Positions between characters ("carets") run from 0 to `chars.count`; a
/// selection is a range of character indices.
public final class PageText: Sendable {
    public let chars: [TextChar]
    public let lines: [TextLine]
    /// The text for copying: lines end with a newline.
    public let string: String
    /// The same text with every line break as a space, for searching. Same
    /// length (in UTF-16) as `string`.
    let searchString: String
    /// The UTF-16 offset at which each character starts in `string`.
    let charOffsets: [Int]
    /// For each UTF-16 unit of `string`: the character it belongs to, or -1
    /// for a line break added between lines.
    let unitToChar: [Int32]

    public init(chars: [TextChar]) {
        self.chars = chars
        var copy: [UInt16] = []
        var search: [UInt16] = []
        var offsets: [Int] = []
        var units: [Int32] = []
        var lines: [TextLine] = []
        copy.reserveCapacity(chars.count + chars.count / 40)
        var lineStart = 0
        var lineBounds = CGRect.null
        for (i, ch) in chars.enumerated() {
            if i > 0 && ch.line != chars[i - 1].line {
                lines.append(TextLine(range: lineStart..<i, bounds: lineBounds, block: chars[i - 1].block))
                lineStart = i
                lineBounds = .null
                copy.append(10)
                search.append(32)
                units.append(-1)
            }
            lineBounds = lineBounds.union(ch.quad.bounds)
            offsets.append(copy.count)
            for unit in String(ch.scalar).utf16 {
                copy.append(unit)
                search.append(unit == 0xA0 ? 32 : unit)
                units.append(Int32(i))
            }
        }
        if !chars.isEmpty {
            lines.append(TextLine(range: lineStart..<chars.count, bounds: lineBounds, block: chars[chars.count - 1].block))
        }
        self.lines = lines
        string = String(utf16CodeUnits: copy, count: copy.count)
        searchString = String(utf16CodeUnits: search, count: search.count)
        charOffsets = offsets
        unitToChar = units
    }

    public var isEmpty: Bool { chars.isEmpty }

    /// The UTF-16 range in `string` of a range of characters.
    public func utf16Range(of range: Range<Int>) -> NSRange {
        guard !range.isEmpty, range.lowerBound < chars.count else {
            let at = range.lowerBound < charOffsets.count ? charOffsets[range.lowerBound] : (string as NSString).length
            return NSRange(location: at, length: 0)
        }
        let start = charOffsets[range.lowerBound]
        let last = min(range.upperBound, chars.count) - 1
        let end = last + 1 < charOffsets.count ? charOffsets[last + 1] : (string as NSString).length
        // Don't include the line break that follows the last character.
        var length = end - start
        if end > start, unitToChar[end - 1] == -1 { length -= 1 }
        return NSRange(location: start, length: length)
    }

    /// The characters covered by a UTF-16 range of `string`.
    public func charRange(of range: NSRange) -> Range<Int>? {
        guard range.length > 0 else { return nil }
        var first: Int?
        var last: Int?
        for unit in range.location..<min(range.location + range.length, unitToChar.count) {
            let c = Int(unitToChar[unit])
            if c >= 0 {
                if first == nil { first = c }
                last = c
            }
        }
        guard let first, let last else { return nil }
        return first..<(last + 1)
    }

    /// The text of a range of characters, with line breaks.
    public func text(in range: Range<Int>) -> String {
        (string as NSString).substring(with: utf16Range(of: range))
    }

    // MARK: Geometry

    /// The character whose outline contains the point, if any.
    public func charIndex(at point: CGPoint) -> Int? {
        for line in lines where line.bounds.insetBy(dx: -1, dy: -1).contains(point) {
            for i in line.range where chars[i].quad.contains(point) { return i }
        }
        return nil
    }

    /// The caret position nearest to the point: 0...chars.count.
    public func caret(at point: CGPoint) -> Int? {
        guard let line = nearestLine(to: point) else { return nil }
        let first = chars[line.range.lowerBound].quad
        var dx = first.upperRight.x - first.upperLeft.x
        var dy = first.upperRight.y - first.upperLeft.y
        let length = (dx * dx + dy * dy).squareRoot()
        if length > 0.001 { dx /= length; dy /= length } else { dx = 1; dy = 0 }
        let origin = first.upperLeft
        func along(_ p: CGPoint) -> CGFloat { (p.x - origin.x) * dx + (p.y - origin.y) * dy }
        let target = along(point)
        for i in line.range where along(chars[i].quad.center) > target { return i }
        return line.range.upperBound
    }

    func nearestLine(to point: CGPoint) -> TextLine? {
        var best: TextLine?
        var bestDistance = CGFloat.infinity
        for line in lines {
            let b = line.bounds
            let dx = max(b.minX - point.x, 0, point.x - b.maxX)
            let dy = max(b.minY - point.y, 0, point.y - b.maxY)
            // Being level with a line counts for more than being near it sideways.
            let distance = dy * 4 + dx
            if distance < bestDistance {
                bestDistance = distance
                best = line
            }
        }
        return best
    }

    /// Rectangles covering a range of characters, one per line, in page space.
    public func rects(for range: Range<Int>) -> [CGRect] {
        let range = range.clamped(to: 0..<chars.count)
        guard !range.isEmpty else { return [] }
        var result: [CGRect] = []
        for line in lines where line.range.overlaps(range) {
            let part = line.range.clamped(to: range)
            var rect = CGRect.null
            for i in part { rect = rect.union(chars[i].quad.bounds) }
            if !rect.isNull { result.append(rect) }
        }
        return result
    }

    public func lineIndex(containing char: Int) -> Int? {
        guard char >= 0 && char < chars.count else { return nil }
        var low = 0, high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let r = lines[mid].range
            if char < r.lowerBound { high = mid - 1 } else if char >= r.upperBound { low = mid + 1 } else { return mid }
        }
        return nil
    }

    /// The word around a character (letters, digits and joining punctuation).
    public func wordRange(at index: Int) -> Range<Int> {
        guard index >= 0 && index < chars.count else { return index..<index }
        func isWord(_ i: Int) -> Bool {
            let s = chars[i].scalar
            return s.properties.isAlphabetic || s.properties.numericType != nil || s == "_" || s == "'" || s == "’"
        }
        guard isWord(index) else { return index..<(index + 1) }
        let line = chars[index].line
        var start = index, end = index + 1
        while start > 0 && chars[start - 1].line == line && isWord(start - 1) { start -= 1 }
        while end < chars.count && chars[end].line == line && isWord(end) { end += 1 }
        return start..<end
    }

    /// The paragraph (block) around a character.
    public func blockRange(at index: Int) -> Range<Int> {
        guard index >= 0 && index < chars.count else { return index..<index }
        let block = chars[index].block
        var start = index, end = index + 1
        while start > 0 && chars[start - 1].block == block { start -= 1 }
        while end < chars.count && chars[end].block == block { end += 1 }
        return start..<end
    }

    // MARK: Search

    /// Every match of `query`, as ranges of characters. Accents are ignored;
    /// case is ignored unless `.matchCase`. Line breaks count as spaces.
    public func search(_ query: String, options: SearchOptions = []) -> [Range<Int>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !chars.isEmpty else { return [] }
        let haystack = searchString as NSString
        var compare: NSString.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
        if !options.contains(.matchCase) { compare.insert(.caseInsensitive) }
        var results: [Range<Int>] = []
        var from = 0
        while from < haystack.length {
            let found = haystack.range(of: needle, options: compare, range: NSRange(location: from, length: haystack.length - from))
            if found.location == NSNotFound { break }
            from = found.location + max(found.length, 1)
            if options.contains(.wholeWords) && !isWordBoundary(haystack, found) { continue }
            if let range = charRange(of: found) { results.append(range) }
        }
        return results
    }

    private func isWordBoundary(_ s: NSString, _ r: NSRange) -> Bool {
        func isWordUnit(_ i: Int) -> Bool {
            guard i >= 0 && i < s.length, let scalar = Unicode.Scalar(s.character(at: i)) else { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }
        return !isWordUnit(r.location - 1) && !isWordUnit(r.location + r.length)
    }
}
