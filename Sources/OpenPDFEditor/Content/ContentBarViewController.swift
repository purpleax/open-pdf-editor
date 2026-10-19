import AppKit

/// The content bar under the toolbar while editing page content
/// (Edit › Edit Content): the content tools, and Done.
@MainActor
final class ContentBarViewController: NSViewController {
    private let tools = NSSegmentedControl()
    private let done = NSButton(title: "Done", target: nil, action: nil)

    var onToolChosen: ((ContentTool) -> Void)?
    var onDone: (() -> Void)?
    /// The text formatting controls, between the tools and Done.
    var formatControls: NSView?

    override func loadView() {
        tools.segmentCount = ContentTool.allCases.count
        tools.trackingMode = .selectOne
        for (index, tool) in ContentTool.allCases.enumerated() {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: index)
            tools.setToolTip(tool.title, forSegment: index)
            tools.setWidth(30, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(toolClicked(_:))
        tools.setAccessibilityLabel("Content tools")
        done.target = self
        done.action = #selector(doneClicked(_:))
        done.controlSize = .small
        let stack = NSStackView(views: [tools] + (formatControls.map { [$0] } ?? []) + [done])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
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
        root.setAccessibilityLabel("Page content")
        view = root
        setTool(.edit)
    }

    func setTool(_ tool: ContentTool) {
        guard isViewLoaded else { return }
        tools.selectedSegment = ContentTool.allCases.firstIndex(of: tool) ?? 0
    }

    @objc private func toolClicked(_ sender: NSSegmentedControl) {
        onToolChosen?(ContentTool.allCases[sender.selectedSegment])
    }

    @objc private func doneClicked(_ sender: Any?) { onDone?() }
}
