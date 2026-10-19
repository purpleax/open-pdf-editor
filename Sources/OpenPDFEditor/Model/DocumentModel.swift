import Foundation
import PDFCore

/// Records each edit for undo (the document does this).
@MainActor
protocol EditRecorder: AnyObject {
    func didEdit(actionName: String, change: ModelChange)
}

/// What an edit changed: what is on some pages, or the pages themselves
/// (their number, order, size or rotation).
enum ModelChange: Sendable {
    case pages(Set<Int>)
    case structure
}

/// An unlocked document and what the viewer keeps of it: page geometry and
/// caches of display lists, text, links and annotations. Thread-safe, except
/// the edits, which run on the main thread. Page geometry changes only on
/// the main thread, so main-thread code may index `pageBounds` with any page
/// below `pageCount`; other threads use `bounds(page:)`.
final class DocumentModel: @unchecked Sendable {
    let engine: EngineDocument
    var pageBounds: [CGRect] { lock.withLock { _pageBounds } }
    var pageCount: Int { lock.withLock { _pageBounds.count } }
    private var _pageBounds: [CGRect]

    private let lock = NSLock()
    private var lists: [Int: DisplayList] = [:]
    private var listOrder: [Int] = []
    private var texts: [Int: PageText] = [:]
    private var textOrder: [Int] = []
    private var linkCache: [Int: [PageLink]] = [:]
    private var contentCache: [Int: PageContent] = [:]
    private var contentOrder: [Int] = []
    private var paragraphCache: [Int: PageParagraphs] = [:]
    private var paragraphOrder: [Int] = []
    private var annotationCache: [Int: [Annotation]] = [:]
    private var fieldCache: [Int: [FormField]] = [:]
    private var fieldOrder: [Int] = []
    private var _revision = 0
    private var pageRevisions: [Int: Int] = [:]

    private static let maxLists = 40
    private static let maxTexts = 400
    /// Pages whose form fields are kept (a crafted page can hold a lot).
    private static let maxFieldPages = 40

    /// Posted on the main thread when pages must be redrawn from scratch
    /// (a layer was turned on or off).
    static let renderingDidChange = Notification.Name("DocumentModelRenderingDidChange")
    /// Posted on the main thread after pages change (an edit, undo or redo);
    /// userInfo["pages"] is the Set<Int> of pages, or absent for all pages.
    static let pagesDidChange = Notification.Name("DocumentModelPagesDidChange")
    /// Posted on the main thread after pages are added, removed, moved,
    /// turned or cropped: everything about pages must be reloaded.
    static let structureDidChange = Notification.Name("DocumentModelStructureDidChange")

    @MainActor weak var editRecorder: EditRecorder?

    /// False for documents that can be viewed but not changed (damaged
    /// beyond repair, or not PDF).
    let isEditable: Bool
    /// What the document's permissions allow (everything for its owner).
    private(set) var allowed: Allowed = .everything

    /// Reads the permissions again (after unlocking as the owner, or a
    /// security change).
    func refreshPermissions() {
        allowed = engine.allowed
    }

    func allows(_ needed: Allowed) -> Bool {
        isEditable && allowed.isSuperset(of: needed)
    }

    init(engine: EngineDocument, isEditable: Bool) throws {
        self.engine = engine
        self.isEditable = isEditable
        allowed = engine.allowed
        _pageBounds = try engine.pageBounds()
    }

    /// A page's bounds, or nil if there is no such page (any thread).
    func bounds(page: Int) -> CGRect? {
        lock.withLock { page >= 0 && page < _pageBounds.count ? _pageBounds[page] : nil }
    }

    /// Bumped whenever rendered output goes out of date.
    var revision: Int { lock.withLock { _revision } }

    /// A page's version: changes whenever what the page draws changes.
    func revision(page: Int) -> Int {
        lock.withLock { unlockedRevision(page) }
    }

    private func unlockedRevision(_ page: Int) -> Int {
        _revision &* 1_000_003 &+ (pageRevisions[page] ?? 0)
    }

    /// Call with `lock` held.
    private func unchanged(_ page: Int, since revision: Int) -> Bool {
        unlockedRevision(page) == revision
    }

