import AppKit
import PDFCore

/// The markup bar under the toolbar: tools, colour, line width, text size
/// and stamp. Shown and hidden with View › Show Markup Toolbar (⇧⌘A).
@MainActor
final class MarkupBarViewController: NSViewController {
    private let tools = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stampPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let signaturePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var signatureIDs: [String] = []
    private(set) var tool = AnnotationTool.select

    /// Called when the user picks a tool.
    var onToolChosen: ((AnnotationTool) -> Void)?
    var onManageSignatures: (() -> Void)?

    static let widths: [CGFloat] = [1, 2, 3, 4, 6, 8, 12]
    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 16, 18, 24, 36]

    override func loadView() {
        tools.segmentCount = AnnotationTool.allCases.count
        tools.trackingMode = .selectOne
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: index)
            tools.setToolTip(tool.title, forSegment: index)
            tools.setWidth(30, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(toolClicked(_:))
        tools.setAccessibilityLabel("Markup tools")

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.setAccessibilityLabel("Colour")
        colorWell.toolTip = "Colour"

        for width in Self.widths { widthPopup.addItem(withTitle: "\(Int(width)) pt") }
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.toolTip = "Line width"
        widthPopup.controlSize = .small

        for size in Self.sizes { sizePopup.addItem(withTitle: "\(Int(size)) pt") }
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))
        sizePopup.toolTip = "Text size"
        sizePopup.controlSize = .small

        for stamp in StandardStamp.allCases {
            stampPopup.addItem(withTitle: stamp.title)
            stampPopup.lastItem?.representedObject = stamp.rawValue
        }
        stampPopup.target = self
        stampPopup.action = #selector(stampChanged(_:))
        stampPopup.toolTip = "Stamp"
        stampPopup.controlSize = .small

        signaturePopup.target = self
        signaturePopup.action = #selector(signatureChanged(_:))
        signaturePopup.toolTip = "Signature"
        signaturePopup.controlSize = .small
        NotificationCenter.default.addObserver(forName: SavedSignatures.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSignatures() }
        }

        let stack = NSStackView(views: [tools, colorWell, widthPopup, sizePopup, stampPopup, signaturePopup])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.heightAnchor.constraint(equalToConstant: 34),
        ])
        root.setAccessibilityRole(.toolbar)
        root.setAccessibilityLabel("Markup")
        view = root
        setTool(.select)
    }

    /// Shows a tool as chosen (from the bar, the Tools menu or the viewer).
    func setTool(_ tool: AnnotationTool) {
        self.tool = tool
        guard isViewLoaded else { return }
        tools.selectedSegment = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
        colorWell.isEnabled = tool.usesColor
        colorWell.color = ToolSettings.color(for: tool).nsColor
        widthPopup.isHidden = !tool.usesLineWidth
        if let index = Self.widths.firstIndex(of: ToolSettings.lineWidth(for: tool)) { widthPopup.selectItem(at: index) }
        sizePopup.isHidden = tool != .textBox
        if let index = Self.sizes.firstIndex(of: ToolSettings.textSize) { sizePopup.selectItem(at: index) }
        stampPopup.isHidden = tool != .stamp
        stampPopup.selectItem(withTitle: ToolSettings.stamp.title)
        signaturePopup.isHidden = tool != .signature
        if tool == .signature { reloadSignatures() }
    }

    /// The saved signatures (read from the keychain only while the tool is chosen).
    private func reloadSignatures() {
        guard isViewLoaded, tool == .signature else { return }
        let all = SavedSignatures.all
        signatureIDs = all.map(\.id)
        signaturePopup.removeAllItems()
        for saved in all { signaturePopup.addItem(withTitle: saved.name) }
        if !all.isEmpty { signaturePopup.menu?.addItem(.separator()) }
        signaturePopup.addItem(withTitle: "Manage Signatures…")
        if let chosen = SavedSignatures.chosen, let index = signatureIDs.firstIndex(of: chosen.id) { signaturePopup.selectItem(at: index) }
    }

    @objc private func signatureChanged(_ sender: NSPopUpButton) {
        if signatureIDs.indices.contains(sender.indexOfSelectedItem) {
            SavedSignatures.choose(signatureIDs[sender.indexOfSelectedItem])
        } else {
            reloadSignatures()
            onManageSignatures?()
        }
    }

    @objc private func toolClicked(_ sender: NSSegmentedControl) {
        let tool = AnnotationTool.allCases[sender.selectedSegment]
        setTool(tool)
        onToolChosen?(tool)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        ToolSettings.setColor(PDFColor(sender.color), for: tool)
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        ToolSettings.setLineWidth(Self.widths[sender.indexOfSelectedItem], for: tool)
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        ToolSettings.textSize = Self.sizes[sender.indexOfSelectedItem]
    }

    @objc private func stampChanged(_ sender: NSPopUpButton) {
        if let name = sender.selectedItem?.representedObject as? String, let stamp = StandardStamp(rawValue: name) {
            ToolSettings.stamp = stamp
        }
    }
}
