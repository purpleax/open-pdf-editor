import AppKit
import PDFCore

extension NSAttributedString.Key {
    /// The page font (index into `PageParagraphs.fonts`) a character was drawn
    /// in; typing carries it on, and changing the font or style removes it.
    static let pdfFont = NSAttributedString.Key("OPDFFont")
    /// The fill components as drawn (grey, RGB or CMYK); removed when the
    /// colour changes.
    static let pdfFill = NSAttributedString.Key("OPDFFill")
}

/// The text view of a paragraph being edited: pastes text only, and Escape
/// ends editing without changes.
final class ParagraphTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Edits a paragraph of a page (or a new text box) in place, like a word
/// processor: a text view laid over it in page points, with the paragraph's
/// text in the Mac font that best matches each of its fonts, kerned so each
/// character takes the width it has in the PDF, so lines break where they did.
/// On commit, the lines from the first change on are taken out of the page
/// and drawn again from the text view's layout: characters still in a page
/// font in that font (by its own codes), others in the Mac font, embedded.
@MainActor
final class ParagraphEditor: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
    let page: Int
    /// nil for a new text box.
    let paragraph: Paragraph?
    let fonts: [ParagraphFont]
    let textView: ParagraphTextView
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container: NSTextContainer
    private let backdrop = NSView()
    /// The text as it was, to see what changed.
    private var original = NSAttributedString()
    /// Where each original line starts in the text.
    private var lineStarts: [Int] = []
    /// The text view's top-left in page space.
    private(set) var origin: CGPoint
    /// Page space to the pages view's coordinates (a translation: editing
    /// isn't offered while the view is rotated).
    private let toView: CGAffineTransform
    private let undo = UndoManager()
    /// A page font's codes and widths, from the engine.
    private let encode: ([Unicode.Scalar], String) -> [FontCode]
    /// Each page font's codes for characters asked about (nil: not in it).
    private var codes: [Int: [Unicode.Scalar: FontCode?]] = [:]
    private var ended = false
    /// Called once: true to commit, false to drop the changes.
    var onEnd: ((ParagraphEditor, Bool) -> Void)?
    /// The selection or its style changed (for the formatting bar).
    var onSelectionChange: (() -> Void)?
    /// The other paragraphs on the page (page space), to say when the box
    /// runs into one: text doesn't flow from paragraph to paragraph.
    var others: [CGRect] = []
    private let overlapLabel = NSTextField(labelWithString: "Overlaps other text")
    private let widthHandle = WidthHandle()

    /// What a new text box starts with.
    static var newTextAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        return [.font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12), .foregroundColor: NSColor.black,
                .paragraphStyle: style, .ligature: 0]
    }

    /// Editing a paragraph. `pageBounds` places a one-line paragraph's box.
    init(paragraph: Paragraph, fonts: [ParagraphFont], pageBounds: CGRect, toView: CGAffineTransform,
         encode: @escaping ([Unicode.Scalar], String) -> [FontCode]) {
        page = paragraph.page
        self.paragraph = paragraph
        self.fonts = fonts
        self.toView = toView
        self.encode = encode
        // The box: the paragraph's width; a single line may grow to the margins.
        let lines = paragraph.lines
        let size = paragraph.characters.map(\.size).max() ?? 12
        var left = lines.map(\.rect.minX).min() ?? paragraph.rect.minX
        var right = lines.map(\.rect.maxX).max() ?? paragraph.rect.maxX
        if lines.count == 1 {
            let margin = max(18, min(left - pageBounds.minX, pageBounds.maxX - right))
            switch paragraph.alignment {
            case .left, .justified: right = max(right, pageBounds.maxX - margin)
            case .right: left = min(left, pageBounds.minX + margin)
            case .center:
                let mid = (left + right) / 2, half = max((right - left) / 2, min(mid - pageBounds.minX, pageBounds.maxX - mid) - margin)
                left = mid - half
                right = mid + half
            }
        }
        container = NSTextContainer(size: CGSize(width: right - left + 1, height: .greatestFiniteMagnitude))
        origin = CGPoint(x: left, y: paragraph.rect.minY)
        textView = ParagraphTextView(frame: CGRect(x: 0, y: 0, width: container.size.width, height: paragraph.rect.height), textContainer: nil)
        super.init()
        let text = buildText(paragraph, size: size)
        configure(text: text)
        // The first baseline where the paragraph's is.
        layoutManager.ensureLayout(for: container)
        origin.y = (lines.first?.baseline ?? paragraph.rect.maxY) - firstBaseline()
        original = NSAttributedString(attributedString: text)
    }

    /// A new text box, its top-left at `point`, `width` wide (page space).
    init(page: Int, at point: CGPoint, width: CGFloat, attributes: [NSAttributedString.Key: Any], toView: CGAffineTransform,
         encode: @escaping ([Unicode.Scalar], String) -> [FontCode]) {
        self.page = page
        paragraph = nil
        fonts = []
        self.toView = toView
        self.encode = encode
        container = NSTextContainer(size: CGSize(width: max(width, 40), height: .greatestFiniteMagnitude))
        origin = point
        textView = ParagraphTextView(frame: CGRect(x: 0, y: 0, width: container.size.width, height: 20), textContainer: nil)
        super.init()
        configure(text: NSAttributedString(string: "", attributes: attributes))
        textView.typingAttributes = attributes
    }

    // MARK: Building

    /// The paragraph as attributed text: its lines joined (with a space, none
    /// after a hyphen, or a line separator where a line was ended on purpose).
    private func buildText(_ p: Paragraph, size: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.alignment = switch p.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        if p.lineSpacing > 0 {
            style.minimumLineHeight = p.lineSpacing
            style.maximumLineHeight = p.lineSpacing
        }
        let left = p.lines.map(\.rect.minX).min() ?? 0
        if let first = p.lines.first {
            let indent = first.rect.minX - left
            if p.lines.count > 1 {
                let rest = p.lines.dropFirst().map(\.rect.minX).min() ?? left
                style.firstLineHeadIndent = max(0, first.rect.minX - left)
                style.headIndent = max(0, rest - left)
            } else {
                style.firstLineHeadIndent = max(0, indent)
            }
        }
        var last: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style, .ligature: 0]
        for (i, line) in p.lines.enumerated() {
            lineStarts.append(text.length)
            for c in p.characters[line.range] {
                var attributes = last
                if let f = c.font {
                    let font = FontFile.match(fonts[f], size: c.size) as NSFont
                    attributes = [.font: font, .paragraphStyle: style, .ligature: 0, .pdfFont: f,
                                  .foregroundColor: c.color.map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } ?? NSColor.black]
                    if !c.fill.isEmpty { attributes[.pdfFill] = c.fill }
                    last = attributes
                }
                text.append(NSAttributedString(string: String(c.scalar), attributes: attributes))
            }
            guard i < p.lines.count - 1 else { continue }
            let end = p.characters[line.range].last?.scalar
            if line.hardBreak {
                text.append(NSAttributedString(string: "\u{2028}", attributes: last))
            } else if end != " " && end != "-" && end != "\u{00AD}" {
                text.append(NSAttributedString(string: " ", attributes: last))
            }
        }
        return text
    }

    private func configure(text: NSAttributedString) {
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        storage.delegate = self
        storage.setAttributedString(text)
        textView.replaceTextContainer(container)
        textView.delegate = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = CGSize(width: container.size.width, height: 4)
        textView.maxSize = CGSize(width: container.size.width, height: .greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.focusRingType = .none
        textView.setAccessibilityLabel("Paragraph")
        textView.onCancel = { [weak self] in self?.end(commit: false) }
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeBackdrop() }
        }
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.white.cgColor
        backdrop.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        backdrop.layer?.borderWidth = 0.5
        applyKerning(in: NSRange(location: 0, length: storage.length))
        textView.sizeToFit()
    }

    private func firstBaseline() -> CGFloat {
        guard layoutManager.numberOfGlyphs > 0 else { return (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.ascender ?? 10 }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return fragment.minY + layoutManager.location(forGlyphAt: 0).y
    }

    // MARK: Showing

    func show(in view: NSView, caretAt point: CGPoint?) {
        let frame = CGRect(origin: origin, size: textView.frame.size).applying(toView)
        textView.frame.origin = frame.origin
        view.addSubview(backdrop)
        view.addSubview(textView)
        overlapLabel.font = .systemFont(ofSize: 10)
        overlapLabel.textColor = .systemOrange
        view.addSubview(overlapLabel)
        widthHandle.onDrag = { [weak self] dx in self?.setWidth((self?.container.size.width ?? 0) + dx) }
        view.addSubview(widthHandle)
        placeBackdrop()
        view.window?.makeFirstResponder(textView)
        if let point {
            let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
            var fraction: CGFloat = 0
            let index = layoutManager.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
            let caret = min(storage.length, index + (fraction > 0.5 ? 1 : 0))
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        }
    }

    /// The page colour under the text and over the paragraph it replaces;
    /// the width handle on its right; and a note when it runs into other text.
    private func placeBackdrop() {
        var area = textView.frame
        if let paragraph, let old = paragraph.rect.applying(toView) as CGRect? { area = area.union(old) }
        backdrop.frame = area.insetBy(dx: -2, dy: -2)
        widthHandle.frame = CGRect(x: textView.frame.maxX + 1, y: textView.frame.midY - 8, width: 6, height: 16)
        let box = CGRect(origin: origin, size: textView.frame.size).insetBy(dx: 1, dy: 1)
        let overlaps = others.contains { $0.insetBy(dx: 1, dy: 1).intersects(box) }
        overlapLabel.isHidden = !overlaps
        overlapLabel.sizeToFit()
        overlapLabel.frame.origin = CGPoint(x: textView.frame.minX, y: backdrop.frame.maxY + 1)
        backdrop.layer?.borderColor = (overlaps ? NSColor.systemOrange : NSColor.controlAccentColor.withAlphaComponent(0.6)).cgColor
        backdrop.layer?.borderWidth = overlaps ? 1 : 0.5
    }

    /// Re-wraps the text at another width (page points).
    func setWidth(_ width: CGFloat) {
        let w = max(20, min(width, 2000))
        container.size = CGSize(width: w, height: .greatestFiniteMagnitude)
        textView.minSize = CGSize(width: w, height: 4)
        textView.maxSize = CGSize(width: w, height: .greatestFiniteMagnitude)
        textView.setFrameSize(CGSize(width: w, height: textView.frame.height))
        textView.sizeToFit()
        placeBackdrop()
        // A changed width is a change, even with the same text.
        widthChanged = true
    }
    private var widthChanged = false

    func finish() { end(commit: true) }

    private func end(commit: Bool) {
        guard !ended else { return }
        ended = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: textView)
        onEnd?(self, commit)
        onEnd = nil
    }

    /// Takes the editor off the page (after the page shows the result).
    func remove() {
        textView.removeFromSuperview()
        backdrop.removeFromSuperview()
        overlapLabel.removeFromSuperview()
        widthHandle.removeFromSuperview()
    }

    // MARK: Kerning to the PDF's widths

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            guard editedMask.contains(.editedCharacters) || editedMask.contains(.editedAttributes) else { return }
            applyKerning(in: editedRange)
        }
    }

    /// Characters still in a page font get its width there: their kern is
    /// the PDF width less the Mac font's. A character given another font
    /// family, bold or italic (from the formatting bar, the Format menu or
    /// the Fonts panel) is no longer in its page font; one given another
    /// colour no longer has its fill as drawn.
    private func applyKerning(in range: NSRange) {
        normalize(in: range)
        let text = storage.string as NSString
        guard range.length > 0, NSMaxRange(range) <= text.length else { return }
        lookUp(charactersByFont(in: range))
        var i = range.location
        while i < NSMaxRange(range) {
            let composed = text.rangeOfComposedCharacterSequence(at: i)
            defer { i = NSMaxRange(composed) }
            guard let f = storage.attribute(.pdfFont, at: i, effectiveRange: nil) as? Int, f < fonts.count,
                  let font = storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont,
                  let scalar = text.substring(with: composed).unicodeScalars.first,
                  let pdf = width(of: scalar, inFont: f) else {
                storage.removeAttribute(.kern, range: composed)
                continue
            }
            var units = Array(text.substring(with: composed).utf16), glyphs = [CGGlyph](repeating: 0, count: units.count)
            var advance = CGSize.zero
            if CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) {
                CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
            }
            storage.addAttribute(.kern, value: pdf * font.pointSize - advance.width, range: composed)
        }
    }

    private var matched: [String: NSFont] = [:]

    private func normalize(in range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.enumerateAttributes(in: range) { attributes, sub, _ in
            if let f = attributes[.pdfFont] as? Int, let font = attributes[.font] as? NSFont {
                let key = "\(f)"
                let match = matched[key] ?? {
                    let m = f < fonts.count ? FontFile.match(fonts[f], size: 12) as NSFont : font
                    matched[key] = m
                    return m
                }()
                let traits: NSFontTraitMask = [.boldFontMask, .italicFontMask]
                let have = NSFontManager.shared.traits(of: font).intersection(traits)
                let want = NSFontManager.shared.traits(of: match).intersection(traits)
                if f >= fonts.count || font.familyName != match.familyName || have != want {
                    storage.removeAttribute(.pdfFont, range: sub)
                }
            }
            if let fill = attributes[.pdfFill] as? [CGFloat] {
                let drawn = Self.color(fill)
                let shown = ((attributes[.foregroundColor] as? NSColor) ?? .black).usingColorSpace(.sRGB)
                if let shown, let drawn,
                   abs(shown.redComponent - drawn.redComponent) + abs(shown.greenComponent - drawn.greenComponent) + abs(shown.blueComponent - drawn.blueComponent) > 0.01 {
                    storage.removeAttribute(.pdfFill, range: sub)
                }
            }
        }
    }

    static func color(_ fill: [CGFloat]) -> NSColor? {
        switch fill.count {
        case 1: NSColor(srgbRed: fill[0], green: fill[0], blue: fill[0], alpha: 1)
        case 3: NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: 1)
        case 4: NSColor(srgbRed: (1 - fill[0]) * (1 - fill[3]), green: (1 - fill[1]) * (1 - fill[3]), blue: (1 - fill[2]) * (1 - fill[3]), alpha: 1)
        default: nil
        }
    }

    // MARK: Formatting

    /// The style at the caret, or at the start of the selection.
    var currentAttributes: [NSAttributedString.Key: Any] {
        let range = textView.selectedRange()
        if range.length == 0 || storage.length == 0 { return textView.typingAttributes }
        return storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
    }

    /// Changes the selection's attributes (or what typing will use, with no
    /// selection), as one step of the editor's undo.
    func change(_ body: (inout [NSAttributedString.Key: Any]) -> Void) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var typing = textView.typingAttributes
            body(&typing)
            textView.typingAttributes = typing
            onSelectionChange?()
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, sub, _ in
            var changed = attributes
            body(&changed)
            storage.setAttributes(changed, range: sub)
        }
        storage.endEditing()
        textView.didChangeText()
        onSelectionChange?()
    }

    /// The paragraph's alignment (it's one paragraph: all of it).
    func setAlignment(_ alignment: NSTextAlignment) {
        let all = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: all, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: all) { value, sub, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: sub)
        }
        storage.endEditing()
        var typing = textView.typingAttributes
        let style = ((typing[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.alignment = alignment
        typing[.paragraphStyle] = style
        textView.typingAttributes = typing
        textView.didChangeText()
        onSelectionChange?()
    }

    nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated { onSelectionChange?() }
    }

    /// A character's code and width in a page font, if the font has it.
    private func code(of scalar: Unicode.Scalar, inFont f: Int) -> FontCode? {
        if let known = codes[f]?[scalar] { return known }
        lookUp([f: [scalar]])
        return codes[f]?[scalar] ?? nil
    }

    private func width(of scalar: Unicode.Scalar, inFont f: Int) -> CGFloat? { code(of: scalar, inFont: f)?.advance }

    /// Asks the engine once per font for the characters not known yet.
    private func lookUp(_ wanted: [Int: Set<Unicode.Scalar>]) {
        for (f, scalars) in wanted where f < fonts.count {
            let missing = Array(scalars.filter { codes[f]?[$0] == nil })
            guard !missing.isEmpty else { continue }
            let resource = fonts[f].resource
            let found = resource.isEmpty ? [] : encode(missing, resource)
            for (i, scalar) in missing.enumerated() {
                let code = i < found.count && found[i].exists ? found[i] : nil
                codes[f, default: [:]][scalar] = .some(code)
            }
        }
    }

    /// The characters of the text still in each page font.
    private func charactersByFont(in range: NSRange) -> [Int: Set<Unicode.Scalar>] {
        var wanted: [Int: Set<Unicode.Scalar>] = [:]
        let text = storage.string as NSString
        storage.enumerateAttribute(.pdfFont, in: range) { value, sub, _ in
            guard let f = value as? Int else { return }
            for scalar in text.substring(with: sub).unicodeScalars { wanted[f, default: []].insert(scalar) }
        }
        return wanted
    }

    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { undo }
    }

    // MARK: Committing

    /// What committing changes, or nil if nothing changed: the glyphs to take
    /// out and the text to draw.
    struct Change {
        var dropping: Set<Paragraph.Glyph>
        var fonts: [TextFont]
        var runs: [GlyphRun]
    }

    private static let compared: [NSAttributedString.Key] = [.font, .foregroundColor, .underlineStyle, .pdfFont, .pdfFill, .paragraphStyle]

    private func sameStyle(_ a: [NSAttributedString.Key: Any], _ b: [NSAttributedString.Key: Any]) -> Bool {
        for key in Self.compared {
            let x = a[key] as? NSObject, y = b[key] as? NSObject
            if x != y && !(x == nil && y == nil) { return false }
        }
        return true
    }

    /// The first place the text differs from the original (length if it doesn't).
    private func firstChange() -> Int {
        let old = original, new = storage
        let a = old.string as NSString, b = new.string as NSString
        let n = min(a.length, b.length)
        var i = 0
        while i < n {
            if a.character(at: i) != b.character(at: i) { return i }
            if !sameStyle(old.attributes(at: i, effectiveRange: nil), new.attributes(at: i, effectiveRange: nil)) { return i }
            i += 1
        }
        return a.length == b.length ? Int.max : n
    }

    func change(fontData: (CTFont) throws -> Data) throws -> Change? {
        let first = widthChanged ? 0 : firstChange()
        if paragraph != nil && first == Int.max { return nil }
        if paragraph == nil && storage.length == 0 { return nil }
        storage.fixAttributes(in: NSRange(location: 0, length: storage.length))
        layoutManager.ensureLayout(for: container)
        // The laid-out lines.
        var fragments: [NSRange] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &range)
            fragments.append(range)
            glyphIndex = NSMaxRange(range)
        }
        // Original lines before the first change stay as they are, when the
        // layout still breaks them in the same places.
        var keep = 0
        if let paragraph {
            for i in 0..<min(paragraph.lines.count, fragments.count) {
                let start = lineStarts[i], end = i + 1 < lineStarts.count ? lineStarts[i + 1] : storage.length
                guard end <= first else { break }
                let chars = layoutManager.characterRange(forGlyphRange: fragments[i], actualGlyphRange: nil)
                guard chars.location == start, NSMaxRange(chars) == end else { break }
                keep = i + 1
            }
        }
        var dropping = Set<Paragraph.Glyph>()
        if let paragraph {
            for line in paragraph.lines.dropFirst(keep) {
                for c in paragraph.characters[line.range] { if let g = c.glyph { dropping.insert(g) } }
            }
        }
        // The runs, from the layout of the lines that change.
        var fontList: [TextFont] = [], fontIndex: [String: Int] = [:], runs: [GlyphRun] = []
        let text = storage.string as NSString
        lookUp(charactersByFont(in: NSRange(location: 0, length: storage.length)))
        func index(_ key: String, _ make: () throws -> TextFont) rethrows -> Int {
            if let i = fontIndex[key] { return i }
            fontList.append(try make())
            fontIndex[key] = fontList.count - 1
            return fontList.count - 1
        }
        for fragment in fragments.dropFirst(keep) {
            var run: GlyphRun?
            for g in fragment.location..<NSMaxRange(fragment) {
                let property = layoutManager.propertyForGlyph(at: g)
                if property.contains(.null) || property.contains(.controlCharacter) { continue }
                let ci = layoutManager.characterIndexForGlyph(at: g)
                guard ci < text.length, let scalar = text.substring(with: text.rangeOfComposedCharacterSequence(at: ci)).unicodeScalars.first,
                      scalar != "\u{2028}", scalar != "\n" else { continue }
                let attributes = storage.attributes(at: ci, effectiveRange: nil)
                guard let font = attributes[.font] as? NSFont else { continue }
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let location = layoutManager.location(forGlyphAt: g)
                let x = origin.x + lineRect.minX + location.x, baseline = origin.y + lineRect.minY + location.y
                let size = font.pointSize
                let underline = ((attributes[.underlineStyle] as? Int) ?? 0) != 0
                let fill: [CGFloat] = (attributes[.pdfFill] as? [CGFloat]) ?? {
                    let c = ((attributes[.foregroundColor] as? NSColor) ?? .black).usingColorSpace(.sRGB) ?? .black
                    return [c.redComponent, c.greenComponent, c.blueComponent]
                }()
                // In the page font, if the character is still in it and the font has it.
                var glyph: GlyphRun.Glyph?, fontNumber = 0
                if let f = attributes[.pdfFont] as? Int, f < fonts.count, !fonts[f].resource.isEmpty {
                    if let code = code(of: scalar, inFont: f), code.exists {
                        fontNumber = index("page:" + fonts[f].resource) { .page(resource: fonts[f].resource) }
                        glyph = GlyphRun.Glyph(code: code.code.reduce(0) { $0 << 8 | UInt32($1) }, length: code.code.count, x: x, scalar: scalar)
                    }
                }
                if glyph == nil {
                    let ct = font as CTFont
                    let name = CTFontCopyPostScriptName(ct) as String
                    fontNumber = try index("mac:" + name) { .embedded(try fontData(ct)) }
                    glyph = GlyphRun.Glyph(code: UInt32(layoutManager.cgGlyph(at: g)), x: x, scalar: scalar)
                }
                if var current = run, current.font == fontNumber, current.size == size, current.fill == fill,
                   current.underline == underline, abs(current.baseline - baseline) < 0.01, let glyph {
                    current.glyphs.append(glyph)
                    run = current
                } else if let glyph {
                    if let run { runs.append(run) }
                    run = GlyphRun(font: fontNumber, size: size, fill: fill, baseline: baseline, glyphs: [glyph], underline: underline)
                }
            }
            if let run { runs.append(run) }
        }
        return Change(dropping: dropping, fonts: fontList, runs: runs)
    }
}

#if SELFTEST
extension ParagraphEditor {
    /// Types at the caret, as the keyboard would.
    func debugType(_ text: String) { textView.insertText(text, replacementRange: textView.selectedRange()) }
    var debugText: String { storage.string }
    var debugOverlaps: Bool { !overlapLabel.isHidden }
}
#endif

/// A grip on the right of a paragraph being edited: drag to change the width
/// it wraps at.
final class WidthHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 2
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Width")
        toolTip = "Drag to change the width the text wraps at"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { last = superview?.convert(event.locationInWindow, from: nil).x }
    override func mouseDragged(with event: NSEvent) {
        guard let x = superview?.convert(event.locationInWindow, from: nil).x, let last else { return }
        self.last = x
        onDrag?(x - last)
    }
    override func mouseUp(with event: NSEvent) { last = nil }
}
