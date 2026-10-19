import AppKit
import PDFCore

/// The inspector: the selected annotation (when there is one) above the
/// document's properties.
@MainActor
final class InspectorViewController: NSViewController {
    let annotation: AnnotationInspectorViewController
    let field: FieldInspectorViewController
    let document: DocumentInfoViewController
    private let separator = NSBox()

    init(viewer: ViewerController, fileURL: URL?) {
        annotation = AnnotationInspectorViewController(viewer: viewer)
        field = FieldInspectorViewController(viewer: viewer)
        document = DocumentInfoViewController(viewer: viewer, fileURL: fileURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        addChild(annotation)
        addChild(field)
        addChild(document)
        separator.boxType = .separator
        // A stack collapses the annotation section when it is hidden.
        let stack = NSStackView(views: [annotation.view, field.view, separator, document.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 0
        for v in [annotation.view, field.view, separator, document.view] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        document.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        annotation.view.setContentHuggingPriority(.required, for: .vertical)
        field.view.setContentHuggingPriority(.required, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        update()
    }

    func show(_ ref: AnnotationRef?) {
        annotation.ref = ref
        update()
    }

    func show(field ref: FieldRef?) {
        field.ref = ref
        update()
    }

    func refresh() {
        annotation.reload()
        field.reload()
        document.reload()
        update()
    }

    private func update() {
        guard isViewLoaded else { return }
        separator.isHidden = annotation.view.isHidden && field.view.isHidden
    }

    func pageDidChange() { document.pageDidChange() }
}
