import AppKit
import PDFCore

/// Filling in form fields with the Select tool: typing into text fields in
/// place, choosing from a menu for dropdowns and list boxes, and clicking
/// checkboxes and radio buttons.
extension PagesView {
    /// Fills in a field the way its kind is filled in.
    func fill(_ field: FormField) {
        guard let forms else { return }
        let ref = FieldRef(page: field.page, id: field.id)
        do {
            switch field.kind {
            case .checkbox, .radio:
                try forms.toggle(ref)
            case .dropdown where !field.allowsTypedChoice, .listBox:
                showChoices(for: field)
            default:
                beginTyping(in: field)
            }
        } catch {
            NSSound.beep()
        }
    }

    /// Lays a text control over the field and types into it.
    func beginTyping(in field: FormField) {
        fieldEditor?.finish()
        guard let frame = convert(field.rect, fromPage: field.page) else { return }
        scrollToVisible(frame.insetBy(dx: -20, dy: -20))
        let editor = FieldEditor(field: field, frame: frame)
        editor.onEnd = { [weak self, weak editor] ending, text in
            guard let self, let editor else { return }
            if self.fieldEditor === editor { self.fieldEditor = nil }
            if ending != .cancel, text != field.value {
                do { try self.forms?.setText(editor.ref, text) } catch { NSSound.beep() }
            }
            self.window?.makeFirstResponder(self)
            if ending == .next || ending == .previous,
               let next = self.forms?.neighbour(of: editor.ref, forward: ending == .next) {
                self.beginTyping(in: next)
            }
        }
        fieldEditor = editor
        editor.show(in: self)
    }

    /// A menu of a dropdown's or list box's options under the field. A list
    /// box that takes several choices adds or removes the one chosen.
    private func showChoices(for field: FormField) {
        guard let frame = convert(field.rect, fromPage: field.page) else { return }
        let ref = FieldRef(page: field.page, id: field.id)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let chosen = field.kind == .listBox ? Set(field.selected) : [field.value]
        for option in field.options {
            let item = menu.addItem(withTitle: option.label.isEmpty ? option.value : option.label,
                                    action: #selector(chooseFieldOption(_:)), keyEquivalent: "")
            item.target = self
            item.state = chosen.contains(option.value) ? .on : .off
            item.representedObject = FieldChoice(ref: ref, value: option.value)
        }
        if field.kind == .listBox, !field.selected.isEmpty {
            menu.addItem(.separator())
            let clear = menu.addItem(withTitle: "Clear Choice", action: #selector(chooseFieldOption(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = FieldChoice(ref: ref, value: nil)
        }
        guard menu.numberOfItems > 0 else { NSSound.beep(); return }
        menu.minimumWidth = frame.width * (enclosingScrollView?.magnification ?? 1)
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSPoint(x: frame.minX, y: frame.maxY), in: self)
    }

    @objc private func chooseFieldOption(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? FieldChoice, let forms, let field = forms.field(choice.ref) else { return }
        do {
            if field.kind == .dropdown {
                try forms.setText(choice.ref, choice.value ?? "")
            } else if let value = choice.value {
                var values = field.selected
                if field.isMultiSelect {
                    if let index = values.firstIndex(of: value) { values.remove(at: index) } else { values.append(value) }
                } else {
                    values = [value]
                }
                try forms.setChoices(choice.ref, values)
            } else {
                try forms.setChoices(choice.ref, [])
            }
        } catch {
            NSSound.beep()
        }
    }
}

/// A menu item's option: which field, and the value to choose (nil clears).
private final class FieldChoice: NSObject {
    let ref: FieldRef
    let value: String?
    init(ref: FieldRef, value: String?) {
        self.ref = ref
        self.value = value
    }
}
