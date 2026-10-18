import AppKit
import PDFCore
import UniformTypeIdentifiers

/// Changes to the pages of the open document: delete, move, turn, crop,
/// insert, and writing pages out. Each change is one undoable step; the
/// views reload through DocumentModel.structureDidChange.
@MainActor
final class PageEditor {
    unowned let viewer: ViewerController
    /// Called with the pages to select (in the thumbnails) after a change.
    var onSelectPages: (([Int]) -> Void)?

    init(viewer: ViewerController) {
        self.viewer = viewer
    }

    private var model: DocumentModel { viewer.model }
    private var window: NSWindow? { viewer.view.window }

    /// The kinds of file that can become pages.
    static var insertableTypes: [UTType] {
        var types: [UTType] = [.pdf, .png, .jpeg, .tiff, .gif, .bmp, .svg, .html, .plainText, .epub]
        for identifier in ["com.microsoft.xps", "org.openxmlformats.wordprocessingml.document",
                           "org.openxmlformats.spreadsheetml.sheet", "org.openxmlformats.presentationml.presentation",
                           "com.comicbook.cbz", "public.fictionbook"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        for ext in ["cbz", "fb2", "xps", "oxps", "mobi", "jxr", "pnm", "pbm", "pgm", "ppm", "pam", "psd"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    // MARK: Changes

    func delete(_ pages: [Int]) {
        let pages = valid(pages)
        guard !pages.isEmpty else { return }
        guard pages.count < model.pageCount else {
            present(message: "A document needs at least one page.", info: "Select fewer pages to delete.")
            return
        }
        let first = pages.min() ?? 0
        let name = pages.count == 1 ? "Delete Page" : "Delete Pages"
        perform(name) { try $0.deletePages(pages) } then: {
            let page = min(first, self.model.pageCount - 1)
            self.show([page])
        }
    }

    /// Moves `pages` so they sit together before what is now page `index`
    /// (`index` may be the page count, for the end).
    func move(_ pages: [Int], to index: Int) {
        let moving = valid(pages).sorted()
        guard !moving.isEmpty else { return }
        let count = model.pageCount
        let set = Set(moving)
        var rest = (0..<count).filter { !set.contains($0) }
        let at = min(max(0, index - moving.filter { $0 < index }.count), rest.count)
        rest.insert(contentsOf: moving, at: at)
        guard rest != Array(0..<count) else { return }
        let name = moving.count == 1 ? "Move Page" : "Move Pages"
        perform(name) { try $0.reorderPages(rest) } then: {
            self.show(Array(at..<at + moving.count))
        }
    }

    func rotate(_ pages: [Int], clockwise: Bool) {
        let pages = valid(pages)
        guard !pages.isEmpty else { return }
        perform(clockwise ? "Rotate Right" : "Rotate Left") { try $0.rotatePages(pages, by: clockwise ? 90 : -90) } then: {
            self.show(pages)
        }
    }

    func crop(_ pages: [Int], to rect: CGRect) {
        let pages = valid(pages)
        guard !pages.isEmpty else { return }
        perform("Crop") { try $0.cropPages(pages, to: rect) } then: {
            self.show(pages)
        }
    }

    /// A blank page the size of `page`, after it.
    func insertBlank(after page: Int) {
        guard let size = model.bounds(page: page)?.size else { return }
        perform("Insert Page") { try $0.insertBlankPage(at: page + 1, size: size) } then: {
            self.show([page + 1])
        }
    }

    /// Asks for files and inserts their pages before page `index`.
    func chooseFilesToInsert(at index: Int) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.insertableTypes
        panel.message = "Choose PDFs, images or other documents to insert."
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            self.insert(panel.urls, at: index)
        }
    }

    /// Inserts the pages of these files before page `index`: a PDF straight
    /// away, anything else (or several files) made into one PDF first.
    func insert(_ files: [URL], at index: Int) {
        guard !files.isEmpty else { return }
        if files.count == 1, let file = files.first, isPDF(file) {
            insertPDF(file, at: index, password: nil)
            return
        }
        convert(files) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(temporary):
                defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
                self.insertPDF(temporary, at: index, password: nil)
            case let .failure(error):
                self.present(error, message: "The files couldn’t be inserted.")
            }
        }
    }

    private func insertPDF(_ url: URL, at index: Int, password: String?) {
        // A locked file: ask for its password first.
        if password == nil, let probe = try? EngineDocument(url: url), probe.needsPassword {
            askPassword(for: url) { password in self.insertPDF(url, at: index, password: password) }
            return
        }
        let at = min(max(index, 0), model.pageCount)
        var inserted = 0
        perform("Insert Pages") { inserted = try $0.insertPages(from: url, at: at, password: password) } then: {
            self.show(Array(at..<min(at + inserted, self.model.pageCount)))
        }
    }

    // MARK: Writing pages out

    /// Asks where to save these pages as a new PDF.
    func extract(_ pages: [Int]) {
        let pages = valid(pages).sorted()
        guard let window, !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName) (\(Self.describe(pages))).pdf"
        panel.message = pages.count == 1 ? "Save page \(pages[0] + 1) as a new PDF." : "Save \(pages.count) pages as a new PDF."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Self.writeReplacing(url) { try self.model.engine.extractPages(pages, to: $0) }
            } catch {
                self.present(error, message: "The pages couldn’t be saved.")
            }
        }
    }

    /// Writes a new PDF per part into a folder the user chooses.
    func split(into parts: [[Int]]) {
        guard let window, !parts.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Split"
        panel.message = "Choose a folder for the \(parts.count) new PDFs."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                var written: [URL] = []
                for (index, part) in parts.enumerated() {
                    let url = try Self.writeNew(in: folder, name: "\(self.baseName) \(index + 1)", ext: "pdf") {
                        try self.model.engine.extractPages(part, to: $0)
                    }
                    written.append(url)
                }
                NSWorkspace.shared.activateFileViewerSelecting(written)
            } catch {
                self.present(error, message: "The document couldn’t be split.")
            }
        }
    }

    // MARK: Helpers

    var baseName: String {
        let name = (viewer.view.window?.windowController?.document as? NSDocument)?.displayName ?? "Document"
        return (name as NSString).deletingPathExtension
    }

    private func valid(_ pages: [Int]) -> [Int] {
        Array(Set(pages.filter { $0 >= 0 && $0 < model.pageCount })).sorted()
    }

    private func perform(_ name: String, _ body: (EngineDocument) throws -> Void, then: () -> Void) {
        do {
            try model.editStructure(name, body)
            then()
        } catch {
            present(error, message: "\(name) didn’t work.")
        }
    }

    private func show(_ pages: [Int]) {
        guard let first = pages.min(), first < model.pageCount else { return }
        viewer.go(toPage: first)
        onSelectPages?(pages)
    }

    private func isPDF(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .pdf) ?? (url.pathExtension.lowercased() == "pdf")
    }

    /// "page 3" or "pages 2–5" or "4 pages".
    static func describe(_ pages: [Int]) -> String {
        let sorted = pages.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        if sorted.count == 1 { return "page \(first + 1)" }
        if last - first + 1 == sorted.count { return "pages \(first + 1)–\(last + 1)" }
        return "\(sorted.count) pages"
    }

    /// Makes one PDF of `files` off the main thread, in a temporary folder of
    /// its own (the caller removes it).
    func convert(_ files: [URL], pageSize: CGSize = CGSize(width: 612, height: 792),
                 completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        let progress = ProgressSheet.show(on: window, message: files.count == 1 ? "Converting…" : "Combining \(files.count) files…")
        EngineExecutor.background.async {
            let result: Result<URL, Error>
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let url = folder.appendingPathComponent("combined.pdf")
                do {
                    try PDFFiles.combine(files, into: url, pageSize: pageSize)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                result = .success(url)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    progress?.close()
                    completion(result)
                }
            }
        }
    }

    /// Writes a file through a temporary copy, then puts it at `url`
    /// (replacing what is there, which the save panel has confirmed).
    nonisolated static func writeReplacing(_ url: URL, _ write: (URL) throws -> Void) throws {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appendingPathComponent(url.lastPathComponent)
        try write(temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    /// Writes a new file in `folder` named `name.ext`, or `name (2).ext` and
    /// so on: never over an existing file.
    nonisolated static func writeNew(in folder: URL, name: String, ext: String, _ write: (URL) throws -> Void) throws -> URL {
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: folder, create: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent("part.\(ext)")
        try write(temporary)
        for attempt in 1...1000 {
            let target = folder.appendingPathComponent(attempt == 1 ? "\(name).\(ext)" : "\(name) (\(attempt)).\(ext)")
            do {
                // Moving fails if something is already there.
                try FileManager.default.moveItem(at: temporary, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func askPassword(for url: URL, then: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” is locked."
        alert.informativeText = "Enter its password to insert its pages."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let password = field.stringValue
            guard let probe = try? EngineDocument(url: url), probe.authenticate(password: password) else {
                self.present(message: "The password is wrong.", info: "“\(url.lastPathComponent)” wasn’t inserted.")
                return
            }
            then(password)
        }
    }

    func present(_ error: Error, message: String) {
        present(message: message, info: "\(error)")
    }

    func present(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// A sheet with a spinning progress indicator, for work that takes a while.
@MainActor
final class ProgressSheet {
    private let sheet: NSWindow
    private weak var parent: NSWindow?

    private init(sheet: NSWindow, parent: NSWindow?) {
        self.sheet = sheet
        self.parent = parent
    }

    /// On `window` as a sheet, or with no window as a small panel of its own.
    static func show(on window: NSWindow?, message: String) -> ProgressSheet? {
        let label = NSTextField(labelWithString: message)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let controller = NSViewController()
        controller.view = stack
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        if let window {
            window.beginSheet(sheet)
        } else {
            sheet.isReleasedWhenClosed = false
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
        return ProgressSheet(sheet: sheet, parent: window)
    }

    func close() {
        parent?.endSheet(sheet)
        sheet.orderOut(nil)
    }
}
