import AppKit
import PDFCore

/// Every match of the current search, with the text around it.
@MainActor
final class SearchResultsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let viewer: ViewerController
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let empty = placeholderLabel("Type in the search field to find text.")
    private var isSyncingSelection = false

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("match"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.usesAutomaticRowHeights = true
        table.setAccessibilityLabel("Search results")
        let scroll = makeTableScrollView(table)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(status)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        embedPlaceholder(empty, in: root)
        view = root
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let find = viewer.find
        table.reloadData()
        let count = find.matches.count
        if find.query.trimmingCharacters(in: .whitespaces).isEmpty {
            status.stringValue = ""
            empty.stringValue = "Type in the search field to find text."
            empty.isHidden = false
        } else if find.isSearching {
            status.stringValue = "\(count) found · searching page \(find.pagesSearched + 1) of \(viewer.model.pageCount)…"
            empty.isHidden = true
        } else {
            status.stringValue = count == 1 ? "1 match" : "\(count) matches"
            empty.stringValue = "No matches for “\(find.query)”."
            empty.isHidden = count > 0
        }
        if let index = find.currentIndex, index < table.numberOfRows {
            isSyncingSelection = true
            table.selectRowIndexes([index], byExtendingSelection: false)
            isSyncingSelection = false
            table.scrollRowToVisible(index)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { viewer.find.matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MatchCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? MatchCell) ?? MatchCell(identifier: identifier)
        let match = viewer.find.matches[row]
        cell.pageLabel.stringValue = "Page \(match.page + 1)"
        let snippet = NSMutableAttributedString(string: match.context.before, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        snippet.append(NSAttributedString(string: match.context.match, attributes: [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
        ]))
        snippet.append(NSAttributedString(string: match.context.after, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        cell.snippet.attributedStringValue = snippet
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, table.selectedRow >= 0 else { return }
        viewer.find.select(table.selectedRow)
        if let match = viewer.find.currentMatch { viewer.showMatch(match) }
    }
}

@MainActor
private final class MatchCell: NSTableCellView {
    let pageLabel = NSTextField(labelWithString: "")
    let snippet = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        pageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        pageLabel.textColor = .secondaryLabelColor
        snippet.maximumNumberOfLines = 3
        snippet.lineBreakMode = .byTruncatingTail
        snippet.cell?.truncatesLastVisibleLine = true
        for field in [pageLabel, snippet] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            pageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            pageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            snippet.topAnchor.constraint(equalTo: pageLabel.bottomAnchor, constant: 1),
            snippet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            snippet.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
