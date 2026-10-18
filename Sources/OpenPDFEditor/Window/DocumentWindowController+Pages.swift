import AppKit
import PDFCore

/// Pages menu (and the thumbnails' menu): changes to pages, which apply to
/// the pages selected in the thumbnails, or else the current page.
extension DocumentWindowController {
    @objc func rotatePagesLeft(_ sender: Any?) { viewer.map { $0.pages.rotate($0.targetPages, clockwise: false) } }
    @objc func rotatePagesRight(_ sender: Any?) { viewer.map { $0.pages.rotate($0.targetPages, clockwise: true) } }
    @objc func deletePages(_ sender: Any?) { viewer.map { $0.pages.delete($0.targetPages) } }
    @objc func extractPages(_ sender: Any?) { viewer.map { $0.pages.extract($0.targetPages) } }

    @objc func insertBlankPage(_ sender: Any?) {
        guard let viewer, let last = viewer.targetPages.max() else { return }
        viewer.pages.insertBlank(after: last)
    }

    @objc func insertPagesFromFile(_ sender: Any?) {
        guard let viewer, let last = viewer.targetPages.max() else { return }
        viewer.pages.chooseFilesToInsert(at: last + 1)
    }

    @objc func toggleCropMode(_ sender: Any?) {
        guard let viewer else { return }
        if !viewer.pagesView.isCropping { viewer.tool = .select }
        viewer.pagesView.isCropping.toggle()
        window?.makeFirstResponder(viewer.pagesView)
    }

    // MARK: Split

    @objc func splitDocument(_ sender: Any?) {
        guard let viewer, let window else { return }
        let count = viewer.model.pageCount
        let bookmarks = ((try? viewer.model.engine.outline()) ?? []).compactMap(\.page)
        let byBookmarks = PageSplit.starting(at: bookmarks, pageCount: count)

        let everyButton = NSButton(radioButtonWithTitle: "Every", target: nil, action: nil)
        everyButton.state = .on
        let sizeField = NSTextField(string: "\(max(1, min(10, count / 2)))")
        sizeField.alignment = .right
        sizeField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: max(count, 1))
        formatter.allowsFloats = false
        sizeField.formatter = formatter
        let pagesLabel = NSTextField(labelWithString: "pages")
        let everyRow = NSStackView(views: [everyButton, sizeField, pagesLabel])
        everyRow.spacing = 6
        let bookmarkButton = NSButton(radioButtonWithTitle: "At each top-level bookmark (\(byBookmarks.count) parts)", target: nil, action: nil)
        bookmarkButton.isEnabled = byBookmarks.count > 1
        // Radio buttons with the same action form a group.
        let group = RadioGroup(buttons: [everyButton, bookmarkButton])
        let stack = NSStackView(views: [everyRow, bookmarkButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)

        let alert = NSAlert()
        alert.messageText = "Split “\(viewer.pages.baseName)” into several PDFs?"
        alert.informativeText = "The document itself isn’t changed."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Split…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            _ = group
            guard response == .alertFirstButtonReturn else { return }
            let parts: [[Int]]
            if bookmarkButton.state == .on {
                parts = byBookmarks
            } else {
                parts = PageSplit.every(max(1, sizeField.integerValue), pageCount: viewer.model.pageCount)
            }
            guard parts.count > 1 else {
                viewer.pages.present(message: "There is nothing to split.", info: "Every page would end up in the same file.")
                return
            }
            // After this sheet has gone.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { viewer.pages.split(into: parts) }
            }
        }
    }

    // MARK: Reduce File Size

    @objc func reduceFileSize(_ sender: Any?) {
        guard let viewer, let window, let document = document as? EditorDocument else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: ["High quality (images at 200 dpi)", "Medium (images at 150 dpi)", "Smallest (images at 100 dpi)"])
        popup.selectItem(at: 1)
        let alert = NSAlert()
        alert.messageText = "Save a smaller copy?"
        alert.informativeText = "Images are reduced and recompressed, and unused data is removed. The document itself isn’t changed."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Save Copy…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let quality = PDFFiles.Quality(rawValue: popup.indexOfSelectedItem) ?? .medium
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.saveReducedCopy(of: document, viewer: viewer, quality: quality) }
            }
        }
    }

    private func saveReducedCopy(of document: EditorDocument, viewer: ViewerController, quality: PDFFiles.Quality) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(viewer.pages.baseName) (smaller).pdf"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let engine = viewer.model.engine
            let editable = viewer.model.isEditable
            let original = document.fileURL
            let password = document.password
            let progress = ProgressSheet.show(on: window, message: "Making a smaller copy…")
            EngineExecutor.background.async {
                let result: Result<(Int, Int), Error> = Result {
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
                    try PageEditor.writeReplacing(url) { try PDFFiles.reduce(source, password: password, quality: quality, into: $0) }
                    let before = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let after = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return (before, after)
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        progress?.close()
                        switch result {
                        case let .success((before, after)):
                            let alert = NSAlert()
                            let format = ByteCountFormatter()
                            alert.messageText = "Saved a copy of \(format.string(fromByteCount: Int64(after)))."
                            alert.informativeText = after < before
                                ? "The document is \(format.string(fromByteCount: Int64(before))) (\(100 - after * 100 / max(before, 1))% smaller)."
                                : "It couldn’t be made smaller than \(format.string(fromByteCount: Int64(before)))."
                            alert.addButton(withTitle: "Show in Finder")
                            alert.addButton(withTitle: "OK")
                            alert.beginSheetModal(for: window) { response in
                                if response == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }
                        case let .failure(error):
                            viewer.pages.present(error, message: "The smaller copy couldn’t be saved.")
                        }
                    }
                }
            }
        }
    }

    // MARK: Validation

    /// nil for actions that aren't page commands.
    func validatePageAction(_ action: Selector?, setState: (Bool) -> Void) -> Bool? {
        guard let viewer else { return nil }
        let editable = viewer.model.isEditable
        switch action {
        case #selector(rotatePagesLeft(_:)), #selector(rotatePagesRight(_:)), #selector(insertBlankPage(_:)),
             #selector(insertPagesFromFile(_:)):
            return editable
        case #selector(deletePages(_:)):
            return editable && viewer.targetPages.count < viewer.model.pageCount
        case #selector(toggleCropMode(_:)):
            setState(viewer.pagesView.isCropping)
            return editable
        case #selector(extractPages(_:)), #selector(reduceFileSize(_:)):
            return viewer.model.engine.isPDF
        case #selector(splitDocument(_:)):
            return viewer.model.engine.isPDF && viewer.model.pageCount > 1
        default:
            return nil
        }
    }
}

/// Radio buttons that turn each other off.
@MainActor
final class RadioGroup: NSObject {
    private let buttons: [NSButton]

    init(buttons: [NSButton]) {
        self.buttons = buttons
        super.init()
        for button in buttons {
            button.target = self
            button.action = #selector(chosen(_:))
        }
    }

    @objc private func chosen(_ sender: NSButton) {
        for button in buttons { button.state = button === sender ? .on : .off }
    }
}
