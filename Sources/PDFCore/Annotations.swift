import CoreGraphics
import Foundation
import MuPDFBridge

/// An RGB colour with components from 0 to 1.
public struct RGBColor: Equatable, Hashable, Sendable {
    public var red, green, blue: CGFloat
    public init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let yellow = RGBColor(red: 1, green: 0.85, blue: 0)
    public static let red = RGBColor(red: 0.9, green: 0.1, blue: 0.1)
    public static let green = RGBColor(red: 0.1, green: 0.65, blue: 0.2)
    public static let blue = RGBColor(red: 0.1, green: 0.35, blue: 0.9)
    public static let black = RGBColor(red: 0, green: 0, blue: 0)
}

/// An annotation as the PDF has it. Geometry is in page space.
public struct Annotation: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Sendable {
        case text = 0, link, freeText, line, square, circle, polygon, polyLine, highlight, underline, squiggly,
             strikeOut, redact, stamp, caret, ink, popup, fileAttachment, sound, movie, richMedia, widget,
             screen, printerMark, trapNet, watermark, threeD, projection
        case unknown = -1

        /// Markup tied to text: shown as quads, can't be moved or resized.
        public var isTextMarkup: Bool { [.highlight, .underline, .squiggly, .strikeOut].contains(self) }

        public var name: String {
            switch self {
            case .text: "Note"
            case .freeText: "Text Box"
            case .line: "Line"
            case .square: "Rectangle"
            case .circle: "Oval"
            case .polygon: "Polygon"
            case .polyLine: "Polyline"
            case .highlight: "Highlight"
            case .underline: "Underline"
            case .squiggly: "Squiggly Underline"
            case .strikeOut: "Strikethrough"
            case .redact: "Redaction"
            case .stamp: "Stamp"
            case .caret: "Caret"
            case .ink: "Drawing"
            case .fileAttachment: "File Attachment"
            case .sound: "Sound"
            default: "Annotation"
            }
        }
    }

    /// PDF line endings, by MuPDF's numbering.
    public enum LineEnding: Int, Sendable {
        case none = 0, square, circle, diamond, openArrow, closedArrow, butt, rOpenArrow, rClosedArrow, slash
    }

    public let page: Int
    public let id: Int
    public var kind: Kind
    public var rect: CGRect
    public var color: RGBColor?
    public var interiorColor: RGBColor?
    public var opacity: CGFloat
    public var borderWidth: CGFloat
    public var flags: Int
    public var contents: String
    public var author: String
    public var subject: String
    public var iconName: String
    public var modified: Date?
    public var created: Date?
    /// The annotation this one replies to.
    public var inReplyTo: Int?
    /// For review statuses (replies with a state).
    public var state: String?
    public var stateModel: String?
    /// Highlight, underline and strikethrough areas.
    public var quads: [Quad]
    /// Freehand strokes.
    public var ink: [[CGPoint]]
    public var line: (CGPoint, CGPoint)?
    public var lineEndings: (start: LineEnding, end: LineEnding)
    public var fontSize: CGFloat
    public var textColor: RGBColor?

    public static func == (a: Annotation, b: Annotation) -> Bool {
        a.page == b.page && a.id == b.id && a.kind == b.kind && a.rect == b.rect && a.color == b.color
            && a.interiorColor == b.interiorColor && a.opacity == b.opacity && a.borderWidth == b.borderWidth
            && a.contents == b.contents && a.author == b.author && a.modified == b.modified && a.quads == b.quads
            && a.ink == b.ink && a.line?.0 == b.line?.0 && a.line?.1 == b.line?.1 && a.state == b.state
    }

    /// A reply, or a review status, rather than an annotation in its own right.
    public var isReply: Bool { inReplyTo != nil && kind == .text }
    public var isStatus: Bool { isReply && stateModel != nil }
    public var isHidden: Bool { flags & 0b11 != 0 }   // Invisible or Hidden

    init(page: Int, _ a: opdf_annot) {
        // Rounded, so colours written from Double come back equal.
        func r(_ v: Float) -> CGFloat { CGFloat((Double(v) * 10000).rounded() / 10000) }
        func color(_ n: Int32, _ c: (Float, Float, Float, Float)) -> RGBColor? {
            switch n {
            case 1: RGBColor(red: r(c.0), green: r(c.0), blue: r(c.0))
            case 3: RGBColor(red: r(c.0), green: r(c.1), blue: r(c.2))
            case 4:
                // CMYK, roughly.
                RGBColor(red: CGFloat((1 - c.0) * (1 - c.3)), green: CGFloat((1 - c.1) * (1 - c.3)),
                         blue: CGFloat((1 - c.2) * (1 - c.3)))
            default: nil
            }
        }
        func string(_ p: UnsafeMutablePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        func date(_ t: Int64) -> Date? { t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil }

        self.page = page
        id = Int(a.id)
        kind = Kind(rawValue: Int(a.type)) ?? .unknown
        rect = CGRect(a.rect)
        self.color = color(a.color_n, a.color)
        interiorColor = color(a.interior_n, a.interior)
        opacity = r(a.opacity)
        borderWidth = r(a.border_width)
        flags = Int(a.flags)
        contents = string(a.contents)
        author = string(a.author)
        subject = string(a.subject)
        iconName = string(a.icon_name)
        modified = date(a.modified)
        created = date(a.created)
        inReplyTo = a.in_reply_to > 0 ? Int(a.in_reply_to) : nil
        state = a.state.map { String(cString: $0) }
        stateModel = a.state_model.map { String(cString: $0) }
        quads = (0..<Int(a.quad_count)).map { i in
            let v = a.quads + i * 8
            return Quad(upperLeft: CGPoint(x: CGFloat(v[0]), y: CGFloat(v[1])),
                        upperRight: CGPoint(x: CGFloat(v[2]), y: CGFloat(v[3])),
                        lowerLeft: CGPoint(x: CGFloat(v[4]), y: CGFloat(v[5])),
                        lowerRight: CGPoint(x: CGFloat(v[6]), y: CGFloat(v[7])))
        }
        var strokes: [[CGPoint]] = []
        var k = 0
        for i in 0..<Int(a.ink_stroke_count) {
            let n = Int(a.ink_counts[i])
            strokes.append((0..<max(n, 0)).map { j in
                CGPoint(x: CGFloat(a.ink_points[(k + j) * 2]), y: CGFloat(a.ink_points[(k + j) * 2 + 1]))
            })
            k += max(n, 0)
        }
        ink = strokes
        line = a.has_line ? (CGPoint(x: CGFloat(a.line.0), y: CGFloat(a.line.1)),
                             CGPoint(x: CGFloat(a.line.2), y: CGFloat(a.line.3))) : nil
        lineEndings = (LineEnding(rawValue: Int(a.line_start)) ?? .none, LineEnding(rawValue: Int(a.line_end)) ?? .none)
        fontSize = CGFloat(a.font_size)
        textColor = color(a.text_color_n, a.text_color)
    }
}

