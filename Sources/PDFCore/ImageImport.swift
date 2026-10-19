import CoreGraphics
import Foundation
import ImageIO
import MuPDFBridge
import UniformTypeIdentifiers

/// Image files for adding to pages: read with ImageIO (so MuPDF's own
/// decoders never see the file), turned upright, and handed over as JPEG
/// (unchanged, when it already is one and needs no turning) or PNG.
public enum ImageImport {
    public static let maxBytes = 100 << 20
    public static let maxPixels = 40_000_000

    public struct Prepared: Sendable {
        public let data: Data
        /// Pixels, upright.
        public let size: CGSize

        public init(data: Data, size: CGSize) {
            self.data = data
            self.size = size
        }
    }

    public static func prepare(contentsOf url: URL) throws -> Prepared {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        guard let bytes, bytes > 0, bytes <= maxBytes else { throw failure("That image file is empty or larger than 100 MB.") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw failure("That file isn't an image this app can read.")
        }
        guard width * height <= maxPixels else { throw failure("That image has more than 40 megapixels.") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let turned = orientation >= 5
        let size = CGSize(width: turned ? height : width, height: turned ? width : height)
        if let type = CGImageSourceGetType(source), UTType(type as String) == .jpeg, orientation == 1 {
            return Prepared(data: try Data(contentsOf: url), size: size)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw failure("That image couldn't be read.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw failure("That image couldn't be converted.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("That image couldn't be converted.") }
        return Prepared(data: data as Data, size: CGSize(width: image.width, height: image.height))
    }

    private static func failure(_ message: String) -> EngineError { EngineError(code: -1, message: message) }
}

extension EngineDocument {
    /// Draws an image over the page, filling `rect` (page space).
    public func addImage(_ image: ImageImport.Prepared, page: Int, rect: CGRect) throws {
        var error = opdf_error()
        let ok = image.data.withUnsafeBytes { raw in
            opdf_image_add(handle, Int32(page), opdf_rect(rect), raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &error)
        }
        guard ok else { throw EngineError(error) }
    }

    /// Moves or resizes an image drawing to fill `rect`.
    public func setImageRect(page: Int, op: Int, rect: CGRect) throws {
        var error = opdf_error()
        guard opdf_image_set_rect(handle, Int32(page), Int32(op), opdf_rect(rect), &error) else { throw EngineError(error) }
    }

    public func deleteImage(page: Int, op: Int) throws {
        var error = opdf_error()
        guard opdf_image_delete(handle, Int32(page), Int32(op), &error) else { throw EngineError(error) }
    }

    /// Draws another image instead, fitted inside the same box.
    public func replaceImage(page: Int, op: Int, with image: ImageImport.Prepared) throws {
        var error = opdf_error()
        let ok = image.data.withUnsafeBytes { raw in
            opdf_image_replace(handle, Int32(page), Int32(op), raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &error)
        }
        guard ok else { throw EngineError(error) }
    }
}