    func displayList(page: Int) throws -> DisplayList {
        if let list = lock.withLock({ lists[page] }) { return list }
        // Loading takes the document lock in the bridge; don't hold ours
        // meanwhile. If the page changes while it loads, it isn't cached.
        let before = revision(page: page)
        let list = try engine.displayList(page: page)
        lock.withLock {
            if lists[page] == nil, unchanged(page, since: before) {
                lists[page] = list
                listOrder.append(page)
                if listOrder.count > Self.maxLists { lists[listOrder.removeFirst()] = nil }
            }
        }
        return list
    }

    func cachedText(page: Int) -> PageText? {
        lock.withLock { texts[page] }
    }

    /// The page's text, loading it if needed. Empty if the page fails.
    func text(page: Int) -> PageText {
        if let text = cachedText(page: page) { return text }
        let before = revision(page: page)
        let text = (try? engine.text(page: page)) ?? PageText(chars: [])
        lock.withLock {
            if texts[page] == nil, unchanged(page, since: before) {
                texts[page] = text
                textOrder.append(page)
                if textOrder.count > Self.maxTexts { texts[textOrder.removeFirst()] = nil }
            }
        }
        return text
    }

    /// The page's text runs and image drawings (Edit Content), cached for
    /// a few pages; nil if the page's content can't be read.
    func content(page: Int) -> PageContent? {
        if let cached = lock.withLock({ contentCache[page] }) { return cached }
        let before = revision(page: page)
        guard let content = try? engine.content(page: page) else { return nil }
        lock.withLock {
            if contentCache[page] == nil, unchanged(page, since: before) {
                contentCache[page] = content
                contentOrder.append(page)
                if contentOrder.count > 20 { contentCache[contentOrder.removeFirst()] = nil }
            }
        }
        return content
    }

    /// The page's paragraphs (editing text), cached for a few pages; nil if
    /// the page's content can't be read.
    func paragraphs(page: Int) -> PageParagraphs? {
        if let cached = lock.withLock({ paragraphCache[page] }) { return cached }
        let before = revision(page: page)
        guard let paragraphs = try? engine.paragraphs(page: page) else { return nil }
        lock.withLock {
            if paragraphCache[page] == nil, unchanged(page, since: before) {
                paragraphCache[page] = paragraphs
                paragraphOrder.append(page)
                if paragraphOrder.count > 10 { paragraphCache[paragraphOrder.removeFirst()] = nil }
            }
        }
        return paragraphs
    }

    func links(page: Int) -> [PageLink] {
        if let links = lock.withLock({ linkCache[page] }) { return links }
        let before = revision(page: page)
        let links = (try? engine.links(page: page)) ?? []
        lock.withLock { if unchanged(page, since: before) { linkCache[page] = links } }
        return links
    }

    // MARK: Annotations and editing

    /// The page's annotations (replies and statuses included), cached.
    func annotations(page: Int) -> [Annotation] {
        if let cached = lock.withLock({ annotationCache[page] }) { return cached }
        let before = revision(page: page)
        let annotations = (try? engine.annotations(page: page)) ?? []
        lock.withLock { if unchanged(page, since: before) { annotationCache[page] = annotations } }
        return annotations
    }

    /// The page's annotations if already loaded (for the cursor, which mustn't load).
    func cachedAnnotations(page: Int) -> [Annotation]? {
        lock.withLock { annotationCache[page] }
    }

    func annotation(page: Int, id: Int) -> Annotation? {
        annotations(page: page).first { $0.id == id }
    }

    /// The page's form fields, cached.
    func fields(page: Int) -> [FormField] {
        if let cached = lock.withLock({ fieldCache[page] }) { return cached }
        let before = revision(page: page)
        let fields = (try? engine.fields(page: page)) ?? []
        lock.withLock {
            if fieldCache[page] == nil, unchanged(page, since: before) {
                fieldCache[page] = fields
                fieldOrder.append(page)
                if fieldOrder.count > Self.maxFieldPages { fieldCache[fieldOrder.removeFirst()] = nil }
            }
        }
        return fields
    }

    /// The page's form fields if already loaded (for the cursor, which mustn't load).
    func cachedFields(page: Int) -> [FormField]? {
        lock.withLock { fieldCache[page] }
    }

    /// Makes one change through the engine, as one undoable step: afterwards
    /// the pages are redrawn and the change is recorded for undo.
    @MainActor
    @discardableResult
    func edit<T>(_ actionName: String, pages: Set<Int>, needs: Allowed = .edit, _ body: (EngineDocument) throws -> T) throws -> T {
        guard isEditable else { throw EngineError(code: -1, message: "This document can’t be changed.") }
        guard allowed.isSuperset(of: needs) else { throw EngineError(code: -1, message: "The document’s owner doesn’t allow this.") }
        let result = try body(engine)
        pagesChanged(pages)
        editRecorder?.didEdit(actionName: actionName, change: .pages(pages))
        return result
    }

