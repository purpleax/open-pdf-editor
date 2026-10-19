import CoreGraphics
import Foundation
import MuPDFBridge

/// What a document can be exported as.
public enum ExportFormat: String, CaseIterable, Sendable {
    case word, html, text, png, jpeg, tiff

    public var title: String {
        switch self {
        case .word: "Word Document"
        case .html: "Web Page"
        case .text: "Plain Text"
        case .png: "PNG Images"
        case .jpeg: "JPEG Images"
        case .tiff: "TIFF Image"
        }
    }

    public var fileExtension: String {
        switch self {
        case .word: "docx"
        case .html: "html"
        case .text: "txt"
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        }
    }

    /// Pictures of pages (one file per page, or a TIFF of them all).
    public var isImage: Bool { self == .png || self == .jpeg || self == .tiff }

    /// One file per page.
    public var filePerPage: Bool { self == .png || self == .jpeg }

    /// MuPDF's writer for the formats that aren't images.
    var writer: String? {
        switch self {
        case .word: "docx"
        case .html: "html"
        case .text: "text"
        default: nil
        }
    }
}

/// A PDF file opened on its own for exporting, with its memory capped as
/// for converting. Use from one thread at a time.
public final class PDFExporter {
    private let handle: OpaquePointer

    public init(url: URL, password: String? = nil, cancel: ConversionCancel? = nil) throws {
        var error = opdf_error()
        let handle = url.withUnsafeFileSystemRepresentation { path in
            path.flatMap { opdf_export_open($0, password, cancel?.handle, &error) }
        }
        guard let handle else { throw EngineError(error) }
        self.handle = handle
    }

    deinit {
        opdf_export_close(handle)
    }

    public func pageCount() throws -> Int {
        var error = opdf_error()
        let count = opdf_export_page_count(handle, &error)
        guard count >= 0 else { throw EngineError(error) }
        return Int(count)
    }

    private final class Progress {
        let report: (Int) -> Void
        init(_ report: @escaping (Int) -> Void) { self.report = report }
    }

    /// Writes the pages (from 0) as Word, HTML or text to `url`; `progress`
    /// is told how many pages are done after each one.
    public func export(_ format: ExportFormat, pages: ClosedRange<Int>, to url: URL, progress: ((Int) -> Void)? = nil) throws {
        guard let writer = format.writer else { throw EngineError(code: -1, message: "\(format.title) is made from page images") }
        var error = opdf_error()
        let box = Unmanaged.passRetained(Progress(progress ?? { _ in }))
        defer { box.release() }
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                opdf_export_document(handle, writer, Int32(pages.lowerBound), Int32(pages.upperBound), $0, { info, done in
                    guard let info else { return }
                    Unmanaged<Progress>.fromOpaque(info).takeUnretainedValue().report(Int(done))
                }, box.toOpaque(), &error)
            } ?? false
        }
        guard ok else { throw EngineError(error) }
    }

    /// Writes one page as a PNG or JPEG (quality 0–1) at `dpi`, or less for
    /// a page too large to draw at it; returns the resolution used.
    @discardableResult
    public func exportImage(page: Int, dpi: CGFloat, jpeg: Bool = false, quality: Double = 0.85, to url: URL) throws -> CGFloat {
        var error = opdf_error()
        var used: Float = 0
        let q = Int32((min(max(quality, 0), 1) * 100).rounded())
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { opdf_export_page_image(handle, Int32(page), Float(dpi), jpeg, q, $0, &used, &error) } ?? false
        }
        guard ok else { throw EngineError(error) }
        return CGFloat(used)
    }

    /// Writes the pages as one multipage TIFF at `dpi` (less for pages too
    /// large to draw at it), a page at a time; returns the lowest resolution
    /// used.
    @discardableResult
    public func exportTIFF(pages: ClosedRange<Int>, dpi: CGFloat, to url: URL, progress: ((Int) -> Void)? = nil) throws -> CGFloat {
        var error = opdf_error()
        var used: Float = 0
        let box = Unmanaged.passRetained(Progress(progress ?? { _ in }))
        defer { box.release() }
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                opdf_export_tiff(handle, Int32(pages.lowerBound), Int32(pages.upperBound), Float(dpi), $0, { info, done in
                    guard let info else { return }
                    Unmanaged<Progress>.fromOpaque(info).takeUnretainedValue().report(Int(done))
                }, box.toOpaque(), &used, &error)
            } ?? false
        }
        guard ok else { throw EngineError(error) }
        return CGFloat(used)
    }
}
