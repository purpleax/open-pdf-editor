import AppKit
import PDFCore

/// Asks where a link goes: a web or email address, or a page.
@MainActor
enum LinkTargetSheet {
    static func ask(on window: NSWindow, pageCount: Int, current: PageLink?, title: String,
                    completion: @escaping (LinkTarget?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Web addresses start with https:// or http://, and email addresses with mailto:."
        let web = NSButton(radioButtonWithTitle: "Web or email address", target: nil, action: nil)
        let page = NSButton(radioButtonWithTitle: "Page", target: nil, action: nil)
        let address = NSTextField(string: current.flatMap { $0.isExternal ? $0.uri : nil } ?? "https://")
        address.placeholderString = "https://example.com"
        let number = NSTextField(string: current?.targetPage.map { "\($0 + 1)" } ?? "1")
        number.formatter = {
            let f = NumberFormatter()
            f.minimum = 1
            f.maximum = NSNumber(value: max(pageCount, 1))
            f.allowsFloats = false
            return f
        }()
        let onPage = current?.targetPage != nil
        web.state = onPage ? .off : .on
        page.state = onPage ? .on : .off
        let toggle = RadioGroup(web: web, page: page, address: address, number: number)
        web.target = toggle
        web.action = #selector(RadioGroup.changed(_:))
        page.target = toggle
        page.action = #selector(RadioGroup.changed(_:))
        toggle.changed(nil)
        let ofPages = NSTextField(labelWithString: "of \(pageCount)")
        let pageRow = NSStackView(views: [page, number, ofPages])
        number.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let stack = NSStackView(views: [web, address, pageRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        address.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 90)
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = onPage ? number : address
        alert.beginSheetModal(for: window) { response in
            _ = toggle
            guard response == .alertFirstButtonReturn else { return completion(nil) }
            if page.state == .on {
                completion(.page(max(1, min(pageCount, number.integerValue)) - 1))
            } else {
                completion(.web(address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    private final class RadioGroup: NSObject {
        let web, page: NSButton
        let address, number: NSTextField
        init(web: NSButton, page: NSButton, address: NSTextField, number: NSTextField) {
            self.web = web
            self.page = page
            self.address = address
            self.number = number
        }

        @MainActor @objc func changed(_ sender: Any?) {
            if (sender as? NSButton) === web { page.state = .off }
            if (sender as? NSButton) === page { web.state = .off }
            address.isEnabled = web.state == .on
            number.isEnabled = page.state == .on
        }
    }
}
