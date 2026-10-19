import AppKit
import PDFCore

/// An annotation on a page.
struct AnnotationRef: Hashable {
    let page: Int
    let id: Int
}

/// The grips on a selected annotation.
enum AnnotationHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, lineStart, lineEnd
}

/// Finds, creates and changes annotations. Every change goes through
/// `DocumentModel.edit`, so it is one undoable step and the page is redrawn.
@MainActor
final class AnnotationController {
    let model: DocumentModel
    private var loading = Set<Int>()

    init(model: DocumentModel) {
        self.model = model
    }

    func annotation(_ ref: AnnotationRef) -> Annotation? {
        model.annotation(page: ref.page, id: ref.id)
    }

    // MARK: Finding

    /// Annotations shown on the page: not replies, statuses or hidden ones.
    func visibleAnnotations(page: Int) -> [Annotation] {
        model.annotations(page: page).filter { !$0.isReply && !$0.isHidden }
    }

    /// The topmost annotation at a point in page space. `tolerance` (points)
    /// widens thin things like lines. With `cachedOnly` (the cursor, as the
    /// mouse moves) nothing is loaded; the page's annotations are fetched in
    /// the background instead.
    func hit(_ point: CGPoint, page: Int, tolerance: CGFloat, cachedOnly: Bool = false) -> Annotation? {
        let list: [Annotation]
        if cachedOnly {
            guard let cached = model.cachedAnnotations(page: page) else {
                // One load per page at a time, however often the mouse moves.
                if !loading.contains(page) {
                    loading.insert(page)
                    let model = self.model
                    EngineExecutor.background.async(.low) { [weak self] in
                        _ = model.annotations(page: page)
                        DispatchQueue.main.async { self?.loading.remove(page) }
                    }
                }
                return nil
            }
            list = cached.filter { !$0.isReply && !$0.isHidden }
        } else {
            list = visibleAnnotations(page: page)
        }
        for annotation in list.reversed() where contains(annotation, point, tolerance) {
            return annotation
        }
        return nil
    }

    private func contains(_ a: Annotation, _ p: CGPoint, _ tolerance: CGFloat) -> Bool {
        if !a.quads.isEmpty {
            return a.quads.contains { $0.bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p) }
        }
        let reach = max(tolerance, a.borderWidth / 2 + tolerance / 2)
        if !a.ink.isEmpty {
            return a.ink.contains { stroke in
                zip(stroke, stroke.dropFirst()).contains { distance(p, $0, $1) <= reach }
                    || (stroke.count == 1 && hypot(stroke[0].x - p.x, stroke[0].y - p.y) <= reach)
            }
        }
        if let line = a.line {
            return distance(p, line.0, line.1) <= reach
        }
        return a.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Selection geometry

    func canMove(_ a: Annotation) -> Bool {
        model.allows(.annotate) && !a.isReadOnly && !a.kind.isTextMarkup && a.flags & 0x80 == 0   // not Locked
    }

    func canEdit(_ a: Annotation) -> Bool {
        model.allows(.annotate) && !a.isReadOnly
    }

    func canResize(_ a: Annotation) -> Bool {
        canMove(a) && [.square, .circle, .freeText, .stamp, .ink, .line].contains(a.kind)
    }

