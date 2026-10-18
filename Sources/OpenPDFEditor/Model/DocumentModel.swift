import Foundation
import PDFCore

/// An unlocked document and what the viewer keeps of it: page geometry and
/// caches of display lists, text and links. Thread-safe.
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
    private var _revision = 0

    private static let maxLists = 40
    private static let maxTexts = 400

    /// Posted on the main thread when pages must be redrawn from scratch
    /// (a layer was turned on or off).
    static let renderingDidChange = Notification.Name("DocumentModelRenderingDidChange")

    init(engine: EngineDocument) throws {
        self.engine = engine
        pageBounds = try engine.pageBounds()
    }

    /// Bumped whenever rendered output goes out of date.
    var revision: Int { lock.withLock { _revision } }

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

    /// Turns a layer on or off and invalidates everything rendered.
    func toggleLayer(_ index: Int) throws {
        try engine.toggleLayer(index)
        lock.withLock {
            lists.removeAll()
            listOrder.removeAll()
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
