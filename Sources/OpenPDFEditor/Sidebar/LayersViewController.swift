import AppKit
import PDFCore

/// The PDF's optional content (layers), as its author arranged them, with
/// switches to show and hide them.
@MainActor
final class LayersViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: DocumentModel
    private let table = NSTableView()
    private let empty = placeholderLabel("This document has no layers.")
    private var layers: [Layer] = []

    init(model: DocumentModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("layer"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.selectionHighlightStyle = .none
        table.setAccessibilityLabel("Layers")
        let scroll = makeTableScrollView(table)
        let root = NSView()
        scroll.frame = root.bounds
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        embedPlaceholder(empty, in: root)
        view = root
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        layers = (try? model.engine.layers()) ?? []
        table.reloadData()
        empty.isHidden = !layers.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layers.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let layer = layers[row]
        let cell = NSTableCellView()
        let control: NSView
        switch layer.kind {
        case .label:
            let label = NSTextField(labelWithString: layer.text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            control = label
        case .checkbox, .radio:
            let button = layer.kind == .checkbox
                ? NSButton(checkboxWithTitle: layer.text, target: self, action: #selector(toggle(_:)))
                : NSButton(radioButtonWithTitle: layer.text, target: self, action: #selector(toggle(_:)))
            button.state = layer.isOn ? .on : .off
            button.isEnabled = !layer.isLocked
            button.tag = layer.index
            button.lineBreakMode = .byTruncatingTail
            control = button
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4 + CGFloat(layer.depth) * 16),
            control.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func toggle(_ sender: NSButton) {
        do {
            try model.toggleLayer(sender.tag)
        } catch {
            NSSound.beep()
        }
        reload()
    }
}
