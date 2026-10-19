import AppKit
import PDFCore

private extension NSToolbarItem.Identifier {
    static let pageNavigation = Self("PageNavigation")
    static let pageNumber = Self("PageNumber")
    static let zoom = Self("Zoom")
    static let zoomMode = Self("ZoomMode")
    static let displayMode = Self("DisplayMode")
    static let rotate = Self("Rotate")
    static let search = Self("Search")
    static let markup = Self("Markup")
}

/// A document window: sidebar, pages and inspector in a split view, with a
/// toolbar. Locked PDFs show a password prompt first.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSMenuItemValidation, NSToolbarItemValidation, NSSearchFieldDelegate, NSTextFieldDelegate {
    private(set) var viewer: ViewerController?
    private(set) var sidebar: SidebarViewController?
    private(set) var inspector: InspectorViewController?
    private let markupBar = MarkupBarViewController()
    private var markupAccessory: NSTitlebarAccessoryViewController?
    private var split: NSSplitViewController?
    private var sidebarItem: NSSplitViewItem?
    private(set) var inspectorItem: NSSplitViewItem?

    private let pageField = NSTextField()
    private let pageCountLabel = NSTextField(labelWithString: "")
    private let navigation = NSSegmentedControl()
    private let zoomButtons = NSSegmentedControl()
    private let zoomPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private weak var searchItem: NSSearchToolbarItem?
    private weak var rotateControl: NSSegmentedControl?
    private var searchDebounce: DispatchWorkItem?
    private var jumpToFirstMatch = false
    private var pendingRestore: (page: Int, zoom: ZoomMode, magnification: CGFloat)?

    private var editorDocument: EditorDocument? { document as? EditorDocument }

    convenience init(document: EditorDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "PDFDocument"
        window.minSize = NSSize(width: 520, height: 400)
        window.center()
        window.setFrameAutosaveName("DocumentWindow")
        window.titlebarSeparatorStyle = .automatic
        self.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
    }

    override var document: AnyObject? {
        didSet { if document != nil, window?.contentViewController == nil { start() } }
    }

    private func start() {
        guard let document = editorDocument, let engine = document.engine else { return }
        if engine.needsPassword {
            window?.contentViewController = PasswordViewController(engine: engine, name: document.displayName) { [weak self] password in
                self?.editorDocument?.password = password
                self?.showDocument()
            }
        } else {
            showDocument()
        }
    }

    // MARK: Building the window

    private func showDocument() {
        guard let document = editorDocument, let window else { return }
        let model: DocumentModel
        do {
            model = try document.makeModel()
        } catch {
            let label = placeholderLabel("This document couldn’t be read.\n\(error)")
            let controller = NSViewController()
            controller.view = NSView()
            embedPlaceholder(label, in: controller.view)
            window.contentViewController = controller
            return
        }
        let viewer = ViewerController(model: model)
        let sidebar = SidebarViewController(viewer: viewer)
        let inspector = InspectorViewController(viewer: viewer, fileURL: document.fileURL)
        self.viewer = viewer
        self.sidebar = sidebar
        self.inspector = inspector

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: viewer)
        contentItem.minimumThickness = 300
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 220
        inspectorItem.maximumThickness = 360
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.addSplitViewItem(inspectorItem)
        split.splitView.autosaveName = "DocumentSplit"
        self.split = split
        self.sidebarItem = sidebarItem
        self.inspectorItem = inspectorItem

        let frame = window.frame
        window.contentViewController = split
        window.setFrame(frame, display: false)
        setUpToolbar()

        viewer.onStateChange = { [weak self] in self?.viewerStateDidChange() }
        viewer.find.onChange = { [weak self] in self?.findDidChange() }
        viewer.onToolChange = { [weak self] tool in self?.markupBar.setTool(tool) }
        viewer.onAnnotationSelectionChange = { [weak self] ref in
            self?.inspector?.show(ref)
            self?.sidebar?.annotationSelectionDidChange(ref)
        }
        markupBar.onToolChosen = { [weak self] tool in
            self?.viewer?.pagesView.isCropping = false
            self?.viewer?.tool = tool
        }
        viewer.selectedPages = { [weak self] in
            guard let self, let sidebar = self.sidebar, sidebar.tab == .thumbnails, self.sidebarItem?.isCollapsed == false else { return [] }
            return sidebar.thumbnails.selectedPages
        }
        viewer.pages.onSelectPages = { [weak self] pages in self?.sidebar?.thumbnails.select(pages) }
        viewer.onCropModeChange = { [weak self] in self?.viewerStateDidChange() }
        setUpMarkupBar()
        NotificationCenter.default.addObserver(forName: DocumentModel.pagesDidChange, object: model, queue: .main) { [weak self] note in
            let pages = note.userInfo?["pages"] as? Set<Int>
            MainActor.assumeIsolated {
                self?.sidebar?.pagesDidChange(pages)
                self?.inspector?.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: DocumentModel.structureDidChange, object: model, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sidebar?.structureDidChange()
                self?.inspector?.refresh()
                self?.inspector?.pageDidChange()
                self?.viewerStateDidChange()
            }
        }
        NotificationCenter.default.addObserver(forName: DocumentModel.renderingDidChange, object: model, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebar?.renderingDidChange() }
        }
        viewerStateDidChange()
        window.makeFirstResponder(viewer.pagesView)
        if let restore = pendingRestore {
            pendingRestore = nil
            viewer.restore(page: restore.page, zoom: restore.zoom, magnification: restore.magnification)
        }
    }

    private func setUpToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "DocumentToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .pageNavigation, .pageNumber, .flexibleSpace,
         .zoom, .zoomMode, .displayMode, .rotate, .markup, .search, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.print, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .pageNavigation:
            navigation.segmentCount = 2
            navigation.trackingMode = .momentary
            navigation.setImage(NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous Page"), forSegment: 0)
            navigation.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next Page"), forSegment: 1)
            navigation.setToolTip("Previous Page", forSegment: 0)
            navigation.setToolTip("Next Page", forSegment: 1)
            navigation.target = self
            navigation.action = #selector(navigationClicked(_:))
            return item(identifier, label: "Previous/Next", view: navigation)
        case .pageNumber:
            pageField.alignment = .right
            pageField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            pageField.delegate = self
            pageField.target = self
            pageField.action = #selector(pageFieldEntered(_:))
            pageField.setAccessibilityLabel("Page number")
            pageField.widthAnchor.constraint(equalToConstant: 48).isActive = true
            pageCountLabel.textColor = .secondaryLabelColor
            pageCountLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let stack = NSStackView(views: [pageField, pageCountLabel])
            stack.spacing = 4
            return item(identifier, label: "Page", view: stack)
        case .zoom:
            zoomButtons.segmentCount = 2
            zoomButtons.trackingMode = .momentary
            zoomButtons.setImage(NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out"), forSegment: 0)
            zoomButtons.setImage(NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In"), forSegment: 1)
            zoomButtons.setToolTip("Zoom Out", forSegment: 0)
            zoomButtons.setToolTip("Zoom In", forSegment: 1)
            zoomButtons.target = self
            zoomButtons.action = #selector(zoomClicked(_:))
            return item(identifier, label: "Zoom", view: zoomButtons)
        case .zoomMode:
            zoomPopup.bezelStyle = .toolbar
            zoomPopup.menu = zoomMenu()
            zoomPopup.widthAnchor.constraint(equalToConstant: 104).isActive = true
            zoomPopup.setAccessibilityLabel("Zoom level")
            return item(identifier, label: "Scale", view: zoomPopup)
        case .displayMode:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "View"
            item.toolTip = "Page display"
            item.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: "Page display")
            item.menu = displayMenu()
            item.showsIndicator = true
            return item
        case .rotate:
            let rotate = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "rotate.left", accessibilityDescription: "Rotate Page Left")!,
                NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "Rotate Page Right")!,
            ], trackingMode: .momentary, target: self, action: #selector(rotateClicked(_:)))
            rotate.setToolTip("Rotate Page Left", forSegment: 0)
            rotate.setToolTip("Rotate Page Right", forSegment: 1)
            rotateControl = rotate
            return item(identifier, label: "Rotate", view: rotate)
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search"
            item.searchField.delegate = self
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldChanged(_:))
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = false
            item.searchField.placeholderString = "Search"
            item.searchField.searchMenuTemplate = searchMenu()
            item.preferredWidthForSearchField = 160
            searchItem = item
            return item
        case .markup:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Markup"
            item.paletteLabel = "Markup"
            item.toolTip = "Show Markup Toolbar"
            item.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Markup")
            item.action = #selector(toggleMarkupBar(_:))
            item.target = self
            return item
        case .print:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Print"
            item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "Print")
            item.action = #selector(NSDocument.printDocument(_:))
            return item
        default:
            return nil
        }
    }

    private func item(_ identifier: NSToolbarItem.Identifier, label: String, view: NSView) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = view
        item.toolTip = label
        return item
    }

    private func zoomMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")   // the pull-down's title
        menu.addItem(withTitle: "Fit Width", action: #selector(zoomToFitWidth(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Fit Page", action: #selector(zoomToFitPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Actual Size", action: #selector(zoomToActualSize(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        for percent in [50, 75, 100, 125, 150, 200, 300, 400, 800] {
            let item = menu.addItem(withTitle: "\(percent)%", action: #selector(zoomToPercent(_:)), keyEquivalent: "")
            item.tag = percent
        }
        return menu
    }

    private func displayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Single Page", action: #selector(displaySinglePage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Single Page Continuous", action: #selector(displaySinglePageContinuous(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Two Pages", action: #selector(displayTwoPages(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Two Pages Continuous", action: #selector(displayTwoPagesContinuous(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Cover Page Separately", action: #selector(toggleCoverSeparately(_:)), keyEquivalent: "")
        return menu
    }

    private func searchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Match Case", action: #selector(toggleMatchCase(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Whole Words", action: #selector(toggleWholeWords(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: State

    private func viewerStateDidChange() {
        guard let viewer, let window else { return }
        let count = viewer.model.pageCount
        if window.firstResponder !== pageField.currentEditor() {
            pageField.stringValue = "\(viewer.currentPage + 1)"
        }
        pageCountLabel.stringValue = "of \(count)"
        navigation.setEnabled(viewer.currentPage > 0, forSegment: 0)
        navigation.setEnabled(viewer.currentPage < count - 1, forSegment: 1)
        zoomButtons.setEnabled(viewer.magnification > ViewerController.minZoom + 0.001, forSegment: 0)
        zoomButtons.setEnabled(viewer.magnification < ViewerController.maxZoom - 0.001, forSegment: 1)
        let title: String
        switch viewer.zoomMode {
        case .fitWidth: title = "Fit Width"
        case .fitPage: title = "Fit Page"
        case .custom: title = "\(Int((viewer.magnification * 100).rounded()))%"
        }
        zoomPopup.menu?.item(at: 0)?.title = title
        zoomPopup.setTitle(title)
        window.subtitle = viewer.pagesView.isCropping
            ? "Drag over a page to crop it · Esc to stop"
            : "Page \(viewer.currentPage + 1) of \(count)"
        rotateControl?.isEnabled = viewer.model.isEditable
        invalidateRestorableState()
        sidebar?.currentPageDidChange()
        inspector?.pageDidChange()
    }

    private func findDidChange() {
        guard let viewer else { return }
        viewer.pagesView.refreshHighlights()
        sidebar?.findDidChange()
        if jumpToFirstMatch, viewer.find.currentIndex == nil, !viewer.find.matches.isEmpty {
            jumpToFirstMatch = false
            viewer.findNext(forward: true)
        }
    }

    // MARK: Toolbar actions

    @objc private func navigationClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? goToPreviousPage(sender) : goToNextPage(sender)
    }

    @objc private func zoomClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? zoomOut(sender) : zoomIn(sender)
    }

    @objc private func rotateClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? rotatePagesLeft(sender) : rotatePagesRight(sender)
    }

    @objc private func pageFieldEntered(_ sender: NSTextField) {
        guard let viewer else { return }
        if let page = Int(sender.stringValue.trimmingCharacters(in: .whitespaces)), page >= 1, page <= viewer.model.pageCount {
            viewer.go(toPage: page - 1)
        } else {
            NSSound.beep()
        }
        sender.stringValue = "\(viewer.currentPage + 1)"
        window?.makeFirstResponder(viewer.pagesView)
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchDebounce?.cancel()
        let text = sender.stringValue
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runSearch(text) }
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func runSearch(_ text: String) {
        guard let viewer else { return }
        guard text != viewer.find.query else { return }
        jumpToFirstMatch = !text.trimmingCharacters(in: .whitespaces).isEmpty
        viewer.find.search(text)
        if jumpToFirstMatch {
            showSidebar(.search)
        }
        findDidChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchItem?.searchField, let viewer else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            searchDebounce?.cancel()
            if control.stringValue != viewer.find.query { runSearch(control.stringValue) } else { viewer.findNext(forward: true) }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            viewer.findNext(forward: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            control.stringValue = ""
            runSearch("")
            window?.makeFirstResponder(viewer.pagesView)
            return true
        default:
            return false
        }
    }

    // MARK: Menu actions (also reached from the menu bar)

    @objc func goToPreviousPage(_ sender: Any?) { viewer?.goToPreviousPage() }
    @objc func goToNextPage(_ sender: Any?) { viewer?.goToNextPage() }
    @objc func goToFirstPage(_ sender: Any?) { viewer?.go(toPage: 0) }
    @objc func goToLastPage(_ sender: Any?) { viewer.map { $0.go(toPage: $0.model.pageCount - 1) } }
    @objc func goToPage(_ sender: Any?) {
        window?.makeFirstResponder(pageField)
        pageField.selectText(nil)
    }
    @objc func goBack(_ sender: Any?) { viewer?.goBack() }
    @objc func goForward(_ sender: Any?) { viewer?.goForward() }

    @objc func zoomIn(_ sender: Any?) { viewer?.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { viewer?.zoomOut() }
    @objc func zoomToActualSize(_ sender: Any?) { viewer?.setMagnification(1) }
    @objc func zoomToFitWidth(_ sender: Any?) { viewer?.setZoom(.fitWidth) }
    @objc func zoomToFitPage(_ sender: Any?) { viewer?.setZoom(.fitPage) }
    @objc func zoomToPercent(_ sender: NSMenuItem) { viewer?.setMagnification(CGFloat(sender.tag) / 100) }

    @objc func displaySinglePage(_ sender: Any?) { setMode(twoPages: false, continuous: false) }
    @objc func displaySinglePageContinuous(_ sender: Any?) { setMode(twoPages: false, continuous: true) }
    @objc func displayTwoPages(_ sender: Any?) { setMode(twoPages: true, continuous: false) }
    @objc func displayTwoPagesContinuous(_ sender: Any?) { setMode(twoPages: true, continuous: true) }
    @objc func toggleFieldHighlights(_ sender: Any?) {
        guard let viewer else { return }
        viewer.pagesView.highlightsFields.toggle()
        UserDefaults.standard.set(viewer.pagesView.highlightsFields, forKey: "HighlightFields")
    }

    @objc func toggleCoverSeparately(_ sender: Any?) {
        guard let viewer else { return }
        var mode = viewer.displayMode
        mode.coverSeparately.toggle()
        viewer.setDisplayMode(mode)
    }

    private func setMode(twoPages: Bool, continuous: Bool) {
        guard let viewer else { return }
        var mode = viewer.displayMode
        mode.twoPages = twoPages
        mode.continuous = continuous
        viewer.setDisplayMode(mode)
    }

    @objc func rotateViewLeft(_ sender: Any?) {
        viewer?.rotate(clockwise: false)
        sidebar?.rotationDidChange()
    }

    @objc func rotateViewRight(_ sender: Any?) {
        viewer?.rotate(clockwise: true)
        sidebar?.rotationDidChange()
    }

    @objc func showThumbnails(_ sender: Any?) { showSidebar(.thumbnails) }
    @objc func showOutline(_ sender: Any?) { showSidebar(.outline) }
    @objc func showSearchResults(_ sender: Any?) { showSidebar(.search) }
    @objc func showAttachments(_ sender: Any?) { showSidebar(.attachments) }
    @objc func showLayers(_ sender: Any?) { showSidebar(.layers) }

    private func showSidebar(_ tab: SidebarTab) {
        sidebar?.show(tab)
        if sidebarItem?.isCollapsed == true { sidebarItem?.animator().isCollapsed = false }
    }

    @objc func showDocumentInfo(_ sender: Any?) {
        guard let inspectorItem else { return }
        inspectorItem.animator().isCollapsed.toggle()
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        switch NSFindPanelAction(rawValue: UInt(item.tag)) {
        case .showFindPanel: focusSearch()
        case .next: viewer?.findNext(forward: true)
        case .previous: viewer?.findNext(forward: false)
        case .setFindString: useSelectionForFind()
        default: break
        }
    }

    private func focusSearch() {
        guard let searchItem else { return }
        searchItem.beginSearchInteraction()
    }

    private func useSelectionForFind() {
        guard let text = viewer?.pagesView.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let field = searchItem?.searchField else { NSSound.beep(); return }
        field.stringValue = String(text.prefix(200))
        runSearch(field.stringValue)
    }

    @objc func toggleMatchCase(_ sender: Any?) { toggleSearchOption(.matchCase) }
    @objc func toggleWholeWords(_ sender: Any?) { toggleSearchOption(.wholeWords) }

    private func toggleSearchOption(_ option: SearchOptions) {
        guard let viewer else { return }
        if viewer.find.options.contains(option) { viewer.find.options.remove(option) } else { viewer.find.options.insert(option) }
        let query = viewer.find.query
        if !query.isEmpty {
            viewer.find.search(query)
            jumpToFirstMatch = true
            findDidChange()
        }
    }

    // MARK: Annotating

    private func setUpMarkupBar() {
        guard markupAccessory == nil, let window else { return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = markupBar.view
        accessory.isHidden = !UserDefaults.standard.bool(forKey: "ShowMarkupBar")
        window.addTitlebarAccessoryViewController(accessory)
        markupAccessory = accessory
    }

    @objc func toggleMarkupBar(_ sender: Any?) {
        guard let accessory = markupAccessory else { return }
        accessory.animator().isHidden.toggle()
        UserDefaults.standard.set(!accessory.isHidden, forKey: "ShowMarkupBar")
        if accessory.isHidden { viewer?.tool = .select }
    }

    /// Tools menu: the menu item's tag is the tool's index.
    @objc func chooseTool(_ sender: NSMenuItem) {
        guard AnnotationTool.allCases.indices.contains(sender.tag), let viewer else { return }
        let tool = AnnotationTool.allCases[sender.tag]
        if markupAccessory?.isHidden == true, tool != .select { toggleMarkupBar(sender) }
        // A text tool with text already selected marks it straight away.
        if tool.marksText, let selection = viewer.pagesView.selection, !selection.isEmpty {
            do {
                _ = try viewer.annotations.markText(tool, selection: selection)
                viewer.pagesView.selection = nil
            } catch {
                NSSound.beep()
            }
            return
        }
        viewer.tool = tool
    }

    @objc func flattenAnnotations(_ sender: Any?) {
        guard let viewer, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Flatten all annotations?"
        alert.informativeText = "Highlights, notes, shapes, drawings and stamps become part of the pages and can no longer be changed. Replies are removed. You can undo this until you close the document."
        alert.addButton(withTitle: "Flatten")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try viewer.model.edit("Flatten Annotations", pages: Set(0..<viewer.model.pageCount)) { try $0.flattenAnnotations() }
                viewer.pagesView.selectedAnnotation = nil
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func showComments(_ sender: Any?) { showSidebar(.comments) }

    // MARK: Validation

    private var tagOfValidatedItem = -1

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        tagOfValidatedItem = item.tag
        return validate(item.action, setState: { item.state = $0 ? .on : .off })
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        validate(item.action, setState: { _ in })
    }

    private func validate(_ action: Selector?, setState: (Bool) -> Void) -> Bool {
        guard let viewer else { return false }
        let mode = viewer.displayMode
        switch action {
        case #selector(goToPreviousPage(_:)), #selector(goToFirstPage(_:)): return viewer.currentPage > 0
        case #selector(goToNextPage(_:)), #selector(goToLastPage(_:)): return viewer.currentPage < viewer.model.pageCount - 1
        case #selector(goBack(_:)): return viewer.canGoBack
        case #selector(goForward(_:)): return viewer.canGoForward
        case #selector(zoomIn(_:)): return viewer.magnification < ViewerController.maxZoom - 0.001
        case #selector(zoomOut(_:)): return viewer.magnification > ViewerController.minZoom + 0.001
        case #selector(zoomToFitWidth(_:)): setState(viewer.zoomMode == .fitWidth)
        case #selector(zoomToFitPage(_:)): setState(viewer.zoomMode == .fitPage)
        case #selector(zoomToActualSize(_:)): setState(viewer.zoomMode == .custom && abs(viewer.magnification - 1) < 0.001)
        case #selector(displaySinglePage(_:)): setState(!mode.twoPages && !mode.continuous)
        case #selector(displaySinglePageContinuous(_:)): setState(!mode.twoPages && mode.continuous)
        case #selector(displayTwoPages(_:)): setState(mode.twoPages && !mode.continuous)
        case #selector(displayTwoPagesContinuous(_:)): setState(mode.twoPages && mode.continuous)
        case #selector(toggleFieldHighlights(_:)): setState(viewer.pagesView.highlightsFields)
        case #selector(toggleCoverSeparately(_:)):
            setState(mode.coverSeparately)
            return mode.twoPages
        case #selector(toggleMatchCase(_:)): setState(viewer.find.options.contains(.matchCase))
        case #selector(toggleWholeWords(_:)): setState(viewer.find.options.contains(.wholeWords))
        case #selector(showThumbnails(_:)): setState(sidebar?.tab == .thumbnails && sidebarItem?.isCollapsed == false)
        case #selector(showOutline(_:)): setState(sidebar?.tab == .outline && sidebarItem?.isCollapsed == false)
        case #selector(showSearchResults(_:)): setState(sidebar?.tab == .search && sidebarItem?.isCollapsed == false)
        case #selector(showComments(_:)): setState(sidebar?.tab == .comments && sidebarItem?.isCollapsed == false)
        case #selector(toggleMarkupBar(_:)):
            setState(markupAccessory?.isHidden == false)
            return viewer.model.isEditable
        case #selector(chooseTool(_:)):
            setState(AnnotationTool.allCases.indices.contains(tagOfValidatedItem) && viewer.tool == AnnotationTool.allCases[tagOfValidatedItem])
            return viewer.model.isEditable
        case #selector(flattenAnnotations(_:)):
            return viewer.model.isEditable
        case #selector(showAttachments(_:)): setState(sidebar?.tab == .attachments && sidebarItem?.isCollapsed == false)
        case #selector(showLayers(_:)): setState(sidebar?.tab == .layers && sidebarItem?.isCollapsed == false)
        case #selector(showDocumentInfo(_:)): setState(inspectorItem?.isCollapsed == false)
        case #selector(performFindPanelAction(_:)): return true
        default:
            if let result = validatePageAction(action, setState: setState) { return result }
        }
        return true
    }

    // MARK: Window

    /// The document was reverted to another version: start again with it.
    func documentDidRevert() {
        let page = viewer?.currentPage
        viewer?.find.cancel()
        viewer = nil
        sidebar = nil
        inspector = nil
        window?.contentViewController = nil
        start()
        if let page { viewer?.go(toPage: min(page, (viewer?.model.pageCount ?? 1) - 1)) }
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        guard let viewer else { return }
        coder.encode(viewer.currentPage, forKey: "Page")
        let mode = switch viewer.zoomMode { case .fitWidth: "fitWidth"; case .fitPage: "fitPage"; case .custom: "custom" }
        coder.encode(mode as NSString, forKey: "ZoomMode")
        coder.encode(Double(viewer.magnification), forKey: "Magnification")
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        guard coder.containsValue(forKey: "Page") else { return }
        let page = coder.decodeInteger(forKey: "Page")
        let zoom: ZoomMode = switch coder.decodeObject(of: NSString.self, forKey: "ZoomMode") as String? {
        case "fitPage": .fitPage
        case "custom": .custom
        default: .fitWidth
        }
        let magnification = CGFloat(coder.decodeDouble(forKey: "Magnification"))
        if let viewer {
            viewer.restore(page: page, zoom: zoom, magnification: magnification)
        } else {
            pendingRestore = (page, zoom, magnification)
        }
    }

    func windowWillClose(_ notification: Notification) {
        viewer?.find.cancel()
        viewer?.renderer.reset()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        viewer?.pagesView.updateVisible()
    }

    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        displayName
    }
}
