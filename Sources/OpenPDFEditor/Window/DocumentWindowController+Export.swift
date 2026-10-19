import AppKit
import PDFCore
import UniformTypeIdentifiers

/// File › Export…: the document as a Word document, web page, plain text or
/// page images. What is exported is the document as it is now, unsaved
/// changes included; the document itself isn't changed.
extension DocumentWindowController {
    @objc func exportDocument(_ sender: Any?) {
        guard let viewer, let window, let document = editorDocument, window.attachedSheet == nil else { return }
        guard viewer.model.allowed.contains(.copy) else {
            viewer.pages.present(message: "The document’s owner doesn’t allow copying its content.", info: "")
            return
        }
        let panel = NSSavePanel()
        let options = ExportOptions(panel: panel, pageCount: viewer.model.pageCount, currentPage: viewer.currentPage,
                                    baseName: viewer.pages.baseName)
        panel.accessoryView = options.view
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let choice = options.choice
            ExportOptions.remember(choice.format)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.export(document, viewer: viewer, choice, to: url) }
            }
        }
    }

    /// Exports in the background with a progress sheet.
    func export(_ document: EditorDocument, viewer: ViewerController, _ choice: ExportOptions.Choice, to url: URL,
                then: (@MainActor @Sendable (Result<URL, Error>) -> Void)? = nil) {
        guard let window else { return }
        // Checked again: permissions can change while the panel is up.
        guard viewer.model.allowed.contains(.copy), viewer.model.engine.isPDF else { return }
        let engine = viewer.model.engine
        let editable = viewer.model.isEditable
        let original = document.fileURL
        let password = document.password
        let cancel = ConversionCancel()
        let pages = choice.pages
        let progress = ProgressSheet.show(on: window, message: "Exporting…", total: pages.count, onCancel: { cancel.cancel() })
        EngineExecutor.conversion.async {
            let report: (Int) -> Void = { done in
                DispatchQueue.main.async { progress?.update(done: done, message: "Exporting page \(min(pages.lowerBound + done + 1, pages.upperBound + 1)) of \(pages.upperBound + 1)…") }
            }
            let result: Result<(URL, CGFloat), Error> = Result {
                let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: url, create: true)
                defer { try? FileManager.default.removeItem(at: scratch) }
                // The document as it is now, unsaved changes included.
                var source = original
                if editable {
                    let current = scratch.appendingPathComponent("current.pdf")
                    try engine.save(to: current)
                    source = current
                }
                guard let source else { throw CocoaError(.fileReadNoSuchFile) }
                let exporter = try PDFExporter(url: source, password: password, cancel: cancel)
                var used = choice.dpi
                var written = url
                switch choice.format {
                case .word, .html, .text:
                    try PageEditor.writeReplacing(url) { try exporter.export(choice.format, pages: pages, to: $0, progress: report) }
                case .tiff:
                    try PageEditor.writeReplacing(url) { used = try exporter.exportTIFF(pages: pages, dpi: choice.dpi, to: $0, progress: report) }
                case .png, .jpeg:
                    let jpeg = choice.format == .jpeg
                    if pages.count == 1 {
                        try PageEditor.writeReplacing(url) {
                            used = try exporter.exportImage(page: pages.lowerBound, dpi: choice.dpi, jpeg: jpeg, quality: choice.quality, to: $0)
                        }
                    } else {
                        // A new folder of numbered images, named like the file chosen.
                        let name = url.deletingPathExtension().lastPathComponent
                        let digits = String(pages.upperBound + 1).count
                        written = try PageEditor.writeNew(in: url.deletingLastPathComponent(), name: name, ext: "") { folder in
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                            for (done, page) in pages.enumerated() {
                                let number = String(repeating: "0", count: max(0, digits - String(page + 1).count)) + String(page + 1)
                                let file = folder.appendingPathComponent("\(name) \(number).\(choice.format.fileExtension)")
                                used = min(used, try exporter.exportImage(page: page, dpi: choice.dpi, jpeg: jpeg, quality: choice.quality, to: file))
                                report(done + 1)
                            }
                        }
                    }
                }
                return (written, used)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    progress?.close()
                    if let then { return then(result.map(\.0)) }
                    switch result {
                    case let .success((_, used)) where choice.format.isImage && used < choice.dpi - 0.5:
                        viewer.pages.present(message: "Some pages were too large for \(Int(choice.dpi)) dpi.",
                                             info: "They were drawn at \(Int(used)) dpi.")
                    case .success:
                        break
                    case let .failure(error):
                        if (error as? EngineError)?.message == "Cancelled" { return }
                        viewer.pages.present(error, message: "The document couldn’t be exported.")
                    }
                }
            }
        }
    }
}

/// The options under the Export save panel.
@MainActor
final class ExportOptions: NSObject {
    struct Choice: Sendable {
        var format: ExportFormat
        var pages: ClosedRange<Int>
        var dpi: CGFloat
        var quality: Double
    }