    /// Like `edit`, for changes to the pages themselves: afterwards
    /// everything about pages is reloaded.
    @MainActor
    @discardableResult
    func editStructure<T>(_ actionName: String, _ body: (EngineDocument) throws -> T) throws -> T {
        guard isEditable else { throw EngineError(code: -1, message: "This document can’t be changed.") }
        guard allowed.contains(.assemble) else { throw EngineError(code: -1, message: "The document’s owner doesn’t allow its pages to be changed.") }
        let result = try body(engine)
        structureChanged()
        editRecorder?.didEdit(actionName: actionName, change: .structure)
        return result
    }

    /// Applies a change made outside `edit` (undo and redo).
    @MainActor
    func changed(_ change: ModelChange) {
        switch change {
        case let .pages(pages): pagesChanged(pages)
        case .structure: structureChanged()
        }
    }

    /// Reloads page geometry, forgets everything cached and tells the views.
    @MainActor
    func structureChanged() {
        // If reading the bounds fails, the old ones are kept for as many
        // pages as there now are.
        let bounds = (try? engine.pageBounds()) ?? {
            let count = (try? engine.pageCount()) ?? pageCount
            let old = pageBounds
            return (0..<count).map { $0 < old.count ? old[$0] : CGRect(x: 0, y: 0, width: 612, height: 792) }
        }()
        lock.withLock {
            _pageBounds = bounds.isEmpty ? [CGRect(x: 0, y: 0, width: 612, height: 792)] : bounds
            lists.removeAll()
            listOrder.removeAll()
            texts.removeAll()
            textOrder.removeAll()
            linkCache.removeAll()
            contentCache.removeAll()
            contentOrder.removeAll()
            paragraphCache.removeAll()
            paragraphOrder.removeAll()
            annotationCache.removeAll()
            fieldCache.removeAll()
            fieldOrder.removeAll()
            pageRevisions.removeAll()
            _revision += 1
        }
        NotificationCenter.default.post(name: Self.structureDidChange, object: self)
    }

    /// Forgets what was cached for these pages (nil: all pages) and tells
    /// the views. Called after edits, undo and redo.
    @MainActor
    func pagesChanged(_ pages: Set<Int>?) {
        lock.withLock {
            let all = pages ?? Set(0..<_pageBounds.count)
            for page in all {
                lists[page] = nil
                texts[page] = nil
                linkCache[page] = nil
                contentCache[page] = nil
                paragraphCache[page] = nil
                annotationCache[page] = nil
                fieldCache[page] = nil
                pageRevisions[page, default: 0] += 1
            }
            listOrder.removeAll { all.contains($0) }
            textOrder.removeAll { all.contains($0) }
            fieldOrder.removeAll { all.contains($0) }
            contentOrder.removeAll { all.contains($0) }
            paragraphOrder.removeAll { all.contains($0) }
        }
        NotificationCenter.default.post(name: Self.pagesDidChange, object: self,
                                        userInfo: pages.map { ["pages": $0] })
    }

    /// Turns a layer on or off and invalidates everything rendered.
    func toggleLayer(_ index: Int) throws {
        try engine.toggleLayer(index)
        // Layers change what pages draw and what text they have.
        lock.withLock {
            lists.removeAll()
            listOrder.removeAll()
            texts.removeAll()
            textOrder.removeAll()
            linkCache.removeAll()
            contentCache.removeAll()
            contentOrder.removeAll()
            paragraphCache.removeAll()
            paragraphOrder.removeAll()
            annotationCache.removeAll()
            fieldCache.removeAll()
            fieldOrder.removeAll()
            _revision += 1
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.renderingDidChange, object: self)
        }
    }

    // MARK: Geometry

    /// A page's size in points once the view rotation is applied.
    func viewSize(page: Int, rotation: Int) -> CGSize {
        let size = pageBounds[page].size
        return rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// From page space to the page's own view coordinates at 1 point per point.
    func pageToView(page: Int, rotation: Int) -> CGAffineTransform {
        EngineDocument.pageTransform(bounds: pageBounds[page], scale: 1, rotation: rotation)
    }
}
