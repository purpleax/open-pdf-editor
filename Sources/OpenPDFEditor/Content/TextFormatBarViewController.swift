import AppKit
import PDFCore

/// The formatting controls in the content bar while a paragraph is being
/// edited: font family, size, bold, italic, underline, colour and alignment,
/// applied to the selection (or to what's typed next).
@MainActor
final class TextFormatBarViewController: NSViewController {
    private let family = NSPopUpButton(frame: .zero, pullsDown: false)
    private let size = NSComboBox()
    private let styles = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let alignment = NSSegmentedControl()
    private static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48, 72]
    private static let alignments: [NSTextAlignment] = [.left, .center, .right, .justified]

    /// The paragraph being edited; the controls are off without one.
    var editor: ParagraphEditor? {
        didSet {
            oldValue?.onSelectionChange = nil
            editor?.onSelectionChange = { [weak self] in self?.reload() }
            reload()
        }
    }

    override func loadView() {
        family.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        family.target = self
        family.action = #selector(familyChosen(_:))
        family.controlSize = .small
        family.toolTip = "Font"
        family.widthAnchor.constraint(equalToConstant: 120).isActive = true
        size.addItems(withObjectValues: Self.sizes.map { "\(Int($0))" })
        size.target = self
        size.action = #selector(sizeChosen(_:))
        size.controlSize = .small
        size.numberOfVisibleItems = 14
        size.toolTip = "Size"
        size.widthAnchor.constraint(equalToConstant: 56).isActive = true
        styles.segmentCount = 3
        styles.trackingMode = .selectAny
        for (i, (symbol, tip)) in [("bold", "Bold"), ("italic", "Italic"), ("underline", "Underline")].enumerated() {
            styles.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            styles.setToolTip(tip, forSegment: i)
            styles.setWidth(24, forSegment: i)
        }
        styles.target = self
        styles.action = #selector(styleClicked(_:))
        styles.controlSize = .small
        colorWell.target = self
        colorWell.action = #selector(colorChosen(_:))
        colorWell.toolTip = "Text colour"
        alignment.segmentCount = 4
        alignment.trackingMode = .selectOne
        for (i, (symbol, tip)) in [("text.alignleft", "Align Left"), ("text.aligncenter", "Center"), ("text.alignright", "Align Right"),
                                   ("text.justify", "Justify")].enumerated() {
            alignment.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: i)
            alignment.setToolTip(tip, forSegment: i)
            alignment.setWidth(24, forSegment: i)
        }
        alignment.target = self
        alignment.action = #selector(alignmentClicked(_:))
        alignment.controlSize = .small
        let stack = NSStackView(views: [family, size, styles, colorWell, alignment])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setAccessibilityLabel("Text format")
        view = stack
        reload()
    }

    private func reload() {
        guard isViewLoaded else { return }
        let enabled = editor != nil
        for control in [family, size, styles, colorWell, alignment] as [NSControl] { control.isEnabled = enabled }
        guard let editor else { return }
        let attributes = editor.currentAttributes
        if let font = attributes[.font] as? NSFont {
            // A family the Mac doesn't list (Times, say) is shown on its own, at the top.
            if let extra = family.item(at: 0), extra.tag == 1 { family.removeItem(at: 0) }
            let name = font.familyName ?? font.fontName
            if family.item(withTitle: name) == nil {
                family.insertItem(withTitle: name, at: 0)
                family.item(at: 0)?.tag = 1
            }
            family.selectItem(withTitle: name)
            size.stringValue = String(format: "%g", (font.pointSize * 10).rounded() / 10)
            let traits = NSFontManager.shared.traits(of: font)
            styles.setSelected(traits.contains(.boldFontMask), forSegment: 0)
            styles.setSelected(traits.contains(.italicFontMask), forSegment: 1)
        }
        styles.setSelected(((attributes[.underlineStyle] as? Int) ?? 0) != 0, forSegment: 2)
        colorWell.color = (attributes[.foregroundColor] as? NSColor) ?? .black
        let current = (attributes[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .left
        alignment.selectedSegment = Self.alignments.firstIndex(of: current) ?? 0
    }

    private func changeFonts(_ convert: @escaping (NSFont) -> NSFont) {
        editor?.change { attributes in
            if let font = attributes[.font] as? NSFont { attributes[.font] = convert(font) }
        }
        editor?.textView.window?.makeFirstResponder(editor?.textView)
    }

    @objc private func familyChosen(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        changeFonts { NSFontManager.shared.convert($0, toFamily: name) }
    }

    @objc private func sizeChosen(_ sender: NSComboBox) {
        let value = CGFloat(sender.doubleValue)
        guard value >= 1, value <= 500 else { return reload() }
        changeFonts { NSFontManager.shared.convert($0, toSize: value) }
    }

    @objc private func styleClicked(_ sender: NSSegmentedControl) {
        let on = sender.isSelected(forSegment: sender.selectedSegment)
        switch sender.selectedSegment {
        case 0:
            changeFonts { on ? NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) : NSFontManager.shared.convert($0, toNotHaveTrait: .boldFontMask) }
        case 1:
            changeFonts { on ? NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) : NSFontManager.shared.convert($0, toNotHaveTrait: .italicFontMask) }
        default:
            editor?.change { $0[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil }
            editor?.textView.window?.makeFirstResponder(editor?.textView)
        }
    }

    @objc private func colorChosen(_ sender: NSColorWell) {
        let color = sender.color
        editor?.change { $0[.foregroundColor] = color }
    }

    @objc private func alignmentClicked(_ sender: NSSegmentedControl) {
        editor?.setAlignment(Self.alignments[max(0, sender.selectedSegment)])
        editor?.textView.window?.makeFirstResponder(editor?.textView)
    }
}

#if SELFTEST
extension TextFormatBarViewController {
    /// Bold, as the B button does.
    func debugBold() {
        styles.setSelected(true, forSegment: 0)
        styles.selectedSegment = 0
        styleClicked(styles)
    }
    var debugBoldShown: Bool { styles.isSelected(forSegment: 0) }
    var debugFamily: String { "\(family.titleOfSelectedItem ?? "none") / font \((editor?.currentAttributes[.font] as? NSFont)?.familyName ?? "nil")" }
}
#endif
