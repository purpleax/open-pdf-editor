import CoreGraphics

/// How pages are arranged.
public struct DisplayMode: Equatable, Sendable {
    public var twoPages = false
    public var continuous = true
    /// In two-page modes, show the first page on its own, like a book cover.
    public var coverSeparately = true

    public init(twoPages: Bool = false, continuous: Bool = true, coverSeparately: Bool = true) {
        self.twoPages = twoPages
        self.continuous = continuous
        self.coverSeparately = coverSeparately
    }

    public static let singleContinuous = DisplayMode(twoPages: false, continuous: true)
}

/// Where each page goes, in document coordinates at 1 point per point (zoom
/// is the scroll view's magnification). Rows of one or two pages run top to
/// bottom; each row is centred horizontally and its pages vertically.
public struct PageLayout: Sendable {
    public static let margin: CGFloat = 20
    public static let pageGap: CGFloat = 12

    /// Frames of the laid-out pages, by page index. In a non-continuous mode
    /// only the pages of the shown spread are present.
    public let frames: [Int: CGRect]
    /// The spreads (rows) in order, each one or two page indices.
    public let spreads: [[Int]]
    /// The shown spread in a non-continuous mode, else nil.
    public let shownSpread: Int?
    public let size: CGSize

    /// Splits pages into rows for a display mode.
    public static func spreads(pageCount: Int, mode: DisplayMode) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        guard mode.twoPages else { return (0..<pageCount).map { [$0] } }
        var result: [[Int]] = []
        var i = 0
        if mode.coverSeparately {
            result.append([0])
            i = 1
        }
        while i < pageCount {
            result.append(i + 1 < pageCount ? [i, i + 1] : [i])
            i += 2
        }
        return result
    }

    public init(sizes: [CGSize], mode: DisplayMode, spread shown: Int = 0) {
        let spreads = Self.spreads(pageCount: sizes.count, mode: mode)
        self.spreads = spreads
        let rows: [[Int]]
        if mode.continuous {
            rows = spreads
            shownSpread = nil
        } else {
            let index = spreads.isEmpty ? 0 : min(max(shown, 0), spreads.count - 1)
            rows = spreads.isEmpty ? [] : [spreads[index]]
            shownSpread = spreads.isEmpty ? nil : index
        }

        func rowSize(_ row: [Int]) -> CGSize {
            let width = row.map { sizes[$0].width }.reduce(0, +) + CGFloat(max(row.count - 1, 0)) * Self.pageGap
            let height = row.map { sizes[$0].height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        // Two-page rows are as wide as the widest row; a lone cover page sits
        // where a right-hand page would.
        let contentWidth = rows.map { rowSize($0).width }.max() ?? 0
        var frames: [Int: CGRect] = [:]
        var y = Self.margin
        for row in rows {
            let size = rowSize(row)
            var x = Self.margin + (contentWidth - size.width) / 2
            if mode.twoPages && row.count == 1 && row[0] == 0 && mode.coverSeparately && rows.count > 1 {
                x = Self.margin + contentWidth / 2 + Self.pageGap / 2
                if x + sizes[0].width > Self.margin + contentWidth { x = Self.margin + (contentWidth - size.width) / 2 }
            }
            for page in row {
                let s = sizes[page]
                frames[page] = CGRect(x: x, y: y + (size.height - s.height) / 2, width: s.width, height: s.height)
                x += s.width + Self.pageGap
            }
            y += size.height + Self.pageGap
        }
        self.frames = frames
        size = CGSize(width: contentWidth + 2 * Self.margin,
                      height: rows.isEmpty ? 2 * Self.margin : y - Self.pageGap + Self.margin)
    }

    public func spreadIndex(containing page: Int) -> Int? {
        spreads.firstIndex { $0.contains(page) }
    }

    /// Pages whose frames meet a rectangle, in order.
    public func pages(in rect: CGRect) -> [Int] {
        frames.filter { $0.value.intersects(rect) }.map(\.key).sorted()
    }

    /// The page at a point, or the nearest one.
    public func page(nearest point: CGPoint) -> Int? {
        var best: Int?
        var bestDistance = CGFloat.infinity
        for (page, frame) in frames {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let d = dx * dx + dy * dy
            if d < bestDistance || (d == bestDistance && page < (best ?? .max)) {
                bestDistance = d
                best = page
            }
        }
        return best
    }
}
