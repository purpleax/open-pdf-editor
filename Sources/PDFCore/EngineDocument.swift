import CoreGraphics
import Foundation
import MuPDFBridge

/// A failure reported by MuPDF.
public struct EngineError: Error, CustomStringConvertible, Sendable {
    public let code: Int
    public let message: String
    public var description: String { message.isEmpty ? "MuPDF error \(code)" : message }

    init(_ error: opdf_error) {
        code = Int(error.code)
        message = withUnsafeBytes(of: error.message) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// One open document in MuPDF.
///
/// Thread-safe: the bridge serialises document access with a lock, and
/// renders display lists on its own pool of contexts, so any method can be
/// called from any thread.
public final class EngineDocument: @unchecked Sendable {
    public static var mupdfVersion: String { String(cString: opdf_mupdf_version()) }

    let handle: OpaquePointer

    public init(url: URL) throws {
        var error = opdf_error()
        guard let handle = url.withUnsafeFileSystemRepresentation({ path in
            path.flatMap { opdf_open($0, &error) }
        }) else {
            throw EngineError(error)
        }
        self.handle = handle
    }

    deinit {
        opdf_close(handle)
    }

    public var isPDF: Bool { opdf_is_pdf(handle) }

    private let unlockLock = NSLock()
    private var unlocked = false

    /// True until the document is unlocked. (MuPDF answers this by trying an
    /// empty password, so it isn't asked again once a password has worked.)
    public var needsPassword: Bool {
        unlockLock.withLock {
            if unlocked { return false }
            let needs = opdf_needs_password(handle)
            if !needs { unlocked = true }
            return needs
        }
    }

    /// True when the password unlocks the document.
    public func authenticate(password: String) -> Bool {
        unlockLock.withLock {
            let ok = opdf_authenticate(handle, password)
            if ok { unlocked = true }
            return ok
        }
    }

    public func pageCount() throws -> Int {
        var error = opdf_error()
        let count = opdf_page_count(handle, &error)
        guard count >= 0 else { throw EngineError(error) }
        return Int(count)
    }

    /// The largest page side accepted, in points. PDF allows 14,400 units
    /// scaled by /UserUnit; MuPDF has no upper limit, so a hostile file can
    /// declare pages of 1e22 points.
    public static let maxPageSide: CGFloat = 200_000
    /// Renders larger than this (per side, and in total) are refused.
    public static let maxRenderSide = 16_384
    public static let maxRenderPixels = 64 * 1024 * 1024

    /// Every page's bounds in page space (MuPDF's coordinates: points, y down,
    /// the page's own rotation applied), made safe with `sanitized(_:)`.
    public func pageBounds() throws -> [CGRect] {
        let count = try pageCount()
        guard count > 0 else { return [] }
        var rects = [opdf_rect](repeating: opdf_rect(), count: count)
        var error = opdf_error()
        guard opdf_page_bounds_all(handle, &rects, Int32(count), &error) else { throw EngineError(error) }
        return rects.map { Self.sanitized(CGRect($0)) }
    }

    /// Page bounds the viewer can work with: finite, at least 1 point and at
    /// most `maxPageSide` per side (larger pages are cropped), and with an
    /// origin in a sane range. Pages that fail any of this become Letter size.
    public static func sanitized(_ rect: CGRect) -> CGRect {
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        let letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard values.allSatisfy(\.isFinite), rect.width >= 1, rect.height >= 1,
              abs(rect.minX) <= 1e7, abs(rect.minY) <= 1e7 else { return letter }
        return CGRect(x: rect.minX, y: rect.minY,
                      width: min(rect.width, maxPageSide), height: min(rect.height, maxPageSide))
    }

    /// Metadata by MuPDF key: "format", "encryption", "info:Title", "info:Author", ...
    public func metadata(_ key: String) -> String? {
        guard let value = opdf_metadata(handle, key) else { return nil }
        defer { opdf_free(value) }
        return String(cString: value)
    }

    /// Sets the document's information (nil leaves a value, "" removes it)
    /// and its modification date, as one step.
    public func setMetadata(title: String? = nil, author: String? = nil, subject: String? = nil, keywords: String? = nil,
                            now: Date = Date()) throws {
        var error = opdf_error()
        let copies: [UnsafeMutablePointer<CChar>?] = [title, author, subject, keywords].map { $0.flatMap { strdup($0) } }
        defer { copies.forEach { free($0) } }
        let p = copies.map { $0.map { UnsafePointer($0) } }
        var spec = opdf_metadata_spec(title: p[0], author: p[1], subject: p[2], keywords: p[3])
        guard opdf_metadata_set(handle, &spec, Int64(now.timeIntervalSince1970), &error) else { throw EngineError(error) }
    }

    /// The transform from page space to view space: scaled, rotated clockwise
    /// by `rotation` degrees (a multiple of 90) and moved so the page's
    /// top-left corner is at the origin.
    public static func pageTransform(bounds: CGRect, scale: CGFloat, rotation: Int) -> CGAffineTransform {
        let m = opdf_page_matrix(opdf_rect(bounds), Float(scale), Int32(rotation))
        return CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d),
                                 tx: CGFloat(m.e), ty: CGFloat(m.f))
    }

