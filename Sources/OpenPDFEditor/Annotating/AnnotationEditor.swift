import AppKit
import PDFCore

/// A popover for an annotation's text: a note's comment, or what a text
/// box says. The change is saved (one undoable step) when it closes.
@MainActor
final class AnnotationEditor: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let textView = NSTextView()
    private let ref: AnnotationRef
    private let controller: AnnotationController
    private let original: String
    private var onClose: (() -> Void)?

    init(ref: AnnotationRef, controller: AnnotationController) {
        self.ref = ref
        self.controller = controller
        let annotation = controller.annotation(ref)
        original = annotation?.contents ?? ""
        super.init()

        let title = NSTextField(labelWithString: annotation.map { a in
            a.kind == .freeText ? "Text Box" : (a.author.isEmpty ? a.kind.name : "\(a.kind.name) · \(a.author)")
        } ?? "")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        title.textColor = .secondaryLabelColor
        textView.string = original
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.setAccessibilityLabel(annotation?.kind == .freeText ? "Text" : "Comment")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let stack = NSStackView(views: [title, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        scroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let controllerView = NSViewController()
        controllerView.view = stack
        popover.contentViewController = controllerView
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(relativeTo rect: CGRect, of view: NSView, onClose: @escaping () -> Void) {
        self.onClose = onClose
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    func close() { popover.close() }

    func popoverDidClose(_ notification: Notification) {
        let text = textView.string
        if text != original {
            try? controller.update(ref, actionName: "Edit Text") { $0.contents = text }
        }
        onClose?()
        onClose = nil
    }
}