    static let resolutions: [CGFloat] = [72, 150, 300, 600]
    static let qualities: [(String, Double)] = [("Low", 0.5), ("Medium", 0.7), ("High", 0.85), ("Best", 0.95)]
    private static let formatKey = "ExportFormat"

    static func remember(_ format: ExportFormat) {
        UserDefaults.standard.set(format.rawValue, forKey: formatKey)
    }

    let view: NSView
    private weak var panel: NSSavePanel?
    private let pageCount: Int
    private let currentPage: Int
    private let format = NSPopUpButton(frame: .zero, pullsDown: false)
    private let all = NSButton(radioButtonWithTitle: "All", target: nil, action: nil)
    private let current: NSButton
    private let range = NSButton(radioButtonWithTitle: "From", target: nil, action: nil)
    private let from = NSTextField(string: "1")
    private let to: NSTextField
    private let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quality = NSPopUpButton(frame: .zero, pullsDown: false)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var resolutionRow: NSGridRow?
    private var qualityRow: NSGridRow?
    private var group: RadioGroup?

    init(panel: NSSavePanel, pageCount: Int, currentPage: Int, baseName: String) {
        self.panel = panel
        self.pageCount = pageCount
        self.currentPage = currentPage
        current = NSButton(radioButtonWithTitle: "This page (\(currentPage + 1))", target: nil, action: nil)
        to = NSTextField(string: "\(pageCount)")
        let grid = NSGridView()
        let container = NSView()
        container.addSubview(grid)
        view = container
        super.init()
        for f in ExportFormat.allCases { format.addItem(withTitle: f.title) }
        let saved = UserDefaults.standard.string(forKey: Self.formatKey).flatMap(ExportFormat.init(rawValue:)) ?? .word
        format.selectItem(at: ExportFormat.allCases.firstIndex(of: saved) ?? 0)
        format.target = self
        format.action = #selector(formatChanged(_:))
        all.state = .on
        group = RadioGroup(buttons: [all, current, range])
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: max(pageCount, 1))
        formatter.allowsFloats = false
        for field in [from, to] {
            field.formatter = formatter
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        for dpi in Self.resolutions { resolution.addItem(withTitle: "\(Int(dpi)) dpi") }
        resolution.selectItem(at: 1)
        for (title, _) in Self.qualities { quality.addItem(withTitle: title) }
        quality.selectItem(at: 2)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 360
        let rangeRow = NSStackView(views: [range, from, NSTextField(labelWithString: "to"), to])
        rangeRow.spacing = 6
        let pages = NSStackView(views: [all, current, rangeRow])
        pages.orientation = .vertical
        pages.alignment = .leading
        pages.spacing = 4
        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        grid.addRow(with: [label("Format:"), format])
        grid.addRow(with: [label("Pages:"), pages])
        resolutionRow = grid.addRow(with: [label("Resolution:"), resolution])
        qualityRow = grid.addRow(with: [label("Quality:"), quality])
        grid.addRow(with: [NSGridCell.emptyContentView, note])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            grid.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
        ])
        update(name: baseName)
    }

    var selectedFormat: ExportFormat { ExportFormat.allCases[max(0, format.indexOfSelectedItem)] }

    var choice: Choice {
        let last = max(pageCount - 1, 0)
        let pages: ClosedRange<Int>
        if current.state == .on {
            pages = min(currentPage, last)...min(currentPage, last)
        } else if range.state == .on {
            let a = max(1, min(from.integerValue, pageCount)) - 1, b = max(1, min(to.integerValue, pageCount)) - 1
            pages = min(a, b)...max(a, b)
        } else {
            pages = 0...last
        }
        return Choice(format: selectedFormat, pages: pages, dpi: Self.resolutions[max(0, resolution.indexOfSelectedItem)],
                      quality: Self.qualities[max(0, quality.indexOfSelectedItem)].1)
    }

    @objc private func formatChanged(_ sender: Any?) {
        update(name: nil)
    }

    /// The file type, name and options shown for the chosen format.
    private func update(name: String?) {
        let f = selectedFormat
        guard let panel else { return }
        let type = UTType(filenameExtension: f.fileExtension) ?? .data
        panel.allowedContentTypes = [type]
        let base = name ?? (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base.isEmpty ? "Document" : base).\(f.fileExtension)"
        resolutionRow?.isHidden = !f.isImage
        qualityRow?.isHidden = f != .jpeg
        switch f {
        case .word: note.stringValue = "Text, pictures and simple layout, to edit in Word or Pages. Recognised text, and any other invisible text, is included as ordinary text."
        case .html: note.stringValue = "One web page with the text and pictures, laid out as on the pages."
        case .text: note.stringValue = "Just the text, in reading order."
        case .png, .jpeg: note.stringValue = "A picture of each page. Several pages go into a new folder with this name."
        case .tiff: note.stringValue = "One image file with a page for each page."
        }
    }
}