    /// The grips for a selected annotation, in page space.
    func handles(for a: Annotation) -> [(AnnotationHandle, CGPoint)] {
        guard canResize(a) else { return [] }
        if let line = a.line {
            return [(.lineStart, line.0), (.lineEnd, line.1)]
        }
        let r = a.rect
        return [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
            (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    /// The rectangle after dragging a handle to `point`.
    func resizedRect(_ rect: CGRect, handle: AnnotationHandle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; minY = point.y
        case .top: minY = point.y
        case .topRight: maxX = point.x; minY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; maxY = point.y
        case .bottom: maxY = point.y
        case .bottomLeft: minX = point.x; maxY = point.y
        case .left: minX = point.x
        case .lineStart, .lineEnd: break
        }
        let r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        return CGRect(x: r.minX, y: r.minY, width: max(r.width, 4), height: max(r.height, 4))
    }

    // MARK: Creating

    private var author: String { ToolSettings.author }

    private func clamp(_ rect: CGRect, page: Int) -> CGRect {
        let bounds = model.pageBounds[page]
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Highlights, underlines, strikes through or marks for redaction the
    /// selected text: one annotation per page.
    func markText(_ tool: AnnotationTool, selection: TextSelection) throws -> AnnotationRef? {
        var created: AnnotationRef?
        for page in selection.start.page...selection.end.page {
            let text = model.text(page: page)
            guard let range = selection.range(onPage: page, count: text.chars.count) else { continue }
            let rects = text.rects(for: range).filter { $0.width > 0 && $0.height > 0 }
            guard !rects.isEmpty else { continue }
            var change = AnnotationChange(kind: tool.kind)
            change.quads = rects.map(Quad.init)
            change.color = .some(ToolSettings.color(for: tool))
            change.author = author
            let id = try model.edit(tool.title, pages: [page], needs: .annotate) {
                try $0.createAnnotation(page: page, change, actionName: tool.title)
            }
            created = created ?? AnnotationRef(page: page, id: id)
        }
        return created
    }

    /// A text box, rectangle, oval, line or arrow dragged from `start` to `end`.
    func createShape(_ tool: AnnotationTool, page: Int, from start: CGPoint, to end: CGPoint) throws -> AnnotationRef? {
        var change = AnnotationChange(kind: tool.kind)
        change.author = author
        let color = ToolSettings.color(for: tool)
        let width = ToolSettings.lineWidth(for: tool)
        var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .line, .arrow:
            guard hypot(end.x - start.x, end.y - start.y) >= 4 else { return nil }
            change.line = (start, end)
            change.lineEndings = (.none, tool == .arrow ? .openArrow : .none)
            change.color = .some(color)
            change.borderWidth = width
        case .textBox:
            if rect.width < 12 || rect.height < 8 { rect = CGRect(x: start.x, y: start.y, width: 200, height: ToolSettings.textSize * 2.2) }
            change.rect = clamp(rect, page: page)
            change.contents = "Text"
            change.font = (size: ToolSettings.textSize, color: color)
            change.color = .some(nil)
            change.borderWidth = 0
        case .redact:
            // A click isn't an area.
            guard rect.width >= 2, rect.height >= 2 else { return nil }
            change.rect = clamp(rect, page: page)
            change.color = .some(color)
        case .rectangle, .oval:
            if rect.width < 4 || rect.height < 4 { rect = CGRect(x: start.x, y: start.y, width: 120, height: 80) }
            change.rect = clamp(rect, page: page)
            change.color = .some(color)
            change.borderWidth = width
        default:
            return nil
        }
        let id = try model.edit(tool.title, pages: [page], needs: .annotate) { try $0.createAnnotation(page: page, change, actionName: tool.title) }
        return AnnotationRef(page: page, id: id)
    }

    func createInk(page: Int, points: [CGPoint]) throws -> AnnotationRef? {
        guard points.count >= 2 else { return nil }
        var change = AnnotationChange(kind: .ink)
        change.ink = [points]
        change.color = .some(ToolSettings.color(for: .pen))
        change.borderWidth = ToolSettings.lineWidth(for: .pen)
        change.author = author
        let id = try model.edit("Drawing", pages: [page], needs: .annotate) { try $0.createAnnotation(page: page, change, actionName: "Drawing") }
        return AnnotationRef(page: page, id: id)
    }

    func createNote(page: Int, at point: CGPoint) throws -> AnnotationRef {
        var change = AnnotationChange(kind: .text)
        change.rect = clamp(CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), page: page)
        change.color = .some(ToolSettings.color(for: .note))
        change.iconName = "Note"
        change.contents = ""
        change.author = author
        let id = try model.edit("Note", pages: [page], needs: .annotate) { try $0.createAnnotation(page: page, change, actionName: "Note") }
        return AnnotationRef(page: page, id: id)
    }

    func createStamp(page: Int, at point: CGPoint) throws -> AnnotationRef {
        let stamp = ToolSettings.stamp
        let width = max(140, CGFloat(stamp.title.count) * 13)
        var change = AnnotationChange(kind: .stamp)
        change.rect = clamp(CGRect(x: point.x - width / 2, y: point.y - 25, width: width, height: 50), page: page)
        change.iconName = stamp.rawValue
        change.author = author
        let id = try model.edit("Stamp", pages: [page], needs: .annotate) { try $0.createAnnotation(page: page, change, actionName: "Stamp") }
        return AnnotationRef(page: page, id: id)
    }

    // MARK: Changing

    func move(_ ref: AnnotationRef, by delta: CGVector) throws {
        guard delta.dx != 0 || delta.dy != 0 else { return }
        try model.edit("Move", pages: [ref.page], needs: .annotate) {
            try $0.transformAnnotation(page: ref.page, id: ref.id, by: CGAffineTransform(translationX: delta.dx, y: delta.dy), actionName: "Move")
        }
    }

    func resize(_ ref: AnnotationRef, handle: AnnotationHandle, to point: CGPoint) throws {
        guard let a = annotation(ref) else { return }
        if let line = a.line, handle == .lineStart || handle == .lineEnd {
            var change = AnnotationChange(kind: a.kind)
            change.line = handle == .lineStart ? (point, line.1) : (line.0, point)
            try model.edit("Resize", pages: [ref.page], needs: .annotate) { try $0.updateAnnotation(page: ref.page, id: ref.id, change, actionName: "Resize") }
            return
        }
        let old = a.rect
        let new = resizedRect(old, handle: handle, to: point)
        guard old.width > 0, old.height > 0, new != old else { return }
        let transform = CGAffineTransform(translationX: -old.minX, y: -old.minY)
            .concatenating(CGAffineTransform(scaleX: new.width / old.width, y: new.height / old.height))
            .concatenating(CGAffineTransform(translationX: new.minX, y: new.minY))
        try model.edit("Resize", pages: [ref.page], needs: .annotate) {
            try $0.transformAnnotation(page: ref.page, id: ref.id, by: transform, actionName: "Resize")
        }
    }

    func delete(_ ref: AnnotationRef) throws {
        if let a = annotation(ref), !canEdit(a) { throw EngineError(code: -1, message: "This annotation can’t be changed.") }
        try model.edit("Delete", pages: [ref.page], needs: .annotate) { try $0.deleteAnnotation(page: ref.page, id: ref.id, actionName: "Delete") }
    }

    /// Changes some properties of an annotation as one undoable step.
    func update(_ ref: AnnotationRef, actionName: String, _ configure: (inout AnnotationChange) -> Void) throws {
        guard let a = annotation(ref) else { return }
        var change = AnnotationChange(kind: a.kind)
        configure(&change)
        try model.edit(actionName, pages: [ref.page], needs: .annotate) {
            try $0.updateAnnotation(page: ref.page, id: ref.id, change, actionName: actionName)
        }
    }

    func reply(to ref: AnnotationRef, text: String) throws {
        try model.edit("Reply", pages: [ref.page], needs: .annotate) { try $0.reply(page: ref.page, to: ref.id, author: author, contents: text) }
    }

    /// Sets (nil: clears) this user's review status on an annotation.
    func setStatus(_ ref: AnnotationRef, _ state: String?) throws {
        try model.edit("Set Status", pages: [ref.page], needs: .annotate) { try $0.setStatus(page: ref.page, of: ref.id, author: author, state: state) }
    }
}
