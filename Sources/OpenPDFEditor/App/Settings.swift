import AppKit

/// The Settings window's switches: features that add a security risk, each
/// off until turned on (ROADMAP.md, Decisions: Risky features), and saving.
enum Settings {
    private static let openWebLinksKey = "OpenWebLinks"
    private static let convertDocumentsKey = "ConvertDocuments"
    private static let autosaveKey = "AutosaveDocuments"

    /// Documents save themselves as they change (macOS autosave, with
    /// Versions); off, they are saved with File › Save, and closing asks.
    /// Read from any thread (NSDocument asks from its own).
    nonisolated static var savesAutomatically: Bool {
        get { UserDefaults.standard.bool(forKey: autosaveKey) }
        set { UserDefaults.standard.set(newValue, forKey: autosaveKey) }
    }

    /// Clicking a web or email link in a page or bookmark opens it.
    static var opensWebLinks: Bool {
        get { UserDefaults.standard.bool(forKey: openWebLinksKey) }
        set { UserDefaults.standard.set(newValue, forKey: openWebLinksKey) }
    }

    /// Create PDF from Files and Insert Pages read HTML, SVG, EPUB, XPS, text
    /// and Office files, not only PDFs and images.
    static var convertsDocuments: Bool {
        get { UserDefaults.standard.bool(forKey: convertDocumentsKey) }
        set { UserDefaults.standard.set(newValue, forKey: convertDocumentsKey) }
    }
}

/// Web and email links from a PDF: only http, https and mailto, and only
/// opened when Settings allows it.
@MainActor
enum WebLinks {
    /// The link's address, if it is a kind that could ever be opened.
    static func url(_ uri: String) -> URL? {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    static func open(_ uri: String, from window: NSWindow?) {
        guard let url = url(uri) else {
            NSSound.beep()
            return
        }
        if Settings.opensWebLinks {
            NSWorkspace.shared.open(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Opening links is turned off."
        alert.informativeText = "This link goes to \(url.absoluteString)\n\nLinks in a PDF go wherever its author chose. You can turn on opening web and email links in Settings."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings…")
        let respond = { (response: NSApplication.ModalResponse) in
            if response == .alertSecondButtonReturn { SettingsWindowController.shared.showWindow(nil) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}

/// The Settings window (⌘,): a checkbox per risky feature, each with a line
/// saying what it exposes.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let links = NSButton(checkboxWithTitle: "Open web and email links", target: nil, action: nil)
    private let documents = NSButton(checkboxWithTitle: "Convert other documents into PDFs", target: nil, action: nil)
    private let autosave = NSButton(checkboxWithTitle: "Save changes automatically", target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        links.target = self
        links.action = #selector(toggle(_:))
        documents.target = self
        documents.action = #selector(toggle(_:))
        autosave.target = self
        autosave.action = #selector(toggle(_:))
        let stack = NSStackView(views: [
            autosave,
            Self.note("Documents save themselves as you work, and File › Revert To shows earlier versions. Off, changes are kept only when you choose File › Save, and closing a changed document asks first."),
            links,
            Self.note("Clicking a link in a page or bookmark opens the web page or email address its author chose."),
            documents,
            Self.note("Create PDF from Files and Insert Pages can read HTML, SVG, EPUB, XPS, text, Word, Excel and PowerPoint files. Reading these formats gives a harmful file more of the app to attack. PDFs and images always work."),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(16, after: stack.views[1])
        stack.setCustomSpacing(16, after: stack.views[3])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func showWindow(_ sender: Any?) {
        reload()
        super.showWindow(sender)
    }

    private func reload() {
        autosave.state = Settings.savesAutomatically ? .on : .off
        links.state = Settings.opensWebLinks ? .on : .off
        documents.state = Settings.convertsDocuments ? .on : .off
    }

    @objc private func toggle(_ sender: NSButton) {
        if sender === links { Settings.opensWebLinks = sender.state == .on }
        if sender === documents { Settings.convertsDocuments = sender.state == .on }
        if sender === autosave { Settings.savesAutomatically = sender.state == .on }
    }

    /// A line under a checkbox, in line with its title rather than its box.
    private static func note(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let indented = NSView()
        indented.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: indented.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: indented.trailingAnchor),
            label.topAnchor.constraint(equalTo: indented.topAnchor),
            label.bottomAnchor.constraint(equalTo: indented.bottomAnchor),
            label.widthAnchor.constraint(equalToConstant: 400),
        ])
        return indented
    }
}
