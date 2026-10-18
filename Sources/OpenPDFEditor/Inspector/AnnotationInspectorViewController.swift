import AppKit
import PDFCore

/// The inspector's section for the selected annotation: its colours,
/// opacity, line width, text size and comment. Each change is one
/// undoable step.
@MainActor
final class AnnotationInspectorViewController: NSViewController, NSTextViewDelegate {
    let viewer: ViewerController
    var ref: AnnotationRef? {
        didSet { reload() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let colorWell = NSColorWell(style: .minimal)
    private let fillWell = NSColorWell(style: .minimal)
    private let fillCheckbox = NSButton(checkboxWithTitle: "Fill", target: nil, action: nil)
    private let opacitySlider = NSSlider(value: 100, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let commentLabel = NSTextField(labelWithString: "Comment")
    private let commentView = NSTextView()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var rows: [String: NSView] = [:]
    private var shownContents = ""

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.setAccessibilityLabel("Colour")
        fillWell.target = self
        fillWell.action = #selector(fillChanged(_:))
        fillWell.setAccessibilityLabel("Fill colour")
        fillCheckbox.target = self
        fillCheckbox.action = #selector(fillChanged(_:))
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.isContinuous = false
        opacitySlider.setAccessibilityLabel("Opacity")
        for width in MarkupBarViewController.widths { widthPopup.addItem(withTitle: "\(Int(width)) pt") }
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.setAccessibilityLabel("Line width")
        for size in MarkupBarViewController.sizes { sizePopup.addItem(withTitle: "\(Int(size)) pt") }
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))
        sizePopup.setAccessibilityLabel("Text size")

        commentLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        commentLabel.textColor = .secondaryLabelColor
        commentView.delegate = self
        commentView.isRichText = false
        commentView.font = .systemFont(ofSize: NSFont.systemFontSize)
        commentView.textContainerInset = NSSize(width: 2, height: 3)
        commentView.setAccessibilityLabel("Comment")
        let commentScroll = NSScrollView()
        commentScroll.documentView = commentView
        commentScroll.hasVerticalScroller = true
        commentScroll.borderType = .bezelBorder
        commentView.autoresizingMask = [.width]
        commentView.isVerticallyResizable = true
        commentView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        commentView.textContainer?.widthTracksTextView = true
        commentScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

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
            titleLabel, detailLabel,
            row("Colour", [colorWell]),
            row("Fill", [fillCheckbox, fillWell]),
            row("Opacity", [opacitySlider]),
            row("Line", [widthPopup]),
            row("Text size", [sizePopup]),
            commentLabel, commentScroll, deleteButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: titleLabel)
        stack.setCustomSpacing(12, after: detailLabel)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        commentScroll.translatesAutoresizingMaskIntoConstraints = false
        commentScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        view = stack
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        guard let ref, let a = viewer.annotations.annotation(ref) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        let editable = viewer.annotations.canEdit(a)
        for control in [colorWell, fillWell, fillCheckbox, opacitySlider, widthPopup, sizePopup, deleteButton] as [NSControl] {
            control.isEnabled = editable
        }
        commentView.isEditable = editable
        titleLabel.stringValue = a.kind == .stamp && !a.iconName.isEmpty ? "Stamp: \(a.iconName)" : a.kind.name
        var detail = [a.author]
        if let date = a.modified { detail.append(date.formatted(date: .abbreviated, time: .shortened)) }
        detail.append("Page \(ref.page + 1)")
        detailLabel.stringValue = detail.filter { !$0.isEmpty }.joined(separator: " · ")

        let isText = a.kind == .freeText
        let color = isText ? a.textColor : a.color
        rows["Colour"]?.isHidden = a.kind == .stamp
        colorWell.color = (color ?? .black).nsColor
        rows["Fill"]?.isHidden = ![.square, .circle].contains(a.kind)
        fillCheckbox.state = a.interiorColor == nil ? .off : .on
        fillWell.color = (a.interiorColor ?? a.color ?? .yellow).nsColor
        fillWell.isEnabled = a.interiorColor != nil
        opacitySlider.doubleValue = Double(a.opacity * 100)
        rows["Line"]?.isHidden = ![.square, .circle, .line, .ink, .polygon, .polyLine].contains(a.kind)
        selectClosest(widthPopup, MarkupBarViewController.widths, a.borderWidth)
        rows["Text size"]?.isHidden = !isText
        selectClosest(sizePopup, MarkupBarViewController.sizes, a.fontSize)
        commentLabel.stringValue = isText ? "Text" : "Comment"
        if view.window?.firstResponder !== commentView || shownContents != a.contents {
            commentView.string = a.contents
        }
        shownContents = a.contents
    }

    private func selectClosest(_ popup: NSPopUpButton, _ values: [CGFloat], _ value: CGFloat) {
        let index = values.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset ?? 0
        popup.selectItem(at: index)
    }

    private func change(_ name: String, _ configure: (inout AnnotationChange) -> Void) {
        guard let ref else { return }
        do {
            try viewer.annotations.update(ref, actionName: name, configure)
        } catch {
            NSSound.beep()
        }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let ref, let a = viewer.annotations.annotation(ref) else { return }
        let color = PDFColor(sender.color)
        change("Colour") { change in
            if a.kind == .freeText {
                change.font = (size: a.fontSize > 0 ? a.fontSize : 12, color: color)
            } else {
                change.color = .some(color)
            }
        }
    }

    @objc private func fillChanged(_ sender: Any?) {
        let fill: PDFColor? = fillCheckbox.state == .on ? PDFColor(fillWell.color) : nil
        change("Fill") { $0.interiorColor = .some(fill) }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        change("Opacity") { $0.opacity = CGFloat(sender.doubleValue / 100) }
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        change("Line Width") { $0.borderWidth = MarkupBarViewController.widths[sender.indexOfSelectedItem] }
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        guard let ref, let a = viewer.annotations.annotation(ref) else { return }
        let size = MarkupBarViewController.sizes[sender.indexOfSelectedItem]
        change("Text Size") { $0.font = (size: size, color: a.textColor ?? .black) }
    }

    func textDidEndEditing(_ notification: Notification) {
        let text = commentView.string
        guard text != shownContents else { return }
        shownContents = text
        change("Edit Text") { $0.contents = text }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let ref else { return }
        try? viewer.annotations.delete(ref)
        viewer.pagesView.selectedAnnotation = nil
    }
}
