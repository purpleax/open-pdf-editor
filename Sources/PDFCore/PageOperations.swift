import CoreGraphics
import Foundation
import MuPDFBridge

/// Changes to the pages themselves. Each is one undoable step in the
/// document's journal; afterwards the page count and bounds may differ, so
/// callers reload them.
extension EngineDocument {
    /// Deletes these pages. At least one page must remain.
    public func deletePages(_ pages: [Int]) throws {
        try withPages(pages) { opdf_pages_delete(handle, $0, $1, &$2) }
    }

    /// Puts the pages in a new order: `order` lists every page exactly once,
    /// as the old page numbers in their new positions.
    public func reorderPages(_ order: [Int]) throws {
        try withPages(order) { opdf_pages_reorder(handle, $0, $1, &$2) }
    }

    /// Inserts a blank page before `index` (or at the end when `index` is
    /// the page count).
    public func insertBlankPage(at index: Int, size: CGSize) throws {
        var error = opdf_error()
        guard opdf_page_insert_blank(handle, Int32(index), Float(size.width), Float(size.height), &error) else {
            throw EngineError(error)
        }
    }

    /// Turns pages by a multiple of 90 degrees, clockwise when positive.
    public func rotatePages(_ pages: [Int], by degrees: Int) throws {
        try withPages(pages) { opdf_pages_rotate(handle, $0, $1, Int32(degrees), &$2) }
    }

    /// Sets the visible area of pages to `box`, in page space, limited to
    /// each page.
    public func cropPages(_ pages: [Int], to box: CGRect) throws {
        let rect = opdf_rect(x0: Float(box.minX), y0: Float(box.minY), x1: Float(box.maxX), y1: Float(box.maxY))
        try withPages(pages) { opdf_pages_crop(handle, $0, $1, rect, &$2) }
    }

    /// Copies every page of the PDF at `url` in before `index`, and returns
    /// how many were inserted.
    @discardableResult
    public func insertPages(from url: URL, at index: Int, password: String? = nil) throws -> Int {
        var error = opdf_error()
        var inserted: Int32 = 0
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { opdf_insert_file(handle, Int32(index), $0, password, &inserted, &error) } ?? false
        }
        guard ok else { throw EngineError(error) }
        return Int(inserted)
    }

    /// Writes these pages, in this order, to a new PDF at `url`.
    public func extractPages(_ pages: [Int], to url: URL) throws {
        var error = opdf_error()
        let ok = url.withUnsafeFileSystemRepresentation { path in
            path.map { out in pages.map(Int32.init).withUnsafeBufferPointer {
                opdf_extract_pages(handle, $0.baseAddress, Int32($0.count), out, &error)
            } } ?? false
        }
        guard ok else { throw EngineError(error) }
    }

    private func withPages(_ pages: [Int], _ body: (UnsafePointer<Int32>?, Int32, inout opdf_error) -> Bool) throws {
        var error = opdf_error()
        let numbers = pages.map { Int32(clamping: $0) }
        let ok = numbers.withUnsafeBufferPointer { body($0.baseAddress, Int32($0.count), &error) }
        guard ok else { throw EngineError(error) }
    }
}

/// Stops a conversion or reduction partway, from any thread.
public final class ConversionCancel: @unchecked Sendable {
    let handle: OpaquePointer?

    public init() { handle = opdf_cancel_new() }
    deinit { opdf_cancel_free(handle) }

    public func cancel() { opdf_cancel_request(handle) }
}

/// Making and shrinking PDF files, outside any open document. Memory use is
/// capped; both can be cancelled.
public enum PDFFiles {
    /// How hard Reduce File Size works on images.
    public enum Quality: Int, CaseIterable, Sendable {
        case high, medium, small
    }

    /// Makes one PDF of these files, in order: PDFs are copied as they are;
    /// images and the other kinds MuPDF reads are laid out on pages of
    /// `pageSize` where they reflow. Unless `allowDocuments`, only PDFs and
    /// images are read (by content, whatever a file is named).
    public static func combine(_ files: [URL], into url: URL, pageSize: CGSize = CGSize(width: 612, height: 792),
                               allowDocuments: Bool, cancel: ConversionCancel? = nil) throws {
        var error = opdf_error()
        let paths = files.map { strdup($0.path(percentEncoded: false)) }
        defer { paths.forEach { free($0) } }
        let constPaths = paths.map { UnsafePointer<CChar>($0) }
        let ok = url.withUnsafeFileSystemRepresentation { out in
            out.map { out in constPaths.withUnsafeBufferPointer {
                opdf_convert_files($0.baseAddress, Int32($0.count), out, Float(pageSize.width), Float(pageSize.height),
                                   allowDocuments, cancel?.handle, &error)
            } } ?? false
        }
        guard ok else { throw EngineError(error) }
    }

    /// Writes a smaller copy of the PDF at `source` to `url`: images are
    /// downsampled and recompressed, and unused and duplicate objects removed.
    public static func reduce(_ source: URL, password: String? = nil, quality: Quality, into url: URL,
                              cancel: ConversionCancel? = nil) throws {
        var error = opdf_error()
        let ok = source.withUnsafeFileSystemRepresentation { input in
            url.withUnsafeFileSystemRepresentation { out in
                guard let input, let out else { return false }
                return opdf_reduce_file(input, password, out, Int32(quality.rawValue), cancel?.handle, &error)
            }
        }
        guard ok else { throw EngineError(error) }
    }
}

/// Ways of dividing a document's pages into parts, for Split.
public enum PageSplit {
    /// Parts of `size` pages (the last may be shorter).
    public static func every(_ size: Int, pageCount: Int) -> [[Int]] {
        guard size > 0, pageCount > 0 else { return [] }
        return stride(from: 0, to: pageCount, by: size).map { Array($0..<min($0 + size, pageCount)) }
    }

    /// Parts that start at these pages (bookmarks); pages before the first
    /// start are a part of their own.
    public static func starting(at starts: [Int], pageCount: Int) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        var bounds = Array(Set(starts.filter { $0 > 0 && $0 < pageCount })).sorted()
        bounds.insert(0, at: 0)
        bounds.append(pageCount)
        return zip(bounds, bounds.dropFirst()).map { Array($0..<$1) }
    }
}