    // MARK: Rendering

    /// The page's drawing commands, ready to render at any scale on any thread.
    public func displayList(page: Int) throws -> DisplayList {
        var error = opdf_error()
        guard let list = opdf_list_load(handle, Int32(page), &error) else { throw EngineError(error) }
        return DisplayList(document: self, handle: list)
    }

    /// Renders the part of a page at `rect` (whole pixels, view space at this
    /// scale and rotation) as an opaque image.
    public func render(_ list: DisplayList, bounds: CGRect, scale: CGFloat, rotation: Int,
                       rect: CGRect, cookie: RenderCookie? = nil) throws -> CGImage {
        // Everything here may come from a hostile file: check before converting.
        let limit = CGFloat(Int32.max / 2)
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              scale.isFinite, scale > 0,
              rect.minX >= -limit, rect.minY >= -limit, rect.maxX <= limit, rect.maxY <= limit else {
            throw EngineError(code: -1, message: "Render area out of range")
        }
        let x = Int(rect.minX.rounded(.down)), y = Int(rect.minY.rounded(.down))
        let width = Int(rect.maxX.rounded(.up)) - x, height = Int(rect.maxY.rounded(.up)) - y
        guard width > 0, height > 0 else { throw EngineError(code: -1, message: "Empty render area") }
        guard width <= Self.maxRenderSide, height <= Self.maxRenderSide, width * height <= Self.maxRenderPixels else {
            throw EngineError(code: -1, message: "Render area too large (\(width) × \(height) pixels)")
        }
        let bytesPerRow = width * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerRow * height)
        var error = opdf_error()
        let ok = opdf_list_render(handle, list.handle, opdf_rect(bounds), Float(scale), Int32(rotation),
                                  Int32(x), Int32(y), Int32(width), Int32(height), buffer, cookie?.handle, &error)
        guard ok else {
            buffer.deallocate()
            if cookie?.isCancelled == true { throw CancellationError() }
            throw EngineError(error)
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: bytesPerRow * height,
                                            releaseData: { _, data, _ in data.deallocate() }),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            throw EngineError(code: -1, message: "Could not make an image from the rendered page")
        }
        return image
    }

    /// A whole page as an image at `scale` (1 = 72 dpi).
    public func renderPage(_ page: Int, bounds: CGRect, scale: CGFloat, rotation: Int = 0,
                           cookie: RenderCookie? = nil) throws -> CGImage {
        let list = try displayList(page: page)
        let size = bounds.applying(Self.pageTransform(bounds: bounds, scale: scale, rotation: rotation)).size
        return try render(list, bounds: bounds, scale: scale, rotation: rotation,
                          rect: CGRect(x: 0, y: 0, width: max(1, size.width.rounded()), height: max(1, size.height.rounded())),
                          cookie: cookie)
    }

    // MARK: Text, links, outline

    public func text(page: Int) throws -> PageText {
        var count: Int32 = 0
        var error = opdf_error()
        let chars = opdf_text_load(handle, Int32(page), &count, &error)
        if chars == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_free(chars) }
        let buffer = UnsafeBufferPointer(start: chars, count: Int(count))
        return PageText(chars: buffer.map(TextChar.init))
    }

    public func links(page: Int) throws -> [PageLink] {
        var count: Int32 = 0
        var error = opdf_error()
        let links = opdf_links_load(handle, Int32(page), &count, &error)
        if links == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_links_free(links, count) }
        return UnsafeBufferPointer(start: links, count: Int(count)).map { link in
            PageLink(rect: CGRect(link.rect), uri: link.uri.map { String(cString: $0) } ?? "",
                     isExternal: link.external, targetPage: link.page >= 0 ? Int(link.page) : nil,
                     targetPoint: CGPoint(x: CGFloat(link.x), y: CGFloat(link.y)).finiteOrNil)
        }
    }

    /// The document's outline (bookmarks) as a tree.
    public func outline() throws -> [OutlineItem] {
        var count: Int32 = 0
        var error = opdf_error()
        let items = opdf_outline_load(handle, &count, &error)
        if items == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_outline_free(items, count) }
        var roots: [OutlineItem] = []
        var stack: [OutlineItem] = []
        for item in UnsafeBufferPointer(start: items, count: Int(count)) {
            let node = OutlineItem(
                title: item.title.map { String(cString: $0) } ?? "",
                uri: item.uri.map { String(cString: $0) },
                page: item.page >= 0 ? Int(item.page) : nil,
                point: CGPoint(x: CGFloat(item.x), y: CGFloat(item.y)).finiteOrNil,
                isOpen: item.open)
            let depth = Int(item.depth)
            while stack.count > depth { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        return roots
    }

    // MARK: Attachments and layers

    public func attachments() throws -> [Attachment] {
        var count: Int32 = 0
        var error = opdf_error()
        let items = opdf_attachments_load(handle, &count, &error)
        if items == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_attachments_free(items, count) }
        return UnsafeBufferPointer(start: items, count: Int(count)).map { item in
            let name = item.name.map { String(cString: $0) } ?? ""
            let filename = item.filename.map { String(cString: $0) }
            return Attachment(
                name: name,
                filename: (filename?.isEmpty == false ? filename : nil) ?? name,
                mimeType: item.mimetype.map { String(cString: $0) },
                size: item.size >= 0 ? Int(item.size) : nil,
                created: item.created >= 0 ? Date(timeIntervalSince1970: TimeInterval(item.created)) : nil,
                modified: item.modified >= 0 ? Date(timeIntervalSince1970: TimeInterval(item.modified)) : nil)
        }
    }

    public func saveAttachment(named name: String, to url: URL) throws {
        var error = opdf_error()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { opdf_attachment_save(handle, name, $0, &error) } ?? false
        }
        guard ok else { throw EngineError(error) }
    }

    public func layers() throws -> [Layer] {
        var count: Int32 = 0
        var error = opdf_error()
        let items = opdf_layers_load(handle, &count, &error)
        if items == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_layers_free(items, count) }
        return UnsafeBufferPointer(start: items, count: Int(count)).enumerated().map { index, item in
            Layer(index: index, text: item.text.map { String(cString: $0) } ?? "", depth: Int(item.depth),
                  kind: Layer.Kind(rawValue: Int(item.type)) ?? .label, isOn: item.selected, isLocked: item.locked)
        }
    }

    /// Turns a layer on or off. Display lists loaded before this are out of date.
    public func toggleLayer(_ index: Int) throws {
        var error = opdf_error()
        guard opdf_layer_toggle(handle, Int32(index), &error) else { throw EngineError(error) }
    }
}

