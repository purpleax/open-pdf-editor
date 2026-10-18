import CoreGraphics
import PDFCore
import Testing

@Suite struct LayoutTests {
    let letter = CGSize(width: 612, height: 792)

    @Test func spreads() {
        #expect(PageLayout.spreads(pageCount: 5, mode: DisplayMode(twoPages: false)) == [[0], [1], [2], [3], [4]])
        #expect(PageLayout.spreads(pageCount: 5, mode: DisplayMode(twoPages: true, coverSeparately: true)) == [[0], [1, 2], [3, 4]])
        #expect(PageLayout.spreads(pageCount: 5, mode: DisplayMode(twoPages: true, coverSeparately: false)) == [[0, 1], [2, 3], [4]])
        #expect(PageLayout.spreads(pageCount: 0, mode: DisplayMode()).isEmpty)
    }

    @Test func singleContinuousStacksPages() {
        let layout = PageLayout(sizes: [letter, letter, CGSize(width: 300, height: 400)], mode: .singleContinuous)
        let frames = (0..<3).map { layout.frames[$0]! }
        #expect(frames[0].minY == PageLayout.margin)
        #expect(frames[1].minY == frames[0].maxY + PageLayout.pageGap)
        // The narrow page is centred under the wide ones.
        #expect(abs(frames[2].midX - frames[0].midX) < 0.001)
        #expect(layout.size.width == 612 + 2 * PageLayout.margin)
        #expect(layout.size.height == frames[2].maxY + PageLayout.margin)
    }

    @Test func twoPagesWithCover() {
        let layout = PageLayout(sizes: Array(repeating: letter, count: 4), mode: DisplayMode(twoPages: true, continuous: true))
        let cover = layout.frames[0]!, left = layout.frames[1]!, right = layout.frames[2]!
        // The cover sits where a right-hand page would.
        #expect(abs(cover.minX - right.minX) < 0.001)
        #expect(left.maxX + PageLayout.pageGap == right.minX)
        #expect(left.minY == right.minY && left.minY > cover.maxY)
        #expect(layout.spreadIndex(containing: 2) == 1)
    }

    @Test func singlePageShowsOneSpread() {
        let layout = PageLayout(sizes: Array(repeating: letter, count: 4), mode: DisplayMode(twoPages: false, continuous: false), spread: 2)
        #expect(layout.frames.keys.sorted() == [2])
        #expect(layout.shownSpread == 2)
        #expect(layout.frames[2]!.minY == PageLayout.margin)
        // Out-of-range spreads are clamped.
        #expect(PageLayout(sizes: [letter], mode: DisplayMode(continuous: false), spread: 9).shownSpread == 0)
    }

    @Test func hitTesting() {
        let layout = PageLayout(sizes: Array(repeating: letter, count: 3), mode: .singleContinuous)
        let second = layout.frames[1]!
        #expect(layout.page(nearest: CGPoint(x: second.midX, y: second.midY)) == 1)
        // In the gap between pages: the nearer page.
        #expect(layout.page(nearest: CGPoint(x: second.midX, y: second.minY - 2)) == 1)
        #expect(layout.pages(in: second.insetBy(dx: 0, dy: -PageLayout.pageGap - 1)) == [0, 1, 2])
        #expect(layout.pages(in: CGRect(x: -100, y: -100, width: 10, height: 10)).isEmpty)
    }
}
