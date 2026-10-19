import AppKit
import ImageIO
import PDFCore
import Security

/// A handwritten signature or its picture, kept to be placed on documents.
struct SavedSignature: Equatable {
    let id: String
    let name: String
    /// PNG (drawn, on transparent) or JPEG (imported).
    let image: Data

    /// Pixels, for its proportions.
    var pixelSize: CGSize {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return CGSize(width: 3, height: 1) }
        return CGSize(width: width, height: height)
    }
}

protocol SignatureStore {
    func all() -> [SavedSignature]
    func add(_ signature: SavedSignature) throws
    func delete(id: String) throws
}

/// Saved signatures, in the login keychain: private to this app (macOS asks
/// before any other app reads them) and kept out of files and backups in the clear.
@MainActor
enum SavedSignatures {
    static let didChange = Notification.Name("SavedSignaturesDidChange")
    /// The self-test swaps in a store in memory.
    static var store: SignatureStore = KeychainSignatureStore()
    private static let chosenKey = "ChosenSignature"

    static var all: [SavedSignature] { store.all() }

    /// The one the Signature tool places (the first, if none was chosen).
    static var chosen: SavedSignature? {
        let all = self.all
        let id = UserDefaults.standard.string(forKey: chosenKey)
        return all.first { $0.id == id } ?? all.first
    }

    static func choose(_ id: String) {
        UserDefaults.standard.set(id, forKey: chosenKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    @discardableResult
    static func add(name: String, image: Data) throws -> SavedSignature {
        let signature = SavedSignature(id: UUID().uuidString, name: name, image: image)
        try store.add(signature)
        choose(signature.id)
        return signature
    }

    static func delete(_ id: String) throws {
        try store.delete(id: id)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

struct KeychainSignatureStore: SignatureStore {
    static let service = "com.purpleax.openpdfeditor.signature"
    /// Signatures are small; anything larger isn't one of ours.
    static let maxBytes = 4 << 20

    func all() -> [SavedSignature] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        // The file-based keychain returns data one item at a time.
        return items.sorted { ($0[kSecAttrCreationDate as String] as? Date ?? .distantPast) < ($1[kSecAttrCreationDate as String] as? Date ?? .distantPast) }
            .compactMap { attributes -> SavedSignature? in
                guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
                let name = (attributes[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "Signature"
                let one: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: Self.service,
                    kSecAttrAccount as String: account,
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var data: CFTypeRef?
                guard SecItemCopyMatching(one as CFDictionary, &data) == errSecSuccess, let image = data as? Data,
                      image.count <= Self.maxBytes else { return nil }
                return SavedSignature(id: account, name: name, image: image)
            }
    }

    func add(_ signature: SavedSignature) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: signature.id,
            kSecAttrLabel as String: "Open PDF Editor signature: \(signature.name)",
            kSecAttrDescription as String: "Signature picture",
            kSecAttrGeneric as String: Data(signature.name.utf8),
            kSecValueData as String: signature.image,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.failure("The signature couldn’t be saved in your keychain.", status) }
    }

    func delete(id: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure("The signature couldn’t be deleted from your keychain.", status)
        }
    }

    private static func failure(_ message: String, _ status: OSStatus) -> NSError {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: message, NSLocalizedFailureReasonErrorKey: reason,
        ])
    }
}

/// Kept in memory only (the self-test).
final class MemorySignatureStore: SignatureStore {
    private var items: [SavedSignature] = []
    func all() -> [SavedSignature] { items }
    func add(_ signature: SavedSignature) throws { items.append(signature) }
    func delete(id: String) throws { items.removeAll { $0.id == id } }
}

/// A pad to sign on with the mouse or trackpad: strokes in black, made into
/// a PNG on transparent at twice the pad's size.
final class SignaturePad: NSView {
    var strokes: [[CGPoint]] = []
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 20, y: bounds.height - 30))
        line.line(to: CGPoint(x: bounds.width - 20, y: bounds.height - 30))
        line.stroke()
        NSColor.textColor.setStroke()
        for stroke in strokes { path(stroke).stroke() }
    }

    private func path(_ stroke: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 2.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = stroke.first else { return path }
        path.move(to: first)
        if stroke.count == 1 { path.line(to: CGPoint(x: first.x + 0.5, y: first.y)) }
        for p in stroke.dropFirst() { path.line(to: p) }
        return path
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
        onChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        strokes[strokes.count - 1].append(p)
        needsDisplay = true
    }

    func clear() {
        strokes = []
        needsDisplay = true
        onChange?()
    }

    /// The strokes as a PNG, cropped to them with a small margin.
    func png() -> Data? {
        let points = strokes.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let area = CGRect(x: xs.min()! - 6, y: ys.min()! - 6, width: xs.max()! - xs.min()! + 12, height: ys.max()! - ys.min()! + 12)
        let scale: CGFloat = 2
        guard let context = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Flipped, as the pad is.
        context.translateBy(x: 0, y: area.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            context.move(to: first)
            if stroke.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.5, y: first.y)) }
            for p in stroke.dropFirst() { context.addLine(to: p) }
            context.strokePath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension SavedSignatures {
    /// A picture of a signature from a file, read with ImageIO, upright, at
    /// most 1200 pixels across, as PNG (keeping transparency).
    nonisolated static func importPicture(contentsOf url: URL) throws -> Data {
        func failure(_ message: String) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0, bytes <= ImageImport.maxBytes else { throw failure("That image file is empty or larger than 100 MB.") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= ImageImport.maxPixels else {
            throw failure("That file isn’t an image this app can read, or it has more than 40 megapixels.")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), 1200),
        ]
        let data = NSMutableData()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw failure("That image couldn’t be read.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= KeychainSignatureStore.maxBytes else {
            throw failure("That image couldn’t be converted.")
        }
        return data as Data
    }
}

