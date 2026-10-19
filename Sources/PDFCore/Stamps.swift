import CoreGraphics
import Foundation
import MuPDFBridge

/// Text stamped over pages: a header, footer (page numbers among them) or
/// watermark.
public struct Stamp: Sendable {
    public enum Kind: Int32, Sendable { case header = 0, footer = 1, watermark = 2 }
    public enum Alignment: Int32, Sendable { case left = 0, centre = 1, right = 2 }

    public var page: Int
    public var kind: Kind
    public var alignment: Alignment
    /// As it is to appear on this page (see `expand`).
    public var text: String
    public var size: CGFloat
    public var color: PDFColor
    public var opacity: CGFloat
    /// Watermarks: degrees, anticlockwise.
    public var angle: CGFloat
    /// Headers and footers: points from the edge.
    public var margin: CGFloat

    public init(page: Int, kind: Kind, alignment: Alignment = .centre, text: String, size: CGFloat = 10,
                color: PDFColor = PDFColor(red: 0, green: 0, blue: 0), opacity: CGFloat = 1, angle: CGFloat = 0, margin: CGFloat = 36) {
        self.page = page
        self.kind = kind
        self.alignment = alignment
        self.text = text
        self.size = size
        self.color = color
        self.opacity = opacity
        self.angle = angle
        self.margin = margin
    }

    /// The text for one page: <<page>> its number, <<pages>> the count,
    /// <<date>> today.
    public static func expand(_ template: String, page: Int, pages: Int, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return template.replacingOccurrences(of: "<<page>>", with: "\(page + 1)")
            .replacingOccurrences(of: "<<pages>>", with: "\(pages)")
            .replacingOccurrences(of: "<<date>>", with: formatter.string(from: date))
    }

    /// Helvetica draws it without an embedded font (Windows-1252 characters).
    public static func fitsHelvetica(_ text: String) -> Bool {
        text.data(using: .windowsCP1252) != nil
    }
}

extension EngineDocument {
    /// Stamps every item as one step; `font` (an sfnt file) draws them all
    /// when given, else Helvetica.
    public func addStamps(_ stamps: [Stamp], font: Data? = nil) throws {
        var error = opdf_error()
        let texts = stamps.map { strdup($0.text) }
        defer { texts.forEach { free($0) } }
        let items = stamps.enumerated().map { i, s in
            opdf_stamp(page: Int32(s.page), kind: s.kind.rawValue, align: s.alignment.rawValue, text: UnsafePointer(texts[i]),
                       size: Float(s.size), color: (Float(s.color.red), Float(s.color.green), Float(s.color.blue)),
                       opacity: Float(s.opacity), angle: Float(s.angle), margin: Float(s.margin))
        }
        let fontData = font ?? Data()
        let ok = items.withUnsafeBufferPointer { list in
            fontData.withUnsafeBytes { raw in
                opdf_stamp_pages(handle, list.baseAddress, Int32(list.count), font == nil ? nil : raw.bindMemory(to: UInt8.self).baseAddress,
                                 font == nil ? 0 : raw.count, &error)
            }
        }
        guard ok else { throw EngineError(error) }
    }

    /// Removes the stamps this app added; returns how many pages had some.
    @discardableResult
    public func removeStamps(headersAndFooters: Bool, watermarks: Bool) throws -> Int {
        var error = opdf_error()
        var pages: Int32 = 0
        let kinds = (headersAndFooters ? 1 : 0) | (watermarks ? 2 : 0)
        guard opdf_stamps_remove(handle, Int32(kinds), &pages, &error) else { throw EngineError(error) }
        return Int(pages)
    }
}
