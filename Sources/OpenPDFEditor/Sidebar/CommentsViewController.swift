import AppKit
import PDFCore

/// The Comments list: every annotation by page, with its replies and
/// review status. Filters by type, author and status; reply, set a status
/// or delete from the buttons or the context menu.
@MainActor
final class CommentsViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let viewer: ViewerController

    final class PageGroup {
        let page: Int
        var threads: [Thread] = []
        init(page: Int) { self.page = page }
    }

    final class Thread {
        let annotation: Annotation
        var replies: [Annotation] = []
        /// Row items for the replies (the outline needs the same objects each time).
        var replyItems: [Reply] = []
        var status: Annotation?
        init(_ annotation: Annotation) { self.annotation = annotation }
        var ref: AnnotationRef { AnnotationRef(page: annotation.page, id: annotation.id) }
    }

    final class Reply {
        let annotation: Annotation
        init(_ annotation: Annotation) { self.annotation = annotation }
    }

    enum TypeFilter: Int, CaseIterable {
        case all, markup, notes, textBoxes, drawings, stamps
        var title: String {
            switch self {
            case .all: "All Types"
            case .markup: "Highlights & Markup"
            case .notes: "Notes"
            case .textBoxes: "Text Boxes"
            case .drawings: "Shapes & Drawings"
            case .stamps: "Stamps"
            }
        }
        func matches(_ kind: Annotation.Kind) -> Bool {
            switch self {
            case .all: true
            case .markup: kind.isTextMarkup || kind == .caret
            case .notes: kind == .text
            case .textBoxes: kind == .freeText
            case .drawings: [.square, .circle, .line, .ink, .polygon, .polyLine].contains(kind)
            case .stamps: kind == .stamp
            }
        }
    }

    static let statuses = ["Accepted", "Rejected", "Cancelled", "Completed"]

    private let outline = NSOutlineView()
    private let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let replyButton = NSButton(title: "Reply…", target: nil, action: nil)
    private let setStatusButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let empty = placeholderLabel("No comments yet. Use the markup tools (⇧⌘A) to add some.")
    private var all: [Int: [Annotation]] = [:]
    private var groups: [PageGroup] = []
    private var isSyncingSelection = false

    init(viewer: ViewerController) {
        self.viewer = viewer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("comment"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.usesAutomaticRowHeights = true
        outline.setAccessibilityLabel("Comments")
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        let scroll = makeTableScrollView(outline)

        for filter in TypeFilter.allCases { typePopup.addItem(withTitle: filter.title) }
        statusPopup.addItems(withTitles: ["Any Status", "No Status"] + Self.statuses)
        for popup in [typePopup, authorPopup, statusPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.target = self
            popup.action = #selector(filterChanged(_:))
        }
        typePopup.setAccessibilityLabel("Type")
        authorPopup.setAccessibilityLabel("Author")
        statusPopup.setAccessibilityLabel("Status")
        let filters = NSStackView(views: [typePopup, authorPopup, statusPopup])
        filters.orientation = .vertical
        filters.alignment = .leading
        filters.spacing = 4

        replyButton.controlSize = .small
        replyButton.target = self
        replyButton.action = #selector(replyClicked(_:))
        setStatusButton.controlSize = .small
        setStatusButton.addItem(withTitle: "Status")
        for status in Self.statuses + ["None"] {
            setStatusButton.addItem(withTitle: status)
            setStatusButton.lastItem?.target = self
            setStatusButton.lastItem?.action = #selector(statusChosen(_:))
        }
        let actions = NSStackView(views: [replyButton, setStatusButton])
        actions.spacing = 6

        let root = NSView()
        for v in [filters, scroll, actions] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            filters.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            filters.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filters.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actions.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        embedPlaceholder(empty, in: root)
        view = root
        reload()
        updateButtons()
    }

    // MARK: Loading

    /// Reloads the annotations of some pages (nil: all). Pages that changed
    /// are read straight away; the whole document loads in the background.
    /// Each page's list is kept with its revision, so an older load never
    /// replaces a newer one.
    func reload(pages: Set<Int>? = nil) {
        guard isViewLoaded else { return }
        let model = viewer.model
        if let pages {
            for page in pages where page < model.pageCount {
                store(page, model.annotations(page: page), revision: model.revision(page: page))
            }
            rebuild()
            return
        }
        EngineExecutor.background.async(.high) { [weak self] in
            var found: [(Int, [Annotation], Int)] = []
            for page in 0..<model.pageCount {
                let revision = model.revision(page: page)
                found.append((page, model.annotations(page: page), revision))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (page, list, revision) in found { self.store(page, list, revision: revision) }
                self.rebuild()
            }
        }
    }

    private var revisions: [Int: Int] = [:]

    private func store(_ page: Int, _ list: [Annotation], revision: Int) {
        if let known = revisions[page], known > revision { return }
        revisions[page] = revision
        all[page] = list
    }

    private func rebuild() {
        let type = TypeFilter(rawValue: typePopup.indexOfSelectedItem) ?? .all
        let author = authorPopup.indexOfSelectedItem > 0 ? authorPopup.titleOfSelectedItem : nil
        let statusFilter = statusPopup.indexOfSelectedItem

        var authors = Set<String>()
        var result: [PageGroup] = []
        for page in all.keys.sorted() {
            let list = all[page] ?? []
            var threads: [Int: Thread] = [:]
            var order: [Int] = []
            for a in list where !a.isReply && ![.popup, .link, .widget].contains(a.kind) {
                // Annotations without an object number (id 0) can't be told
                // apart by id: give each its own key.
                let key = a.id == 0 ? -(order.count + 1) : a.id
                threads[key] = Thread(a)
                order.append(key)
            }
            for a in list where a.isReply {
                guard let parent = a.inReplyTo, let thread = threads[parent] else { continue }
                if a.isStatus {
                    if a.stateModel == "Review" && (thread.status?.modified ?? .distantPast) <= (a.modified ?? .distantPast) {
                        thread.status = a
                    }
                } else {
                    thread.replies.append(a)
                }
            }
            let group = PageGroup(page: page)
            for id in order {
                guard let thread = threads[id] else { continue }
                if !thread.annotation.author.isEmpty { authors.insert(thread.annotation.author) }
                thread.replies.forEach { if !$0.author.isEmpty { authors.insert($0.author) } }
                guard type.matches(thread.annotation.kind) else { continue }
                if let author, thread.annotation.author != author && !thread.replies.contains(where: { $0.author == author }) { continue }
                let state = thread.status?.state
                switch statusFilter {
                case 1: if state != nil && state != "None" { continue }
                case 2...: if state != Self.statuses[statusFilter - 2] { continue }
                default: break
                }
                thread.replies.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
                thread.replyItems = thread.replies.map(Reply.init)
                group.threads.append(thread)
            }
            if !group.threads.isEmpty { result.append(group) }
        }

        let chosenAuthor = authorPopup.titleOfSelectedItem
        authorPopup.removeAllItems()
        authorPopup.addItem(withTitle: "All Authors")
        authorPopup.addItems(withTitles: authors.sorted())
        if let chosenAuthor, authorPopup.item(withTitle: chosenAuthor) != nil { authorPopup.selectItem(withTitle: chosenAuthor) }

        let selected = selectedThread?.ref
        groups = result
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let count = result.reduce(0) { $0 + $1.threads.count }
        empty.isHidden = count > 0
        empty.stringValue = all.values.contains(where: { !$0.isEmpty })
            ? "No comments match these filters."
            : "No comments yet. Use the markup tools (⇧⌘A) to add some."
        if let selected { select(selected) }
        updateButtons()
    }

    @objc private func filterChanged(_ sender: Any?) { rebuild() }

    // MARK: Selection

    private var selectedThread: Thread? {
        let item = outline.item(atRow: outline.selectedRow)
        if let thread = item as? Thread { return thread }
        if let reply = item as? Reply { return outline.parent(forItem: reply) as? Thread }
        return nil
    }

    /// Shows an annotation selected in the viewer as selected here.
    func select(_ ref: AnnotationRef?) {
        guard isViewLoaded else { return }
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        guard let ref, let thread = groups.lazy.flatMap(\.threads).first(where: { $0.ref == ref }) else {
            outline.deselectAll(nil)
            updateButtons()
            return
        }
        let row = outline.row(forItem: thread)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        updateButtons()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        guard !isSyncingSelection, let thread = selectedThread else { return }
        viewer.reveal(thread.ref)
    }

    #if SELFTEST
    var debugState: String { "row \(outline.selectedRow), reply enabled \(replyButton.isEnabled), threads \(groups.reduce(0) { $0 + $1.threads.count })" }
    #endif

    private func updateButtons() {
        let enabled = selectedThread != nil
        replyButton.isEnabled = enabled
        setStatusButton.isEnabled = enabled
    }

    // MARK: Actions

    @objc private func replyClicked(_ sender: Any?) {
        guard let thread = selectedThread ?? clickedThread, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Reply to \(thread.annotation.author.isEmpty ? "this comment" : thread.annotation.author)"
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        text.isRichText = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        scroll.documentView = text
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Reply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let reply = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { return }
            do { try self.viewer.annotations.reply(to: thread.ref, text: reply) } catch { NSSound.beep() }
        }
    }

    @objc private func statusChosen(_ sender: NSMenuItem) {
        guard let thread = clickedThread ?? selectedThread else { return }
        let state = sender.title == "None" ? nil : sender.title
        do { try viewer.annotations.setStatus(thread.ref, state) } catch { NSSound.beep() }
    }

    @objc private func deleteClicked(_ sender: Any?) {
        guard let thread = clickedThread ?? selectedThread else { return }
        do { try viewer.annotations.delete(thread.ref) } catch { NSSound.beep() }
    }

    @objc private func editClicked(_ sender: Any?) {
        guard let thread = clickedThread ?? selectedThread else { return }
        viewer.reveal(thread.ref)
        viewer.editAnnotation(thread.ref)
    }

    private var clickedThread: Thread? {
        let item = outline.item(atRow: outline.clickedRow)
        if let thread = item as? Thread { return thread }
        if let reply = item as? Reply { return outline.parent(forItem: reply) as? Thread }
        return nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard clickedThread != nil else { return }
        menu.addItem(withTitle: "Edit Comment…", action: #selector(editClicked(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reply…", action: #selector(replyClicked(_:)), keyEquivalent: "").target = self
        let statusItem = menu.addItem(withTitle: "Status", action: nil, keyEquivalent: "")
        let statusMenu = NSMenu()
        for status in Self.statuses + ["None"] {
            statusMenu.addItem(withTitle: status, action: #selector(statusChosen(_:)), keyEquivalent: "").target = self
        }
        statusItem.submenu = statusMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteClicked(_:)), keyEquivalent: "").target = self
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: groups.count
        case let group as PageGroup: group.threads.count
        case let thread as Thread: thread.replies.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: return groups[index]
        case let group as PageGroup: return group.threads[index]
        case let thread as Thread: return thread.replyItems[index]
        default: return NSNull()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let group = item as? PageGroup { return !group.threads.isEmpty }
        if let thread = item as? Thread { return !thread.replies.isEmpty }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is PageGroup }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is PageGroup) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let group as PageGroup:
            let label = NSTextField(labelWithString: "Page \(group.page + 1)")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case let thread as Thread:
            return CommentCell(annotation: thread.annotation, status: thread.status, isReply: false)
        case let reply as Reply:
            return CommentCell(annotation: reply.annotation, status: nil, isReply: true)
        default:
            return nil
        }
    }
}