/// A page's drawing commands. Holds its document open.
public final class DisplayList: @unchecked Sendable {
    let document: EngineDocument
    let handle: OpaquePointer

    init(document: EngineDocument, handle: OpaquePointer) {
        self.document = document
        self.handle = handle
    }

    deinit {
        opdf_list_drop(document.handle, handle)
    }
}

/// Cancels a render in progress.
public final class RenderCookie: @unchecked Sendable {
    let handle: OpaquePointer
    private let lock = NSLock()
    private var cancelled = false

    public init() {
        handle = opdf_cookie_new()
    }

    deinit {
        opdf_cookie_free(handle)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        opdf_cookie_abort(handle)
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }
}

public struct PageLink: Sendable {
    public let rect: CGRect
    public let uri: String
    public let isExternal: Bool
    public let targetPage: Int?
    public let targetPoint: CGPoint?
}

public final class OutlineItem: @unchecked Sendable {
    public let title: String
    public let uri: String?
    public let page: Int?
    public let point: CGPoint?
    public let isOpen: Bool
    public internal(set) var children: [OutlineItem] = []

    init(title: String, uri: String?, page: Int?, point: CGPoint?, isOpen: Bool) {
        self.title = title
        self.uri = uri
        self.page = page
        self.point = point
        self.isOpen = isOpen
    }
}

public struct Attachment: Sendable {
    public let name: String
    public let filename: String
    public let mimeType: String?
    public let size: Int?
    public let created: Date?
    public let modified: Date?
}

public struct Layer: Sendable {
    public enum Kind: Int, Sendable { case label = 0, checkbox = 1, radio = 2 }
    public let index: Int
    public let text: String
    public let depth: Int
    public let kind: Kind
    public let isOn: Bool
    public let isLocked: Bool
}

extension CGRect {
    init(_ r: opdf_rect) {
        self.init(x: CGFloat(r.x0), y: CGFloat(r.y0), width: CGFloat(r.x1 - r.x0), height: CGFloat(r.y1 - r.y0))
    }
}

extension opdf_rect {
    init(_ r: CGRect) {
        self.init(x0: Float(r.minX), y0: Float(r.minY), x1: Float(r.maxX), y1: Float(r.maxY))
    }
}

extension CGPoint {
    var finiteOrNil: CGPoint? { x.isFinite && y.isFinite ? self : nil }
}