/// Tools › Signatures…: the saved signatures, to choose one, draw or import
/// another, or delete one.
@MainActor
final class SignatureManager: NSObject {
    private static var open: SignatureManager?
    private let window: NSWindow
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
    private let popup = NSPopUpButton()
    private let preview = NSImageView()
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var signatures: [SavedSignature] = []

    static func present(on window: NSWindow) {
        guard open == nil else { return }
        let manager = SignatureManager(window: window)
        open = manager
        manager.show()
    }

    private init(window: NSWindow) {
        self.window = window
        super.init()
    }

    private func show() {
        let title = NSTextField(labelWithString: "Signatures")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let note = NSTextField(wrappingLabelWithString: "The Signature tool places the chosen one. Signatures are kept in your keychain.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        popup.target = self
        popup.action = #selector(chosen(_:))
        preview.imageScaling = .scaleProportionallyDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.white.cgColor
        preview.layer?.cornerRadius = 4
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 420).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let draw = NSButton(title: "Draw New…", target: self, action: #selector(drawNew(_:)))
        let picture = NSButton(title: "Import Picture…", target: self, action: #selector(importPicture(_:)))
        deleteButton.target = self
        deleteButton.action = #selector(deleteChosen(_:))
        let done = NSButton(title: "Done", target: self, action: #selector(close(_:)))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [draw, picture, deleteButton, NSView(), done])
        let stack = NSStackView(views: [title, note, popup, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        popup.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        reload()
        window.beginSheet(panel)
    }

    private func reload() {
        signatures = SavedSignatures.all
        popup.removeAllItems()
        if signatures.isEmpty { popup.addItem(withTitle: "No signatures yet") }
        for s in signatures { popup.addItem(withTitle: s.name) }
        let chosen = SavedSignatures.chosen
        if let chosen, let index = signatures.firstIndex(of: chosen) { popup.selectItem(at: index) }
        popup.isEnabled = !signatures.isEmpty
        deleteButton.isEnabled = !signatures.isEmpty
        preview.image = chosen.flatMap { NSImage(data: $0.image) }
    }

    @objc private func chosen(_ sender: NSPopUpButton) {
        guard signatures.indices.contains(sender.indexOfSelectedItem) else { return }
        SavedSignatures.choose(signatures[sender.indexOfSelectedItem].id)
        reload()
    }

    @objc private func deleteChosen(_ sender: Any?) {
        guard let chosen = SavedSignatures.chosen else { return }
        do { try SavedSignatures.delete(chosen.id) } catch { NSAlert(error: error).beginSheetModal(for: panel) }
        reload()
    }

    @objc private func close(_ sender: Any?) {
        window.endSheet(panel)
        Self.open = nil
    }

    private func save(name: String, image: Data) {
        do {
            try SavedSignatures.add(name: name.isEmpty ? "Signature \(signatures.count + 1)" : name, image: image)
        } catch {
            NSAlert(error: error).beginSheetModal(for: panel)
        }
        reload()
    }

    @objc private func importPicture(_ sender: Any?) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.message = "Choose a picture of your signature (best on a white or transparent background)."
        open.beginSheetModal(for: panel) { [weak self] response in
            guard response == .OK, let url = open.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try SavedSignatures.importPicture(contentsOf: url) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch result {
                        case let .success(data): self.save(name: url.deletingPathExtension().lastPathComponent, image: data)
                        case let .failure(error): NSAlert(error: error).beginSheetModal(for: self.panel)
                        }
                    }
                }
            }
        }
    }

    @objc private func drawNew(_ sender: Any?) {
        let pad = SignaturePad(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 420).isActive = true
        pad.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let name = NSTextField()
        name.placeholderString = "Name"
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled], backing: .buffered, defer: true)
        let save = ClosureButton(title: "Save") { [weak self] in
            guard let self, let png = pad.png() else { return }
            self.panel.endSheet(sheet)
            self.save(name: name.stringValue, image: png)
        }
        save.keyEquivalent = "\r"
        save.isEnabled = false
        pad.onChange = { [weak save] in save?.isEnabled = !pad.strokes.isEmpty }
        let clear = ClosureButton(title: "Clear") { pad.clear() }
        let cancel = ClosureButton(title: "Cancel") { [weak self] in self?.panel.endSheet(sheet) }
        cancel.keyEquivalent = "\u{1b}"
        let hint = NSTextField(labelWithString: "Sign above the line with your mouse or trackpad.")
        hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [clear, NSView(), cancel, save])
        let stack = NSStackView(views: [hint, pad, name, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: pad.widthAnchor).isActive = true
        name.widthAnchor.constraint(equalTo: pad.widthAnchor).isActive = true
        sheet.contentView = stack
        sheet.setContentSize(stack.fittingSize)
        sheet.initialFirstResponder = pad
        panel.beginSheet(sheet)
    }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private final class Action: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func run() { body() }
    }
    private var handler: Action?

    convenience init(title: String, _ body: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        let handler = Action(body)
        self.handler = handler
        target = handler
        action = #selector(Action.run)
    }
}
