import AppKit
import PDFCore

/// The inspector: the document's properties. Title, Author, Subject and
/// Keywords can be changed; each change is one undoable step.
@MainActor
final class DocumentInfoViewController: NSViewController, NSTextFieldDelegate {
    let viewer: ViewerController
    let fileURL: URL?
    private let list = NSStackView()
    private var pageSizeField: NSTextField?
    private var pageCountField: NSTextField?
    /// The editable fields, by Info key.
    private var editable: [String: NSTextField] = [:]
    private var valueFields: [String: NSTextField] = [:]
    private static let editableKeys = ["Title", "Author", "Subject", "Keywords"]

    init(viewer: ViewerController, fileURL: URL?) {
        self.viewer = viewer
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: "Document")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        let stack = NSStackView(views: [title, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = scroll
        fill()
    }

    private func fill() {
        let engine = viewer.model.engine
        func meta(_ key: String) -> String? {
            engine.metadata(key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        var rows: [(String, String?)] = [
            ("Title", meta("info:Title")),
            ("Author", meta("info:Author")),
            ("Subject", meta("info:Subject")),
            ("Keywords", meta("info:Keywords")),
            ("Created", meta("info:CreationDate").map { PDFDate.parse($0).map(dates.string) ?? $0 }),
            ("Modified", meta("info:ModDate").map { PDFDate.parse($0).map(dates.string) ?? $0 }),
            ("Application", meta("info:Creator")),
            ("PDF Producer", meta("info:Producer")),
            ("Version", meta("format")),
            ("Security", meta("encryption").flatMap { $0 == "None" ? nil : $0 } ?? "None"),
            ("Pages", "\(viewer.model.pageCount)"),
            ("Page Size", ""),
        ]
        if let url = fileURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            rows.append(("File Size", size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }))
            rows.append(("Location", url.deletingLastPathComponent().path))
        }
        // Each property's name above its value, which suits a narrow panel.
        for (label, value) in rows {
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            name.textColor = .secondaryLabelColor
            let field: NSTextField
            if Self.editableKeys.contains(label) {
                field = NSTextField(string: value ?? "")
                field.placeholderString = "—"
                field.isEditable = viewer.model.allows(.edit)
                field.delegate = self
                field.target = self
                field.action = #selector(infoCommitted(_:))
                field.lineBreakMode = .byTruncatingTail
                field.setAccessibilityLabel(label)
                editable[label] = field
            } else {
                field = NSTextField(wrappingLabelWithString: value ?? "—")
                field.isSelectable = true
                valueFields[label] = field
            }
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if label == "Page Size" { pageSizeField = field }
            if label == "Pages" { pageCountField = field }
            let pair = NSStackView(views: [name, field])
            pair.orientation = .vertical
            pair.alignment = .leading
            pair.spacing = 1
            list.addArrangedSubview(pair)
            pair.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            field.widthAnchor.constraint(equalTo: pair.widthAnchor).isActive = true
            pair.setAccessibilityElement(true)
            pair.setAccessibilityRole(.group)
            pair.setAccessibilityLabel(label)
        }
        if let stack = list.superview { list.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        pageDidChange()
    }

    /// Shows the document's information again (after a change, undo or redo),
    /// leaving alone a field being typed in.
    func reload() {
        guard isViewLoaded else { return }
        let engine = viewer.model.engine
        for (key, field) in editable where field.currentEditor() == nil {
            field.stringValue = engine.metadata("info:\(key)") ?? ""
            field.isEditable = viewer.model.allows(.edit)
        }
        valueFields["Security"]?.stringValue = engine.metadata("encryption").flatMap { $0 == "None" ? nil : $0 } ?? "None"
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        if let modified = engine.metadata("info:ModDate") {
            valueFields["Modified"]?.stringValue = PDFDate.parse(modified).map(dates.string) ?? modified
        }
    }

    @objc private func infoCommitted(_ sender: NSTextField) {
        guard let key = editable.first(where: { $0.value === sender })?.key else { return }
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (viewer.model.engine.metadata("info:\(key)") ?? "") else { return }
        do {
            try viewer.model.edit("Change \(key)", pages: []) { engine in
                switch key {
                case "Title": try engine.setMetadata(title: value)
                case "Author": try engine.setMetadata(author: value)
                case "Subject": try engine.setMetadata(subject: value)
                default: try engine.setMetadata(keywords: value)
                }
            }
        } catch {
            NSSound.beep()
            reload()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { infoCommitted(field) }
    }

    func pageDidChange() {
        let page = viewer.currentPage
        guard page < viewer.model.pageCount else { return }
        pageCountField?.stringValue = "\(viewer.model.pageCount)"
        let size = viewer.model.pageBounds[page].size
        pageSizeField?.stringValue = Self.describe(size) + " (page \(page + 1))"
    }

    static func describe(_ size: CGSize) -> String {
        let mm = { (points: CGFloat) in Int((points / 72 * 25.4).rounded()) }
        let inches = { (points: CGFloat) in String(format: "%.2f", points / 72).replacingOccurrences(of: ".00", with: "") }
        let metric = "\(mm(size.width)) × \(mm(size.height)) mm"
        let imperial = "\(inches(size.width)) × \(inches(size.height)) in"
        return Locale.current.measurementSystem == .metric ? metric : "\(imperial) (\(metric))"
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
