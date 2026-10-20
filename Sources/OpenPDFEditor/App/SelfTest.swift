#if SELFTEST
import AppKit
import ImageIO
import PDFCore

/// A scripted run through annotating, for builds made with `make selftest`
/// (never in releases): opens a copy of a test PDF, uses the tools through
/// the same code the mouse uses, undoes, saves, replies, and writes window
/// snapshots and a log to OPDF_SELFTEST_OUT.
@MainActor
enum SelfTest {
    static var log: [String] = []
    static var out: URL!

    static func say(_ line: String) {
        log.append(line)
        print("SELFTEST " + line)
    }

    static func run() {
        // Saved signatures in memory: the self-test never touches the keychain.
        SavedSignatures.store = MemorySignatureStore()
        if let outPath = ProcessInfo.processInfo.environment["OPDF_SELFTEST_WELCOME"] {
            out = URL(fileURLWithPath: outPath)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            return welcomeSteps()
        }
        guard let source = ProcessInfo.processInfo.environment["OPDF_SELFTEST"],
              let outPath = ProcessInfo.processInfo.environment["OPDF_SELFTEST_OUT"] else { return }
        out = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let environment = ProcessInfo.processInfo.environment
        let copy = out.appendingPathComponent(environment["OPDF_SELFTEST_GUIDE"] != nil ? "Harbour Gardens Report.pdf" : "selftest.pdf")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { document, _, error in
            guard let document = document as? EditorDocument else {
                say("FAIL open: \(String(describing: error))")
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let environment = ProcessInfo.processInfo.environment
                if environment["OPDF_SELFTEST_MANUAL"] != nil {
                    manualSaveSteps(document)
                } else if environment["OPDF_SELFTEST_FORMS"] != nil {
                    formSteps(document)
                } else if environment["OPDF_SELFTEST_SIGN"] != nil {
                    signSteps(document)
                } else if environment["OPDF_SELFTEST_REDACT"] != nil {
                    redactSteps(document)
                } else if environment["OPDF_SELFTEST_SECURITY"] != nil {
                    securitySteps(document)
                } else if environment["OPDF_SELFTEST_CONTENT"] != nil {
                    contentSteps(document)
                } else if environment["OPDF_SELFTEST_OCR"] != nil {
                    ocrSteps(document)
                } else if environment["OPDF_SELFTEST_EXPORT"] != nil {
                    exportSteps(document)
                } else if environment["OPDF_SELFTEST_GUIDE"] != nil {
                    guideSteps(document)
                } else {
                    steps(document)
                }
            }
        }
    }

    static func steps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        let a = viewer.annotations
        do {
            controller.toggleMarkupBar(nil)
            // Highlight through a text selection, as the highlight tool does on mouse-up.
            let text = viewer.model.text(page: 0)
            guard let range = text.search("quick brown fox").first else { say("FAIL search"); return finish() }
            let selection = TextSelection(anchor: TextPosition(page: 0, caret: range.lowerBound),
                                          focus: TextPosition(page: 0, caret: range.upperBound))
            _ = try a.markText(.highlight, selection: selection)
            if let strike = text.search("lazy dog").first {
                _ = try a.markText(.strikeOut, selection: TextSelection(anchor: TextPosition(page: 0, caret: strike.lowerBound), focus: TextPosition(page: 0, caret: strike.upperBound)))
            }
            let note = try a.createNote(page: 0, at: CGPoint(x: 480, y: 130))
            try a.update(note, actionName: "Edit Text") { $0.contents = "Check this paragraph" }
            _ = try a.createShape(.textBox, page: 0, from: CGPoint(x: 72, y: 280), to: CGPoint(x: 300, y: 310))
            _ = try a.createShape(.arrow, page: 0, from: CGPoint(x: 320, y: 330), to: CGPoint(x: 420, y: 420))
            _ = try a.createInk(page: 0, points: (0..<30).map { CGPoint(x: 80 + Double($0) * 6, y: 470 + sin(Double($0) / 3) * 15) })
            _ = try a.createStamp(page: 0, at: CGPoint(x: 420, y: 560))
        } catch {
            say("FAIL creating: \(error)")
        }

