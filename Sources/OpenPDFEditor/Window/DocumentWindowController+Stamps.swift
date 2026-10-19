import AppKit
import CoreText
import PDFCore

/// Pages menu: headers and footers (page numbers among them) and
/// watermarks, added to a range of pages and removed again.
extension DocumentWindowController {
    @objc func addHeadersAndFooters(_ sender: Any?) { askForHeaders(pageNumbers: false) }

    @objc func addPageNumbers(_ sender: Any?) { askForHeaders(pageNumbers: true) }

    @objc func addWatermark(_ sender: Any?) {
        guard let viewer, let window else { return }
        let text = NSTextField(string: "DRAFT")
        let size = NSTextField(string: "72")
        size.formatter = Self.numberFormatter(min: 4, max: 400)
        let color = NSColorWell(style: .minimal)
        color.color = .systemRed
        let opacity = NSSlider(value: 0.3, minValue: 0.05, maxValue: 1, target: nil, action: nil)
        let angle = NSPopUpButton(frame: .zero, pullsDown: false)
        for degrees in [45, 0, 90, -45] { angle.addItem(withTitle: "\(degrees)°") }
        let range = PageRangeControl(pageCount: viewer.model.pageCount)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Text:"), text],
            [NSTextField(labelWithString: "Size:"), NSStackView(views: [size, NSTextField(labelWithString: "pt")])],
            [NSTextField(labelWithString: "Colour:"), color],
            [NSTextField(labelWithString: "Opacity:"), opacity],
            [NSTextField(labelWithString: "Angle:"), angle],
            [NSTextField(labelWithString: "Pages:"), range.view],
        ])
        grid.column(at: 0).xPlacement = .trailing
        text.widthAnchor.constraint(equalToConstant: 240).isActive = true
        size.widthAnchor.constraint(equalToConstant: 60).isActive = true
        opacity.widthAnchor.constraint(equalToConstant: 160).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        let alert = NSAlert()
        alert.messageText = "Add a watermark"
        alert.informativeText = "The text is drawn across the middle of each page. Pages › Remove Watermarks takes it off again."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let words = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty, let pages = range.pages else { return }
            let rgb = color.color.usingColorSpace(.sRGB) ?? .red
            let degrees = CGFloat(Int(angle.titleOfSelectedItem?.dropLast() ?? "45") ?? 45)
            let stamps = pages.map {
                Stamp(page: $0, kind: .watermark, text: words, size: CGFloat(size.doubleValue > 0 ? size.doubleValue : 72),
                      color: PDFColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent),
                      opacity: CGFloat(opacity.doubleValue), angle: degrees)
            }
            self.stamp(stamps, actionName: "Add Watermark")
        }
    }

    @objc func removeHeadersAndFooters(_ sender: Any?) { removeStamps(headers: true) }

    @objc func removeWatermarks(_ sender: Any?) { removeStamps(headers: false) }

    // MARK: Headers and footers

    private func askForHeaders(pageNumbers: Bool) {
        guard let viewer, let window else { return }
        let fields = (0..<6).map { _ in NSTextField(string: "") }
        if pageNumbers { fields[4].stringValue = "Page <<page>> of <<pages>>" }
        fields.forEach { $0.widthAnchor.constraint(equalToConstant: 150).isActive = true }
        fields.enumerated().forEach { i, f in
            f.placeholderString = ["Left", "Centre", "Right"][i % 3]
            f.setAccessibilityLabel((i < 3 ? "Header " : "Footer ") + ["left", "centre", "right"][i % 3])
        }
        let size = NSPopUpButton(frame: .zero, pullsDown: false)
        for points in [8, 9, 10, 11, 12, 14, 16] { size.addItem(withTitle: "\(points) pt") }
        size.selectItem(withTitle: "10 pt")
        let range = PageRangeControl(pageCount: viewer.model.pageCount)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Header:") as NSView] + fields[0..<3].map { $0 as NSView },
            [NSTextField(labelWithString: "Footer:") as NSView] + fields[3..<6].map { $0 as NSView },
        ])
        grid.column(at: 0).xPlacement = .trailing
        let note = NSTextField(wrappingLabelWithString: "<<page>> is the page number, <<pages>> the number of pages, and <<date>> today’s date.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 520
        let options = NSStackView(views: [NSTextField(labelWithString: "Size:"), size, NSTextField(labelWithString: "Pages:"), range.view])
        let stack = NSStackView(views: [grid, note, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        let alert = NSAlert()
        alert.messageText = pageNumbers ? "Add page numbers" : "Add headers and footers"
        alert.informativeText = "Pages › Remove Headers & Footers takes them off again."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = fields[pageNumbers ? 4 : 0]
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let pages = range.pages else { return }
            let points = CGFloat(Int(size.titleOfSelectedItem?.split(separator: " ").first ?? "10") ?? 10)
            let count = viewer.model.pageCount
            var stamps: [Stamp] = []
            for page in pages {
                for (i, field) in fields.enumerated() {
                    let template = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !template.isEmpty else { continue }
                    stamps.append(Stamp(page: page, kind: i < 3 ? .header : .footer, alignment: Stamp.Alignment(rawValue: Int32(i % 3)) ?? .centre,
                                        text: Stamp.expand(template, page: page, pages: count), size: points))
                }
            }
            guard !stamps.isEmpty else { return }
            self.stamp(stamps, actionName: pageNumbers ? "Add Page Numbers" : "Add Headers & Footers")
        }
    }

    // MARK: Doing it

    /// Stamps them as one step: in Helvetica, or in an embedded system font
    /// when Helvetica can't draw some of the text.
    private func stamp(_ stamps: [Stamp], actionName: String) {
        guard let viewer, let window else { return }
        do {
            var font: Data?
            let all = stamps.map(\.text).joined()
            if !Stamp.fitsHelvetica(all) {
                var chosen = CTFontCreateWithName("Helvetica Neue" as CFString, 12, nil)
                if !FontFile.covers(chosen, all) {
                    chosen = CTFontCreateForString(chosen, all as CFString, CFRange(location: 0, length: (all as NSString).length))
                }
                guard FontFile.covers(chosen, all) else { throw EngineError(code: -1, message: "No font on this Mac has all of that text’s characters.") }
                font = try FontFile.data(for: chosen)
            }
            let pages = Set(stamps.map(\.page))
            try viewer.model.edit(actionName, pages: pages) { try $0.addStamps(stamps, font: font) }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private func removeStamps(headers: Bool) {
        guard let viewer, let window else { return }
        do {
            let removed = try viewer.model.edit(headers ? "Remove Headers & Footers" : "Remove Watermarks",
                                                pages: Set(0..<viewer.model.pageCount)) {
                try $0.removeStamps(headersAndFooters: headers, watermarks: !headers)
            }
            if removed == 0 {
                let alert = NSAlert()
                alert.messageText = headers ? "There are no headers or footers to remove." : "There are no watermarks to remove."
                alert.informativeText = "Only those added with this app can be removed here."
                alert.beginSheetModal(for: window)
            }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    private static func numberFormatter(min: Double, max: Double) -> NumberFormatter {
        let f = NumberFormatter()
        f.minimum = NSNumber(value: min)
        f.maximum = NSNumber(value: max)
        f.allowsFloats = false
        return f
    }
}

/// All pages, or a range of them.
@MainActor
final class PageRangeControl: NSObject {
    let view: NSView
    private let all = NSButton(radioButtonWithTitle: "All", target: nil, action: nil)
    private let some = NSButton(radioButtonWithTitle: "From", target: nil, action: nil)
    private let from = NSTextField(string: "1")
    private let to: NSTextField
    private let count: Int

    init(pageCount: Int) {
        count = pageCount
        to = NSTextField(string: "\(pageCount)")
        view = NSStackView()
        super.init()
        for field in [from, to] {
            let f = NumberFormatter()
            f.minimum = 1
            f.maximum = NSNumber(value: max(pageCount, 1))
            f.allowsFloats = false
            field.formatter = f
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        all.state = .on
        all.target = self
        all.action = #selector(changed(_:))
        some.target = self
        some.action = #selector(changed(_:))
        let stack = view as! NSStackView
        [all, some, from, NSTextField(labelWithString: "to"), to].forEach { stack.addArrangedSubview($0) }
        changed(all)
    }

    @objc private func changed(_ sender: NSButton) {
        all.state = sender === all ? .on : .off
        some.state = sender === some ? .on : .off
        from.isEnabled = some.state == .on
        to.isEnabled = some.state == .on
    }

    /// The pages chosen (from 0), or nil for an empty range.
    var pages: [Int]? {
        guard some.state == .on else { return Array(0..<count) }
        let a = max(1, from.integerValue), b = min(count, to.integerValue)
        return a <= b ? Array((a - 1)...(b - 1)) : nil
    }
}
