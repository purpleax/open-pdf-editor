import AppKit
import PDFCore
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle: checks the appcast (SUFeedURL in Info.plist) and installs
    /// updates signed with the key in SUPublicEDKey. Only when asked
    /// (Check for Updates…): never automatically, even where an earlier
    /// version saved a yes to Sparkle's "check automatically?" question.
    let updaterController: SPUStandardUpdaterController = {
        UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
        UserDefaults.standard.set(false, forKey: "SUAutomaticallyUpdate")
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
    private var acknowledgements: NSWindowController?
    static let website = URL(string: "https://github.com/purpleax/open-pdf-editor")!

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(updater: updaterController)
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    // When the app starts (or is reopened from the Dock) with no documents,
    // the welcome window offers a new PDF or opening one.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        #if SELFTEST
        let environment = ProcessInfo.processInfo.environment
        if environment["OPDF_SELFTEST"] != nil || environment["OPDF_SELFTEST_WELCOME"] != nil { return false }
        #endif
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if SELFTEST
        SelfTest.run()
        #endif
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        WelcomeWindowController.show()
        return true
    }

    /// File › New: an untitled PDF of one blank page (Letter in the US and
    /// Canada, A4 elsewhere), saved wherever it's first saved to.
    @objc func newBlankPDF(_ sender: Any?) {
        let letter = ["US", "CA"].contains(Locale.current.region?.identifier ?? "")
        let size = letter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-new-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("Untitled.pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try PDFFiles.writeBlank(to: url, pageSize: size)
            let controller = NSDocumentController.shared
            let document = try controller.makeDocument(for: nil, withContentsOf: url, ofType: "com.adobe.pdf")
            // Untouched, it closes without asking to be saved.
            document.updateChangeCount(.changeCleared)
            controller.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The tab bar's + button: there are no new PDFs to make yet, so it opens one.
    @objc func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Free software under the GNU Affero General Public License 3.0.\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "Source code", attributes: [
            .link: Self.website, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ]))
        credits.append(NSAttributedString(
            string: "\nBuilt on MuPDF \(EngineDocument.mupdfVersion) and Sparkle. See Help › Acknowledgements.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        if acknowledgements == nil {
            let text = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The acknowledgements are missing from this build."
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Acknowledgements"
            window.isReleasedWhenClosed = false
            let scroll = NSTextView.scrollableTextView()
            if let textView = scroll.documentView as? NSTextView {
                textView.isEditable = false
                textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                textView.string = text
                textView.textContainerInset = NSSize(width: 12, height: 12)
            }
            window.contentView = scroll
            window.center()
            acknowledgements = NSWindowController(window: window)
        }
        acknowledgements?.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(Self.website)
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = NSDocumentController.shared.currentDocument?.fileURL else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Makes one PDF of PDFs, images and other documents, in name order,
    /// saves it and opens it.
    @objc func createPDFFromFiles(_ sender: Any?) {
        let open = NSOpenPanel()
        open.allowsMultipleSelection = true
        open.allowedContentTypes = PageEditor.insertableTypes
        open.message = Settings.convertsDocuments
            ? "Choose PDFs, images or other documents. They are combined in name order."
            : "Choose PDFs or images. They are combined in name order. (Other documents can be turned on in Settings.)"
        open.prompt = "Choose"
        guard open.runModal() == .OK, !open.urls.isEmpty else { return }
        let allowDocuments = Settings.convertsDocuments
        let files = open.urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let save = NSSavePanel()
        save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = files.count == 1
            ? files[0].deletingPathExtension().lastPathComponent + ".pdf"
            : "Combined.pdf"
        guard save.runModal() == .OK, let url = save.url else { return }
        let cancel = ConversionCancel()
        let progress = ProgressSheet.show(on: nil, message: files.count == 1 ? "Converting…" : "Combining \(files.count) files…",
                                          cancel: cancel)
        EngineExecutor.conversion.async {
            let result = Result { try PageEditor.writeReplacing(url) { try PDFFiles.combine(files, into: $0, allowDocuments: allowDocuments, cancel: cancel) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    progress?.close()
                    switch result {
                    case .success:
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    case let .failure(error):
                        if (error as? EngineError)?.message == "Cancelled" { return }
                        let alert = NSAlert()
                        alert.messageText = "The PDF couldn’t be made."
                        alert.informativeText = "\(error)"
                        alert.runModal()
                    }
                }
            }
        }
    }
}
