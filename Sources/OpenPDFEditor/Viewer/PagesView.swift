import AppKit
import PDFCore

/// A place in the text: a caret position on a page.
struct TextPosition: Comparable {
    var page: Int
    var caret: Int
    static func < (a: TextPosition, b: TextPosition) -> Bool {
        (a.page, a.caret) < (b.page, b.caret)
    }
}

/// A text selection, possibly across pages.
struct TextSelection: Equatable {
    var anchor: TextPosition
    var focus: TextPosition
    var start: TextPosition { min(anchor, focus) }
    var end: TextPosition { max(anchor, focus) }
    var isEmpty: Bool { anchor == focus }

    /// The selected characters on a page.
    func range(onPage page: Int, count: Int) -> Range<Int>? {
        guard page >= start.page && page <= end.page else { return nil }
        // Clamped: the page's text may have changed since the selection was made.
        let lower = min(page == start.page ? start.caret : 0, count)
        let upper = min(page == end.page ? end.caret : count, count)
        return lower < upper ? lower..<upper : nil
    }
}

@MainActor
protocol PagesViewDelegate: AnyObject {
    func pagesView(_ view: PagesView, activate link: PageLink, onPage page: Int)
    /// Search matches to show on a page, in page space.
    func pagesView(_ view: PagesView, searchHighlightsOnPage page: Int) -> (all: [CGRect], current: [CGRect])
    func pagesViewSelectionDidChange(_ view: PagesView)
    func pagesView(_ view: PagesView, scrollBy lines: CGFloat)
    func pagesView(_ view: PagesView, scrollByPages pages: CGFloat)
    func pagesView(_ view: PagesView, goToPageOffset offset: Int)
    func pagesView(_ view: PagesView, goToEnd end: Bool)
    /// The selected annotation changed.
    func pagesView(_ view: PagesView, didSelect annotation: AnnotationRef?)
    /// Open the editor for an annotation's text (a new note, a double-click).
    func pagesView(_ view: PagesView, edit annotation: AnnotationRef)
    /// A tool that doesn't stay chosen has been used.
    func pagesView(_ view: PagesView, didUse tool: AnnotationTool)
    /// An area was dragged out in crop mode (page space).
    func pagesView(_ view: PagesView, crop rect: CGRect, onPage page: Int)
    /// Crop mode was turned on or off.
    func pagesViewCropModeDidChange(_ view: PagesView)
}

/// The scroll view's document view: lays out page views for the visible
/// pages (reusing them as the view scrolls) and handles the mouse and keys.
@MainActor
final class PagesView: NSView, NSMenuItemValidation {
    weak var delegate: PagesViewDelegate?
    let model: DocumentModel
    let renderer: TileRenderer

    private(set) var layout: PageLayout
    private(set) var rotation = 0
    private var pageViews: [Int: PageView] = [:]
    private var reusable: [PageView] = []

    var selection: TextSelection? {
        didSet {
            if selection != oldValue {
                refreshSelection()
                delegate?.pagesViewSelectionDidChange(self)
            }
        }
    }

    private enum Granularity { case character, word, block }
    private var dragGranularity = Granularity.character
    private var dragOrigin: (page: Int, range: Range<Int>)?
    private var pendingLink: (link: PageLink, page: Int, point: NSPoint)?

    lazy var accessibilityPages = PageAccessibility(view: self)

