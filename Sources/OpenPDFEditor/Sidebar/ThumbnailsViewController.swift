import AppKit
import PDFCore

/// Page thumbnails. Uses the same preview images as the page view, so a
/// page is rendered small only once.
@MainActor
final class ThumbnailsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let viewer: ViewerController
    private let table = NSTableView()
    private var isSyncingSelection = false
    static let thumbnailWidth: CGFloat = 110

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.setAccessibilityLabel("Page thumbnails")
        let scroll = makeTableScrollView(table)
        table.style = .inset
        view = scroll
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        showCurrentPage()
    }

    func reload() {
        table.reloadData()
        showCurrentPage()
    }

    /// Redraws the thumbnails of pages that changed (nil: all).
    func reload(pages: Set<Int>?) {
        guard isViewLoaded else { return }
        guard let pages else { return reload() }
        let rows = IndexSet(pages.filter { $0 < table.numberOfRows })
        table.reloadData(forRowIndexes: rows, columnIndexes: [0])
    }

    func showCurrentPage() {
        let page = viewer.currentPage
        guard page < table.numberOfRows, table.selectedRow != page else { return }
        isSyncingSelection = true
        table.selectRowIndexes([page], byExtendingSelection: false)
        isSyncingSelection = false
        table.scrollRowToVisible(page)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { viewer.model.pageCount }

    private func thumbnailSize(_ page: Int) -> NSSize {
        let size = viewer.model.viewSize(page: page, rotation: viewer.rotation)
        let width = Self.thumbnailWidth
        let height = min(width * size.height / max(size.width, 1), width * 1.6)
        return NSSize(width: min(width, height * size.width / max(size.height, 1)), height: height)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        thumbnailSize(row).height + 26
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ThumbnailCell.identifier, owner: nil) as? ThumbnailCell) ?? ThumbnailCell()
        cell.show(page: row, size: thumbnailSize(row), renderer: viewer.renderer, rotation: viewer.rotation,
                  revision: viewer.model.revision(page: row))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, table.selectedRow >= 0 else { return }
        viewer.go(to: ViewLocation(page: table.selectedRow), record: false)
    }
}

@MainActor
final class ThumbnailCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")
    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var ticket: RenderTicket?
    private var page = -1
    private var sizeConstraints: [NSLayoutConstraint] = []

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.white.cgColor
        image.layer?.borderColor = NSColor.separatorColor.cgColor
        image.layer?.borderWidth = 0.5
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(label)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 3),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(page: Int, size: NSSize, renderer: TileRenderer, rotation: Int, revision: Int) {
        ticket?.cancel()
        ticket = nil
        self.page = page
        image.image = nil
        label.stringValue = "\(page + 1)"
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints = [image.widthAnchor.constraint(equalToConstant: size.width),
                           image.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(sizeConstraints)
        setAccessibilityLabel("Page \(page + 1)")
        let key = RenderKey.preview(page: page, width: PageView.previewWidth, rotation: rotation, revision: revision)
        ticket = renderer.request(key, priority: .low) { [weak self] cgImage in
            guard let self, self.page == page else { return }
            self.ticket = nil
            self.image.image = NSImage(cgImage: cgImage, size: size)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ticket?.cancel()
        ticket = nil
    }
}
