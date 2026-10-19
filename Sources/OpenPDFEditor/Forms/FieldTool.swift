import AppKit
import PDFCore

/// The tools in the field bar, shown while editing a form's fields.
enum FieldTool: String, CaseIterable {
    case select, text, checkbox, radio, dropdown, listBox, signature

    var title: String {
        switch self {
        case .select: "Select"
        case .text: "Text Field"
        case .checkbox: "Checkbox"
        case .radio: "Radio Button"
        case .dropdown: "Dropdown"
        case .listBox: "List Box"
        case .signature: "Signature Field"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "character.textbox"
        case .checkbox: "checkmark.square"
        case .radio: "smallcircle.filled.circle"
        case .dropdown: "chevron.down.square"
        case .listBox: "list.bullet.rectangle"
        case .signature: "signature"
        }
    }

    var kind: FormField.Kind {
        switch self {
        case .select: .unknown
        case .text: .text
        case .checkbox: .checkbox
        case .radio: .radio
        case .dropdown: .dropdown
        case .listBox: .listBox
        case .signature: .signature
        }
    }

    /// The size a field is made at when clicked rather than dragged out (points).
    var defaultSize: CGSize {
        switch self {
        case .checkbox, .radio: CGSize(width: 14, height: 14)
        case .listBox: CGSize(width: 140, height: 60)
        case .signature: CGSize(width: 180, height: 50)
        default: CGSize(width: 160, height: 22)
        }
    }
}

extension FormField.Kind {
    var title: String {
        switch self {
        case .text: "Text Field"
        case .checkbox: "Checkbox"
        case .radio: "Radio Button"
        case .dropdown: "Dropdown"
        case .listBox: "List Box"
        case .signature: "Signature Field"
        case .button: "Button"
        case .unknown: "Field"
        }
    }
}
