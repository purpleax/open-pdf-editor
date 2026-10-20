import AppKit
import PDFCore

/// The tools in the markup bar.
enum AnnotationTool: String, CaseIterable {
    case select, highlight, underline, strikeOut, note, textBox, rectangle, oval, line, arrow, pen, stamp, signature, redact

    var title: String {
        switch self {
        case .select: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .note: "Note"
        case .textBox: "Text Box"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .pen: "Draw"
        case .stamp: "Stamp"
        case .signature: "Signature"
        case .redact: "Redact"
        }
    }

    var symbol: String {
        switch self {
        case .select: "character.cursor.ibeam"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .textBox: "character.textbox"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "scribble.variable"
        case .stamp: "seal"
        case .signature: "signature"
        case .redact: "eye.slash"
        }
    }

    var kind: Annotation.Kind {
        switch self {
        case .select: .unknown
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        case .note: .text
        case .textBox: .freeText
        case .rectangle: .square
        case .oval: .circle
        case .line, .arrow: .line
        case .pen: .ink
        case .stamp, .signature: .stamp
        case .redact: .redact
        }
    }

    /// Tools that work on selected text.
    var marksText: Bool { [.highlight, .underline, .strikeOut].contains(self) }
    /// Tools drawn by dragging out a shape.
    var drawsShape: Bool { [.textBox, .rectangle, .oval, .line, .arrow, .pen].contains(self) }
    /// Tools that stay chosen after use; the others go back to Select.
    var staysActive: Bool { marksText || self == .pen || self == .redact }
    var usesLineWidth: Bool { [.rectangle, .oval, .line, .arrow, .pen].contains(self) }
    var usesColor: Bool { ![.select, .stamp, .signature, .redact].contains(self) }

    var defaultColor: PDFColor {
        switch self {
        case .highlight, .note: .yellow
        case .underline: .green
        case .strikeOut, .rectangle, .oval, .line, .arrow, .redact: .red
        case .pen: .blue
        case .textBox, .select, .stamp, .signature: .black
        }
    }

    /// The tool's menu key equivalent in Tools ▸ (with ⌃⌘).
    var keyEquivalent: String {
        switch self {
        case .select: "1"
        case .highlight: "h"
        case .underline: "u"
        case .strikeOut: "k"
        case .note: "n"
        case .textBox: "t"
        case .rectangle: "r"
        case .oval: "o"
        case .line: "l"
        case .arrow: "a"
        case .pen: "d"
        case .stamp: "m"
        case .signature: "g"
        case .redact: "x"
        }
    }
}

/// The standard stamps MuPDF draws (names as PDF has them).
enum StandardStamp: String, CaseIterable {
    case approved = "Approved", notApproved = "NotApproved", draft = "Draft", final = "Final",
         confidential = "Confidential", forComment = "ForComment", forPublicRelease = "ForPublicRelease",
         notForPublicRelease = "NotForPublicRelease", asIs = "AsIs", departmental = "Departmental",
         experimental = "Experimental", expired = "Expired", sold = "Sold", topSecret = "TopSecret"

    var title: String {
        // "NotForPublicRelease" -> "Not For Public Release"
        rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

/// Each tool's colour and line width, and the chosen stamp, remembered
/// between launches.
@MainActor
enum ToolSettings {
    private static let defaults = UserDefaults.standard

    static func color(for tool: AnnotationTool) -> PDFColor {
        guard let parts = defaults.string(forKey: "ToolColor.\(tool.rawValue)")?.split(separator: ",").compactMap({ Double($0) }),
              parts.count == 3 else { return tool.defaultColor }
        return PDFColor(red: parts[0], green: parts[1], blue: parts[2])
    }

    static func setColor(_ color: PDFColor, for tool: AnnotationTool) {
        defaults.set("\(color.red),\(color.green),\(color.blue)", forKey: "ToolColor.\(tool.rawValue)")
    }

    static func lineWidth(for tool: AnnotationTool) -> CGFloat {
        let value = defaults.double(forKey: "ToolWidth.\(tool.rawValue)")
        return value > 0 ? value : 2
    }

    static func setLineWidth(_ width: CGFloat, for tool: AnnotationTool) {
        defaults.set(Double(width), forKey: "ToolWidth.\(tool.rawValue)")
    }

    static var stamp: StandardStamp {
        get { defaults.string(forKey: "Stamp").flatMap(StandardStamp.init) ?? .approved }
        set { defaults.set(newValue.rawValue, forKey: "Stamp") }
    }

    static var textSize: CGFloat {
        get { let v = defaults.double(forKey: "TextBoxSize"); return v > 0 ? v : 12 }
        set { defaults.set(Double(newValue), forKey: "TextBoxSize") }
    }

    /// Set only by the self-test, so screenshots show a made-up author.
    static var authorOverride: String?

    /// The author written into new annotations.
    static var author: String {
        if let authorOverride { return authorOverride }
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }
}

extension PDFColor {
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}
