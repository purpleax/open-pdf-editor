import AppKit
import PDFCore

/// The window shown when the app starts (or is reopened from the Dock)
/// with no documents: the app's icon and name, and a choice between making
/// a new PDF and opening one.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private static var shown: WelcomeWindowController?

    static func show() {
        let controller = shown ?? WelcomeWindowController()
        shown = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Closes the window once a document is open.
    static func dismiss() {
        shown?.close()
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Open PDF Editor"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        window.title = "Welcome to \(name)"

        let logo = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([logo.widthAnchor.constraint(equalToConstant: 128), logo.heightAnchor.constraint(equalToConstant: 128)])
        logo.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let subtitle = NSTextField(labelWithString: version.isEmpty ? "" : "Version \(version)")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor

        let newButton = Self.button("New PDF", symbol: "doc.badge.plus", action: #selector(newPDF(_:)), target: self)
        newButton.keyEquivalent = "\r"
        let openButton = Self.button("Open…", symbol: "folder", action: #selector(openPDF(_:)), target: self)
        let guideButton = Self.button("Guide", symbol: "book", action: #selector(openGuide(_:)), target: self)
        let buttons = NSStackView(views: [newButton, openButton, guideButton])
        buttons.spacing = 12
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [logo, title, subtitle, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(16, after: logo)
        stack.setCustomSpacing(28, after: subtitle)
        buttons.widthAnchor.constraint(equalToConstant: 390).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -36),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -48),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func button(_ title: String, symbol: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: target, action: action)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.controlSize = .large
        return button
    }

    @objc private func newPDF(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newBlankPDF(sender)
    }

    @objc private func openPDF(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }

    @objc private func openGuide(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showGuide(sender)
    }

    func windowWillClose(_ notification: Notification) {
        Self.shown = nil
    }
}