        // A rectangle drawn with real mouse events, then moved and resized.
        viewer.tool = .rectangle
        drag(viewer, page: 0, from: CGPoint(x: 72, y: 600), to: CGPoint(x: 240, y: 700))
        let afterDraw = viewer.model.annotations(page: 0)
        say("annotations after drawing: \(afterDraw.count) \(afterDraw.map(\.kind.name))")
        say("tool after rectangle: \(viewer.tool) selected: \(String(describing: viewer.pagesView.selectedAnnotation))")
        if let rect = afterDraw.last(where: { $0.kind == .square }) {
            drag(viewer, page: 0, from: CGPoint(x: rect.rect.midX, y: rect.rect.midY), to: CGPoint(x: rect.rect.midX + 50, y: rect.rect.midY + 20))
            let moved = viewer.model.annotation(page: 0, id: rect.id)?.rect ?? .zero
            say("moved rectangle from \(rect.rect.origin) to \(moved.origin)")
            viewer.pagesView.selectedAnnotation = AnnotationRef(page: 0, id: rect.id)
            drag(viewer, page: 0, from: CGPoint(x: moved.maxX, y: moved.maxY), to: CGPoint(x: moved.maxX + 40, y: moved.maxY + 30))
            let resized = viewer.model.annotation(page: 0, id: rect.id)?.rect ?? .zero
            say("resized rectangle to \(resized.size)")
        }
        // Underline by dragging across text with the tool, as a user would.
        viewer.tool = .underline
        let text = viewer.model.text(page: 0)
        if let line = text.search("Search should find").first {
            let r = text.rects(for: line)[0]
            drag(viewer, page: 0, from: CGPoint(x: r.minX + 1, y: r.midY), to: CGPoint(x: r.maxX - 1, y: r.midY))
        }
        say("after underline drag: \(viewer.model.annotations(page: 0).filter { $0.kind == .underline }.count) underline(s); tool \(viewer.tool)")
        viewer.tool = .select
        controller.showComments(nil)
        if controller.inspectorItem?.isCollapsed == true { controller.showDocumentInfo(nil) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            snapshot(window, "1-annotated")
            let count = viewer.model.annotations(page: 0).count
            document.undoManager?.undo()
            document.undoManager?.undo()
            say("undo x2: \(count) -> \(viewer.model.annotations(page: 0).count)")
            document.undoManager?.redo()
            say("redo: \(viewer.model.annotations(page: 0).count); undo name: \(document.undoManager?.undoActionName ?? "")")
            if let highlight = viewer.model.annotations(page: 0).first(where: { $0.kind == .highlight }) {
                let ref = AnnotationRef(page: 0, id: highlight.id)
                try? viewer.annotations.reply(to: ref, text: "Agreed, this needs rewording.")
                try? viewer.annotations.setStatus(ref, "Accepted")
                viewer.reveal(ref)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                snapshot(window, "2-comments")
                say("comments: \(controller.sidebar?.comments.debugState ?? "none")")
                document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let url = document.fileURL, let saved = try? EngineDocument(url: url) {
                        let annots = (try? saved.annotations(page: 0)) ?? []
                        say("saved file: \(annots.count) annotations: \(annots.map(\.kind.name)); edited: \(document.isDocumentEdited)")
                        let original = try? Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPDF_SELFTEST"]!))
                        let data = try? Data(contentsOf: url)
                        say("incremental: \(original.map { data?.prefix($0.count) == $0 } ?? false)")
                    }
                    say("can still undo after save: \(document.undoManager?.canUndo ?? false)")
                    do {
                        try viewer.model.edit("Flatten Annotations", pages: Set(0..<viewer.model.pageCount)) { try $0.flattenAnnotations() }
                        say("flattened: \(viewer.model.annotations(page: 0).count) annotations left")
                    } catch { say("FAIL flatten: \(error)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        snapshot(window, "3-flattened")
                        document.undoManager?.undo()
                        say("undo flatten: \(viewer.model.annotations(page: 0).count) annotations")
                        pageSteps(document, controller, viewer, window)
                    }
                }
            }
        }
    }

    static func titles(_ viewer: ViewerController) -> [String] {
        (0..<viewer.model.pageCount).map {
            viewer.model.text(page: $0).string.split(separator: "\n").first.map(String.init) ?? "(blank)"
        }
    }

    /// Clicks the sheet's button with this title.
    static func pressSheetButton(_ window: NSWindow, _ title: String) -> Bool {
        guard let sheet = window.attachedSheet else { return false }
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let button = sheet.contentView.flatMap(find) else { return false }
        button.performClick(nil)
        return true
    }

    /// Page management through the same code as the menus and thumbnails.
    static func pageSteps(_ document: EditorDocument, _ controller: DocumentWindowController, _ viewer: ViewerController, _ window: NSWindow) {
        controller.showThumbnails(nil)
        guard let thumbnails = controller.sidebar?.thumbnails else { say("FAIL thumbnails"); return finish() }
        say("pages: \(titles(viewer))")
        let before = viewer.model.pageBounds
        thumbnails.select([0, 2])
        say("selected: \(viewer.targetPages)")
        controller.rotatePagesRight(nil)
        say("rotated 1 and 3: \(before[0].size) -> \(viewer.model.pageBounds[0].size), \(viewer.model.pageBounds[2].size); page 2 \(viewer.model.pageBounds[1].size)")
        say("selected after rotate: \(thumbnails.selectedPages)")
        viewer.pages.move([2], to: 0)
        say("moved page 3 first: \(titles(viewer)); selected \(thumbnails.selectedPages)")
        viewer.pages.insertBlank(after: 0)
        say("blank after 1: \(titles(viewer))")
        let corpus = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPDF_SELFTEST"]!).deletingLastPathComponent()
        viewer.pages.insert([corpus.appendingPathComponent("mixed.pdf")], at: 2)
        say("inserted mixed.pdf at 3: \(viewer.model.pageCount) pages: \(titles(viewer))")
        viewer.go(toPage: 0)
        controller.toggleCropMode(nil)
        say("crop mode: \(viewer.pagesView.isCropping) subtitle: \(window.subtitle)")
        let cropFrom = CGPoint(x: 100, y: 60), cropTo = CGPoint(x: 500, y: 400)
        drag(viewer, page: 0, from: cropFrom, to: cropTo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snapshot(window, "4-crop-sheet")
            say("pressed crop: \(pressSheetButton(window, "Crop Page 1"))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                say("cropped page 1: \(viewer.model.pageBounds[0].size); crop mode \(viewer.pagesView.isCropping)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    for case let view as PageView in viewer.pagesView.subviews where view.page <= 1 {
                        say("view: \(view.debugDescriptionOfTiles)")
                    }
                    say("layout page 0: \(String(describing: viewer.pagesView.layout.frames[0])) bounds \(viewer.model.pageBounds[0]) rev \(viewer.model.revision(page: 0))")
                    snapshot(window, "5-pages")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    snapshot(window, "5b-pages-later")
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.appendingPathComponent("5c-screen.png").path]
                    try? capture.run()
                    capture.waitUntilExit()
                    for case let view as PageView in viewer.pagesView.subviews {
                        say("all: \(view.debugDescriptionOfTiles) sublayers \(view.layer?.sublayers?.map { "\($0.frame.integral)" } ?? [])")
                    }
                    thumbnails.select([1])
                    controller.deletePages(nil)
                    say("deleted the blank page: \(viewer.model.pageCount) pages; undo name: \(document.undoManager?.undoActionName ?? "")")
                    for _ in 0..<6 { document.undoManager?.undo() }
                    say("after undoing 6 page steps: \(titles(viewer)); sizes \(viewer.model.pageBounds.map(\.size))")
                    for _ in 0..<6 { document.undoManager?.redo() }
                    say("after redoing: \(viewer.model.pageCount) pages: \(titles(viewer))")
                    let extract = out.appendingPathComponent("extract.pdf")
                    try? FileManager.default.removeItem(at: extract)
                    do {
                        try viewer.model.engine.extractPages([0, 1], to: extract)
                        say("extracted: \((try? EngineDocument(url: extract).pageCount()) ?? -1) pages")
                    } catch { say("FAIL extract: \(error)") }
                    document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if let url = document.fileURL, let saved = try? EngineDocument(url: url) {
                            say("saved: \((try? saved.pageCount()) ?? -1) pages, sizes \(((try? saved.pageBounds()) ?? []).map(\.size))")
                            let original = try? Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPDF_SELFTEST"]!))
                            let data = try? Data(contentsOf: url)
                            say("incremental: \(original.map { data?.prefix($0.count) == $0 } ?? false)")
                        }
                        snapshot(window, "6-saved")
                        finish()
                    }
                    }
                }
            }
        }
    }

    /// Fills in forms.pdf through the pages view: typing, Tab, clicking
    /// checkboxes and radio buttons, choosing, undo, save.
    static func formSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        let forms = viewer.forms
        func field(_ name: String) -> FormField? { viewer.model.fields(page: 0).first { $0.name == name } }
        func values() -> String {
            ["name", "notes", "zip", "agree", "size", "colour", "fruits"].map { name in
                guard let f = field(name) else { return "\(name)=?" }
                return "\(name)=\(f.kind == .listBox ? f.selected.joined(separator: "+") : f.value)"
            }.joined(separator: " ")
        }
        say("fields: \(viewer.model.fields(page: 0).map { "\($0.name):\($0.kind)\($0.isReadOnly ? "(ro)" : "")" })")
        guard let name = field("name"), let agree = field("agree"),
              let medium = viewer.model.fields(page: 0).first(where: { $0.name == "size" && $0.onState == "M" }) else {
            say("FAIL fields missing")
            return finish()
        }
        click(viewer, page: 0, at: CGPoint(x: name.rect.midX, y: name.rect.midY))
        guard let editor = viewer.pagesView.fieldEditor else {
            say("FAIL no editor after clicking a text field")
            return finish()
        }
        editor.debugType("Grace Hopper")
        editor.debugEnd(.next)
        say("after Tab: editing \(viewer.pagesView.fieldEditor.flatMap { forms.field($0.ref)?.name } ?? "nothing")")
        viewer.pagesView.fieldEditor?.debugType("Line one\nLine two")
        // Pages redraw in the background: snapshots wait for them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        snapshot(window, "forms-1-typing")
        viewer.pagesView.fieldEditor?.finish()
        click(viewer, page: 0, at: CGPoint(x: agree.rect.midX, y: agree.rect.midY))
        click(viewer, page: 0, at: CGPoint(x: medium.rect.midX, y: medium.rect.midY))
        do {
            if let colour = field("colour") { try forms.setText(FieldRef(page: 0, id: colour.id), "b") }
            if let fruits = field("fruits") { try forms.setChoices(FieldRef(page: 0, id: fruits.id), ["Apple", "Cherry"]) }
        } catch { say("FAIL choosing: \(error)") }
        if let locked = field("locked") {
            click(viewer, page: 0, at: CGPoint(x: locked.rect.midX, y: locked.rect.midY))
            say("clicking the read-only field: editor \(viewer.pagesView.fieldEditor == nil ? "none" : "OPEN")")
        }
        say("filled: \(values().replacingOccurrences(of: "\n", with: "|"))")
        say("undo name: \(document.undoManager?.undoActionName ?? "")")
        document.undoManager?.undo()
        say("after undo: \(values())")
        document.undoManager?.redo()
        say("after redo: \(values().replacingOccurrences(of: "\n", with: "|"))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        snapshot(window, "forms-2-filled")
        document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let url = document.fileURL, let saved = try? EngineDocument(url: url) {
                let fields = (try? saved.fields(page: 0)) ?? []
                let named = { (n: String) in fields.first { $0.name == n } }
                say("saved: name=\(named("name")?.value ?? "?") notes=\(named("notes")?.value.replacingOccurrences(of: "\n", with: "|") ?? "?") agree=\(named("agree")?.value ?? "?") size=\(named("size")?.value ?? "?") colour=\(named("colour")?.value ?? "?") fruits=\(named("fruits")?.selected.joined(separator: "+") ?? "?") xfa=\((try? saved.formInfo().hasXFA) ?? true)")
            }
            editSteps(document, controller, viewer, window)
        }
        }
        }
    }

    /// Edits the form's fields: makes one of each kind with the field tools,
    /// moves one, renames it, gives a dropdown choices, deletes one, saves.
    static func editSteps(_ document: EditorDocument, _ controller: DocumentWindowController, _ viewer: ViewerController, _ window: NSWindow) {
        controller.setEditingFields(true)
        let forms = viewer.forms
        let before = viewer.model.fields(page: 0).count
        let places: [(FieldTool, CGPoint)] = [
            (.text, CGPoint(x: 330, y: 330)), (.checkbox, CGPoint(x: 330, y: 380)), (.radio, CGPoint(x: 360, y: 380)),
            (.radio, CGPoint(x: 390, y: 380)), (.dropdown, CGPoint(x: 330, y: 420)), (.listBox, CGPoint(x: 330, y: 460)),
            (.signature, CGPoint(x: 330, y: 540)),
        ]
        for (tool, point) in places {
            viewer.pagesView.fieldTool = tool
            click(viewer, page: 0, at: point)
        }
        let fields = viewer.model.fields(page: 0)
        let made = fields.dropFirst(before)
        say("made: \(made.map { "\($0.name):\($0.kind)" }); tool after: \(viewer.pagesView.fieldTool)")
        say("radio group: \(made.filter { $0.kind == .radio }.map(\.name))")
        if let text = made.first(where: { $0.kind == .text }) {
            viewer.pagesView.fieldTool = .select
            drag(viewer, page: 0, from: CGPoint(x: text.rect.midX, y: text.rect.midY), to: CGPoint(x: text.rect.midX + 40, y: text.rect.midY + 10))
            let moved = forms.field(FieldRef(page: 0, id: text.id))?.rect.origin ?? .zero
            say("moved text field from \(text.rect.origin) to \(moved); selected \(viewer.pagesView.selectedField?.id == text.id)")
            var change = FieldChange()
            change.name = "email"
            change.tooltip = "Email address"
            do { try forms.update(FieldRef(page: 0, id: text.id), actionName: "Rename Field", change) } catch { say("FAIL rename: \(error)") }
            say("inspector shows: \(controller.inspector?.field.view.isHidden == false ? "field" : "nothing")")
        }
        if let dropdown = made.first(where: { $0.kind == .dropdown }) {
            var change = FieldChange()
            change.options = [.init(value: "yes", label: "Yes"), .init(value: "no", label: "No")]
            do { try forms.update(FieldRef(page: 0, id: dropdown.id), actionName: "Change Choices", change) } catch { say("FAIL choices: \(error)") }
        }
        if let signature = made.first(where: { $0.kind == .signature }) {
            viewer.pagesView.selectedField = FieldRef(page: 0, id: signature.id)
            viewer.pagesView.deleteSelectedAnnotation()
        }
        say("after editing: \(viewer.model.fields(page: 0).dropFirst(before).map { "\($0.name):\($0.kind)\($0.options.isEmpty ? "" : "\($0.options.map(\.label))")" })")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            snapshot(window, "forms-3-editing")
            controller.setEditingFields(false)
            document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let url = document.fileURL, let saved = try? EngineDocument(url: url) {
                    let fields = (try? saved.fields(page: 0)) ?? []
                    say("saved fields: \(fields.count); email: \(fields.first { $0.name == "email" }?.tooltip ?? "missing")")
                }
                controller.flattenForm(nil)
                _ = pressSheetButton(window, "Flatten")
                say("after flattening: \(viewer.model.fields(page: 0).count) fields; undo name: \(document.undoManager?.undoActionName ?? "")")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    snapshot(window, "forms-4-flattened")
                    finish()
                }
            }
        }
    }

    /// Edits page content: the document's information, then links drawn with
    /// the Link tool, moved, retargeted and deleted.
    static func contentSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        do {
            try viewer.model.edit("Change Title", pages: []) { try $0.setMetadata(title: "Self test title") }
        } catch { say("FAIL metadata: \(error)") }
        say("title: \(viewer.model.engine.metadata("info:Title") ?? "none")")
        // Select and type, in plain viewing: no mode to turn on first.
        func rect(_ words: String) -> CGRect? {
            let text = viewer.model.text(page: 0)
            return text.search(words).first.flatMap { text.rects(for: $0).first }
        }
        window.makeFirstResponder(viewer.pagesView)
        if let brown = rect("brown") {
            drag(viewer, page: 0, from: CGPoint(x: brown.minX + 0.5, y: brown.midY), to: CGPoint(x: brown.maxX - 0.5, y: brown.midY))
            say("selected before typing: \(viewer.pagesView.selectedText ?? "nothing")")
            viewer.pagesView.insertText("red")
            say("typing over it: editing \(viewer.pagesView.textEditor != nil), Edit Content on \(viewer.pagesView.editingContent)")
            viewer.pagesView.textEditor?.finish()
        }
        controller.setEditingContent(false)
        if let lazy = rect("lazy") {
            click(viewer, page: 0, at: CGPoint(x: lazy.maxX - 0.3, y: lazy.midY))
            say("caret after a click: \(viewer.pagesView.selection?.isEmpty == true)")
            viewer.pagesView.insertText(" old")
            viewer.pagesView.textEditor?.finish()
        }
        controller.setEditingContent(false)
        if let search = rect("Search") {
            drag(viewer, page: 0, from: CGPoint(x: search.minX + 0.5, y: search.midY), to: CGPoint(x: search.maxX - 0.5, y: search.midY))
            viewer.pagesView.deleteBackward(nil)
            viewer.pagesView.textEditor?.finish()
        }
        controller.setEditingContent(false)
        let flat = viewer.model.text(page: 0).string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        say("still left-aligned after editing: \(viewer.model.paragraphs(page: 0)?.paragraphs.first { $0.text.hasPrefix("The quick") }?.alignment == .left)")
        say("after typing: 'quick red fox' \(flat.contains("quick red fox")), 'lazy old dog' \(flat.contains("lazy old dog")), 'Search' gone \(!flat.contains("Search"))")
        viewer.pagesView.selection = nil
        say("with nothing selected, typing goes nowhere (Space scrolls): \(!viewer.pagesView.typeIntoSelection { _ in })")
        controller.setEditingContent(true)
        let before = viewer.model.links(page: 0).count
        viewer.pagesView.contentTool = .link
        drag(viewer, page: 0, from: CGPoint(x: 300, y: 400), to: CGPoint(x: 450, y: 425))
        if let sheet = window.attachedSheet?.contentView {
            func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
            fields(sheet).first { $0.stringValue == "https://" }?.stringValue = "https://example.com/self-test"
        }
        let asked = pressSheetButton(window, "OK")
        let links = viewer.model.links(page: 0)
        say("link sheet: \(asked); links \(before) -> \(links.count); selected \(String(describing: viewer.pagesView.selectedContent))")
        if let made = links.first(where: { $0.id != 0 && abs($0.rect.minX - 300) < 1 }) {
            say("made link: \(made.uri) at \(made.rect.integral)")
            viewer.pagesView.contentTool = .edit
            drag(viewer, page: 0, from: CGPoint(x: made.rect.midX, y: made.rect.midY), to: CGPoint(x: made.rect.midX + 30, y: made.rect.midY + 40))
            let moved = viewer.model.links(page: 0).first { $0.id == made.id }
            say("moved link to \(moved?.rect.integral ?? .zero)")
            do {
                try viewer.content.setTarget(.link(page: 0, id: made.id), .page(2))
            } catch { say("FAIL retarget: \(error)") }
            say("retargeted: page \(viewer.model.links(page: 0).first { $0.id == made.id }?.targetPage ?? -1)")
        }
        // An image: added, dragged, resized keeping its proportions.
        let png = out.appendingPathComponent("picture.png")
        if let context = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            if let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        do {
            let prepared = try ImageImport.prepare(contentsOf: png)
            let ref = try viewer.content.addImage(prepared, page: 0, rect: CGRect(x: 100, y: 500, width: 160, height: 80))
            viewer.pagesView.selectedContent = ref
            if let item = viewer.content.item(ref) {
                drag(viewer, page: 0, from: CGPoint(x: item.rect.midX, y: item.rect.midY), to: CGPoint(x: item.rect.midX + 200, y: item.rect.midY))
            }
            let moved = viewer.content.item(ref)?.rect ?? .zero
            say("image added and moved: \(moved.integral); images on page: \(viewer.model.content(page: 0)?.images.count ?? -1)")
            document.undoManager?.undo()
            document.undoManager?.undo()
            say("after undoing both: \(viewer.model.content(page: 0)?.images.count ?? -1) images")
            document.undoManager?.redo()
            document.undoManager?.redo()
            say("after redoing: \(viewer.content.item(ref)?.rect.integral ?? .zero)")
        } catch { say("FAIL image: \(error)") }
        // Text, as in a word processor: a click in the heading puts the caret
        // there; typing (with a character its font lacks) and clicking away
        // changes it. Then a paragraph grows by a line as it re-wraps, and
        // what follows it stays put.
        viewer.pagesView.contentTool = .edit
        let paragraphs = viewer.model.paragraphs(page: 0)?.paragraphs ?? []
        say("paragraphs on page 1: \(paragraphs.map { $0.text.prefix(20) })")
        if let heading = paragraphs.first(where: { $0.text == "Chapter One" }) {
            click(viewer, page: 0, at: CGPoint(x: heading.rect.maxX - 1, y: heading.rect.midY))
            say("editing after a click: \(viewer.pagesView.textEditor != nil)")
            viewer.pagesView.textEditor?.debugType(", edited Ω")
            viewer.pagesView.textEditor?.finish()
            say("heading now: \(viewer.model.paragraphs(page: 0)?.paragraphs.first { $0.text.hasPrefix("Chapter One") }?.text ?? "?")")
        }
        if let body = viewer.model.paragraphs(page: 0)?.paragraphs.first(where: { $0.text.hasPrefix("The quick brown fox") }),
           let next = viewer.model.paragraphs(page: 0)?.paragraphs.first(where: { $0.text.hasPrefix("Go to page three") }) {
            let dog = viewer.model.text(page: 0)
            if let range = dog.search("lazy dog.").first, let r = dog.rects(for: range).first {
                click(viewer, page: 0, at: CGPoint(x: r.maxX, y: r.midY))
                viewer.pagesView.textEditor?.debugType(" A sentence added here is long enough to make the paragraph wrap onto one more line than it had.")
                viewer.pagesView.textEditor?.finish()
            }
            let after = viewer.model.paragraphs(page: 0)?.paragraphs ?? []
            let grown = after.first { $0.text.hasPrefix("The quick brown fox") }
            let moved = after.first { $0.text.hasPrefix("Go to page three") }
            say("paragraph lines \(body.lines.count) -> \(grown?.lines.count ?? -1); text has the sentence: \(viewer.model.text(page: 0).string.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains("one more line than it had")); next paragraph moved: \(moved.map { abs($0.rect.minY - next.rect.minY) > 0.01 } ?? true)")
            // The editor is still over the page here; the page itself, as drawn:
            snapshot(window, "content-0-paragraph")
            if let image = try? viewer.model.engine.renderPage(0, bounds: viewer.model.pageBounds[0], scale: 1.5),
               let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent("content-0-engine.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            document.undoManager?.undo()
            say("after undo: \(viewer.model.paragraphs(page: 0)?.paragraphs.first { $0.text.hasPrefix("The quick brown fox") }?.lines.count ?? -1) lines")
            document.undoManager?.redo()
            // Bold on one word: it leaves the page's font for a Mac one; the rest stays in it.
            if let para = viewer.model.paragraphs(page: 0)?.paragraphs.first(where: { $0.text.hasPrefix("The quick brown fox") }) {
                click(viewer, page: 0, at: CGPoint(x: para.rect.minX + 2, y: para.lines[0].rect.midY))
                if let editor = viewer.pagesView.textEditor {
                    editor.textView.setSelectedRange(NSRange(location: 4, length: 5))
                    controller.formatBar.debugBold()
                    say("bar shows bold: \(controller.formatBar.debugBoldShown)")
                    editor.finish()
                }
                let page = viewer.model.paragraphs(page: 0)
                if let p = page?.paragraphs.first(where: { $0.text.hasPrefix("The quick brown fox") }), let fonts = page?.fonts {
                    let resource = { (i: Int) in p.characters[i].font.map { fonts[$0].resource } ?? "-" }
                    say("after bold: 'q' in \(resource(4)), 'b' in \(resource(10))")
                }
            }
        }
        // A new text box with Add Text, and a paragraph made narrower with its
        // width handle (it re-wraps; growing, it says it runs into what's below).
        viewer.pagesView.contentTool = .addText
        click(viewer, page: 0, at: CGPoint(x: 300, y: 650))
        viewer.pagesView.textEditor?.debugType("A new text box, typed in place.")
        viewer.pagesView.textEditor?.finish()
        say("new text box: \(viewer.model.text(page: 0).string.contains("A new text box, typed in place."))")
        viewer.pagesView.contentTool = .edit
        if let body = viewer.model.paragraphs(page: 0)?.paragraphs.first(where: { $0.text.hasPrefix("The quick brown fox") }) {
            click(viewer, page: 0, at: CGPoint(x: body.rect.minX + 2, y: body.lines[0].rect.midY))
            if let editor = viewer.pagesView.textEditor {
                editor.setWidth(body.rect.width * 0.6)
                say("narrower box overlaps other text: \(editor.debugOverlaps)")
                editor.finish()
            }
            let narrower = viewer.model.paragraphs(page: 0)?.paragraphs.first { $0.text.hasPrefix("The quick brown fox") }
            say("narrower paragraph: \(body.lines.count) -> \(narrower?.lines.count ?? -1) lines, width \(Int(body.rect.width)) -> \(Int(narrower?.rect.width ?? 0))")
        }
        // Edit Text from the right-click menu, starting from plain viewing.
        controller.setEditingContent(false)
        if let next = viewer.model.paragraphs(page: 0)?.paragraphs.first(where: { $0.text.hasPrefix("Go to page") }),
           let t = viewer.pagesView.transform(forPage: 0) {
            let location = viewer.pagesView.convert(CGPoint(x: next.rect.midX, y: next.rect.midY).applying(t), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let item = viewer.pagesView.menu(for: event)?.items.first { $0.title == "Edit Text" }
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            say("Edit Text in the menu: \(item != nil); editing content: \(viewer.pagesView.editingContent); caret in it: \(viewer.pagesView.textEditor?.paragraph?.text.hasPrefix("Go to page") == true)")
            viewer.pagesView.textEditor?.finish()
        }
        // Page numbers and a watermark, through the sheets.
        controller.addPageNumbers(nil)
        let numbered = pressSheetButton(window, "Add")
        controller.addWatermark(nil)
        let marked = pressSheetButton(window, "Add")
        let texts = (0..<viewer.model.pageCount).map { viewer.model.text(page: $0).string }
        say("stamps: sheets \(numbered) \(marked); page 2 has \"Page 2 of 3\": \(texts[1].contains("Page 2 of 3")); DRAFT on every page: \(texts.allSatisfy { $0.contains("DRAFT") })")
        // A caret after a click in plain viewing, as people see it.
        controller.setEditingContent(false)
        if let fox = viewer.model.text(page: 0).search("jumps").first.flatMap({ viewer.model.text(page: 0).rects(for: $0).first }) {
            click(viewer, page: 0, at: CGPoint(x: fox.minX, y: fox.midY))
        }
        window.makeFirstResponder(viewer.pagesView)
        // Before the caret's first blink (every 0.55 s) hides it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        let caretCapture = Process()
        caretCapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        caretCapture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.appendingPathComponent("content-3-caret.png").path]
        try? caretCapture.run()
        caretCapture.waitUntilExit()
        say("caret on screen: \(viewer.pagesView.selection?.isEmpty == true)")
        // The window as people see it while editing: the bar, a box with a selection.
        controller.setEditingContent(true)
        if let heading = viewer.model.paragraphs(page: 0)?.paragraphs.first(where: { $0.text.hasPrefix("Chapter One") }) {
            click(viewer, page: 0, at: CGPoint(x: heading.rect.minX + 4, y: heading.rect.midY))
            viewer.pagesView.textEditor?.textView.setSelectedRange(NSRange(location: 8, length: 3))
            say("bar font: \(controller.formatBar.debugFamily)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.appendingPathComponent("content-2-screen.png").path]
            try? capture.run()
            capture.waitUntilExit()
            viewer.pagesView.textEditor?.finish()
            snapshot(window, "content-1-links")
            controller.removeWatermarks(nil)
            say("after removing watermarks: \((0..<viewer.model.pageCount).contains { viewer.model.text(page: $0).string.contains("DRAFT") } ? "some left" : "none"); numbers kept: \(viewer.model.text(page: 0).string.contains("Page 1 of 3"))")
            document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let url = document.fileURL, let saved = try? EngineDocument(url: url) {
                    say("saved: title \(saved.metadata("info:Title") ?? "none"), links \((try? saved.links(page: 0).count) ?? -1)")
                }
                finish()
            }
        }
        }
    }

    /// Saving by hand (Settings › Save changes automatically off): an edit
    /// leaves the document marked changed until File › Save.
    static func manualSaveSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        say("autosaves: \(EditorDocument.autosavesInPlace)")
        let note = try? viewer.annotations.createNote(page: 0, at: CGPoint(x: 400, y: 200))
        say("note made: \(note != nil); edited: \(document.isDocumentEdited); window shows it: \(window.isDocumentEdited)")
        if let file = NSApp.mainMenu?.item(withTitle: "File")?.submenu {
            FileMenuDelegate.shared.menuNeedsUpdate(file)
            let shown = file.items.filter { !$0.isHidden && $0.tag >= FileMenuDelegate.manualTag }.map(\.title)
            say("File menu saving items: \(shown)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let onDisk = (try? EngineDocument(url: document.fileURL!).annotations(page: 0).count) ?? -1
            say("annotations on disk before saving: \(onDisk); edited: \(document.isDocumentEdited); window shows it: \(window.isDocumentEdited)")
            document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let saved = (try? EngineDocument(url: document.fileURL!).annotations(page: 0).count) ?? -1
                say("after File › Save: on disk \(saved); edited: \(document.isDocumentEdited)")
                finish()
            }
        }
    }

    /// File › Security…: an owner password that keeps copying and editing
    /// back; then the saved file opened again, restricted, and unlocked.
    static func securitySteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
        }
        controller.showSecurity(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let sheet = window.attachedSheet?.contentView else { say("FAIL no Security sheet"); return finish() }
            let boxes = Dictionary(views(sheet, NSButton.self).map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
            let secure = views(sheet, NSSecureTextField.self)
            say("sheet: open password \(boxes["Require a password to open the document"]?.state == .on), restricted \(boxes["Require a password to change security and to:"]?.state == .on), fields \(secure.count)")
            boxes["Require a password to change security and to:"]?.state = .on
            boxes["Copy text and images"]?.state = .off
            boxes["Edit content and pages"]?.state = .off
            secure[2].stringValue = "owner"
            secure[3].stringValue = "owner"
            _ = pressSheetButton(window, "Apply")
            let engine = document.engine!
            say("applied: encrypted \(engine.isEncrypted), owner \(engine.isOwner), grants \(engine.ownerAllowedToUser.rawValue), undo \(document.undoManager?.canUndo == true)")
            document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let url = document.fileURL!
                let reopened = try? EngineDocument(url: url)
                say("on disk: needs password \(reopened?.needsPassword == true), owner \(reopened?.isOwner == true), allowed \(reopened?.allowed.rawValue ?? -1)")
                document.close()
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { again, _, _ in
                    guard let again = again as? EditorDocument else { say("FAIL reopen"); return finish() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard let controller = again.windowControllers.first as? DocumentWindowController,
                              let viewer = controller.viewer, let window = controller.window else { say("FAIL no viewer"); return finish() }
                        let editItem = NSMenuItem(title: "", action: #selector(DocumentWindowController.toggleEditContent(_:)), keyEquivalent: "")
                        say("restricted: banner \(controller.restrictionAccessory?.isHidden == false) “\(controller.restrictionLabel?.stringValue ?? "")”, edit allowed \(viewer.model.allows(.edit)), Edit Content enabled \(controller.validateMenuItem(editItem)), annotate \(viewer.model.allows(.annotate))")
                        snapshot(window, "restricted")
                        controller.enterOwnerPassword(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            guard let sheet = window.attachedSheet?.contentView, let field = views(sheet, NSSecureTextField.self).first else {
                                say("FAIL no password sheet")
                                return finish()
                            }
                            field.stringValue = "owner"
                            _ = pressSheetButton(window, "OK")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                say("owner: banner \(controller.restrictionAccessory?.isHidden == false), edit allowed \(viewer.model.allows(.edit)), Edit Content enabled \(controller.validateMenuItem(editItem))")
                                finish()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Clicking a signature field offers to sign it; then signing with the
    /// corpus's test identity (kept in memory), saving, and the inspector's
    /// account of the signature.
    static func signSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window,
              let field = viewer.model.fields(page: 0).first(where: { $0.kind == .signature }) else {
            say("FAIL no signature field")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        // The Signature tool with nothing saved opens Signatures…
        viewer.tool = .signature
        say("Signatures… after choosing the tool with none saved: \(window.attachedSheet != nil)")
        _ = pressSheetButton(window, "Done")
        // A signature drawn on the pad, saved and placed.
        let pad = SignaturePad(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        pad.strokes = [[CGPoint(x: 20, y: 100), CGPoint(x: 70, y: 40), CGPoint(x: 120, y: 110), CGPoint(x: 170, y: 50), CGPoint(x: 260, y: 90)],
                       [CGPoint(x: 200, y: 30), CGPoint(x: 210, y: 120)]]
        guard let png = pad.png(), (try? SavedSignatures.add(name: "Self test", image: png)) != nil else {
            say("FAIL drawn signature not saved")
            return finish()
        }
        viewer.tool = .signature
        click(viewer, page: 0, at: CGPoint(x: 450, y: 120))
        let stamps = viewer.model.annotations(page: 0).filter { $0.kind == .stamp }
        say("signature stamps placed: \(stamps.count), size \(stamps.first.map { "\(Int($0.rect.width))×\(Int($0.rect.height))" } ?? "-"); tool after: \(viewer.tool.rawValue)")
        viewer.tool = .select
        click(viewer, page: 0, at: CGPoint(x: field.rect.midX, y: field.rect.midY))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            say("sheet after clicking the field: \(window.attachedSheet != nil)")
            _ = pressSheetButton(window, "Cancel") || pressSheetButton(window, "OK")
            guard #available(macOS 15, *), let p12 = ProcessInfo.processInfo.environment["OPDF_SELFTEST_P12"],
                  let data = try? Data(contentsOf: URL(fileURLWithPath: p12)) else {
                say("FAIL no test identity")
                return finish()
            }
            let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
            var items: CFArray?
            guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
                  let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String] else {
                say("FAIL test identity not imported")
                return finish()
            }
            do {
                try document.sign(field, identity: identity as! SecIdentity, reason: "Self test", location: "",
                                  picture: SavedSignatures.chosen?.image)
                controller.updateRestrictionBanner()
                controller.saveRewritten(document)
            } catch {
                say("FAIL signing: \(error)")
                return finish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                snapshot(window, "signed")
                let shown = controller.inspector?.signatures.signatures.map { SignaturesViewController.describe($0) } ?? []
                say("inspector: \(shown)")
                let onDisk = (try? EngineDocument(url: document.fileURL!).signatures()) ?? []
                say("on disk: \(onDisk.map { "\($0.integrity) \($0.trust) changedAfter \($0.changedAfter)" }); edited \(document.isDocumentEdited)")
                finish()
            }
        }
    }

    /// The Redact tool on text and on an area, then Tools › Apply
    /// Redactions… through its alert: the text is gone from the saved file,
    /// and so are its earlier versions.
    static func redactSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        let text = viewer.model.text(page: 0)
        guard let fox = text.search("quick brown fox").first, let r = text.rects(for: fox).first,
              let visit = text.search("Visit example.com").first, let v = text.rects(for: visit).first else {
            say("FAIL no text to redact")
            return finish()
        }
        viewer.tool = .redact
        drag(viewer, page: 0, from: CGPoint(x: r.minX + 1, y: r.midY), to: CGPoint(x: r.maxX - 1, y: r.midY))
        // An area: from the margin left of the line, across it.
        drag(viewer, page: 0, from: CGPoint(x: v.minX - 20, y: v.minY - 4), to: CGPoint(x: v.maxX + 10, y: v.maxY + 4))
        let marks = (try? document.engine!.annotations(page: 0))?.filter { $0.kind == .redact } ?? []
        say("marks: \(marks.count) (text \(marks.filter { !$0.quads.isEmpty }.count)); tool after: \(viewer.tool.rawValue)")
        // Saved once, so the file has a version from before.
        document.save(withDelegate: nil, didSave: nil, contextInfo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            snapshot(window, "marked")
            let url = document.fileURL!
            say("versions before: \(NSFileVersion.otherVersionsOfItem(at: url)?.count ?? 0)")
            controller.applyRedactions(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                say("alert: \(window.attachedSheet != nil)")
                _ = pressSheetButton(window, "Apply Redactions")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    snapshot(window, "redacted")
                    let page = viewer.model.text(page: 0).string
                    say("in the window: quick \(page.contains("quick")), example.com \(page.contains("example.com")), lazy dog \(page.contains("lazy dog")); marks left \(controller.redactionMarkCount()); undo \(document.undoManager?.canUndo == true); edited \(document.isDocumentEdited)")
                    let saved = (try? EngineDocument(url: url).text(page: 0).string) ?? ""
                    say("on disk: quick \(saved.contains("quick")), lazy dog \(saved.contains("lazy dog")); versions after: \(NSFileVersion.otherVersionsOfItem(at: url)?.count ?? 0)")
                    finish()
                }
            }
        }
    }

    /// A scanned document: the notice, Tools › Recognise Text… through its
    /// sheet, then finding, selecting and copying a recognised word, undo and
    /// redo, and the text in the saved file.
    static func ocrSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        say("notice on a scan: \(controller.scanAccessory?.isHidden == false)")
        snapshot(window, "scan-notice")
        controller.recognizeText(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            say("sheet: \(window.attachedSheet != nil)")
            _ = pressSheetButton(window, "Recognise")
            waitForRecognition(document, controller, viewer, window, started: Date())
        }
    }

    static func waitForRecognition(_ document: EditorDocument, _ controller: DocumentWindowController, _ viewer: ViewerController,
                                   _ window: NSWindow, started: Date) {
        let seconds = Date().timeIntervalSince(started)
        guard viewer.model.text(page: 0).string.contains("brown") || seconds > 60 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForRecognition(document, controller, viewer, window, started: started) }
            return
        }
        do {
            let pages = (0..<viewer.model.pageCount).map { viewer.model.text(page: $0).search("quick brown fox").count }
            say(String(format: "recognised in %.0fs: “quick brown fox” on pages %@; notice now %@", seconds, "\(pages)",
                       controller.scanAccessory?.isHidden == false ? "shown" : "hidden"))
            say("page 4 “Page 5” count: \(viewer.model.text(page: 4).search("Page 5").count); undo \(document.undoManager?.undoActionName ?? "-")")
            viewer.find.search("brown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                say("Find “brown”: \(viewer.find.matches.count) matches")
                let text = viewer.model.text(page: 0)
                guard let word = text.search("brown").first, let r = text.rects(for: word).first else {
                    say("FAIL no word to select")
                    return finish()
                }
                viewer.tool = .select
                drag(viewer, page: 0, from: CGPoint(x: r.minX + 0.5, y: r.midY), to: CGPoint(x: r.maxX - 0.5, y: r.midY))
                say("selected: “\(viewer.pagesView.selectedText ?? "")”")
                snapshot(window, "ocr-selection")
                document.undoManager?.undo()
                let afterUndo = viewer.model.text(page: 0).string.contains("brown")
                document.undoManager?.redo()
                say("after undo: \(afterUndo); after redo: \(viewer.model.text(page: 0).string.contains("brown"))")
                // Once the autosave the undo started has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { document.save(withDelegate: nil, didSave: nil, contextInfo: nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let saved = try? EngineDocument(url: document.fileURL!)
                    say("on disk: “quick brown fox” \((try? saved?.text(page: 0).search("quick brown fox").count) ?? -1), invisible \((try? saved?.textInfo(page: 0).invisibleCharacters) ?? -1)")
                    finish()
                }
            }
        }
    }

    /// File › Export… to each format (through the same code as the panel),
    /// numbered images into new folders, never over earlier ones, and the
    /// menu item on a document that doesn't allow copying.
    static func exportSteps(_ document: EditorDocument) {
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 860), display: true)
        // An unsaved change, which the export includes.
        _ = try? viewer.model.edit("Stamp", pages: [0]) { try $0.addStamps([Stamp(page: 0, kind: .footer, text: "Unsaved footer")]) }
        let item = NSMenuItem(title: "", action: #selector(DocumentWindowController.exportDocument(_:)), keyEquivalent: "")
        say("Export… enabled: \(controller.validateMenuItem(item))")
        controller.exportDocument(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let panel = window.attachedSheet as? NSSavePanel
            say("panel: \(panel != nil), name \(panel?.nameFieldStringValue ?? "-")")
            if let options = panel?.accessoryView { snapshot(view: options, "export-options") }
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            let folder = out.appendingPathComponent("exported")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let jobs: [ExportJob] = [
                ExportJob(format: .word, pages: 0...2, name: "doc.docx"), ExportJob(format: .html, pages: 0...2, name: "doc.html"),
                ExportJob(format: .text, pages: 0...2, name: "doc.txt"), ExportJob(format: .png, pages: 0...0, name: "one.png"),
                ExportJob(format: .jpeg, pages: 1...1, name: "one.jpg"), ExportJob(format: .tiff, pages: 0...2, name: "all.tiff"),
                ExportJob(format: .png, pages: 0...2, name: "pages.png"), ExportJob(format: .png, pages: 0...2, name: "pages.png"),
            ]
            runExports(jobs, document, controller, viewer, folder)
        }
    }

    struct ExportJob: Sendable {
        var format: ExportFormat
        var pages: ClosedRange<Int>
        var name: String
    }

    static func runExports(_ jobs: [ExportJob], _ document: EditorDocument, _ controller: DocumentWindowController,
                           _ viewer: ViewerController, _ folder: URL) {
        guard let job = jobs.first else { return exportsDone(folder) }
        let choice = ExportOptions.Choice(format: job.format, pages: job.pages, dpi: 100, quality: 0.85)
        controller.export(document, viewer: viewer, choice, to: folder.appendingPathComponent(job.name)) { result in
            switch result {
            case let .success(url): say("\(job.format.rawValue) \(job.pages): \(url.lastPathComponent)")
            case let .failure(error): say("FAIL \(job.format.rawValue): \(error)")
            }
            runExports(Array(jobs.dropFirst()), document, controller, viewer, folder)
        }
    }

    static func exportsDone(_ folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        say("files: \(names)")
        let inner = ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("pages").path)) ?? []).sorted()
        say("in pages: \(inner)")
        let text = (try? String(contentsOf: folder.appendingPathComponent("doc.txt"), encoding: .utf8)) ?? ""
        say("text: fox \(text.contains("quick brown fox")), unsaved footer \(text.contains("Unsaved footer"))")
        let corpus = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPDF_SELFTEST"]!).deletingLastPathComponent()
        NSDocumentController.shared.openDocument(withContentsOf: corpus.appendingPathComponent("restricted.pdf"), display: true) { other, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let item = NSMenuItem(title: "", action: #selector(DocumentWindowController.exportDocument(_:)), keyEquivalent: "")
                let restricted = (other as? EditorDocument)?.windowControllers.first as? DocumentWindowController
                say("restricted: Export… enabled \(restricted?.validateMenuItem(item) ?? true)")
                finish()
            }
        }
    }

    /// The welcome window, then New PDF from it.
    static func welcomeSteps() {
        WelcomeWindowController.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = NSApp.windows.first(where: { $0.windowController is WelcomeWindowController }) else {
                say("FAIL no welcome window")
                return finish()
            }
            snapshot(window, "welcome")
            func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            say("welcome buttons: \(buttons(window.contentView!).map(\.title))")
            buttons(window.contentView!).first { $0.title == "New PDF" }?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let documents = NSDocumentController.shared.documents.compactMap { $0 as? EditorDocument }
                say("documents: \(documents.count); welcome open: \(NSApp.windows.contains { $0.windowController is WelcomeWindowController && $0.isVisible })")
                if let document = documents.first, let model = document.model {
                    say("new document: \(document.displayName ?? "") untitled \(document.fileURL == nil) pages \(model.pageCount) size \(model.pageBounds.first?.size ?? .zero) editable \(model.isEditable)")
                    if let window = document.windowControllers.first?.window { snapshot(window, "new-pdf") }
                }
                finish()
            }
        }
    }

    /// A click through the pages view, as the mouse would.
    static func click(_ viewer: ViewerController, page: Int, at point: CGPoint) {
        let view = viewer.pagesView
        guard let window = view.window, let t = view.transform(forPage: page) else { return }
        let location = view.convert(point.applying(t), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    /// Sends a mouse drag through the pages view, as the mouse would.
    static func drag(_ viewer: ViewerController, page: Int, from: CGPoint, to: CGPoint) {
        let view = viewer.pagesView
        guard let window = view.window, let t = view.transform(forPage: page) else { return }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            let location = view.convert(p.applying(t), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, from))
        for i in 1...5 {
            let f = CGFloat(i) / 5
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)))
        }
        view.mouseUp(with: event(.leftMouseUp, to))
    }

    /// The window's layers rendered to a PNG.
    static func snapshot(_ window: NSWindow, _ name: String) {
        guard let frameView = window.contentView?.superview, let layer = frameView.layer else { return }
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        say("snapshot \(name)")
    }

    /// One view drawn to a PNG (for views in windows that can't be captured,
    /// like a save panel's).
    static func snapshot(view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        say("snapshot \(name)")
    }

    static func finish() {
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
#endif
