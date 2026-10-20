#if SELFTEST
import AppKit
import PDFCore

/// The user guide's screenshots (`make guide-images`): the sample document
/// and a few corpus files, in light mode at a fixed size, through the same
/// code the mouse and menus use. Each picture is written to OPDF_SELFTEST_OUT
/// under the name the guide uses.
extension SelfTest {
    typealias Step = @MainActor (@escaping @MainActor () -> Void) -> Void

    static let guideFrame = NSRect(x: 80, y: 80, width: 1100, height: 760)

    static func guideSteps(_ document: EditorDocument) {
        NSApp.appearance = NSAppearance(named: .aqua)
        guard let controller = document.windowControllers.first as? DocumentWindowController,
              let viewer = controller.viewer, let window = controller.window else {
            say("FAIL no viewer")
            return finish()
        }
        window.setFrame(guideFrame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        ToolSettings.authorOverride = "Ada Lovelace"
        // The markup bar starts hidden (it is remembered between runs).
        let markupItem = NSMenuItem(title: "", action: #selector(DocumentWindowController.toggleMarkupBar(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(markupItem)
        if markupItem.state == .on { controller.toggleMarkupBar(nil) }
        let corpus = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OPDF_SELFTEST"]!).deletingLastPathComponent()
        let a = viewer.annotations

        let steps: [Step] = [
            // The window: thumbnails and the inspector.
            { next in
                controller.showThumbnails(nil)
                if controller.inspectorItem?.isCollapsed == true { controller.showDocumentInfo(nil) }
                later { shot(window, "window"); next() }
            },
            { next in
                controller.sidebar?.thumbnails.select([0, 1])
                later { shot(window, "thumbnails"); controller.sidebar?.thumbnails.select([0]); next() }
            },
            // Markup and comments.
            { next in
                controller.toggleMarkupBar(nil)
                let text = viewer.model.text(page: 0)
                do {
                    if let range = text.search("six raised beds").first {
                        _ = try a.markText(.highlight, selection: TextSelection(anchor: TextPosition(page: 0, caret: range.lowerBound),
                                                                              focus: TextPosition(page: 0, caret: range.upperBound)))
                    }
                    if let range = text.search("Thank you to everyone").first {
                        _ = try a.markText(.underline, selection: TextSelection(anchor: TextPosition(page: 0, caret: range.lowerBound),
                                                                              focus: TextPosition(page: 0, caret: range.upperBound)))
                    }
                    let note = try a.createNote(page: 0, at: CGPoint(x: 500, y: 150))
                    try a.update(note, actionName: "Edit Text") { $0.contents = "Can we add the new members' names?" }
                    _ = try a.createShape(.oval, page: 0, from: CGPoint(x: 370, y: 590), to: CGPoint(x: 460, y: 650))
                    _ = try a.createShape(.arrow, page: 0, from: CGPoint(x: 500, y: 560), to: CGPoint(x: 455, y: 600))
                } catch {
                    say("FAIL markup: \(error)")
                }
                viewer.tool = .highlight
                later { shot(window, "markup"); next() }
            },
            { next in
                viewer.tool = .select
                if let highlight = viewer.model.annotations(page: 0).first(where: { $0.kind == .highlight }) {
                    let ref = AnnotationRef(page: 0, id: highlight.id)
                    try? a.reply(to: ref, text: "Yes, and the rainwater store too.")
                    try? a.setStatus(ref, "Accepted")
                    viewer.reveal(ref)
                }
                controller.showComments(nil)
                later { shot(window, "comments"); next() }
            },
            { next in
                undoAll(document)
                controller.toggleMarkupBar(nil)
                controller.showThumbnails(nil)
                next()
            },
            // Forms: filling in, then Edit Fields.
            { next in
                viewer.go(toPage: 1)
                let fields = viewer.model.fields(page: 1)
                func ref(_ name: String) -> FieldRef? { fields.first { $0.name == name }.map { FieldRef(page: 1, id: $0.id) } }
                try? ref("name").map { try viewer.forms.setText($0, "Ada Lovelace") }
                try? ref("email").map { try viewer.forms.setText($0, "ada@example.com") }
                if let agree = fields.first(where: { $0.name == "agree" }) {
                    click(viewer, page: 1, at: CGPoint(x: agree.rect.midX, y: agree.rect.midY))
                }
                viewer.pagesView.highlightsFields = true
                later { shot(window, "form-fill"); next() }
            },
            { next in
                controller.setEditingFields(true)
                if let email = viewer.model.fields(page: 1).first(where: { $0.name == "email" }) {
                    click(viewer, page: 1, at: CGPoint(x: email.rect.midX, y: email.rect.midY))
                }
                later { shot(window, "edit-fields"); controller.setEditingFields(false); undoAll(document); next() }
            },
            // Editing a paragraph, with the formatting bar.
            { next in
                viewer.go(toPage: 0)
                controller.setEditingContent(true, showInspector: false)
                let text = viewer.model.text(page: 0)
                if let range = text.search("tool shed,").first, let r = text.rects(for: range).last {
                    click(viewer, page: 0, at: CGPoint(x: r.maxX - 1, y: r.midY))
                    viewer.pagesView.textEditor?.debugType(" a bench")
                }
                later { shot(window, "edit-text"); viewer.pagesView.textEditor?.finish(); controller.setEditingContent(false); undoAll(document); next() }
            },
            // Redaction marks.
            { next in
                viewer.tool = .redact
                let text = viewer.model.text(page: 0)
                for phrase in ["forty new members", "rainwater store"] {
                    if let range = text.search(phrase).first, let r = text.rects(for: range).first {
                        drag(viewer, page: 0, from: CGPoint(x: r.minX + 1, y: r.midY), to: CGPoint(x: r.maxX - 1, y: r.midY))
                    }
                }
                viewer.tool = .select
                later { shot(window, "redact"); undoAll(document); next() }
            },
            // Saved signatures.
            { next in
                let pad = SignaturePad(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
                pad.strokes = [[CGPoint(x: 20, y: 90), CGPoint(x: 60, y: 40), CGPoint(x: 100, y: 110), CGPoint(x: 150, y: 50),
                                CGPoint(x: 200, y: 100), CGPoint(x: 260, y: 60), CGPoint(x: 330, y: 85)]]
                if let png = pad.png() { _ = try? SavedSignatures.add(name: "Ada Lovelace", image: png) }
                controller.manageSignatures(nil)
                later {
                    if let sheet = window.attachedSheet { shot(sheet, "sign-sheet") } else { say("FAIL no Signatures sheet") }
                    _ = pressSheetButton(window, "Done")
                    next()
                }
            },
            // Export options.
            { next in
                controller.exportDocument(nil)
                later {
                    if let options = (window.attachedSheet as? NSSavePanel)?.accessoryView {
                        snapshot(view: options, "export-options")
                    } else {
                        say("FAIL no export panel")
                    }
                    if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
                    next()
                }
            },
            // Settings.
            { next in
                // As they start out (off), put back afterwards. (The self-test
                // app has a bundle identifier of its own, so these are never
                // the installed app's settings.)
                let saved = (Settings.savesAutomatically, Settings.opensWebLinks, Settings.convertsDocuments, Settings.checksCertificatesOnline)
                Settings.savesAutomatically = false
                Settings.opensWebLinks = false
                Settings.convertsDocuments = false
                Settings.checksCertificatesOnline = false
                SettingsWindowController.shared.showWindow(nil)
                later {
                    if let settings = SettingsWindowController.shared.window { shot(settings, "settings") }
                    SettingsWindowController.shared.close()
                    (Settings.savesAutomatically, Settings.opensWebLinks, Settings.convertsDocuments, Settings.checksCertificatesOnline) = saved
                    next()
                }
            },
            // Signing the form's signature field, then the other documents
            // on their own.
            { next in
                guard let field = viewer.model.fields(page: 1).first(where: { $0.kind == .signature }),
                      #available(macOS 15, *), let identity = testIdentity() else {
                    say("FAIL no signature field or identity")
                    return next()
                }
                do {
                    try document.sign(field, identity: identity, reason: "Membership approved", location: "Harbour Gardens",
                                      picture: SavedSignatures.chosen?.image)
                    controller.updateRestrictionBanner()
                } catch {
                    say("FAIL signing: \(error)")
                }
                viewer.go(toPage: 1)
                if controller.inspectorItem?.isCollapsed == true { controller.showDocumentInfo(nil) }
                later(2) { shot(window, "signatures"); document.close(); next() }
            },
            { next in
                open(corpus.appendingPathComponent("restricted.pdf"), copyAs: "Restricted.pdf") { other, otherWindow in
                    other.inspectorItem?.isCollapsed = true
                    later { shot(otherWindow, "restricted"); otherWindow.close(); next() }
                }
            },
            { next in
                open(corpus.appendingPathComponent("scanned.pdf"), copyAs: "Scanned Letter.pdf") { other, otherWindow in
                    later {
                        shot(otherWindow, "scan-notice")
                        other.recognizeText(nil)
                        later {
                            if let sheet = otherWindow.attachedSheet { shot(sheet, "recognise") } else { say("FAIL no Recognise Text sheet") }
                            _ = pressSheetButton(otherWindow, "Cancel")
                            otherWindow.close()
                            next()
                        }
                    }
                }
            },
            // Help › Open PDF Editor Guide: a copy in Caches, bookmarks showing;
            // asking again brings the same window back.
            { next in
                let delegate = NSApp.delegate as? AppDelegate
                delegate?.showGuide(nil)
                later(2) {
                    let guides = NSDocumentController.shared.documents.filter { $0.fileURL?.lastPathComponent == "Open PDF Editor Guide.pdf" }
                    let url = guides.first?.fileURL
                    let inCaches = url?.path.contains("/Library/Caches/") == true
                    let inBundle = url.map { $0.path.hasPrefix(Bundle.main.bundlePath) } ?? false
                    let controller = guides.first?.windowControllers.first as? DocumentWindowController
                    say("guide: open \(guides.count), in caches \(inCaches), in app \(inBundle), outline \(controller?.sidebar?.tab == .outline), pages \(controller?.viewer?.model.pageCount ?? 0)")
                    delegate?.showGuide(nil)
                    later {
                        let again = NSDocumentController.shared.documents.filter { $0.fileURL?.lastPathComponent == "Open PDF Editor Guide.pdf" }.count
                        say("guide asked for again: \(again) open")
                        if guides.count != 1 || !inCaches || inBundle || again != 1 { say("FAIL guide") }
                        next()
                    }
                }
            },
            // The welcome window, with no documents open.
            { next in
                for document in NSDocumentController.shared.documents { document.close() }
                WelcomeWindowController.show()
                later {
                    if let welcome = NSApp.windows.first(where: { $0.windowController is WelcomeWindowController }) {
                        // Without its version, which would date the guide.
                        func labels(_ view: NSView) -> [NSTextField] {
                            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(labels)
                        }
                        for label in labels(welcome.contentView ?? NSView()) where label.stringValue.hasPrefix("Version ") {
                            label.stringValue = " "
                        }
                        shot(welcome, "welcome")
                    } else {
                        say("FAIL no welcome window")
                    }
                    next()
                }
            },
        ]
        run(steps)
    }

    private static func run(_ steps: [Step]) {
        guard let first = steps.first else { return finish() }
        first { run(Array(steps.dropFirst())) }
    }

    /// After pages have had time to draw.
    private static func later(_ seconds: Double = 1.5, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
    }

    private static func undoAll(_ document: EditorDocument) {
        while document.undoManager?.canUndo == true { document.undoManager?.undo() }
    }

    /// A window drawn at 1.5× (sharp in print, smaller than 2×).
    private static func shot(_ window: NSWindow, _ name: String) {
        guard let frameView = window.contentView?.superview, let layer = frameView.layer else { return say("FAIL no layer for \(name)") }
        let scale: CGFloat = 1.5
        let size = frameView.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: out.appendingPathComponent(name + ".png"))
        say("snapshot \(name)")
    }

    /// Opens a copy of a corpus file in a window of the guide's size.
    private static func open(_ url: URL, copyAs name: String,
                             then: @escaping @MainActor (DocumentWindowController, NSWindow) -> Void) {
        let copy = out.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: url, to: copy)
        NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { document, _, error in
            MainActor.assumeIsolated {
                guard let controller = document?.windowControllers.first as? DocumentWindowController, let window = controller.window else {
                    say("FAIL open \(name): \(String(describing: error))")
                    return finish()
                }
                window.setFrame(guideFrame, display: true)
                later { then(controller, window) }
            }
        }
    }

    /// The corpus's signing identity, kept in memory (never the keychain).
    @available(macOS 15, *)
    private static func testIdentity() -> SecIdentity? {
        guard let p12 = ProcessInfo.processInfo.environment["OPDF_SELFTEST_P12"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: p12)) else { return nil }
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first, let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }
}
#endif
