import AppKit
import PDFCore

/// The inspector's section for the selected page content while editing
/// content: where a link goes, an image's size, or a text run's font, size
/// and colour. Each change is one undoable step.
@MainActor
final class ContentInspectorViewController: NSViewController, NSTextFieldDelegate {
    let viewer: ViewerController
    var ref: ContentRef? {
        didSet { reload() }
    }
    /// Asks where a link goes (the window shows the sheet).
    var onChangeLink: ((ContentRef) -> Void)?
    /// Asks for another image file.
    var onReplaceImage: ((ContentRef) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let changeButton = NSButton(title: "Change Target…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let editTextButton = NSButton(title: "Edit Text", target: nil, action: nil)
    private let fontButton = NSButton(title: "Change Font…", target: nil, action: nil)
    private let sizeField = NSTextField()
    private let colorWell = NSColorWell(style: .minimal)
    private var textRows: [NSView] = []

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        for (button, action) in [(changeButton, #selector(changeClicked(_:))), (deleteButton, #selector(deleteClicked(_:))),
                                 (editTextButton, #selector(editTextClicked(_:))), (fontButton, #selector(fontClicked(_:)))] {
            button.target = self
            button.action = action
            button.controlSize = .small
        }
        sizeField.delegate = self
        sizeField.target = self
        sizeField.action = #selector(sizeCommitted(_:))
        sizeField.formatter = {
            let f = NumberFormatter()
            f.minimum = 1
            f.maximum = 1000
            f.maximumFractionDigits = 1
            return f
        }()
        sizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        sizeField.setAccessibilityLabel("Text size in points")
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.setAccessibilityLabel("Text colour")

        func row(_ label: String, _ views: [NSView]) -> NSView {
            let name = NSTextField(labelWithString: label)
            name.textColor = .secondaryLabelColor
            name.widthAnchor.constraint(equalToConstant: 64).isActive = true
            let stack = NSStackView(views: [name] + views)
            stack.spacing = 8
            return stack
        }
        let sizeRow = row("Size", [sizeField, NSTextField(labelWithString: "pt")])
        let colorRow = row("Colour", [colorWell])
        textRows = [editTextButton, fontButton, sizeRow, colorRow]
        let stack = NSStackView(views: [titleLabel, detailLabel, editTextButton, fontButton, sizeRow, colorRow,
                                        NSStackView(views: [changeButton, deleteButton])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        view = stack
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        guard let ref, let item = viewer.content.item(ref) else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        let editable = viewer.model.isEditable
        textRows.forEach { $0.isHidden = true }
        changeButton.isHidden = false
        switch ref {
        case .link:
            titleLabel.stringValue = "Link"
            detailLabel.stringValue = item.link.map { "Goes to \(ContentController.describe($0))" } ?? ""
            changeButton.title = "Change Target…"
        case .image:
            titleLabel.stringValue = "Image"
            detailLabel.stringValue = item.image.map { "\($0.pixelWidth) × \($0.pixelHeight) pixels. Shift-drag a corner to keep its proportions." } ?? ""
            changeButton.title = "Replace…"
        case .text:
            titleLabel.stringValue = "Text"
            changeButton.isHidden = true
            guard let run = item.run else { break }
            let reason = ContentController.restriction(run)
            detailLabel.stringValue = reason ?? "\(run.fontName.isEmpty ? "Unnamed font" : run.fontName). Double-click the text, or press Return, to change it."
            textRows.forEach { $0.isHidden = reason != nil }
            if sizeField.currentEditor() == nil { sizeField.stringValue = String(format: "%g", (run.size * 10).rounded() / 10) }
            colorWell.color = run.color?.nsColor ?? .black
            colorWell.isEnabled = editable && run.color != nil
            colorWell.toolTip = run.color == nil ? "This text's colour isn't plain grey, RGB or CMYK, so it isn't changed here." : nil
        }
        for control in [changeButton, deleteButton, editTextButton, fontButton] { control.isEnabled = editable }
        sizeField.isEnabled = editable
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            guard let window = view.window else { return NSSound.beep() }
            let alert = NSAlert()
            alert.messageText = "The change couldn’t be made."
            alert.informativeText = "\(error)"
            alert.beginSheetModal(for: window)
        }
        reload()
    }

    @objc private func changeClicked(_ sender: Any?) {
        guard let ref else { return }
        switch ref {
        case .link: onChangeLink?(ref)
        case .image: onReplaceImage?(ref)
        case .text: break
        }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let ref else { return }
        perform {
            try viewer.content.delete(ref)
            viewer.pagesView.selectedContent = nil
        }
    }

    @objc private func editTextClicked(_ sender: Any?) {
        viewer.pagesView.beginTextEdit()
    }

    // MARK: Font

    @objc private func fontClicked(_ sender: Any?) {
        guard let ref, let run = viewer.content.item(ref)?.run else { return }
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(fontChosen(_:))
        manager.setSelectedFont(NSFont(name: run.fontName, size: max(run.size, 4)) ?? .systemFont(ofSize: max(run.size, 4)), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc private func fontChosen(_ sender: NSFontManager) {
        guard let ref, let run = viewer.content.item(ref)?.run else { return }
        let current = NSFont(name: run.fontName, size: max(run.size, 4)) ?? .systemFont(ofSize: max(run.size, 4))
        let chosen = sender.convert(current)
        perform {
            if chosen.fontName != current.fontName { try viewer.content.setFont(ref, chosen) }
            if abs(chosen.pointSize - run.size) > 0.05 { try viewer.content.setSize(ref, chosen.pointSize) }
        }
    }

    // MARK: Size and colour

    @objc private func sizeCommitted(_ sender: NSTextField) {
        guard let ref, let run = viewer.content.item(ref)?.run else { return }
        let size = CGFloat(sender.doubleValue)
        guard size > 0, abs(size - run.size) > 0.05 else { return }
        perform { try viewer.content.setSize(ref, size) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === sizeField { sizeCommitted(sizeField) }
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let ref, let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        perform { try viewer.content.setColor(ref, PDFColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)) }
    }
}
