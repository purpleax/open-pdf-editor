import AppKit
import PDFCore

/// Page thumbnails. Uses the same preview images as the page view, so a
/// page is rendered small only once. Pages can be selected together, dragged
/// to a new place, and files dropped between them to insert their pages.
@MainActor
final class ThumbnailsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let viewer: ViewerController
    private let table = ThumbnailTable()
    private var isSyncingSelection = false
    static let thumbnailWidth: CGFloat = 110
    /// Rows dragged within this table (never between documents).
    private static let pagesType = NSPasteboard.PasteboardType("com.purpleax.openpdfeditor.pages")
    private let dragToken = UUID().uuidString

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
        table.allowsMultipleSelection = true
        table.setAccessibilityLabel("Page thumbnails")
        table.onDelete = { [weak self] in self?.deleteSelected() }
        if viewer.model.allows(.assemble) {
            table.registerForDraggedTypes([Self.pagesType, .fileURL])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.draggingDestinationFeedbackStyle = .gap
        }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
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

    /// The pages themselves changed: everything is reloaded.
    func structureDidChange() {
        guard isViewLoaded else { return }
        isSyncingSelection = true
        table.reloadData()
        isSyncingSelection = false
        showCurrentPage()
    }

    func showCurrentPage() {
        let page = viewer.currentPage
        // A selection of several pages that includes the current one stays.
        guard page < table.numberOfRows, !table.selectedRowIndexes.contains(page) else { return }
        isSyncingSelection = true
        table.selectRowIndexes([page], byExtendingSelection: false)
        isSyncingSelection = false
        table.scrollRowToVisible(page)
    }

    /// Selects these pages (after a change to them).
    func select(_ pages: [Int]) {
        guard isViewLoaded else { return }
        let rows = IndexSet(pages.filter { $0 < table.numberOfRows })
        guard !rows.isEmpty else { return }
        isSyncingSelection = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        isSyncingSelection = false
        if let first = rows.first { table.scrollRowToVisible(first) }
    }

    /// The selected pages, when the thumbnails are on screen.
    var selectedPages: [Int] {
        guard isViewLoaded, table.window != nil else { return [] }
        return Array(table.selectedRowIndexes)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { viewer.model.pageCount }

    private func thumbnailSize(_ page: Int) -> NSSize {
        guard page < viewer.model.pageCount else { return NSSize(width: Self.thumbnailWidth, height: Self.thumbnailWidth) }
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
        guard !isSyncingSelection else { return }
        let rows = table.selectedRowIndexes
        // With several selected, show the one just clicked (or the first).
        let row = rows.count > 1 && rows.contains(table.clickedRow) ? table.clickedRow : rows.first
        guard let row, rows.count == 1 || row != viewer.currentPage else { return }
        viewer.go(to: ViewLocation(page: row), record: false)
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard viewer.model.allows(.assemble) else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(dragToken):\(row)", forType: Self.pagesType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard viewer.model.allows(.assemble) else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        if !draggedRows(info).isEmpty { return .move }
        return droppedFiles(info).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let rows = draggedRows(info)
        if !rows.isEmpty {
            viewer.pages.move(rows, to: row)
            return true
        }
        let files = droppedFiles(info)
        guard !files.isEmpty else { return false }
        // After the panel has finished with the drop.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.viewer.pages.insert(files, at: row) }
        }
        return true
    }

    /// Rows being dragged from this table.
    private func draggedRows(_ info: NSDraggingInfo) -> [Int] {
        guard (info.draggingSource as? NSTableView) === table else { return [] }
        let items = info.draggingPasteboard.pasteboardItems ?? []
        return items.compactMap { item -> Int? in
            guard let value = item.string(forType: Self.pagesType) else { return nil }
            let parts = value.split(separator: ":")
            guard parts.count == 2, parts[0] == dragToken else { return nil }
            return Int(parts[1])
        }
    }

    /// Files of a kind that can become pages.
    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: PageEditor.insertableTypes.map(\.identifier),
        ]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    // MARK: Menu and keys

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
            table.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        guard clicked >= 0 else { return }
        let count = table.selectedRowIndexes.count
        let noun = count == 1 ? "Page" : "\(count) Pages"
        menu.addItem(withTitle: "Rotate Left", action: #selector(DocumentWindowController.rotatePagesLeft(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Rotate Right", action: #selector(DocumentWindowController.rotatePagesRight(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Insert Blank Page After", action: #selector(DocumentWindowController.insertBlankPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Insert Pages from File…", action: #selector(DocumentWindowController.insertPagesFromFile(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Extract \(noun)…", action: #selector(DocumentWindowController.extractPages(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Delete \(noun)", action: #selector(DocumentWindowController.deletePages(_:)), keyEquivalent: "")
    }

    private func deleteSelected() {
        guard viewer.model.allows(.assemble) else {
            NSSound.beep()
            return
        }
        viewer.pages.delete(Array(table.selectedRowIndexes))
    }
}

/// The thumbnails table: Delete and Forward Delete delete the selected pages.
@MainActor
final class ThumbnailTable: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           key == NSDeleteCharacter || key == NSDeleteFunctionKey || key == NSBackspaceCharacter {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class ThumbnailCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")
    private let image = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var ticket: RenderTicket?
    private var page = -1
    private var revision = -1
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
        self.revision = revision
        image.image = nil
        label.stringValue = "\(page + 1)"
        NSLayoutConstraint.deactivate(sizeConstraints)
        sizeConstraints = [image.widthAnchor.constraint(equalToConstant: size.width),
                           image.heightAnchor.constraint(equalToConstant: size.height)]
        NSLayoutConstraint.activate(sizeConstraints)
        setAccessibilityLabel("Page \(page + 1)")
        let key = RenderKey.preview(page: page, width: PageView.previewWidth, rotation: rotation, revision: revision)
        ticket = renderer.request(key, priority: .low) { [weak self] cgImage in
            guard let self, self.page == page, self.revision == revision else { return }
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
