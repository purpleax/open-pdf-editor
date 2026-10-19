import AppKit
import PDFCore

/// Mouse handling while editing a form's fields: selecting, moving and
/// resizing fields, and making new ones with the field tools (drag out an
/// area, or click for the tool's usual size).
extension PagesView {
    private static let handleOrder: [AnnotationHandle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    private func handles(_ rect: CGRect) -> [(AnnotationHandle, CGPoint)] {
        Self.handleOrder.map { handle in
            let point: CGPoint = switch handle {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .top: CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            default: CGPoint(x: rect.minX, y: rect.midY)
            }
            return (handle, point)
        }
    }

    private func handle(at point: CGPoint, of field: FormField) -> AnnotationHandle? {
        handles(field.rect).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance }?.0
    }

    func fieldMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let forms, model.isEditable, let (page, point) = pageAndPoint(at: location),
              layout.frames[page]?.contains(location) == true else {
            selectedField = nil
            return
        }
        if fieldTool != .select {
            fieldGesture = .create(page: page, start: point, current: point)
            return
        }
        if let ref = selectedField, ref.page == page, let field = forms.field(ref), let handle = handle(at: point, of: field) {
            fieldGesture = .resize(ref, handle, current: point)
            return
        }
        if let field = forms.hitAny(point, page: page, tolerance: tolerance) {
            let ref = FieldRef(page: page, id: field.id)
            selectedField = ref
            fieldGesture = .move(ref, start: point, current: point)
            return
        }
        selectedField = nil
    }

    func fieldMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        switch fieldGesture {
        case .none:
            return
        case let .create(page, start, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: page) else { return }
            fieldGesture = .create(page: page, start: start, current: point)
        case let .move(ref, start, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: ref.page) else { return }
            fieldGesture = .move(ref, start: start, current: point)
        case let .resize(ref, handle, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: ref.page) else { return }
            fieldGesture = .resize(ref, handle, current: point)
        }
        drawFieldDraft()
    }

    func fieldMouseUp(with event: NSEvent) {
        let finished = fieldGesture
        fieldGesture = .none
        clearDrafts()
        guard let forms else { return }
        do {
            switch finished {
            case .none:
                break
            case let .create(page, start, current):
                let tool = fieldTool
                var rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                  width: abs(current.x - start.x), height: abs(current.y - start.y))
                // A click, or a sliver, makes the tool's usual size.
                if rect.width < 6 || rect.height < 6 { rect = CGRect(origin: start, size: tool.defaultSize) }
                // A new radio button joins the selected radio button's group.
                let group = selectedField.flatMap { forms.field($0)?.kind == .radio ? $0 : nil }
                selectedField = try forms.create(tool, page: page, rect: rect, joining: tool == .radio ? group : nil)
                fieldTool = .select
                delegate?.pagesViewDidUseFieldTool(self)
            case let .move(ref, start, current):
                // A click selects without moving.
                guard hypot(current.x - start.x, current.y - start.y) * zoom >= 2 else { return }
                try forms.move(ref, by: CGVector(dx: current.x - start.x, dy: current.y - start.y))
            case let .resize(ref, handle, current):
                guard let field = forms.field(ref), let annotations else { return }
                try forms.resize(ref, from: field.rect, to: annotations.resizedRect(field.rect, handle: handle, to: current))
            }
        } catch {
            NSSound.beep()
        }
    }

    /// The outline of a field being made, moved or resized.
    private func drawFieldDraft() {
        let page: Int
        let rect: CGRect
        switch fieldGesture {
        case .none:
            return
        case let .create(p, start, current):
            page = p
            rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        case let .move(ref, start, current):
            guard let field = forms?.field(ref) else { return }
            page = ref.page
            rect = field.rect.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
        case let .resize(ref, handle, current):
            guard let field = forms?.field(ref), let annotations else { return }
            page = ref.page
            rect = annotations.resizedRect(field.rect, handle: handle, to: current)
        }
        pageView(page)?.setDraft(CGPath(rect: rect, transform: nil), color: .controlAccentColor, lineWidth: 1.5 / zoom,
                                 transform: model.pageToView(page: page, rotation: rotation), dashed: true)
    }

    /// The selected field's outline and grips.
    func applyFieldSelection(to view: PageView, page: Int) {
        guard let ref = selectedField, ref.page == page, let field = forms?.field(ref) else {
            view.setAnnotationSelection(outline: nil, handles: [], transform: .identity, zoom: zoom)
            return
        }
        view.setAnnotationSelection(outline: CGPath(rect: field.rect, transform: nil), handles: handles(field.rect).map(\.1),
                                    transform: model.pageToView(page: page, rotation: rotation), zoom: zoom)
    }

    func fieldCursor(at location: NSPoint) -> NSCursor {
        guard let forms, let (page, point) = pageAndPoint(at: location), layout.frames[page]?.contains(location) == true else {
            return .arrow
        }
        if fieldTool != .select { return .crosshair }
        if let ref = selectedField, ref.page == page, let field = model.cachedFields(page: page)?.first(where: { $0.id == ref.id }),
           handle(at: point, of: field) != nil {
            return .crosshair
        }
        return forms.hitAny(point, page: page, tolerance: tolerance, cachedOnly: true) != nil ? .openHand : .arrow
    }
}
