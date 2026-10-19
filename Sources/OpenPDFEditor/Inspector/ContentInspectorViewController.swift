import AppKit
import PDFCore

/// The inspector's section for the selected page content while editing
/// content: where a link goes, or an image's size. (Text is formatted in the
/// formatting bar while it is being edited.) Each change is one undoable step.
@MainActor
final class ContentInspectorViewController: NSViewController {
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
        for (button, action) in [(changeButton, #selector(changeClicked(_:))), (deleteButton, #selector(deleteClicked(_:)))] {
            button.target = self
            button.action = action
            button.controlSize = .small
        }
        let stack = NSStackView(views: [titleLabel, detailLabel, NSStackView(views: [changeButton, deleteButton])])
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
        switch ref {
        case .link:
            titleLabel.stringValue = "Link"
            detailLabel.stringValue = item.link.map { "Goes to \(ContentController.describe($0))" } ?? ""
            changeButton.title = "Change Target…"
        case .image:
            titleLabel.stringValue = "Image"
            detailLabel.stringValue = item.image.map { "\($0.pixelWidth) × \($0.pixelHeight) pixels. Shift-drag a corner to keep its proportions." } ?? ""
            changeButton.title = "Replace…"
        }
        view.isHidden = false
        let editable = viewer.model.allows(.edit)
        for control in [changeButton, deleteButton] { control.isEnabled = editable }
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
        }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let ref else { return }
        perform {
            try viewer.content.delete(ref)
            viewer.pagesView.selectedContent = nil
        }
    }
}
