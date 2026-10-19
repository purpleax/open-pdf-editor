import CoreGraphics
import Foundation
import MuPDFBridge

/// What a page's contents draw (not its comments or fields): how much text,
/// seen and unseen, and how much of the page images cover.
public struct PageTextInfo: Sendable, Equatable {
    /// Characters drawn so they can be seen.
    public let visibleCharacters: Int
    /// Characters drawn invisibly, as a text layer from OCR is.
    public let invisibleCharacters: Int
    /// The share of the page (0–1) covered by images.
    public let imageCoverage: Double

    public init(visibleCharacters: Int, invisibleCharacters: Int, imageCoverage: Double) {
        self.visibleCharacters = visibleCharacters
        self.invisibleCharacters = invisibleCharacters
        self.imageCoverage = imageCoverage
    }

    /// No text worth the name: almost none visible (a stamped page number is
    /// allowed) and none recognised already. What "pages without text" means.
    public var lacksText: Bool { visibleCharacters < 20 && invisibleCharacters == 0 }

    /// A picture of a page with no text to search or copy: mostly image.
    public var isScan: Bool { lacksText && imageCoverage > 0.5 }
}

extension EngineDocument {
    public func textInfo(page: Int) throws -> PageTextInfo {
        var info = opdf_text_info()
        var error = opdf_error()
        guard opdf_page_text_info(handle, Int32(page), &info, &error) else { throw EngineError(error) }
        return PageTextInfo(visibleCharacters: Int(info.visible), invisibleCharacters: Int(info.invisible),
                            imageCoverage: Double(info.image_coverage))
    }
}
