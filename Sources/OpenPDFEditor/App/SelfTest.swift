#if SELFTEST
import AppKit
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
        guard let source = ProcessInfo.processInfo.environment["OPDF_SELFTEST"],
              let outPath = ProcessInfo.processInfo.environment["OPDF_SELFTEST_OUT"] else { return }
        out = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let copy = out.appendingPathComponent("selftest.pdf")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { document, _, error in
            guard let document = document as? EditorDocument else {
                say("FAIL open: \(String(describing: error))")
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { steps(document) }
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
                        finish()
                    }
                }
            }
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

    static func finish() {
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
#endif
