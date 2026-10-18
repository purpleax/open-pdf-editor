import AppKit
import PDFCore

/// Shown in the window of a locked PDF until the right password is entered.
@MainActor
final class PasswordViewController: NSViewController {
    private let engine: EngineDocument
    private let name: String
    private let onUnlock: (String) -> Void
    private let field = NSSecureTextField()
    private let message = NSTextField(labelWithString: "")

    init(engine: EngineDocument, name: String, onUnlock: @escaping (String) -> Void) {
        self.engine = engine
        self.name = name
        self.onUnlock = onUnlock
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.doc", accessibilityDescription: "Locked document")!)
        icon.symbolConfiguration = .init(pointSize: 48, weight: .light)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "“\(name)” is password protected.")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)
        let hint = NSTextField(labelWithString: "Enter the password to open it.")
        hint.textColor = .secondaryLabelColor
        field.placeholderString = "Password"
        field.target = self
        field.action = #selector(unlock(_:))
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        field.setAccessibilityLabel("Password")
        let button = NSButton(title: "Open", target: self, action: #selector(unlock(_:)))
        button.keyEquivalent = "\r"
        message.textColor = .systemRed
        message.isHidden = true
        let row = NSStackView(views: [field, button])
        row.spacing = 8
        let stack = NSStackView(views: [icon, title, hint, row, message])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(18, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -40),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func unlock(_ sender: Any?) {
        let password = field.stringValue
        if engine.authenticate(password: password) {
            onUnlock(password)
        } else {
            message.stringValue = "The password is incorrect."
            message.isHidden = false
            field.selectText(nil)
            NSAccessibility.post(element: message, notification: .announcementRequested,
                                 userInfo: [.announcement: "The password is incorrect.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
            view.window?.shake()
        }
    }
}

extension NSWindow {
    /// The standard "wrong password" shake.
    func shake() {
        let frame = self.frame
        let animation = CAKeyframeAnimation()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: frame.minX, y: frame.minY))
        for i in 0..<3 {
            path.addLine(to: CGPoint(x: frame.minX - 8, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.minX + 8, y: frame.minY))
            if i == 2 { path.addLine(to: CGPoint(x: frame.minX, y: frame.minY)) }
        }
        animation.path = path
        animation.duration = 0.35
        animations = ["frameOrigin": animation]
        animator().setFrameOrigin(frame.origin)
    }
}
