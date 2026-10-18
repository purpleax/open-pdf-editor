import AppKit
import PDFCore

/// A document window. Phase 0: the first page, rendered by MuPDF at the
/// screen's scale, in a scroll view.
final class DocumentWindowController: NSWindowController {
    convenience init(document: EditorDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.center()
        window.setFrameAutosaveName("DocumentWindow")
        self.init(window: window)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 8
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true
        window.contentView = scroll

        guard let engine = document.engine else { return }
        if engine.needsPassword {
            scroll.documentView = message("This document is password-protected. Opening it comes in a later version.")
            return
        }
        do {
            let scale = window.backingScaleFactor
            let image = try engine.render(page: 0, scale: scale)
            let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            let view = NSImageView(frame: NSRect(origin: .zero, size: size))
            view.image = NSImage(cgImage: image, size: size)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel("Page 1 of \((try? engine.pageCount()) ?? 1)")
            scroll.documentView = view
        } catch {
            scroll.documentView = message("This page could not be shown: \(error)")
        }
    }

    private func message(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 20, y: 20, width: 600, height: 60)
        return label
    }
}
