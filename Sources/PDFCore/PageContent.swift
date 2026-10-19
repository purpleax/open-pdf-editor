import CoreGraphics
import MuPDFBridge

/// A text operation on a page, as Edit Content shows it.
public struct TextRun: Equatable, Sendable {
    public enum Restriction: Int, Sendable {
        case none = 0, type3, vertical, invisible, tooLong
    }

    public let page: Int
    /// Which text operation on the page, from 0.
    public let op: Int
    public let text: String
    public let rect: CGRect
    /// One per character.
    public let quads: [Quad]
    public let fontName: String
    public let isSerif, isBold, isItalic, isMonospaced: Bool
    /// As drawn, in points.
    public let size: CGFloat
    /// The fill colour, when it is grey, RGB or CMYK (converted to RGB).
    public let color: PDFColor?
    public let restriction: Restriction

    public var isEditable: Bool { restriction == .none }
}

/// One drawing of an image XObject on a page.
public struct ImagePlacement: Equatable, Sendable {
    public let page: Int
    /// Which image drawing on the page, from 0.
    public let op: Int
    public let rect: CGRect
    /// The image's unit square to page space.
    public let transform: CGAffineTransform
    public let pixelWidth, pixelHeight: Int
}

public struct PageContent: Sendable {
    public let runs: [TextRun]
    public let images: [ImagePlacement]
}

extension EngineDocument {
    public func content(page: Int) throws -> PageContent {
        var c = opdf_page_content()
        var error = opdf_error()
        guard opdf_page_content_load(handle, Int32(page), &c, &error) else { throw EngineError(error) }
        defer { opdf_page_content_free(&c) }
        let runs = UnsafeBufferPointer(start: c.runs, count: Int(c.run_count)).map { r in
            TextRun(page: page, op: Int(r.op), text: r.text.map { String(cString: $0) } ?? "", rect: CGRect(r.rect),
                    quads: (0..<Int(r.quad_count)).map { i in
                        let q = r.quads + i * 8
                        return Quad(upperLeft: CGPoint(x: CGFloat(q[0]), y: CGFloat(q[1])), upperRight: CGPoint(x: CGFloat(q[2]), y: CGFloat(q[3])),
                                    lowerLeft: CGPoint(x: CGFloat(q[4]), y: CGFloat(q[5])), lowerRight: CGPoint(x: CGFloat(q[6]), y: CGFloat(q[7])))
                    },
                    fontName: r.font.map { String(cString: $0) } ?? "", isSerif: r.serif, isBold: r.bold, isItalic: r.italic,
                    isMonospaced: r.monospaced, size: CGFloat(r.size), color: Self.color(r.color_n, r.color),
                    restriction: TextRun.Restriction(rawValue: Int(r.not_editable)) ?? .tooLong)
        }
        let images = UnsafeBufferPointer(start: c.images, count: Int(c.image_count)).map { i in
            ImagePlacement(page: page, op: Int(i.op), rect: CGRect(i.rect),
                           transform: CGAffineTransform(a: CGFloat(i.matrix.0), b: CGFloat(i.matrix.1), c: CGFloat(i.matrix.2),
                                                        d: CGFloat(i.matrix.3), tx: CGFloat(i.matrix.4), ty: CGFloat(i.matrix.5)),
                           pixelWidth: Int(i.width), pixelHeight: Int(i.height))
        }
        return PageContent(runs: runs, images: images)
    }

    /// Writes the page's content again with no change (tests).
    public func rewritePageContent(page: Int) throws {
        var error = opdf_error()
        guard opdf_page_content_rewrite(handle, Int32(page), &error) else { throw EngineError(error) }
    }

    private static func color(_ n: Int32, _ c: (Float, Float, Float, Float)) -> PDFColor? {
        switch n {
        case 1: PDFColor(red: CGFloat(c.0), green: CGFloat(c.0), blue: CGFloat(c.0))
        case 3: PDFColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2))
        case 4: PDFColor(red: CGFloat((1 - c.0) * (1 - c.3)), green: CGFloat((1 - c.1) * (1 - c.3)), blue: CGFloat((1 - c.2) * (1 - c.3)))
        default: nil
        }
    }
}
