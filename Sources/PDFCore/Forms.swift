import CoreGraphics
import MuPDFBridge

/// A form field widget on a page. Several widgets can belong to one field
/// (a radio group's buttons, or the same field shown twice); each is listed.
public struct FormField: Equatable, Sendable {
    public enum Kind: Int, Sendable {
        case unknown = 0, button, checkbox, dropdown, listBox, radio, signature, text
    }

    /// A choice in a dropdown or list box: `value` is stored, `label` shown.
    public struct Option: Equatable, Sendable {
        public let value: String
        public let label: String
    }

    public let page: Int
    /// The widget's PDF object number.
    public let id: Int
    public let kind: Kind
    public let rect: CGRect
    /// The full name ("address.street").
    public let name: String
    public let tooltip: String
    /// The text, a dropdown's choice, or a checkbox or radio group's state
    /// ("Off" when off).
    public let value: String
    /// Checkbox and radio button: this widget's state when on, and whether it is.
    public let onState: String
    public let isOn: Bool
    public let flags: Int
    /// Text: the most characters it takes, or 0 for any number.
    public let maxLength: Int
    public let options: [Option]
    /// List box: the chosen options' values.
    public let selected: [String]
    public let isSigned: Bool
    /// Can't be filled in here (read-only in the file, a kind that isn't
    /// filled in, or over a limit).
    public let isReadOnly: Bool

    // Field flags (PDF 32000 12.7.3.1, 12.7.4).
    public var isRequired: Bool { flags & (1 << 1) != 0 }
    public var isMultiline: Bool { kind == .text && flags & (1 << 12) != 0 }
    public var isPassword: Bool { kind == .text && flags & (1 << 13) != 0 }
    public var isComb: Bool { kind == .text && flags & (1 << 24) != 0 }
    public var allowsTypedChoice: Bool { kind == .dropdown && flags & (1 << 18) != 0 }
    public var isMultiSelect: Bool { kind == .listBox && flags & (1 << 21) != 0 }

    init(page: Int, _ f: opdf_field) {
        func string(_ p: UnsafeMutablePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }
        func strings(_ p: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ n: Int32) -> [String] {
            UnsafeBufferPointer(start: p, count: p == nil ? 0 : Int(n)).map(string)
        }
        self.page = page
        id = Int(f.id)
        kind = Kind(rawValue: Int(f.type)) ?? .unknown
        rect = CGRect(f.rect)
        name = string(f.name)
        tooltip = string(f.tooltip)
        value = string(f.value)
        onState = string(f.on_state)
        isOn = f.is_on
        flags = Int(f.flags)
        maxLength = Int(f.max_length)
        options = zip(strings(f.option_values, f.option_count), strings(f.option_labels, f.option_count))
            .map { Option(value: $0, label: $1) }
        selected = strings(f.selected, f.selected_count)
        isSigned = f.is_signed
        isReadOnly = f.read_only
    }
}

/// What a document's form holds.
public struct FormInfo: Equatable, Sendable {
    public let hasFields: Bool
    /// XFA data, which other apps may show instead of the fields.
    public let hasXFA: Bool
    /// A signature field has been signed.
    public let isSigned: Bool
}

extension EngineDocument {
    public func formInfo() throws -> FormInfo {
        var info = opdf_form_info()
        var error = opdf_error()
        guard opdf_form_get_info(handle, &info, &error) else { throw EngineError(error) }
        return FormInfo(hasFields: info.has_fields, hasXFA: info.has_xfa, isSigned: info.is_signed)
    }

    public func fields(page: Int) throws -> [FormField] {
        var count: Int32 = 0
        var error = opdf_error()
        let items = opdf_fields_load(handle, Int32(page), &count, &error)
        if items == nil && error.code != 0 { throw EngineError(error) }
        defer { opdf_fields_free(items, count) }
        return UnsafeBufferPointer(start: items, count: Int(count)).map { FormField(page: page, $0) }
    }

    /// Fills in a text field, or chooses a dropdown's option (by value).
    public func setText(_ text: String, page: Int, field id: Int) throws {
        var error = opdf_error()
        guard opdf_field_set_text(handle, Int32(page), Int32(id), text, &error) else { throw EngineError(error) }
    }

    /// Chooses a list box's options (by value); none clears it.
    public func setChoices(_ values: [String], page: Int, field id: Int) throws {
        var error = opdf_error()
        let copies = values.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { UnsafePointer<CChar>($0) }
        let ok = pointers.withUnsafeBufferPointer {
            opdf_field_set_choices(handle, Int32(page), Int32(id), $0.baseAddress, Int32($0.count), &error)
        }
        guard ok else { throw EngineError(error) }
    }

    /// Turns a checkbox or radio button on, or a checkbox off.
    public func toggle(page: Int, field id: Int) throws {
        var error = opdf_error()
        guard opdf_field_toggle(handle, Int32(page), Int32(id), &error) else { throw EngineError(error) }
    }
}
