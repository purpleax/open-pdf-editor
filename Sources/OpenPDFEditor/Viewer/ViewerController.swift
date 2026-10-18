import AppKit
import PDFCore

/// A place to return to: a page and, optionally, a point on it (page space)
/// that should be at the top left of the view.
struct ViewLocation: Equatable {
    var page: Int
    var point: CGPoint?
}

enum ZoomMode: Equatable {
    case fitWidth, fitPage, custom
}

/// The document area: a scroll view of pages, with zoom, display modes,
/// rotation, navigation history, links and find.
@MainActor
final class ViewerController: NSViewController, PagesViewDelegate {
    let model: DocumentModel
    let renderer: TileRenderer
    let find: FindController
    let scrollView = NSScrollView()
    let pagesView: PagesView
    let annotations: AnnotationController
    private(set) lazy var pages = PageEditor(viewer: self)
    private var editor: AnnotationEditor?

    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 32
    static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]

    private(set) var displayMode: DisplayMode
    private(set) var rotation = 0
    private(set) var zoomMode = ZoomMode.fitWidth
    private(set) var currentPage = 0
    private var shownSpread = 0
    private var backStack: [ViewLocation] = []
    private var forwardStack: [ViewLocation] = []
    private var isApplyingZoom = false

    /// Called when the current page, zoom, mode or history changes.
    var onStateChange: (() -> Void)?
    /// Called when the text selection changes.
    var onSelectionChange: (() -> Void)?
    /// Called when the selected annotation changes.
    var onAnnotationSelectionChange: ((AnnotationRef?) -> Void)?
    /// Called when the tool changes (a one-off tool going back to Select).
    var onToolChange: ((AnnotationTool) -> Void)?
    /// Called when crop mode is turned on or off.
    var onCropModeChange: (() -> Void)?
    /// The pages that page commands apply to: those selected in the
    /// thumbnails, or else the current page.
    var selectedPages: (() -> [Int])?

    var targetPages: [Int] {
        let pages = selectedPages?() ?? []
        return pages.isEmpty ? [currentPage] : pages
    }

    var tool: AnnotationTool {
        get { pagesView.tool }
        set {
            pagesView.tool = newValue
            onToolChange?(newValue)
        }
    }

    init(model: DocumentModel) {
        self.model = model
        renderer = TileRenderer(model: model)
        find = FindController(model: model)
        pagesView = PagesView(model: model, renderer: renderer)
        annotations = AnnotationController(model: model)
        displayMode = Self.savedDisplayMode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = pagesView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.minZoom
        scrollView.maxMagnification = Self.maxZoom
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder
        view = scrollView
        pagesView.delegate = self
        pagesView.annotations = annotations
        pagesView.accessibilityPages.focusHandler = { [weak self] page in
            guard let self, !self.isVisible(page: page) else { return }
            self.go(to: ViewLocation(page: page), record: false)
        }

        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibleAreaDidChange() }
        }
        center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.zoomMode = .custom
                self.pagesView.updateVisible()
                self.onStateChange?()
            }
        }
        // Scrollers switch between overlay and always-visible (e.g. when a
        // mouse is connected), changing the width a fit zoom must use.
        center.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.main.async {
                    if self.zoomMode != .custom { self.applyZoomMode(keeping: self.anchor()) }
                }
            }
        }
        center.addObserver(forName: DocumentModel.pagesDidChange, object: model, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pagesView.updateVisible()
                self.pagesView.refreshAnnotationSelection()
            }
        }
        center.addObserver(forName: DocumentModel.structureDidChange, object: model, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.structureDidChange() }
        }
        center.addObserver(forName: DocumentModel.renderingDidChange, object: model, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderer.reset()
                self.pagesView.selection = nil
                self.pagesView.reloadPages()
            }
        }
        find.onChange = { [weak self] in
            self?.pagesView.refreshHighlights()
        }
        relayout()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if zoomMode != .custom { applyZoomMode(keeping: anchor()) }
        pagesView.updateVisible()
    }

    private var hasAppeared = false
    private var pendingRestore: (page: Int, zoom: ZoomMode, magnification: CGFloat)?

    override func viewDidAppear() {
        super.viewDidAppear()
        hasAppeared = true
        if let restore = pendingRestore {
            pendingRestore = nil
            self.restore(page: restore.page, zoom: restore.zoom, magnification: restore.magnification)
        } else {
            applyZoomMode(keeping: ViewLocation(page: currentPage))
        }
    }

    /// Puts back the page and zoom saved with the window (state restoration).
    func restore(page: Int, zoom: ZoomMode, magnification: CGFloat) {
        guard hasAppeared else {
            pendingRestore = (page, zoom, magnification)
            return
        }
        let page = min(max(page, 0), model.pageCount - 1)
        zoomMode = zoom
        if zoom == .custom {
            scrollView.magnification = min(max(magnification, Self.minZoom), Self.maxZoom)
        }
        if !displayMode.continuous, let spread = layout.spreadIndex(containing: page) {
            shownSpread = spread
            relayout()
        }
        if zoom == .custom { scroll(to: ViewLocation(page: page)) } else { applyZoomMode(keeping: ViewLocation(page: page)) }
        updateCurrentPage()
        onStateChange?()
    }

    // MARK: Layout

    private var pageSizes: [CGSize] {
        (0..<model.pageCount).map { model.viewSize(page: $0, rotation: rotation) }
    }

    private func relayout() {
        let layout = PageLayout(sizes: pageSizes, mode: displayMode, spread: shownSpread)
        pagesView.apply(layout: layout, rotation: rotation)
    }

    private var layout: PageLayout { pagesView.layout }

    /// The height, in document points, of the strip under the toolbar:
    /// content scrolls behind it, so it isn't really visible.
    private var topInset: CGFloat { scrollView.contentInsets.top / max(scrollView.magnification, 0.01) }

    /// The part of the document the user can see.
    var visibleArea: CGRect {
        var rect = scrollView.contentView.bounds
        rect.origin.y += topInset
        rect.size.height = max(rect.height - topInset, 1)
        return rect
    }

    /// Scrolls so that `top` (in document coordinates) is just below the toolbar.
    private func scrollTo(x: CGFloat, top: CGFloat) {
        let clip = scrollView.contentView
        let rect = clip.constrainBoundsRect(NSRect(origin: CGPoint(x: x, y: top - topInset), size: clip.bounds.size))
        clip.setBoundsOrigin(rect.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func visibleAreaDidChange() {
        pagesView.updateVisible()
        updateCurrentPage()
    }

    private func updateCurrentPage() {
        let visible = visibleArea
        var best = currentPage
        var bestArea: CGFloat = -1
        for page in layout.pages(in: visible) {
            guard let frame = layout.frames[page] else { continue }
            let part = frame.intersection(visible)
            // Favour the upper page when two share the view about equally.
            let area = part.width * part.height / max(frame.width * frame.height, 1) + (part.minY <= visible.minY + 1 ? 0.05 : 0)
            if area > bestArea + 0.001 {
                bestArea = area
                best = page
            }
        }
        if best != currentPage {
            currentPage = best
            onStateChange?()
        }
    }

    func isVisible(page: Int) -> Bool {
        guard let frame = layout.frames[page] else { return false }
        return frame.intersects(visibleArea)
    }

    // MARK: Navigation

    /// Where the view is now: the page at the top left and the point there.
    func anchor() -> ViewLocation {
        let visible = visibleArea
        let top = CGPoint(x: max(visible.minX, 0), y: max(visible.minY, 0))
        guard let page = layout.pages(in: visible).first ?? layout.page(nearest: top),
              let frame = layout.frames[page] else { return ViewLocation(page: currentPage) }
        let clamped = CGPoint(x: min(max(top.x, frame.minX), frame.maxX), y: min(max(top.y, frame.minY), frame.maxY))
        return ViewLocation(page: page, point: pagesView.convert(clamped, toPage: page))
    }

    func go(to location: ViewLocation, record: Bool = true) {
        guard location.page >= 0 && location.page < model.pageCount else { return }
        if record {
            let here = anchor()
            if backStack.last != here { backStack.append(here) }
            forwardStack.removeAll()
        }
        if !displayMode.continuous, let spread = layout.spreadIndex(containing: location.page), spread != layout.shownSpread {
            shownSpread = spread
            relayout()
        }
        scroll(to: location)
        updateCurrentPage()
        if currentPage != location.page && layout.frames[location.page] != nil {
            currentPage = location.page
        }
        onStateChange?()
    }

    func go(toPage page: Int) {
        go(to: ViewLocation(page: page))
    }

    private func scroll(to location: ViewLocation) {
        guard let frame = layout.frames[location.page] else { return }
        let clip = scrollView.contentView
        // The first row shows the margin above it; others start just above the page.
        let firstRow = layout.spreads.first?.contains(location.page) == true || !displayMode.continuous
        var x = clip.bounds.minX
        var top = firstRow ? 0 : frame.minY - PageLayout.pageGap / 2
        if let point = location.point, let transform = pagesView.transform(forPage: location.page) {
            let viewPoint = point.applying(transform)
            top = max(viewPoint.y - 8 / scrollView.magnification, firstRow ? 0 : frame.minY - PageLayout.pageGap / 2)
            if clip.bounds.width < pagesView.frame.width {
                x = viewPoint.x - 8 / scrollView.magnification
            }
        }
        scrollTo(x: x, top: top)
        pagesView.updateVisible()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let location = backStack.popLast() else { return }
        forwardStack.append(anchor())
        go(to: location, record: false)
    }

    func goForward() {
        guard let location = forwardStack.popLast() else { return }
        backStack.append(anchor())
        go(to: location, record: false)
    }

    func goToNextPage() { step(pages: 1) }
    func goToPreviousPage() { step(pages: -1) }

    private func step(pages: Int) {
        // Two-page modes step by spreads.
        if displayMode.twoPages, let spread = layout.spreadIndex(containing: currentPage) {
            let target = spread + pages
            guard layout.spreads.indices.contains(target) else { return }
            go(to: ViewLocation(page: layout.spreads[target][0]), record: false)
        } else {
            let target = currentPage + pages
            guard target >= 0 && target < model.pageCount else { return }
            go(to: ViewLocation(page: target), record: false)
        }
    }

    /// Pages were added, removed, moved, turned or cropped: page numbers
    /// and sizes no longer mean what they did.
    private func structureDidChange() {
        editor?.close()
        editor = nil
        pagesView.selection = nil
        pagesView.selectedAnnotation = nil
        backStack.removeAll()
        forwardStack.removeAll()
        renderer.reset()
        let page = min(currentPage, model.pageCount - 1)
        shownSpread = PageLayout.spreads(pageCount: model.pageCount, mode: displayMode).firstIndex { $0.contains(page) } ?? 0
        relayout()
        pagesView.reloadPages()
        if zoomMode != .custom { applyZoomMode(keeping: ViewLocation(page: page)) }
        currentPage = page
        updateCurrentPage()
        if !find.query.isEmpty { find.search(find.query) }
        onStateChange?()
    }

    // MARK: Zoom

    var magnification: CGFloat { scrollView.magnification }

    func setZoom(_ mode: ZoomMode) {
        zoomMode = mode
        applyZoomMode(keeping: anchor())
    }

    func setMagnification(_ value: CGFloat) {
        zoomMode = .custom
        let clamped = min(max(value, Self.minZoom), Self.maxZoom)
        let visible = visibleArea
        scrollView.setMagnification(clamped, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        pagesView.updateVisible()
        onStateChange?()
    }

    func zoomIn() {
        let current = scrollView.magnification
        setMagnification(Self.zoomSteps.first { $0 > current * 1.01 } ?? Self.maxZoom)
    }

    func zoomOut() {
        let current = scrollView.magnification
        setMagnification(Self.zoomSteps.last { $0 < current * 0.99 } ?? Self.minZoom)
    }

    private func applyZoomMode(keeping location: ViewLocation) {
        guard zoomMode != .custom, !isApplyingZoom, model.pageCount > 0 else { return }
        isApplyingZoom = true
        defer { isApplyingZoom = false }
        // The view's size without scrollers: with always-visible scrollers
        // the vertical one takes width, which would otherwise bring a
        // horizontal scroller with it.
        var available = scrollView.frame.size
        available.height -= scrollView.contentInsets.top + scrollView.contentInsets.bottom
        if scrollView.scrollerStyle == .legacy {
            available.width -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        guard available.width > 10 && available.height > 10 else { return }
        let target: CGFloat
        switch zoomMode {
        case .fitWidth:
            // Room for a vertical scroller that may appear.
            target = (available.width - 1) / layout.size.width
        case .fitPage:
            // The shown page (or spread) fits whole. In two-page modes the
            // width allows for a full spread, so a lone cover page doesn't
            // set a zoom the other spreads overflow.
            let page = min(max(location.page, 0), model.pageCount - 1)
            let spread = layout.spreadIndex(containing: page).map { layout.spreads[$0] } ?? [page]
            let frames = spread.compactMap { layout.frames[$0] }
            let union = frames.reduce(CGRect.null) { $0.union($1) }
            let width = displayMode.twoPages || union.isNull ? layout.size.width : union.width + 2 * PageLayout.margin
            let height = (union.isNull ? layout.size.height : union.height) + PageLayout.pageGap * 2
            target = min(available.width / width, available.height / height)
        case .custom:
            return
        }
        let clamped = min(max(target, Self.minZoom), Self.maxZoom)
        if abs(clamped - scrollView.magnification) > 0.0001 {
            scrollView.magnification = clamped
        }
        scroll(to: zoomMode == .fitPage ? ViewLocation(page: location.page) : location)
        onStateChange?()
    }

    // MARK: Display mode and rotation

    func setDisplayMode(_ mode: DisplayMode) {
        guard mode != displayMode else { return }
        let here = anchor()
        displayMode = mode
        Self.savedDisplayMode = mode
        let spreads = PageLayout.spreads(pageCount: model.pageCount, mode: mode)
        shownSpread = spreads.firstIndex { $0.contains(here.page) } ?? 0
        relayout()
        if zoomMode != .custom { applyZoomMode(keeping: here) } else { scroll(to: here) }
        updateCurrentPage()
        onStateChange?()
    }

    func rotate(clockwise: Bool) {
        let here = ViewLocation(page: anchor().page)
        rotation = (rotation + (clockwise ? 90 : 270)) % 360
        relayout()
        if zoomMode != .custom { applyZoomMode(keeping: here) } else { scroll(to: here) }
        updateCurrentPage()
        onStateChange?()
    }

    private static var savedDisplayMode: DisplayMode {
        get {
            let defaults = UserDefaults.standard
            return DisplayMode(twoPages: defaults.bool(forKey: "TwoPages"),
                               continuous: defaults.object(forKey: "Continuous") as? Bool ?? true,
                               coverSeparately: defaults.object(forKey: "CoverSeparately") as? Bool ?? true)
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(newValue.twoPages, forKey: "TwoPages")
            defaults.set(newValue.continuous, forKey: "Continuous")
            defaults.set(newValue.coverSeparately, forKey: "CoverSeparately")
        }
    }

    // MARK: Find

    func showMatch(_ match: SearchMatch) {
        guard let rect = match.rects.first else { return }
        if !displayMode.continuous, let spread = layout.spreadIndex(containing: match.page), spread != layout.shownSpread {
            shownSpread = spread
            relayout()
        }
        guard let viewRect = pagesView.convert(rect, fromPage: match.page) else { return }
        let visible = visibleArea
        if !visible.insetBy(dx: 10, dy: 10).contains(viewRect) {
            let x = visible.width < pagesView.frame.width ? viewRect.midX - visible.width / 2 : scrollView.contentView.bounds.minX
            scrollTo(x: x, top: viewRect.midY - visible.height / 3)
        }
        pagesView.updateVisible()
        updateCurrentPage()
        // The match's page is the one being looked at, even if the next
        // page fills more of the view.
        currentPage = match.page
        pagesView.refreshHighlights()
        onStateChange?()
    }

    func findNext(forward: Bool) {
        guard let match = find.step(forward: forward, from: currentPage) else {
            NSSound.beep()
            return
        }
        showMatch(match)
    }

    // MARK: PagesViewDelegate

    func pagesView(_ view: PagesView, activate link: PageLink, onPage page: Int) {
        if link.isExternal {
            guard let url = URL(string: link.uri), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)
        } else if let target = link.targetPage {
            go(to: ViewLocation(page: target, point: link.targetPoint))
        }
    }

    func pagesView(_ view: PagesView, searchHighlightsOnPage page: Int) -> (all: [CGRect], current: [CGRect]) {
        find.highlights(onPage: page)
    }

    func pagesViewSelectionDidChange(_ view: PagesView) {
        onSelectionChange?()
    }

    func pagesView(_ view: PagesView, scrollBy lines: CGFloat) {
        scrollBy(dy: lines * 40 / scrollView.magnification)
    }

    func pagesView(_ view: PagesView, scrollByPages pages: CGFloat) {
        let visible = visibleArea
        if !displayMode.continuous {
            let atEnd = pages > 0 ? visible.maxY >= pagesView.frame.height - 1 : visible.minY <= 1
            if atEnd {
                step(pages: pages > 0 ? 1 : -1)
                if pages < 0 { scrollBy(dy: pagesView.frame.height) }
                return
            }
        }
        scrollBy(dy: pages * (visible.height - 40 / scrollView.magnification))
    }

    func pagesView(_ view: PagesView, goToPageOffset offset: Int) {
        // With room to scroll sideways, the arrows scroll; otherwise they turn pages.
        if scrollView.contentView.bounds.width < pagesView.frame.width - 1 {
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.x += CGFloat(offset) * 40 / scrollView.magnification
            clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        } else {
            step(pages: offset)
        }
    }

    func pagesView(_ view: PagesView, didSelect annotation: AnnotationRef?) {
        onAnnotationSelectionChange?(annotation)
    }

    func pagesView(_ view: PagesView, edit annotation: AnnotationRef) {
        editAnnotation(annotation)
    }

    func pagesView(_ view: PagesView, didUse tool: AnnotationTool) {
        self.tool = .select
    }

    func pagesViewCropModeDidChange(_ view: PagesView) {
        onCropModeChange?()
    }

    /// An area to crop to: asks which pages, then crops them.
    func pagesView(_ view: PagesView, crop rect: CGRect, onPage page: Int) {
        guard let window = self.view.window else { return }
        let selected = targetPages
        let alert = NSAlert()
        alert.messageText = "Crop to the selected area?"
        alert.informativeText = "Everything outside the area is hidden. Pages of a different size are cropped to the same area, as far as it falls on them. You can undo this."
        alert.addButton(withTitle: "Crop Page \(page + 1)")
        let several = selected.count > 1 && selected.contains(page)
        alert.addButton(withTitle: several ? "Crop \(selected.count) Selected Pages" : "Crop All Pages")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let pages: [Int]
            switch response {
            case .alertFirstButtonReturn: pages = [page]
            case .alertSecondButtonReturn: pages = several ? selected : Array(0..<self.model.pageCount)
            default: return
            }
            self.pagesView.isCropping = false
            self.pages.crop(pages, to: rect)
        }
    }

    // MARK: Annotations

    /// Opens the popover for an annotation's text.
    func editAnnotation(_ ref: AnnotationRef) {
        guard let a = annotations.annotation(ref), let rect = pagesView.convert(a.rect, fromPage: ref.page) else { return }
        // Make sure it's on screen first.
        if !visibleArea.intersects(rect) { go(to: ViewLocation(page: ref.page, point: a.rect.origin), record: true) }
        editor?.close()
        let editor = AnnotationEditor(ref: ref, controller: annotations)
        self.editor = editor
        editor.show(relativeTo: pagesView.convert(a.rect, fromPage: ref.page) ?? rect, of: pagesView) { [weak self, weak editor] in
            if self?.editor === editor { self?.editor = nil }
        }
    }

    /// Selects an annotation and shows it.
    func reveal(_ ref: AnnotationRef) {
        guard let a = annotations.annotation(ref) else { return }
        if let viewRect = pagesView.convert(a.rect, fromPage: ref.page), !visibleArea.insetBy(dx: 10, dy: 10).contains(viewRect) {
            go(to: ViewLocation(page: ref.page, point: CGPoint(x: a.rect.minX - 20, y: a.rect.minY - 40)), record: true)
        }
        if tool != .select { tool = .select }
        pagesView.selectedAnnotation = ref
        view.window?.makeFirstResponder(pagesView)
    }

    func pagesView(_ view: PagesView, goToEnd end: Bool) {
        go(to: ViewLocation(page: end ? model.pageCount - 1 : 0), record: true)
    }

    private func scrollBy(dy: CGFloat) {
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += dy
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
