import AppKit
import PDFCore

/// Types over a text run in place: a text field laid over the run in the
/// pages view, which scales with it. Return or clicking away changes the
/// text; Escape doesn't.
@MainActor
final class TextRunEditor: NSObject, NSTextFieldDelegate {
    let ref: ContentRef
    private let original: String
    private let field: NSTextField
    private var ended = false
    /// Called once, with the new text (nil if cancelled or unchanged).
    var onEnd: ((String?) -> Void)?

    init(ref: ContentRef, run: TextRun, frame: CGRect) {
        self.ref = ref
        original = run.text
        // A little wider than the run, for typing more.
        field = NSTextField(frame: CGRect(x: frame.minX - 2, y: frame.minY, width: frame.width + max(40, frame.height * 4), height: frame.height))
        super.init()
        field.stringValue = run.text
        field.font = NSFont(name: run.fontName, size: max(run.size, 4)) ?? .systemFont(ofSize: max(run.size, 4))
        field.isBordered = true
        field.focusRingType = .exterior
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Text")
    }

    func show(in view: NSView) {
        view.addSubview(field)
        view.window?.makeFirstResponder(field)
    }

    func finish() { end(commit: true) }

    private func end(commit: Bool) {
        guard !ended else { return }
        ended = true
        let text = field.stringValue
        field.removeFromSuperview()
        onEnd?(commit && text != original ? text : nil)
        onEnd = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): end(commit: true)
        case #selector(NSResponder.cancelOperation(_:)): end(commit: false)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { end(commit: true) }
}

#if SELFTEST
extension TextRunEditor {
    func debugType(_ text: String) { field.stringValue = text }
}
#endif
