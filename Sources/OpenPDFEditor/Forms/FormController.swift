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
    /// then the order of each page's fields; wraps around.
    func neighbour(of ref: FieldRef, forward: Bool) -> FormField? {
        let count = model.pageCount
        guard count > 0 else { return nil }
        var page = ref.page
        var current: Int? = ref.id
        for _ in 0...count {
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
