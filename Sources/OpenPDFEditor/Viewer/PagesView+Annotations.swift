import AppKit
import PDFCore

/// Mouse handling for annotations: selecting, moving and resizing them with
/// the Select tool, and drawing new ones with the other tools. Text
/// selection (and the text markup tools) use the text handlers.
extension PagesView {
    private var zoom: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.05) }
    /// Six screen points, in page points.
    private var tolerance: CGFloat { 6 / zoom }

    override func mouseDown(with event: NSEvent) {
        fieldEditor?.finish()
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        guard let (page, point) = pageAndPoint(at: location), let annotations else {
            textMouseDown(with: event)
            return
        }
        let onPage = layout.frames[page]?.contains(location) == true
        if isCropping {
            guard onPage, model.isEditable else { return }
            gesture = .crop(page: page, start: point, current: point)
            return
        }
        if !model.isEditable && tool != .select { tool = .select }
        switch tool {
        case .select:
            if let ref = selectedAnnotation, ref.page == page, let a = annotations.annotation(ref),
               let handle = annotations.handles(for: a).first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance })?.0 {
                gesture = .resize(ref, handle, current: point)
                return
            }
            if onPage, let a = annotations.hit(point, page: page, tolerance: tolerance) {
                let ref = AnnotationRef(page: page, id: a.id)
                selection = nil
                selectedAnnotation = ref
                if event.clickCount == 2 {
                    delegate?.pagesView(self, edit: ref)
                } else if annotations.canMove(a) {
                    gesture = .move(ref, start: point, current: point)
                }
                return
            }
            selectedAnnotation = nil
            if onPage, model.isEditable, let field = forms?.hit(point, page: page) {
                selection = nil
                fill(field)
                return
            }
            textMouseDown(with: event)
        case .highlight, .underline, .strikeOut:
            selectedAnnotation = nil
            textMouseDown(with: event)
        default:
            guard onPage else { return }
            selectedAnnotation = nil
            selection = nil
            gesture = .create(page: page, start: point, current: point, points: [point])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        switch gesture {
        case .none:
            textMouseDragged(with: event)
        case let .create(page, start, _, points):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: page) else { return }
            var points = points
            if tool == .pen, let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1 / zoom {
                points.append(point)
            }
            gesture = .create(page: page, start: start, current: point, points: points)
            drawCreationDraft()
        case let .move(ref, start, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: ref.page) else { return }
            gesture = .move(ref, start: start, current: point)
            drawMoveDraft()
        case let .resize(ref, handle, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: ref.page) else { return }
            gesture = .resize(ref, handle, current: point)
            drawMoveDraft()
        case let .crop(page, start, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: page) else { return }
            gesture = .crop(page: page, start: start, current: point)
            drawCropDraft()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = gesture
        gesture = .none
        clearDrafts()
        if case let .crop(page, start, current) = finished {
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            // A click, or a sliver, isn't an area.
            if rect.width * zoom >= 8 && rect.height * zoom >= 8 && rect.width >= 4 && rect.height >= 4 {
                delegate?.pagesView(self, crop: rect, onPage: page)
            }
            return
        }
        guard let annotations else {
            textMouseUp(with: event)
            return
        }
        do {
            switch finished {
            case .none:
                textMouseUp(with: event)
                if tool.marksText, let selection, !selection.isEmpty {
                    let ref = try annotations.markText(tool, selection: selection)
                    self.selection = nil
                    _ = ref
                }
            case let .create(page, start, current, points):
                var created: AnnotationRef?
                switch tool {
                case .note: created = try annotations.createNote(page: page, at: start)
                case .stamp: created = try annotations.createStamp(page: page, at: start)
                case .pen: created = try annotations.createInk(page: page, points: points)
                default: created = try annotations.createShape(tool, page: page, from: start, to: current)
                }
                let used = tool
                if let created {
                    if !used.staysActive { selectedAnnotation = created }
                    if used == .note || used == .textBox { delegate?.pagesView(self, edit: created) }
                }
                if !used.staysActive { delegate?.pagesView(self, didUse: used) }
            case let .move(ref, start, current):
                try annotations.move(ref, by: CGVector(dx: current.x - start.x, dy: current.y - start.y))
            case let .resize(ref, handle, current):
                try annotations.resize(ref, handle: handle, to: current)
            case .crop:
                break
            }
        } catch {
            NSSound.beep()
        }
    }

    /// A point on the page, kept inside it.
    private func clampedPoint(_ location: NSPoint, page: Int) -> CGPoint? {
        guard let point = convert(location, toPage: page), page < model.pageCount else { return nil }
        let bounds = model.pageBounds[page]
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    // MARK: Drafts (shapes being drawn, moved or resized)

    private func pageView(_ page: Int) -> PageView? {
        subviews.lazy.compactMap { $0 as? PageView }.first { $0.page == page }
    }

    private func drawCreationDraft() {
        guard case let .create(page, start, current, points) = gesture, let view = pageView(page) else { return }
        let path = CGMutablePath()
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        switch tool {
        case .rectangle, .textBox: path.addRect(rect)
        case .oval: path.addEllipse(in: rect)
        case .line, .arrow:
            path.move(to: start)
            path.addLine(to: current)
            if tool == .arrow { addArrowHead(to: path, from: start, to: current) }
        case .pen:
            if let first = points.first {
                path.move(to: first)
                for p in points.dropFirst() { path.addLine(to: p) }
            }
        default: return
        }
        let width = tool == .textBox ? 1 / zoom : ToolSettings.lineWidth(for: tool)
        view.setDraft(path, color: ToolSettings.color(for: tool).nsColor, lineWidth: width,
                      transform: model.pageToView(page: page, rotation: rotation), dashed: tool == .textBox)
    }

    private func drawCropDraft() {
        guard case let .crop(page, start, current) = gesture, let view = pageView(page) else { return }
        let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        view.setDraft(CGPath(rect: rect, transform: nil), color: .controlAccentColor, lineWidth: 1.5 / zoom,
                      transform: model.pageToView(page: page, rotation: rotation), dashed: true)
    }

    private func addArrowHead(to path: CGMutablePath, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let size = max(8, ToolSettings.lineWidth(for: .arrow) * 4)
        for side in [-1.0, 1.0] {
            let a = angle + .pi - side * .pi / 7
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x + cos(a) * size, y: end.y + sin(a) * size))
        }
    }

    private func drawMoveDraft() {
        guard let annotations else { return }
        let ref: AnnotationRef
        let path: CGPath
        switch gesture {
        case let .move(r, start, current):
            ref = r
            guard let a = annotations.annotation(r) else { return }
            var t = CGAffineTransform(translationX: current.x - start.x, y: current.y - start.y)
            guard let moved = outline(of: a)?.copy(using: &t) else { return }
            path = moved
        case let .resize(r, handle, current):
            ref = r
            guard let a = annotations.annotation(r) else { return }
            let p = CGMutablePath()
            if let line = a.line {
                p.move(to: handle == .lineStart ? current : line.0)
                p.addLine(to: handle == .lineEnd ? current : line.1)
            } else {
                let rect = annotations.resizedRect(a.rect, handle: handle, to: current)
                if a.kind == .circle { p.addEllipse(in: rect) } else { p.addRect(rect) }
            }
            path = p
        default:
            return
        }
        pageView(ref.page)?.setDraft(path, color: .controlAccentColor, lineWidth: 1.5 / zoom,
                                     transform: model.pageToView(page: ref.page, rotation: rotation), dashed: true)
    }

    func clearDrafts() {
        for view in subviews.compactMap({ $0 as? PageView }) {
            view.setDraft(nil, color: .clear, lineWidth: 1, transform: .identity)
        }
    }

    // MARK: Selection outline

    /// An annotation's shape for outlining: its rectangle, or its line, or
    /// its quads.
    private func outline(of a: Annotation) -> CGPath? {
        let path = CGMutablePath()
        if let line = a.line {
            path.move(to: line.0)
            path.addLine(to: line.1)
        } else if !a.quads.isEmpty {
            for q in a.quads { path.addRect(q.bounds) }
        } else {
            path.addRect(a.rect)
        }
        return path
    }

    func refreshAnnotationSelection() {
        if let ref = selectedAnnotation, annotations?.annotation(ref) == nil {
            selectedAnnotation = nil   // it was deleted or undone
            return
        }
        for view in subviews.compactMap({ $0 as? PageView }) {
            applyAnnotationSelection(to: view, page: view.page)
        }
    }

    func applyAnnotationSelection(to view: PageView, page: Int) {
        guard let ref = selectedAnnotation, ref.page == page, let annotations, let a = annotations.annotation(ref) else {
            view.setAnnotationSelection(outline: nil, handles: [], transform: .identity, zoom: zoom)
            return
        }
        let outlinePath: CGPath? = a.line == nil ? outline(of: a) : nil
        view.setAnnotationSelection(outline: outlinePath, handles: annotations.handles(for: a).map(\.1),
                                    transform: model.pageToView(page: page, rotation: rotation), zoom: zoom)
    }

    // MARK: Cursor, delete

    func annotationCursor(at location: NSPoint) -> NSCursor? {
        guard let annotations, let (page, point) = pageAndPoint(at: location),
              layout.frames[page]?.contains(location) == true else { return nil }
        if let ref = selectedAnnotation, ref.page == page, let a = annotations.model.cachedAnnotations(page: page)?.first(where: { $0.id == ref.id }),
           annotations.handles(for: a).contains(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance }) {
            return .crosshair
        }
        if let a = annotations.hit(point, page: page, tolerance: tolerance, cachedOnly: true) {
            return annotations.canMove(a) ? .openHand : .arrow
        }
        return nil
    }

    func deleteSelectedAnnotation() {
        guard let ref = selectedAnnotation, let annotations else {
            NSSound.beep()
            return
        }
        do {
            try annotations.delete(ref)
            selectedAnnotation = nil
        } catch {
            NSSound.beep()
        }
    }
}
