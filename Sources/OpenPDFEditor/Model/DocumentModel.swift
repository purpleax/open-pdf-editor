import Foundation
import PDFCore

/// Records each edit for undo (the document does this).
@MainActor
protocol EditRecorder: AnyObject {
    func didEdit(actionName: String, pages: Set<Int>)
}

/// An unlocked document and what the viewer keeps of it: page geometry and
/// caches of display lists, text, links and annotations. Thread-safe, except
/// `edit`, which runs on the main thread.
final class DocumentModel: @unchecked Sendable {
    let engine: EngineDocument
    let pageBounds: [CGRect]
    var pageCount: Int { pageBounds.count }

    private let lock = NSLock()
    private var lists: [Int: DisplayList] = [:]
    private var listOrder: [Int] = []
    private var texts: [Int: PageText] = [:]
    private var textOrder: [Int] = []
    private var linkCache: [Int: [PageLink]] = [:]
    private var annotationCache: [Int: [Annotation]] = [:]
    private var _revision = 0
    private var pageRevisions: [Int: Int] = [:]

    private static let maxLists = 40
    private static let maxTexts = 400

    /// Posted on the main thread when pages must be redrawn from scratch
    /// (a layer was turned on or off).
    static let renderingDidChange = Notification.Name("DocumentModelRenderingDidChange")
    /// Posted on the main thread after pages change (an edit, undo or redo);
    /// userInfo["pages"] is the Set<Int> of pages, or absent for all pages.
    static let pagesDidChange = Notification.Name("DocumentModelPagesDidChange")

    @MainActor weak var editRecorder: EditRecorder?

    /// False for documents that can be viewed but not changed (damaged
    /// beyond repair, or not PDF).
    let isEditable: Bool

    init(engine: EngineDocument, isEditable: Bool) throws {
        self.engine = engine
        self.isEditable = isEditable
        pageBounds = try engine.pageBounds()
    }

    /// Bumped whenever rendered output goes out of date.
    var revision: Int { lock.withLock { _revision } }

    /// A page's version: changes whenever what the page draws changes.
    func revision(page: Int) -> Int {
        lock.withLock { _revision &* 1_000_003 &+ (pageRevisions[page] ?? 0) }
    }

    func displayList(page: Int) throws -> DisplayList {
        if let list = lock.withLock({ lists[page] }) { return list }
        // Loading takes the document lock in the bridge; don't hold ours meanwhile.
        let list = try engine.displayList(page: page)
        lock.withLock {
            if lists[page] == nil {
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
        let text = (try? engine.text(page: page)) ?? PageText(chars: [])
        lock.withLock {
            if texts[page] == nil {
                texts[page] = text
                textOrder.append(page)
                if textOrder.count > Self.maxTexts { texts[textOrder.removeFirst()] = nil }
            }
        }
        return text
    }

    func links(page: Int) -> [PageLink] {
        if let links = lock.withLock({ linkCache[page] }) { return links }
        let links = (try? engine.links(page: page)) ?? []
        lock.withLock { linkCache[page] = links }
        return links
    }

    // MARK: Annotations and editing

    /// The page's annotations (replies and statuses included), cached.
    func annotations(page: Int) -> [Annotation] {
        if let cached = lock.withLock({ annotationCache[page] }) { return cached }
        let annotations = (try? engine.annotations(page: page)) ?? []
        lock.withLock { annotationCache[page] = annotations }
        return annotations
    }

    /// The page's annotations if already loaded (for the cursor, which mustn't load).
    func cachedAnnotations(page: Int) -> [Annotation]? {
        lock.withLock { annotationCache[page] }
    }

    func annotation(page: Int, id: Int) -> Annotation? {
        annotations(page: page).first { $0.id == id }
    }

    /// Makes one change through the engine, as one undoable step: afterwards
    /// the pages are redrawn and the change is recorded for undo.
    @MainActor
    @discardableResult
    func edit<T>(_ actionName: String, pages: Set<Int>, _ body: (EngineDocument) throws -> T) throws -> T {
        guard isEditable else { throw EngineError(code: -1, message: "This document can’t be changed.") }
        let result = try body(engine)
        pagesChanged(pages)
        editRecorder?.didEdit(actionName: actionName, pages: pages)
        return result
    }

    /// Forgets what was cached for these pages (nil: all pages) and tells
    /// the views. Called after edits, undo and redo.
    @MainActor
    func pagesChanged(_ pages: Set<Int>?) {
        lock.withLock {
            let all = pages ?? Set(0..<pageCount)
            for page in all {
                lists[page] = nil
                texts[page] = nil
                linkCache[page] = nil
                annotationCache[page] = nil
                pageRevisions[page, default: 0] += 1
            }
            listOrder.removeAll { all.contains($0) }
            textOrder.removeAll { all.contains($0) }
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
            annotationCache.removeAll()
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