    /// Finds and changes annotations (set by the viewer).
    var annotations: AnnotationController?
    /// Finds and fills in form fields (set by the viewer).
    var forms: FormController?
    /// The text field being typed into, if any.
    var fieldEditor: FieldEditor?
    /// Tints the form fields that can be filled in.
    var highlightsFields = true {
        didSet { if highlightsFields != oldValue { refreshFieldHighlights() } }
    }
    /// The markup tool in use.
    var tool: AnnotationTool = .select {
        didSet {
            gesture = .none
            if tool != .select { selectedAnnotation = nil }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Dragging out an area to crop pages to, instead of using the tool.
    var isCropping = false {
        didSet {
            guard isCropping != oldValue else { return }
            gesture = .none
            clearDrafts()
            if isCropping {
                selectedAnnotation = nil
                selection = nil
            }
            window?.invalidateCursorRects(for: self)
            delegate?.pagesViewCropModeDidChange(self)
        }
    }
    var selectedAnnotation: AnnotationRef? {
        didSet {
            guard selectedAnnotation != oldValue else { return }
            refreshAnnotationSelection()
            delegate?.pagesView(self, didSelect: selectedAnnotation)
        }
    }

    enum AnnotationGesture {
        case none
        /// Drawing with a tool: a shape from `start`, or a pen stroke.
        case create(page: Int, start: CGPoint, current: CGPoint, points: [CGPoint])
        case move(AnnotationRef, start: CGPoint, current: CGPoint)
        case resize(AnnotationRef, AnnotationHandle, current: CGPoint)
        /// Dragging out a crop area.
        case crop(page: Int, start: CGPoint, current: CGPoint)
    }
    var gesture = AnnotationGesture.none

    init(model: DocumentModel, renderer: TileRenderer) {
        self.model = model
        self.renderer = renderer
        layout = PageLayout(sizes: [], mode: .singleContinuous)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: Layout

    func apply(layout: PageLayout, rotation: Int) {
        // The field being typed into would be left where the page was.
        fieldEditor?.finish()
        self.layout = layout
        self.rotation = rotation
        setFrameSize(layout.size)
        for (page, view) in pageViews where layout.frames[page] == nil {
            recycle(view)
            pageViews[page] = nil
        }
        accessibilityPages.invalidate()
        updateVisible()
    }

    /// Adds, moves and recycles page views for what is on screen, and asks
    /// them for tiles at the current zoom.
    func updateVisible() {
        guard let scroll = enclosingScrollView else { return }
        let visible = scroll.contentView.bounds
        let wanted = Set(layout.pages(in: visible.insetBy(dx: 0, dy: -visible.height * 0.5)))
        for (page, view) in pageViews where !wanted.contains(page) {
            recycle(view)
            pageViews[page] = nil
        }
        for page in wanted {
            guard let frame = layout.frames[page] else { continue }
            let view = pageViews[page] ?? dequeue()
            if view.frame != frame { view.frame = frame }
            let changed = view.configure(page: page, rotation: rotation, revision: model.revision(page: page))
            if pageViews[page] == nil || changed {
                pageViews[page] = view
                applyFieldHighlights(to: view, page: page)
                applyHighlights(to: view, page: page)
                applySelection(to: view, page: page)
                applyAnnotationSelection(to: view, page: page)
            }
        }
        let deviceScale = scroll.magnification * (window?.backingScaleFactor ?? 2)
        for (_, view) in pageViews {
            view.updateTiles(visible: view.convert(visible, from: self), deviceScale: deviceScale)
        }
    }

    private func dequeue() -> PageView {
        let view = reusable.popLast() ?? PageView(renderer: renderer)
        addSubview(view)
        return view
    }

    private func recycle(_ view: PageView) {
        view.clear()
        view.removeFromSuperview()
        if reusable.count < 12 { reusable.append(view) }
    }

    /// Forgets every page view, e.g. after a layer changes what pages show.
    func reloadPages() {
        for view in pageViews.values { recycle(view) }
        pageViews.removeAll()
        updateVisible()
    }

    // MARK: Geometry

    func viewFrame(ofPage page: Int) -> CGRect? { layout.frames[page] }

    /// From page space to this view's coordinates.
    func transform(forPage page: Int) -> CGAffineTransform? {
        guard let frame = layout.frames[page] else { return nil }
        return model.pageToView(page: page, rotation: rotation)
            .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
    }

    func convert(_ point: CGPoint, toPage page: Int) -> CGPoint? {
        transform(forPage: page).map { point.applying($0.inverted()) }
    }

    func convert(_ rect: CGRect, fromPage page: Int) -> CGRect? {
        transform(forPage: page).map { rect.applying($0) }
    }

    // MARK: Highlights

    func refreshFieldHighlights() {
        for (page, view) in pageViews { applyFieldHighlights(to: view, page: page) }
    }

    /// Tints the page's fillable fields, loading them in the background the
    /// first time.
    private func applyFieldHighlights(to view: PageView, page: Int) {
        let transform = model.pageToView(page: page, rotation: rotation)
        guard highlightsFields else {
            view.setFieldHighlights([], transform: transform)
            return
        }
        guard let fields = model.cachedFields(page: page) else {
            view.setFieldHighlights([], transform: transform)
            let model = self.model
            EngineExecutor.background.async(.low) { [weak self] in
                _ = model.fields(page: page)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let view = self.pageViews[page], model.cachedFields(page: page) != nil else { return }
                        self.applyFieldHighlights(to: view, page: page)
                    }
                }
            }
            return
        }
        view.setFieldHighlights(fields.filter(FormController.isFillable).map(\.rect), transform: transform)
    }

    func refreshHighlights() {
        for (page, view) in pageViews { applyHighlights(to: view, page: page) }
    }

    private func applyHighlights(to view: PageView, page: Int) {
        let highlights = delegate?.pagesView(self, searchHighlightsOnPage: page) ?? (all: [], current: [])
        view.setSearchHighlights(highlights.all, current: highlights.current,
                                 transform: model.pageToView(page: page, rotation: rotation))
    }

    private func refreshSelection() {
        for (page, view) in pageViews { applySelection(to: view, page: page) }
    }

    private func applySelection(to view: PageView, page: Int) {
        var rects: [CGRect] = []
        if let selection, !selection.isEmpty, let text = textIfSelected(page: page),
           let range = selection.range(onPage: page, count: text.chars.count) {
            rects = text.rects(for: range)
        }
        view.setSelection(rects, transform: model.pageToView(page: page, rotation: rotation))
    }

    private func textIfSelected(page: Int) -> PageText? {
        guard let selection, page >= selection.start.page, page <= selection.end.page else { return nil }
        return model.text(page: page)
    }

    // MARK: Selection and copying

    var selectedText: String? {
        guard let selection, !selection.isEmpty else { return nil }
        var parts: [String] = []
        for page in selection.start.page...selection.end.page {
            let text = model.text(page: page)
            if let range = selection.range(onPage: page, count: text.chars.count) {
                parts.append(text.text(in: range))
            }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard model.pageCount > 0 else { return }
        let last = model.pageCount - 1
        selection = TextSelection(anchor: TextPosition(page: 0, caret: 0),
                                  focus: TextPosition(page: last, caret: model.text(page: last).chars.count))
    }

    @objc func selectNone(_ sender: Any?) { selection = nil }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selection.map { !$0.isEmpty } ?? false
        case #selector(selectAll(_:)): return model.pageCount > 0
        case #selector(delete(_:)): return selectedAnnotation != nil
        default: return true
        }
    }

