import AppKit
import PDFCore

/// VoiceOver's view of the document: one static-text element per page, for
/// every page (not only those on screen), with the page's text, its lines
/// and where each range of characters is on screen. Focusing a page that is
/// off screen scrolls it into view.
@MainActor
final class PageAccessibility {
    private weak var view: PagesView?
    private var cache: [Int: PageAccessibilityElement] = [:]
    /// Called with a page index when VoiceOver moves to it.
    var focusHandler: ((Int) -> Void)?

    init(view: PagesView) {
        self.view = view
    }

    var elements: [PageAccessibilityElement] {
        guard let view else { return [] }
        return (0..<view.model.pageCount).map(element)
    }

    func element(_ page: Int) -> PageAccessibilityElement {
        if let element = cache[page] { return element }
        let element = PageAccessibilityElement(owner: self, page: page)
        cache[page] = element
        return element
    }

    func invalidate() {
        guard let view else { return }
        cache = cache.filter { $0.key < view.model.pageCount }
    }

    fileprivate var pagesView: PagesView? { view }

    // MARK: Answers for the page elements

    private func text(_ page: Int) -> PageText? { view?.model.text(page: page) }

    fileprivate func label(_ page: Int) -> String? {
        view.map { "Page \(page + 1) of \($0.model.pageCount)" }
    }

    fileprivate func value(_ page: Int) -> String? {
        guard let text = text(page) else { return nil }
        return text.isEmpty ? "No text on this page" : text.string
    }

    fileprivate func frame(_ page: Int) -> NSRect {
        guard let view, let frame = view.viewFrame(ofPage: page) else { return .zero }
        return screenRect(frame, in: view)
    }

    fileprivate func length(_ page: Int) -> Int {
        (text(page)?.string as NSString?)?.length ?? 0
    }

    fileprivate func selectedRange(_ page: Int) -> NSRange {
        guard let view, let text = text(page), let selection = view.selection,
              let range = selection.range(onPage: page, count: text.chars.count) else { return NSRange(location: 0, length: 0) }
        return text.utf16Range(of: range)
    }

    fileprivate func string(_ page: Int, _ range: NSRange) -> String? {
        guard let string = text(page)?.string as NSString?,
              range.location >= 0, range.location + range.length <= string.length else { return nil }
        return string.substring(with: range)
    }

    fileprivate func line(_ page: Int, at index: Int) -> Int {
        guard let text = text(page), !text.lines.isEmpty else { return 0 }
        // The character at the index, or the one before a line break.
        var probe = index
        while probe >= 0 {
            if let chars = text.charRange(of: NSRange(location: probe, length: 1)),
               let line = text.lineIndex(containing: chars.lowerBound) {
                return line
            }
            probe -= 1
        }
        return index <= 0 ? 0 : text.lines.count - 1
    }

    fileprivate func range(_ page: Int, line: Int) -> NSRange {
        guard let text = text(page), line >= 0, line < text.lines.count else { return NSRange(location: 0, length: 0) }
        let range = text.utf16Range(of: text.lines[line].range)
        // Include the line break, so lines cover the whole text.
        let length = (text.string as NSString).length
        let extra = line < text.lines.count - 1 && range.location + range.length < length ? 1 : 0
        return NSRange(location: range.location, length: range.length + extra)
    }

    fileprivate func frame(_ page: Int, range: NSRange) -> NSRect {
        guard let view, let text = text(page), let chars = text.charRange(of: range) else { return .zero }
        var rect = CGRect.null
        for r in text.rects(for: chars) {
            if let converted = view.convert(r, fromPage: page) { rect = rect.union(converted) }
        }
        return rect.isNull ? .zero : screenRect(rect, in: view)
    }

    private func screenRect(_ rect: CGRect, in view: NSView) -> NSRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    fileprivate func didFocus(_ page: Int) { focusHandler?(page) }
}

/// One page for VoiceOver. AppKit calls these overrides (nonisolated in the
/// SDK) on the main thread; each asks its main-actor owner.
final class PageAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    private weak var owner: PageAccessibility?
    let page: Int

    init(owner: PageAccessibility, page: Int) {
        self.owner = owner
        self.page = page
        super.init()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityRoleDescription() -> String? { "page" }
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityLabel() -> String? {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.label(page) }
    }

    override func accessibilityParent() -> Any? {
        let owner = owner
        return MainActor.assumeIsolated { owner?.pagesView }
    }

    override func accessibilityValue() -> Any? {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.value(page) }
    }

    override func accessibilityFrame() -> NSRect {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.frame(page) ?? .zero }
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        guard focused else { return }
        let (owner, page) = (owner, page)
        MainActor.assumeIsolated { owner?.didFocus(page) }
    }

    override func accessibilityNumberOfCharacters() -> Int {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.length(page) ?? 0 }
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.selectedRange(page) ?? NSRange(location: 0, length: 0) }
    }

    override func accessibilitySelectedText() -> String? {
        let range = accessibilitySelectedTextRange()
        return range.length > 0 ? accessibilityString(for: range) : nil
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.string(page, range) }
    }

    override func accessibilityLine(for index: Int) -> Int {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.line(page, at: index) ?? 0 }
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.range(page, line: line) ?? NSRange(location: 0, length: 0) }
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let (owner, page) = (owner, page)
        return MainActor.assumeIsolated { owner?.frame(page, range: range) ?? .zero }
    }
}
