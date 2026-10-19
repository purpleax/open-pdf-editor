import AppKit
import PDFCore

/// A form field widget on a page.
struct FieldRef: Hashable {
    let page: Int
    let id: Int
}

/// Finds and fills in form fields. Every change goes through
/// `DocumentModel.edit`, so it is one undoable step and the pages are
/// redrawn: every page, since a field's other widgets (a radio group, the
/// same field shown twice) may be on any of them.
@MainActor
final class FormController {
    let model: DocumentModel
    private var loading = Set<Int>()

    init(model: DocumentModel) {
        self.model = model
    }

    func field(_ ref: FieldRef) -> FormField? {
        model.fields(page: ref.page).first { $0.id == ref.id }
    }

    /// Fields this app fills in: text, checkboxes, radio buttons, dropdowns
    /// and list boxes the file doesn't make read-only.
    static func isFillable(_ field: FormField) -> Bool {
        guard !field.isReadOnly else { return false }
        switch field.kind {
        case .text, .checkbox, .radio, .dropdown, .listBox: return true
        default: return false
        }
    }

    /// Fields filled in by typing: text, and dropdowns that take typed choices.
    static func isTyped(_ field: FormField) -> Bool {
        field.kind == .text || field.allowsTypedChoice
    }

    /// The topmost fillable field at a point in page space. With
    /// `cachedOnly` (the cursor, as the mouse moves) nothing is loaded; the
    /// page's fields are fetched in the background instead.
    func hit(_ point: CGPoint, page: Int, cachedOnly: Bool = false) -> FormField? {
        let fields: [FormField]
        if cachedOnly {
            guard let cached = model.cachedFields(page: page) else {
                if !loading.contains(page) {
                    loading.insert(page)
                    let model = self.model
                    EngineExecutor.background.async(.low) { [weak self] in
                        _ = model.fields(page: page)
                        DispatchQueue.main.async { self?.loading.remove(page) }
                    }
                }
                return nil
            }
            fields = cached
        } else {
            fields = model.fields(page: page)
        }
        return fields.last { Self.isFillable($0) && $0.rect.contains(point) }
    }

    /// The field typed into after (or before) this one, in page order and
    /// then the order of each page's fields; wraps around. Looks at most 20
    /// pages on (fields load on the main thread).
    func neighbour(of ref: FieldRef, forward: Bool) -> FormField? {
        let count = model.pageCount
        guard count > 0 else { return nil }
        var page = ref.page
        var current: Int? = ref.id
        for _ in 0...min(count, 20) {
            let fields = model.fields(page: page).filter { Self.isFillable($0) && Self.isTyped($0) }
            let ordered = forward ? fields : fields.reversed()
            if let id = current {
                if let index = ordered.firstIndex(where: { $0.id == id }), index + 1 < ordered.count {
                    return ordered[index + 1]
                }
            } else if let first = ordered.first {
                return first
            }
            current = nil
            page = (page + (forward ? 1 : count - 1)) % count
        }
        return nil
    }

    private var allPages: Set<Int> { Set(0..<model.pageCount) }

    // MARK: Editing fields

    /// The topmost field of any kind at a point, for editing the form.
    func hitAny(_ point: CGPoint, page: Int, tolerance: CGFloat, cachedOnly: Bool = false) -> FormField? {
        let fields = cachedOnly ? model.cachedFields(page: page) ?? [] : model.fields(page: page)
        return fields.last { $0.id != 0 && $0.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) }
    }

    /// Makes a field; a radio button joins the group of `group` (a radio
    /// button) if given.
    func create(_ tool: FieldTool, page: Int, rect: CGRect, joining group: FieldRef? = nil) throws -> FieldRef {
        let bounds = model.pageBounds[page]
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        let joined = group.flatMap { $0.page == page ? $0.id : nil }
        let id = try model.edit("New \(tool.title)", pages: allPages) { try $0.createField(tool.kind, page: page, rect: r, joining: joined) }
        return FieldRef(page: page, id: id)
    }

    func update(_ ref: FieldRef, actionName: String, _ change: FieldChange) throws {
        try model.edit(actionName, pages: allPages) { try $0.updateField(page: ref.page, id: ref.id, change) }
    }

    func move(_ ref: FieldRef, by offset: CGVector) throws {
        try model.edit("Move Field", pages: [ref.page]) {
            try $0.transformField(page: ref.page, id: ref.id, by: CGAffineTransform(translationX: offset.dx, y: offset.dy))
        }
    }

    /// Resizes a field's widget from `old` to `new` (page space).
    func resize(_ ref: FieldRef, from old: CGRect, to new: CGRect) throws {
        guard old.width > 0, old.height > 0 else { return }
        let sx = new.width / old.width, sy = new.height / old.height
        let t = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: new.minX - old.minX * sx, ty: new.minY - old.minY * sy)
        try model.edit("Resize Field", pages: [ref.page]) { try $0.transformField(page: ref.page, id: ref.id, by: t) }
    }

    func delete(_ ref: FieldRef) throws {
        try model.edit("Delete Field", pages: allPages) { try $0.deleteField(page: ref.page, id: ref.id) }
    }

    func setText(_ ref: FieldRef, _ text: String) throws {
        try model.edit("Fill In Field", pages: allPages) { try $0.setText(text, page: ref.page, field: ref.id) }
    }

    func setChoices(_ ref: FieldRef, _ values: [String]) throws {
        try model.edit("Fill In Field", pages: allPages) { try $0.setChoices(values, page: ref.page, field: ref.id) }
    }

    func toggle(_ ref: FieldRef) throws {
        try model.edit("Fill In Field", pages: allPages) { try $0.toggle(page: ref.page, field: ref.id) }
    }
}
