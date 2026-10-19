import AppKit
import PDFCore

/// Tools › Recognise Text…: finding the words in scanned pages, on this Mac
/// with Apple's Vision, so they can be searched, selected and copied; and
/// the notice shown on a page that is a scan.
extension DocumentWindowController {
    // MARK: Scan notice

    func setUpScanNotice() {
        guard scanAccessory == nil, let window else { return }
        let label = NSTextField(labelWithString: "This page is a scanned image: its text can’t be searched or copied yet.")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: "Recognise Text…", target: self, action: #selector(recognizeText(_:)))
        button.controlSize = .small
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(),
                             target: self, action: #selector(dismissScanNotice(_:)))
        close.isBordered = false
        close.controlSize = .small
        close.toolTip = "Don’t show this again for this document"
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text.viewfinder", accessibilityDescription: nil) ?? NSImage())
        let stack = NSStackView(views: [icon, label, button, close])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.heightAnchor.constraint(equalToConstant: 28),
        ])
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(label.stringValue)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = root
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)
        scanAccessory = accessory
    }

    /// Shows the notice when the current page is a scan (worked out off the
    /// main thread, once per page version), and the document can be changed.
    func updateScanNotice() {
        guard let viewer, let accessory = scanAccessory else { return }
        let model = viewer.model, page = viewer.currentPage
        guard !scanNoticeDismissed, model.allows(.edit), model.engine.isPDF, page < model.pageCount else {
            accessory.isHidden = true
            lastScanCheck = nil
            return
        }
        let revision = model.revision(page: page)
        if let last = lastScanCheck, last.page == page, last.revision == revision { return }
        lastScanCheck = (page, revision)
        EngineExecutor.background.async(.low) { [weak self] in
            let isScan = model.textInfo(page: page)?.isScan == true
            DispatchQueue.main.async {
                guard let self, let viewer = self.viewer, viewer.currentPage == page,
                      self.lastScanCheck?.page == page, self.lastScanCheck?.revision == revision else { return }
                self.scanAccessory?.isHidden = !(isScan && !self.scanNoticeDismissed && viewer.model.allows(.edit))
            }
        }
    }

    @objc func dismissScanNotice(_ sender: Any?) {
        scanNoticeDismissed = true
        scanAccessory?.isHidden = true
    }

    // MARK: Recognise Text

    private enum PageChoice: Int {
        case withoutText, all, current, range
    }

    @objc func recognizeText(_ sender: Any?) {
        guard let viewer, let window, window.attachedSheet == nil else { return }
        let count = viewer.model.pageCount
        let withoutText = NSButton(radioButtonWithTitle: "Pages without text", target: nil, action: nil)
        withoutText.state = .on
        let all = NSButton(radioButtonWithTitle: "All pages (replacing text recognised before)", target: nil, action: nil)
        let current = NSButton(radioButtonWithTitle: "This page (\(viewer.currentPage + 1))", target: nil, action: nil)
        let range = NSButton(radioButtonWithTitle: "Pages", target: nil, action: nil)
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: max(count, 1))
        formatter.allowsFloats = false
        let from = NSTextField(string: "1"), to = NSTextField(string: "\(count)")
        for field in [from, to] {
            field.formatter = formatter
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        let rangeRow = NSStackView(views: [range, from, NSTextField(labelWithString: "to"), to])
        rangeRow.spacing = 6
        let group = RadioGroup(buttons: [withoutText, all, current, range])

        let languages = NSPopUpButton(frame: .zero, pullsDown: false)
        languages.addItem(withTitle: "Automatic")
        languages.menu?.addItem(.separator())
        let codes = TextRecognizer.supportedLanguages()
        for code in codes {
            languages.addItem(withTitle: Locale.current.localizedString(forIdentifier: code) ?? code)
            languages.lastItem?.representedObject = code
        }
        let languageRow = NSStackView(views: [NSTextField(labelWithString: "Language:"), languages])
        languageRow.spacing = 6

        var views: [NSView] = [withoutText, all, current, rangeRow, languageRow]
        if (try? viewer.model.engine.formInfo().isSigned) == true {
            let warning = NSTextField(wrappingLabelWithString:
                "This document is signed. Adding text changes it after signing, which its signatures will show.")
            warning.textColor = .systemOrange
            warning.preferredMaxLayoutWidth = 320
            views.append(warning)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: rangeRow)
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Recognise text in scanned pages?"
        alert.informativeText = "The words found are added to the pages invisibly, under the scan, so they can be searched, selected and copied. Recognition happens on this Mac."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Recognise")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            _ = group
            guard let self, response == .alertFirstButtonReturn, let viewer = self.viewer else { return }
            let pageCount = viewer.model.pageCount
            let pages: [Int]
            var onlyWithoutText = false
            if all.state == .on {
                pages = Array(0..<pageCount)
            } else if current.state == .on {
                pages = [min(viewer.currentPage, pageCount - 1)]
            } else if range.state == .on {
                let a = max(1, min(from.integerValue, pageCount)), b = max(1, min(to.integerValue, pageCount))
                pages = Array((min(a, b) - 1)..<max(a, b))
            } else {
                pages = Array(0..<pageCount)
                onlyWithoutText = true
            }
            let language = languages.selectedItem?.representedObject as? String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.recognize(pages: pages, onlyWithoutText: onlyWithoutText, languages: language.map { [$0] } ?? [])
                }
            }
        }
    }

    /// Reads the pages in the background with a progress sheet, then puts
    /// what was found on them as one undoable change.
    func recognize(pages: [Int], onlyWithoutText: Bool, languages: [String], then: (@MainActor @Sendable (Result<Int, Error>) -> Void)? = nil) {
        guard let viewer, let window, !pages.isEmpty else { return }
        let model = viewer.model
        let changes = model.changes
        let cancel = RecognitionCancel()
        let progress = ProgressSheet.show(on: window, message: onlyWithoutText ? "Looking for pages without text…" : "Recognising text…",
                                          total: pages.count, onCancel: { cancel.cancel() })
        EngineExecutor.conversion.async {
            let result: Result<[RecognizedPage], Error> = Result {
                var found: [RecognizedPage] = []
                for (done, page) in pages.enumerated() {
                    if cancel.isCancelled { throw CancellationError() }
                    guard let bounds = model.bounds(page: page) else { continue }
                    if onlyWithoutText, model.textInfo(page: page)?.lacksText != true { continue }
                    DispatchQueue.main.async {
                        progress?.update(done: done, message: "Recognising text on page \(page + 1)…")
                    }
                    found.append(try TextRecognizer.recognize(model.engine, page: page, bounds: bounds,
                                                              languages: languages, cancel: cancel))
                }
                return found
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    progress?.close()
                    self?.finishRecognizing(result, changes: changes, onlyWithoutText: onlyWithoutText, then: then)
                }
            }
        }
    }

    private func finishRecognizing(_ result: Result<[RecognizedPage], Error>, changes: Int, onlyWithoutText: Bool,
                                   then: (@MainActor @Sendable (Result<Int, Error>) -> Void)?) {
        guard let viewer else { return }
        let outcome: Result<Int, Error> = Result {
            let found = try result.get()
            guard viewer.model.changes == changes else {
                throw EngineError(code: -1, message: "The document changed while its text was being recognised. Recognise Text again to include the changes.")
            }
            if found.isEmpty { return 0 }
            return try viewer.model.edit("Recognise Text", pages: Set(found.map(\.page))) { try $0.setTextLayers(found) }
        }
        lastScanCheck = nil
        updateScanNotice()
        if let then { return then(outcome) }
        switch outcome {
        case let .success(words) where words == 0:
            viewer.pages.present(message: onlyWithoutText && (try? result.get())?.isEmpty == true
                                    ? "Every page already has text." : "No text was found.",
                                 info: onlyWithoutText ? "To read pages that have some text too, choose All pages." : "")
        case .success:
            break
        case let .failure(error):
            if error is CancellationError { return }
            viewer.pages.present(error, message: "The text couldn’t be recognised.")
        }
    }
}
