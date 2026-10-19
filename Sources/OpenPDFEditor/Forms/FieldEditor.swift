import AppKit
import PDFCore

/// Types into a text field (or a dropdown that takes typed choices) in
/// place: a text control laid over the field in the pages view, which scales
/// with it. Return, Tab or clicking away fills the field in; Escape doesn't.
@MainActor
final class FieldEditor: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    enum Ending { case commit, cancel, next, previous }

    let ref: FieldRef
    private let field: FormField
    private let control: NSView
    private let textView: NSTextView?
    private let textField: NSTextField?
    private var ended = false
    /// Called once, when editing ends, with how it ended and the text.
    var onEnd: ((Ending, String) -> Void)?

    init(field: FormField, frame: CGRect) {
        ref = FieldRef(page: field.page, id: field.id)
        self.field = field
        // A size that fits the field, in page points (the view scales it).
        let size = min(12, max(6, (field.isMultiline ? 14 : frame.height) * 0.7))
        let font = NSFont.systemFont(ofSize: size)
        if field.isMultiline {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = frame
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = false
            let view = scroll.documentView as! NSTextView
            view.font = font
            view.string = field.value
            view.isRichText = false
            view.allowsUndo = true
            view.textContainerInset = NSSize(width: 1, height: 1)
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            textView = view
            textField = nil
            control = scroll
        } else {
            let text: NSTextField
            if field.isPassword {
                text = NSSecureTextField(frame: frame)
            } else if field.kind == .dropdown {
                let combo = NSComboBox(frame: frame)
                combo.addItems(withObjectValues: field.options.map(\.label))
                combo.completes = true
                text = combo
            } else {
                text = NSTextField(frame: frame)
            }
            text.font = font
            text.stringValue = field.kind == .dropdown
                ? field.options.first { $0.value == field.value }?.label ?? field.value
                : field.value
            text.isBordered = false
            text.focusRingType = .exterior
            text.cell?.isScrollable = true
            text.cell?.wraps = false
            textField = text
            textView = nil
            control = text
        }
        super.init()
        textField?.delegate = self
        textView?.delegate = self
        control.setAccessibilityLabel(field.tooltip.isEmpty ? field.name : field.tooltip)
    }

    func show(in view: NSView) {
        view.addSubview(control)
        view.window?.makeFirstResponder(textField ?? textView)
        textView?.selectAll(nil)
    }

    /// Ends editing (if it hasn't ended), filling the field in.
    func finish() { end(.commit) }

    func cancel() { end(.cancel) }

    private var text: String { textField?.stringValue ?? textView?.string ?? "" }

    private func end(_ ending: Ending) {
        guard !ended else { return }
        ended = true
        var value = text
        // A dropdown stores the chosen option's value, not its label.
        if field.kind == .dropdown, let option = field.options.first(where: { $0.label == value }) { value = option.value }
        control.removeFromSuperview()
        onEnd?(ending, value)
        onEnd = nil
    }

    // MARK: Limits

    /// Cuts typing at the field's maximum length.
    private func limit(_ string: String) -> String? {
        guard field.maxLength > 0, string.count > field.maxLength else { return nil }
        return String(string.prefix(field.maxLength))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let textField, let limited = limit(textField.stringValue) else { return }
        textField.stringValue = limited
        NSSound.beep()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView, let limited = limit(textView.string) else { return }
        textView.string = limited
        NSSound.beep()
    }

    // MARK: Ending

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handle(selector)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return makes a new line in a multiline field; Tab moves on.
        if selector == #selector(NSResponder.insertNewline(_:)) { return false }
        return handle(selector)
    }

    private func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): end(.commit)
        case #selector(NSResponder.insertTab(_:)): end(.next)
        case #selector(NSResponder.insertBacktab(_:)): end(.previous)
        case #selector(NSResponder.cancelOperation(_:)): end(.cancel)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { end(.commit) }

    func textDidEndEditing(_ notification: Notification) { end(.commit) }
}

#if SELFTEST
extension FieldEditor {
    func debugType(_ string: String) {
        if let textField { textField.stringValue = string } else { textView?.string = string }
    }

    func debugEnd(_ ending: Ending) { end(ending) }
}
#endif