    // MARK: Mouse

    func pageAndPoint(at location: NSPoint) -> (page: Int, point: CGPoint)? {
        guard let page = layout.page(nearest: location), let point = convert(location, toPage: page) else { return nil }
        return (page, point)
    }

    func link(at point: CGPoint, page: Int) -> PageLink? {
        model.links(page: page).first { $0.rect.contains(point) }
    }

    func textMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let (page, point) = pageAndPoint(at: location) else { return }
        pendingLink = nil
        if event.clickCount == 1, !event.modifierFlags.contains(.shift),
           layout.frames[page]?.contains(location) == true, let link = link(at: point, page: page) {
            pendingLink = (link, page, location)
        }
        let text = model.text(page: page)
        guard let caret = text.caret(at: point) else {
            if !event.modifierFlags.contains(.shift) { selection = nil }
            dragOrigin = nil
            return
        }
        let position = TextPosition(page: page, caret: caret)
        switch event.clickCount {
        case 2, 3:
            let index = text.charIndex(at: point) ?? min(caret, max(text.chars.count - 1, 0))
            let range = event.clickCount == 2 ? text.wordRange(at: index) : text.blockRange(at: index)
            dragGranularity = event.clickCount == 2 ? .word : .block
            dragOrigin = (page, range)
            selection = TextSelection(anchor: TextPosition(page: page, caret: range.lowerBound),
                                      focus: TextPosition(page: page, caret: range.upperBound))
        default:
            dragGranularity = .character
            dragOrigin = nil
            if event.modifierFlags.contains(.shift), var current = selection {
                current.focus = position
                selection = current
            } else {
                selection = TextSelection(anchor: position, focus: position)
            }
        }
    }

    func textMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let pending = pendingLink, hypot(location.x - pending.point.x, location.y - pending.point.y) > 3 {
            pendingLink = nil
        }
        guard pendingLink == nil else { return }
        autoscroll(with: event)
        guard let (page, point) = pageAndPoint(at: location), var current = selection else { return }
        let text = model.text(page: page)
        guard let caret = text.caret(at: point) else { return }
        var focus = TextPosition(page: page, caret: caret)
        if dragGranularity != .character, let origin = dragOrigin {
            // Extend by whole words or paragraphs, keeping the first one selected.
            let index = text.charIndex(at: point) ?? min(caret, max(text.chars.count - 1, 0))
            let unit = dragGranularity == .word ? text.wordRange(at: index) : text.blockRange(at: index)
            let originStart = TextPosition(page: origin.page, caret: origin.range.lowerBound)
            let originEnd = TextPosition(page: origin.page, caret: origin.range.upperBound)
            if focus < originStart {
                current.anchor = originEnd
                focus.caret = unit.lowerBound
            } else {
                current.anchor = originStart
                focus.caret = max(unit.upperBound, page == origin.page ? origin.range.upperBound : 0)
            }
        }
        current.focus = focus
        selection = current
    }

    func textMouseUp(with event: NSEvent) {
        if let pending = pendingLink {
            pendingLink = nil
            if selection?.isEmpty ?? true { selection = nil }
            delegate?.pagesView(self, activate: pending.link, onPage: pending.page)
            return
        }
        if selection?.isEmpty == true { selection = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(event) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isCropping || (tool != .select && !tool.marksText) {
            NSCursor.crosshair.set()
            return
        }
        if tool == .select, let cursor = annotationCursor(at: location) {
            cursor.set()
            return
        }
        guard let page = layout.pages(in: CGRect(origin: location, size: CGSize(width: 1, height: 1))).first,
              let point = convert(location, toPage: page) else {
            NSCursor.arrow.set()
            return
        }
        let link = link(at: point, page: page)
        let address = link.flatMap { $0.isExternal ? WebLinks.url($0.uri)?.absoluteString : nil }
        let field = tool == .select && model.isEditable ? forms?.hit(point, page: page, cachedOnly: true) : nil
        let tip = address ?? field.flatMap { $0.tooltip.isEmpty ? nil : $0.tooltip }
        if toolTip != tip { toolTip = tip }
        if let field {
            (FormController.isTyped(field) ? NSCursor.iBeam : NSCursor.pointingHand).set()
        } else if link != nil {
            NSCursor.pointingHand.set()
        } else if let text = model.cachedText(page: page), text.lines.contains(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }) {
            NSCursor.iBeam.set()
        } else {
            if model.cachedText(page: page) == nil {
                let model = self.model
                EngineExecutor.background.async(.low) { _ = model.text(page: page) }
            }
            NSCursor.arrow.set()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    override func rectForSmartMagnification(at location: NSPoint, in visibleRect: NSRect) -> NSRect {
        guard let page = layout.page(nearest: location), let frame = layout.frames[page] else { return visibleRect }
        return frame.insetBy(dx: -8, dy: 0)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            delegate?.pagesView(self, scrollByPages: event.modifierFlags.contains(.shift) ? -1 : 1)
            return
        }
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) { delegate?.pagesView(self, scrollBy: -1) }
    override func moveDown(_ sender: Any?) { delegate?.pagesView(self, scrollBy: 1) }
    override func moveLeft(_ sender: Any?) { delegate?.pagesView(self, goToPageOffset: -1) }
    override func moveRight(_ sender: Any?) { delegate?.pagesView(self, goToPageOffset: 1) }
    override func scrollPageUp(_ sender: Any?) { delegate?.pagesView(self, scrollByPages: -1) }
    override func scrollPageDown(_ sender: Any?) { delegate?.pagesView(self, scrollByPages: 1) }
    override func pageUp(_ sender: Any?) { delegate?.pagesView(self, scrollByPages: -1) }
    override func pageDown(_ sender: Any?) { delegate?.pagesView(self, scrollByPages: 1) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { delegate?.pagesView(self, goToEnd: false) }
    override func scrollToEndOfDocument(_ sender: Any?) { delegate?.pagesView(self, goToEnd: true) }
    override func moveToBeginningOfDocument(_ sender: Any?) { delegate?.pagesView(self, goToEnd: false) }
    override func moveToEndOfDocument(_ sender: Any?) { delegate?.pagesView(self, goToEnd: true) }
    override func cancelOperation(_ sender: Any?) {
        if case .none = gesture {} else {
            gesture = .none
            clearDrafts()
            return
        }
        if isCropping {
            isCropping = false
            return
        }
        if selectedAnnotation != nil { selectedAnnotation = nil } else { selection = nil }
    }

    override func deleteBackward(_ sender: Any?) { deleteSelectedAnnotation() }
    override func deleteForward(_ sender: Any?) { deleteSelectedAnnotation() }
    @objc func delete(_ sender: Any?) { deleteSelectedAnnotation() }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Pages" }
    override func accessibilityChildren() -> [Any]? { accessibilityPages.elements }
}

/// Centres the document in the scroll view when it is smaller than the view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if rect.height > frame.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}