/// What to create, or what to change, in an annotation. Only the fields
/// that are set are applied.
public struct AnnotationChange: Sendable {
    public var kind: Annotation.Kind
    public var rect: CGRect?
    /// Set to `.some(nil)` to remove the colour.
    public var color: RGBColor??
    public var interiorColor: RGBColor??
    public var opacity: CGFloat?
    public var borderWidth: CGFloat?
    public var contents: String?
    public var author: String?
    public var iconName: String?
    public var quads: [Quad]?
    public var ink: [[CGPoint]]?
    public var line: (CGPoint, CGPoint)?
    public var lineEndings: (Annotation.LineEnding, Annotation.LineEnding)?
    public var font: (size: CGFloat, color: RGBColor)?

    public init(kind: Annotation.Kind) {
        self.kind = kind
    }
}

extension EngineDocument {
    public func annotations(page: Int) throws -> [Annotation] {
        var count: Int32 = 0
        var error = opdf_error()
        let items = opdf_annots_load(handle, Int32(page), &count, &error)
        if items == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_annots_free(items, count) }
        return UnsafeBufferPointer(start: items, count: Int(count)).map { Annotation(page: page, $0) }
    }

    /// Creates an annotation; returns its id.
    @discardableResult
    public func createAnnotation(page: Int, _ change: AnnotationChange, actionName: String) throws -> Int {
        var error = opdf_error()
        let id = withSpec(change) { spec, fields in
            opdf_annot_create(handle, Int32(page), spec, fields, actionName, &error)
        }
        guard id > 0 else { throw EngineError(error) }
        return Int(id)
    }

    public func updateAnnotation(page: Int, id: Int, _ change: AnnotationChange, actionName: String) throws {
        var error = opdf_error()
        let ok = withSpec(change) { spec, fields in
            opdf_annot_update(handle, Int32(page), Int32(id), spec, fields, actionName, &error)
        }
        guard ok else { throw EngineError(error) }
    }

    /// Moves or resizes an annotation and all its geometry.
    public func transformAnnotation(page: Int, id: Int, by transform: CGAffineTransform, actionName: String) throws {
        var error = opdf_error()
        let m = opdf_matrix(a: Float(transform.a), b: Float(transform.b), c: Float(transform.c),
                            d: Float(transform.d), e: Float(transform.tx), f: Float(transform.ty))
        guard opdf_annot_transform(handle, Int32(page), Int32(id), m, actionName, &error) else { throw EngineError(error) }
    }

    /// Deletes an annotation with its replies.
    public func deleteAnnotation(page: Int, id: Int, actionName: String) throws {
        var error = opdf_error()
        guard opdf_annot_delete(handle, Int32(page), Int32(id), actionName, &error) else { throw EngineError(error) }
    }

    @discardableResult
    public func reply(page: Int, to parent: Int, author: String, contents: String) throws -> Int {
        var error = opdf_error()
        let id = opdf_annot_reply(handle, Int32(page), Int32(parent), author, contents, &error)
        guard id > 0 else { throw EngineError(error) }
        return Int(id)
    }

    /// Sets (or with nil clears) an author's review status on an annotation.
    public func setStatus(page: Int, of parent: Int, author: String, state: String?) throws {
        var error = opdf_error()
        guard opdf_annot_set_status(handle, Int32(page), Int32(parent), author, state, &error) else { throw EngineError(error) }
    }

    public var canUndo: Bool { opdf_can_undo(handle) }
    public var canRedo: Bool { opdf_can_redo(handle) }
    public var hasUnsavedChanges: Bool { opdf_has_unsaved_changes(handle) }

    public func undo() throws {
        var error = opdf_error()
        guard opdf_undo(handle, &error) else { throw EngineError(error) }
    }

    public func redo() throws {
        var error = opdf_error()
        guard opdf_redo(handle, &error) else { throw EngineError(error) }
    }

    /// Writes the document with its changes to `url` (never the file that is
    /// open): the original file with every change appended as one
    /// incremental update, which keeps signatures valid. The document stays
    /// open as it was, with its undo history.
    public func save(to url: URL) throws {
        var error = opdf_error()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { opdf_save(handle, $0, &error) } ?? false
        }
        guard ok else { throw EngineError(error) }
    }

    /// Draws all annotations into the pages and removes them.
    public func flattenAnnotations() throws {
        var error = opdf_error()
        guard opdf_flatten_annotations(handle, &error) else { throw EngineError(error) }
    }

    private func withSpec<T>(_ change: AnnotationChange, _ body: (UnsafePointer<opdf_annot_spec>, UInt32) -> T) -> T {
        var spec = opdf_annot_spec()
        var fields: UInt32 = 0
        spec.type = Int32(change.kind.rawValue)
        if let rect = change.rect {
            spec.rect = opdf_rect(rect)
            fields |= UInt32(OPDF_FIELD_RECT)
        }
        func rgb(_ c: RGBColor?) -> (Int32, (Float, Float, Float)) {
            guard let c else { return (0, (0, 0, 0)) }
            return (3, (Float(c.red), Float(c.green), Float(c.blue)))
        }
        if let color = change.color {
            (spec.color_n, spec.color) = rgb(color)
            fields |= UInt32(OPDF_FIELD_COLOR)
        }
        if let interior = change.interiorColor {
            (spec.interior_n, spec.interior) = rgb(interior)
            fields |= UInt32(OPDF_FIELD_INTERIOR)
        }
        if let opacity = change.opacity {
            spec.opacity = Float(opacity)
            fields |= UInt32(OPDF_FIELD_OPACITY)
        }
        if let width = change.borderWidth {
            spec.border_width = Float(width)
            fields |= UInt32(OPDF_FIELD_BORDER)
        }
        if let line = change.line {
            spec.line = (Float(line.0.x), Float(line.0.y), Float(line.1.x), Float(line.1.y))
            fields |= UInt32(OPDF_FIELD_LINE)
        }
        if let endings = change.lineEndings {
            spec.line_start = Int32(endings.0.rawValue)
            spec.line_end = Int32(endings.1.rawValue)
            fields |= UInt32(OPDF_FIELD_LINE_ENDINGS)
        }
        if let font = change.font {
            spec.font_size = Float(font.size)
            spec.text_color = (Float(font.color.red), Float(font.color.green), Float(font.color.blue))
            fields |= UInt32(OPDF_FIELD_FONT)
        }
        let quadValues: [Float] = change.quads?.flatMap { q in
            [q.upperLeft, q.upperRight, q.lowerLeft, q.lowerRight].flatMap { [Float($0.x), Float($0.y)] }
        } ?? []
        let inkCounts: [Int32] = change.ink?.map { Int32($0.count) } ?? []
        let inkValues: [Float] = change.ink?.flatMap { $0.flatMap { [Float($0.x), Float($0.y)] } } ?? []
        if change.quads != nil { fields |= UInt32(OPDF_FIELD_QUADS) }
        if change.ink != nil { fields |= UInt32(OPDF_FIELD_INK) }
        if change.contents != nil { fields |= UInt32(OPDF_FIELD_CONTENTS) }
        if change.author != nil { fields |= UInt32(OPDF_FIELD_AUTHOR) }
        if change.iconName != nil { fields |= UInt32(OPDF_FIELD_ICON) }

        return (change.contents ?? "").withCString { contents in
            (change.author ?? "").withCString { author in
                (change.iconName ?? "").withCString { icon in
                    quadValues.withUnsafeBufferPointer { quads in
                        inkCounts.withUnsafeBufferPointer { counts in
                            inkValues.withUnsafeBufferPointer { points in
                                spec.contents = contents
                                spec.author = author
                                spec.icon_name = icon
                                spec.quad_count = Int32(quadValues.count / 8)
                                spec.quads = quads.baseAddress
                                spec.ink_stroke_count = Int32(inkCounts.count)
                                spec.ink_counts = counts.baseAddress
                                spec.ink_points = points.baseAddress
                                return withUnsafePointer(to: &spec) { body($0, fields) }
                            }
                        }
                    }
                }
            }
        }
    }
}
