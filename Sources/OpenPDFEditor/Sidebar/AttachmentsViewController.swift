import AppKit
import PDFCore
import UniformTypeIdentifiers

/// Files embedded in the PDF, which can be saved out.
@MainActor
final class AttachmentsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: DocumentModel
    private let table = NSTableView()
    private let saveButton = NSButton(title: "Save…", target: nil, action: nil)
    private let empty = placeholderLabel("This document has no attachments.")
    private var items: [Attachment] = []

    init(model: DocumentModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 36
        table.target = self
        table.doubleAction = #selector(save(_:))
        table.setAccessibilityLabel("Attachments")
        let scroll = makeTableScrollView(table)
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.isEnabled = false
        saveButton.controlSize = .small
        for v in [scroll, saveButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        let root = NSView()
        root.addSubview(scroll)
        root.addSubview(saveButton)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            saveButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            saveButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        embedPlaceholder(empty, in: root)
        view = root
        let engine = model.engine
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = (try? engine.attachments()) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.items = items
                self.table.reloadData()
                self.empty.isHidden = !items.isEmpty
                self.saveButton.isHidden = items.isEmpty
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data))
        let name = NSTextField(labelWithString: item.filename)
        name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        for v in [icon, name, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor),
        ])
        cell.textField = name
        cell.setAccessibilityLabel("\(item.filename), \(detail.stringValue)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        saveButton.isEnabled = table.selectedRow >= 0
    }

    @objc private func save(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, let window = view.window else { return }
        let item = items[row]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (item.filename as NSString).lastPathComponent
        panel.beginSheetModal(for: window) { [model] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try model.engine.saveAttachment(named: item.name, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The attachment couldn’t be saved."
                alert.informativeText = "\(error)"
                alert.beginSheetModal(for: window)
            }
        }
    }
}
