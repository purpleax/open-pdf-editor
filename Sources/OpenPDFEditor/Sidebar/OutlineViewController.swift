import AppKit
import PDFCore

/// The document's bookmarks (outline). Clicking an item goes there.
@MainActor
final class OutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let viewer: ViewerController
    private let outlineView = NSOutlineView()
    private var roots: [OutlineItem] = []
    private let empty = placeholderLabel("This document has no outline.")

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("title"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.setAccessibilityLabel("Outline")
        let scroll = makeTableScrollView(outlineView)
        let root = NSView()
        scroll.frame = root.bounds
        scroll.autoresizingMask = [.width, .height]
        root.addSubview(scroll)
        embedPlaceholder(empty, in: root)
        view = root
        load()
    }

    /// Pages moved or went: the outline's page numbers are read again.
    func reload() {
        guard isViewLoaded else { return }
        load()
    }

    private func load() {
        empty.stringValue = "Loading…"
        let engine = viewer.model.engine
        EngineExecutor.background.async(.high) { [weak self] in
            let roots = (try? engine.outline()) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.roots = roots
                self.outlineView.reloadData()
                self.expand(roots)
                self.empty.stringValue = "This document has no outline."
                self.empty.isHidden = !roots.isEmpty
            }
        }
    }

    private func expand(_ items: [OutlineItem]) {
        for item in items where item.isOpen && !item.children.isEmpty {
            outlineView.expandItem(item)
            expand(item.children)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OutlineItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? OutlineItem)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? OutlineItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? OutlineItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? OutlineCell) ?? OutlineCell(identifier: identifier)
        cell.title.stringValue = item.title
        // A web link's tooltip shows where it goes.
        if item.page == nil, let url = item.uri.flatMap(WebLinks.url) {
            cell.title.toolTip = "\(item.title)\n\(url.absoluteString)"
        } else {
            cell.title.toolTip = item.title
        }
        cell.pageLabel.stringValue = item.page.map { "\($0 + 1)" } ?? ""
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? OutlineItem else { return }
        if let page = item.page {
            viewer.go(to: ViewLocation(page: page, point: item.point))
        } else if let uri = item.uri, WebLinks.url(uri) != nil {
            WebLinks.open(uri, from: view.window)
        }
    }
}

@MainActor
private final class OutlineCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let pageLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(title)
        addSubview(pageLabel)
        textField = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            pageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            pageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
