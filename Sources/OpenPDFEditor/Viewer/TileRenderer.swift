import AppKit
import PDFCore

/// What a rendered image shows: a tile of a page at a zoom level, or a
/// whole page as a small preview.
enum RenderKey: Hashable, Sendable {
    /// `level` is a zoom step: the render scale is 2^(level/4) pixels per point.
    case tile(page: Int, level: Int, column: Int, row: Int, rotation: Int, revision: Int)
    /// A whole page `width` pixels wide (before rotation is applied to the shape).
    case preview(page: Int, width: Int, rotation: Int, revision: Int)
}

/// A pending render that can be cancelled.
final class RenderTicket: @unchecked Sendable {
    fileprivate let key: RenderKey
    fileprivate weak var renderer: TileRenderer?
    fileprivate let id: Int

    fileprivate init(key: RenderKey, renderer: TileRenderer, id: Int) {
        self.key = key
        self.renderer = renderer
        self.id = id
    }

    func cancel() { renderer?.cancel(self) }
}

/// Renders page tiles and previews off the main thread and caches them.
///
/// Tiles are `tileSize` pixels square in view space at their level's scale.
/// Requests for the same image share one render; a render is stopped when
/// every request for it is cancelled.
final class TileRenderer: @unchecked Sendable {
    static let tileSize = 512
    static let cacheLimit = 384 * 1024 * 1024

    let model: DocumentModel

    private let queue: OperationQueue
    private let previewQueue: OperationQueue
    private let lock = NSLock()

    private struct Entry {
        let image: CGImage
        let cost: Int
        var used: Int
    }
    private var cache: [RenderKey: Entry] = [:]
    private var cacheCost = 0
    private var clock = 0

    private final class Job: @unchecked Sendable {
        let cookie = RenderCookie()
        var operation: Operation?
        var waiting: [Int: @MainActor @Sendable (CGImage) -> Void] = [:]
    }
    private var jobs: [RenderKey: Job] = [:]
    private var nextTicket = 0

    init(model: DocumentModel) {
        self.model = model
        queue = OperationQueue()
        queue.name = "Tile rendering"
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        queue.qualityOfService = .userInitiated
        previewQueue = OperationQueue()
        previewQueue.name = "Preview rendering"
        previewQueue.maxConcurrentOperationCount = 2
        previewQueue.qualityOfService = .userInitiated
    }

    static func scale(forLevel level: Int) -> CGFloat {
        pow(2, CGFloat(level) / 4)
    }

    /// The smallest level whose scale is at least `scale`.
    static func level(forScale scale: CGFloat) -> Int {
        // The small allowance keeps an exact level's own scale on that level.
        Int((log2(max(scale, 1.0 / 64)) * 4 - 0.001).rounded(.up))
    }

    func cached(_ key: RenderKey) -> CGImage? {
        lock.withLock {
            guard var entry = cache[key] else { return nil }
            clock += 1
            entry.used = clock
            cache[key] = entry
            return entry.image
        }
    }

    /// Renders `key` unless it is cached; `completion` runs on the main thread.
    @discardableResult
    func request(_ key: RenderKey, priority: Operation.QueuePriority = .normal,
                 completion: @escaping @MainActor @Sendable (CGImage) -> Void) -> RenderTicket? {
        if let image = cached(key) {
            MainActor.assumeIsolated { completion(image) }
            return nil
        }
        return lock.withLock {
            nextTicket += 1
            let ticket = RenderTicket(key: key, renderer: self, id: nextTicket)
            if let job = jobs[key] {
                job.waiting[ticket.id] = completion
                if priority.rawValue > (job.operation?.queuePriority.rawValue ?? 0) {
                    job.operation?.queuePriority = priority
                }
                return ticket
            }
            let job = Job()
            job.waiting[ticket.id] = completion
            let operation = BlockOperation { [weak self, job] in
                self?.run(key, job: job)
            }
            operation.queuePriority = priority
            job.operation = operation
            jobs[key] = job
            if case .preview = key { previewQueue.addOperation(operation) } else { queue.addOperation(operation) }
            return ticket
        }
    }

    fileprivate func cancel(_ ticket: RenderTicket) {
        lock.withLock {
            guard let job = jobs[ticket.key] else { return }
            job.waiting[ticket.id] = nil
            if job.waiting.isEmpty {
                job.operation?.cancel()
                job.cookie.cancel()
                jobs[ticket.key] = nil
            }
        }
    }

    /// Drops every cached image and pending render.
    func reset() {
        lock.withLock {
            for job in jobs.values {
                job.operation?.cancel()
                job.cookie.cancel()
            }
            jobs.removeAll()
            cache.removeAll()
            cacheCost = 0
        }
    }

    private func run(_ key: RenderKey, job: Job) {
        if job.cookie.isCancelled { return }
        let image: CGImage?
        do {
            image = try render(key, cookie: job.cookie)
        } catch {
            image = nil
        }
        let callbacks: [@MainActor @Sendable (CGImage) -> Void] = lock.withLock {
            if let image { store(key, image) }
            // A newer job may have replaced this one after a cancel.
            guard jobs[key] === job else { return [] }
            jobs[key] = nil
            return image == nil ? [] : Array(job.waiting.values)
        }
        guard let image, !callbacks.isEmpty else { return }
        DispatchQueue.main.async {
            for callback in callbacks { callback(image) }
        }
    }

    private func render(_ key: RenderKey, cookie: RenderCookie) throws -> CGImage {
        switch key {
        case let .tile(page, level, column, row, rotation, _):
            let bounds = model.pageBounds[page]
            let scale = Self.scale(forLevel: level)
            let full = bounds.applying(EngineDocument.pageTransform(bounds: bounds, scale: scale, rotation: rotation))
            let size = CGFloat(Self.tileSize)
            let rect = CGRect(x: CGFloat(column) * size, y: CGFloat(row) * size, width: size, height: size)
                .intersection(CGRect(origin: .zero, size: CGSize(width: full.width.rounded(.up), height: full.height.rounded(.up))))
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
                throw EngineError(code: -1, message: "Tile outside the page")
            }
            let list = try model.displayList(page: page)
            return try model.engine.render(list, bounds: bounds, scale: scale, rotation: rotation, rect: rect, cookie: cookie)
        case let .preview(page, width, rotation, _):
            let bounds = model.pageBounds[page]
            let unrotatedWidth = rotation % 180 == 0 ? bounds.width : bounds.height
            let scale = CGFloat(width) / max(unrotatedWidth, 1)
            let list = try model.displayList(page: page)
            let full = bounds.applying(EngineDocument.pageTransform(bounds: bounds, scale: scale, rotation: rotation))
            return try model.engine.render(list, bounds: bounds, scale: scale, rotation: rotation,
                                           rect: CGRect(x: 0, y: 0, width: max(1, full.width.rounded()), height: max(1, full.height.rounded())),
                                           cookie: cookie)
        }
    }

    /// Call with `lock` held.
    private func store(_ key: RenderKey, _ image: CGImage) {
        let cost = image.bytesPerRow * image.height
        clock += 1
        if let old = cache[key] { cacheCost -= old.cost }
        cache[key] = Entry(image: image, cost: cost, used: clock)
        cacheCost += cost
        if cacheCost > Self.cacheLimit {
            // Evict the least recently used quarter.
            let sorted = cache.sorted { $0.value.used < $1.value.used }
            var freed = 0
            for (k, entry) in sorted {
                if cacheCost - freed <= Self.cacheLimit * 3 / 4 { break }
                cache[k] = nil
                freed += entry.cost
            }
            cacheCost -= freed
        }
    }
}
