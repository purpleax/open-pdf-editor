import AppKit
import PDFCore

/// Mouse handling while editing page content: selecting, moving and
/// resizing what Edit Content changes, and making links with the Link tool.
extension PagesView {
    private func contentHandle(at point: CGPoint, of rect: CGRect) -> AnnotationHandle? {
        rectHandles(rect).first { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance }?.0
    }

    func contentMouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let content, model.allows(.edit), let (page, point) = pageAndPoint(at: location),
              layout.frames[page]?.contains(location) == true else {
            selectedContent = nil
            return
        }
        if contentTool == .text {
            selectedContent = nil
            guard let paragraph = content.paragraph(at: point, page: page) else { return }
            beginParagraphEdit(paragraph, at: point)
            return
        }
        if contentTool == .link || contentTool == .image {
            contentGesture = .create(page: page, start: point, current: point)
            return
        }
        if let ref = selectedContent, ref.page == page, let item = content.item(ref), let handle = contentHandle(at: point, of: item.rect) {
            contentGesture = .resize(ref, handle, current: point)
            return
        }
        if let item = content.hit(point, page: page, tolerance: tolerance) {
            selectedContent = item.ref
            contentGesture = .move(item.ref, start: point, current: point)
            return
        }
        selectedContent = nil
    }

    func contentMouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        switch contentGesture {
        case .none:
            return
        case let .create(page, start, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: page) else { return }
            contentGesture = .create(page: page, start: start, current: point)
        case let .move(ref, start, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: ref.page) else { return }
            contentGesture = .move(ref, start: start, current: point)
        case let .resize(ref, handle, _):
            autoscroll(with: event)
            guard let point = clampedPoint(location, page: ref.page) else { return }
            contentGesture = .resize(ref, handle, current: point)
        }
        drawContentDraft()
    }

    func contentMouseUp(with event: NSEvent) {
        let finished = contentGesture
        contentGesture = .none
        clearDrafts()
        guard let content else { return }
        do {
            switch finished {
            case .none:
                break
            case let .create(page, start, current):
                let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                                  width: abs(current.x - start.x), height: abs(current.y - start.y))
                let sized = rect.width * zoom >= 6 && rect.height * zoom >= 6
                if contentTool == .image {
                    // A click places the image at its own proportions.
                    delegate?.pagesView(self, makeImageIn: sized ? rect : CGRect(origin: start, size: .zero), onPage: page)
                } else if sized {
                    delegate?.pagesView(self, makeLinkIn: rect, onPage: page)
                }
            case let .move(ref, start, current):
                guard hypot(current.x - start.x, current.y - start.y) * zoom >= 2, let item = content.item(ref) else { return }
                try content.setRect(ref, item.rect.offsetBy(dx: current.x - start.x, dy: current.y - start.y), actionName: "Move \(ref.noun)")
            case let .resize(ref, handle, current):
                guard let item = content.item(ref), let annotations else { return }
                var rect = annotations.resizedRect(item.rect, handle: handle, to: current)
                // Shift keeps an image's proportions.
                if case .image = ref, event.modifierFlags.contains(.shift), item.rect.height > 0 {
                    let aspect = item.rect.width / item.rect.height
                    if [.top, .bottom].contains(handle) { rect.size.width = rect.height * aspect } else { rect.size.height = rect.width / aspect }
                    if [.topLeft, .topRight, .top].contains(handle) { rect.origin.y = item.rect.maxY - rect.height }
                    if [.topLeft, .bottomLeft, .left].contains(handle) { rect.origin.x = item.rect.maxX - rect.width }
                }
                try content.setRect(ref, rect, actionName: "Resize \(ref.noun)")
            }
        } catch {
            NSSound.beep()
        }
    }

    private func drawContentDraft() {
        let page: Int
        let rect: CGRect
        switch contentGesture {
        case .none:
            return
        case let .create(p, start, current):
            page = p
            rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        case let .move(ref, start, current):
            guard let item = content?.item(ref) else { return }
            page = ref.page
            rect = item.rect.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
        case let .resize(ref, handle, current):
            guard let item = content?.item(ref), let annotations else { return }
            page = ref.page
            rect = annotations.resizedRect(item.rect, handle: handle, to: current)
        }
        pageView(page)?.setDraft(CGPath(rect: rect, transform: nil), color: .controlAccentColor, lineWidth: 1.5 / zoom,
                                 transform: model.pageToView(page: page, rotation: rotation), dashed: true)
    }

    /// The selected item's outline and grips (text runs aren't moved, so have none).
    func applyContentSelection(to view: PageView, page: Int) {
        guard let ref = selectedContent, ref.page == page, let item = content?.item(ref) else {
            view.setAnnotationSelection(outline: nil, handles: [], transform: .identity, zoom: zoom)
            return
        }
        var handles = rectHandles(item.rect).map(\.1)
        if case .text = ref { handles = [] }
        view.setAnnotationSelection(outline: CGPath(rect: item.rect.insetBy(dx: -1, dy: -1), transform: nil), handles: handles,
                                    transform: model.pageToView(page: page, rotation: rotation), zoom: zoom)
    }

    /// Edits the paragraph of the selected text run (the inspector's Edit
    /// Text, Return).
    func beginTextEdit() {
        guard let ref = selectedContent, case .text = ref, let content, let item = content.item(ref),
              let paragraph = content.paragraph(at: CGPoint(x: item.rect.midX, y: item.rect.midY), page: ref.page) else { return }
        beginParagraphEdit(paragraph, at: nil)
    }

    /// Edits a paragraph in place, with the caret at the point (page space),
    /// or at its end.
    func beginParagraphEdit(_ paragraph: Paragraph, at point: CGPoint?) {
        textEditor?.finish()
        guard let content, model.allows(.edit) else { return }
        if let reason = ContentController.restriction(paragraph) {
            delegate?.pagesView(self, contentProblem: reason)
            return
        }
        guard rotation == 0, let toView = transform(forPage: paragraph.page) else {
            delegate?.pagesView(self, contentProblem: "Turn the view back upright (View › Rotate) to edit text.")
            return
        }
        let editor = content.editor(for: paragraph, toView: toView)
        editor.onEnd = { [weak self] editor, commit in
            guard let self else { return editor.remove() }
            if self.textEditor === editor { self.textEditor = nil }
            if self.window?.firstResponder === editor.textView { self.window?.makeFirstResponder(self) }
            var changed = false
            if commit {
                do {
                    changed = try content.commit(editor)
                } catch {
                    self.delegate?.pagesView(self, contentProblem: "\(error)")
                }
            }
            // Kept up until the page has been drawn again, so nothing flickers.
            if changed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { editor.remove() }
            } else {
                editor.remove()
            }
        }
        textEditor = editor
        editor.show(in: self, caretAt: point)
    }

    func contentCursor(at location: NSPoint) -> NSCursor {
        guard let content, let (page, point) = pageAndPoint(at: location), layout.frames[page]?.contains(location) == true else {
            return .arrow
        }
        if contentTool == .text { return content.paragraph(at: point, page: page) != nil ? .iBeam : .arrow }
        if contentTool != .select { return .crosshair }
        if let ref = selectedContent, ref.page == page, let item = content.item(ref), contentHandle(at: point, of: item.rect) != nil {
            return .crosshair
        }
        return content.hit(point, page: page, tolerance: tolerance) != nil ? .openHand : .arrow
    }
}
