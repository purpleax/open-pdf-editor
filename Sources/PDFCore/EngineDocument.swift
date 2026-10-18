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
}

/// One open document in MuPDF, with its own MuPDF context.
///
/// Not thread-safe: use an instance from one thread or actor at a time.
public final class EngineDocument {
    public static var mupdfVersion: String { String(cString: opdf_mupdf_version()) }

    private let handle: OpaquePointer

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

    public var needsPassword: Bool { opdf_needs_password(handle) }

    /// True when the password unlocks the document.
    public func authenticate(password: String) -> Bool {
        opdf_authenticate(handle, password)
    }

    public func pageCount() throws -> Int {
        var error = opdf_error()
        let count = opdf_page_count(handle, &error)
        guard count >= 0 else { throw EngineError(error) }
        return Int(count)
    }

    /// The page's size in points, after its own rotation.
    public func pageSize(_ page: Int) throws -> CGSize {
        var error = opdf_error()
        var width: Float = 0, height: Float = 0
        guard opdf_page_size(handle, Int32(page), &width, &height, &error) else { throw EngineError(error) }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// Renders a page at `scale` (1 = 72 dpi) as an sRGB image with premultiplied alpha.
    public func render(page: Int, scale: CGFloat) throws -> CGImage {
        var error = opdf_error()
        var bitmap = opdf_bitmap()
        guard opdf_render_page(handle, Int32(page), Float(scale), &bitmap, &error) else { throw EngineError(error) }
        defer { opdf_bitmap_free(handle, &bitmap) }

        let width = Int(bitmap.width), height = Int(bitmap.height), stride = Int(bitmap.stride)
        let data = Data(bytes: bitmap.samples, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            throw EngineError(code: -1, message: "Could not make an image from the rendered page")
        }
        return image
    }
}

extension EngineError {
    init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}
