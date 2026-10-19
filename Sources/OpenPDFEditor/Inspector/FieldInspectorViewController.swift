import AppKit
import PDFCore

/// The inspector's section for the selected form field while editing
/// fields: its name, tooltip, whether it is required or read-only, and its
/// kind's own settings (a text field's lines, characters and boxes, a
/// dropdown's or list's choices). Each change is one undoable step.
@MainActor
final class FieldInspectorViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    let viewer: ViewerController
    var ref: FieldRef? {
        didSet { reload() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField()
    private let tooltipField = NSTextField()
    private let required = NSButton(checkboxWithTitle: "Required", target: nil, action: nil)
    private let readOnly = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    private let multiline = NSButton(checkboxWithTitle: "Several lines", target: nil, action: nil)
    private let password = NSButton(checkboxWithTitle: "Hide what’s typed", target: nil, action: nil)
    private let comb = NSButton(checkboxWithTitle: "One box per character", target: nil, action: nil)
    private let maxLengthField = NSTextField()
    private let typedChoice = NSButton(checkboxWithTitle: "Allow typing a choice", target: nil, action: nil)
    private let multiSelect = NSButton(checkboxWithTitle: "Allow several choices", target: nil, action: nil)
    private let choicesLabel = NSTextField(labelWithString: "Choices, one per line")
    private let choicesView = NSTextView()
    private let choicesScroll = NSScrollView()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var rows: [String: NSView] = [:]
    private var shownChoices = ""

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        for field in [nameField, tooltipField, maxLengthField] {
            field.delegate = self
            field.target = self
            field.action = #selector(textCommitted(_:))
        }
        nameField.setAccessibilityLabel("Name")
        tooltipField.setAccessibilityLabel("Tooltip")
        tooltipField.placeholderString = "Shown when pointing at it"
        maxLengthField.setAccessibilityLabel("Most characters")
        maxLengthField.placeholderString = "Any"
        maxLengthField.formatter = {
            let f = NumberFormatter()
            f.minimum = 0
            f.maximum = 100_000
            f.allowsFloats = false
            return f
        }()
        maxLengthField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for box in [required, readOnly, multiline, password, comb, typedChoice, multiSelect] {
            box.target = self
            box.action = #selector(flagChanged(_:))
        }
        choicesLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        choicesLabel.textColor = .secondaryLabelColor
        choicesView.delegate = self
        choicesView.isRichText = false
        choicesView.font = .systemFont(ofSize: NSFont.systemFontSize)
        choicesView.textContainerInset = NSSize(width: 2, height: 3)
        choicesView.setAccessibilityLabel("Choices, one per line")
        choicesView.autoresizingMask = [.width]
        choicesView.isVerticallyResizable = true
        choicesView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        choicesView.textContainer?.widthTracksTextView = true
        choicesScroll.documentView = choicesView
        choicesScroll.hasVerticalScroller = true
        choicesScroll.borderType = .bezelBorder
        choicesScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked(_:))
        deleteButton.controlSize = .small

        func row(_ label: String, _ views: [NSView]) -> NSView {
            let name = NSTextField(labelWithString: label)
            name.textColor = .secondaryLabelColor
            name.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let stack = NSStackView(views: [name] + views)
            stack.spacing = 8
            rows[label] = stack
            return stack
        }
        let stack = NSStackView(views: [
            titleLabel,
            row("Name", [nameField]),
            row("Tooltip", [tooltipField]),
            required, readOnly, multiline, password, comb,
            row("Characters", [maxLengthField]),
            typedChoice, multiSelect,
            choicesLabel, choicesScroll, deleteButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: titleLabel)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        for view in [choicesScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        for field in [nameField, tooltipField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            rows[field === nameField ? "Name" : "Tooltip"]?.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        view = stack
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        guard let ref, let field = viewer.forms.field(ref) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        titleLabel.stringValue = field.kind.title
        // The full name ("address.street") is shown; its last part is changed.
        nameField.stringValue = field.name
        tooltipField.stringValue = field.tooltip
        required.state = field.isRequired ? .on : .off
        readOnly.state = field.flags & 1 != 0 ? .on : .off
        multiline.state = field.isMultiline ? .on : .off
        password.state = field.isPassword ? .on : .off
        comb.state = field.isComb ? .on : .off
        maxLengthField.stringValue = field.maxLength > 0 ? "\(field.maxLength)" : ""
        typedChoice.state = field.allowsTypedChoice ? .on : .off
        multiSelect.state = field.isMultiSelect ? .on : .off
        let isText = field.kind == .text
        let hasChoices = field.kind == .dropdown || field.kind == .listBox
        for view in [multiline, password, comb] { view.isHidden = !isText }
        rows["Characters"]?.isHidden = !isText
        typedChoice.isHidden = field.kind != .dropdown
        multiSelect.isHidden = field.kind != .listBox
        choicesLabel.isHidden = !hasChoices
        choicesScroll.isHidden = !hasChoices
        required.isHidden = field.kind == .signature
        // Choices as "value" or "value | label" lines.
        shownChoices = field.options.map { $0.label.isEmpty || $0.label == $0.value ? $0.value : "\($0.value) | \($0.label)" }
            .joined(separator: "\n")
        if choicesView.string != shownChoices, view.window?.firstResponder !== choicesView { choicesView.string = shownChoices }
        let editable = viewer.model.isEditable
        for control in [nameField, tooltipField, maxLengthField] as [NSControl] { control.isEnabled = editable }
        for box in [required, readOnly, multiline, password, comb, typedChoice, multiSelect, deleteButton] { box.isEnabled = editable }
        choicesView.isEditable = editable
    }

    private func change(_ actionName: String, _ configure: (inout FieldChange) -> Void) {
        guard let ref else { return }
        var change = FieldChange()
        configure(&change)
        do {
            try viewer.forms.update(ref, actionName: actionName, change)
        } catch {
            showFailure(error)
        }
        reload()
    }

    private func showFailure(_ error: Error) {
        guard let window = view.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "The field couldn’t be changed."
        alert.informativeText = "\(error)"
        alert.beginSheetModal(for: window)
    }

    @objc private func textCommitted(_ sender: NSTextField) {
        guard let ref, let field = viewer.forms.field(ref) else { return }
        switch sender {
        case nameField:
            // Only the last part of a dotted name is the field's own.
            let own = sender.stringValue.split(separator: ".").last.map(String.init) ?? ""
            let current = field.name.split(separator: ".").last.map(String.init) ?? ""
            guard own != current else { return }
            change("Rename Field") { $0.name = own }
        case tooltipField:
            guard sender.stringValue != field.tooltip else { return }
            change("Change Tooltip") { $0.tooltip = sender.stringValue }
        case maxLengthField:
            let length = Int(sender.stringValue) ?? 0
            guard length != field.maxLength else { return }
            change("Change Length") { $0.maxLength = length }
        default:
            break
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { textCommitted(field) }
    }

    @objc private func flagChanged(_ sender: NSButton) {
        let on = sender.state == .on
        change("Change Field") {
            switch sender {
            case required: $0.isRequired = on
            case readOnly: $0.isReadOnly = on
            case multiline: $0.isMultiline = on
            case password: $0.isPassword = on
            case comb: $0.isComb = on
            case typedChoice: $0.allowsTypedChoice = on
            case multiSelect: $0.isMultiSelect = on
            default: break
            }
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard choicesView.string != shownChoices else { return }
        let options = choicesView.string.split(separator: "\n").compactMap { line -> FormField.Option? in
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let value = parts.first, !value.isEmpty else { return nil }
            return FormField.Option(value: value, label: parts.count > 1 ? parts[1] : "")
        }
        change("Change Choices") { $0.options = options }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let ref else { return }
        do {
            try viewer.forms.delete(ref)
            viewer.pagesView.selectedField = nil
        } catch {
            showFailure(error)
        }
    }
}