/// One comment: an icon in the annotation's colour, author and date, and
/// the text.
@MainActor
private final class CommentCell: NSTableCellView {
    init(annotation a: Annotation, status: Annotation?, isReply: Bool) {
        super.init(frame: .zero)
        let symbol: String = switch a.kind {
        case .highlight: "highlighter"
        case .underline, .squiggly: "underline"
        case .strikeOut: "strikethrough"
        case .text: isReply ? "arrowshape.turn.up.left" : "note.text"
        case .freeText: "character.textbox"
        case .square: "rectangle"
        case .circle: "circle"
        case .line: "line.diagonal"
        case .ink: "scribble.variable"
        case .stamp: "seal"
        default: "bubble.left"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: a.kind.name) ?? NSImage())
        icon.contentTintColor = (a.kind == .freeText ? a.textColor : a.color)?.nsColor ?? .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        var heading = a.author.isEmpty ? a.kind.name : a.author
        if let date = a.modified { heading += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        var text = a.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && !isReply { text = a.kind == .stamp && !a.iconName.isEmpty ? a.iconName : a.kind.name }
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        body.maximumNumberOfLines = 4
        body.lineBreakMode = .byTruncatingTail
        body.cell?.truncatesLastVisibleLine = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lines = NSStackView(views: [title, body])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        if let state = status?.state {
            let badge = NSTextField(labelWithString: status.map { $0.author.isEmpty ? state : "\(state) · \($0.author)" } ?? state)
            badge.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .medium)
            badge.textColor = state == "Rejected" || state == "Cancelled" ? .systemRed : .systemGreen
            lines.addArrangedSubview(badge)
        }
        let row = NSStackView(views: [icon, lines])
        row.alignment = .top
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel("\(a.kind.name) by \(a.author): \(text)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
