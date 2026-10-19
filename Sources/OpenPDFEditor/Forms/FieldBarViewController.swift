import AppKit
import PDFCore

/// The field bar under the toolbar while editing a form's fields
/// (Forms › Edit Fields): the field tools, and Done.
@MainActor
final class FieldBarViewController: NSViewController {
    private let tools = NSSegmentedControl()
    private let done = NSButton(title: "Done", target: nil, action: nil)

    /// Called when the user picks a tool.
    var onToolChosen: ((FieldTool) -> Void)?
    var onDone: (() -> Void)?

    override func loadView() {
        tools.segmentCount = FieldTool.allCases.count
        tools.trackingMode = .selectOne
        for (index, tool) in FieldTool.allCases.enumerated() {
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: index)
            tools.setToolTip(tool.title, forSegment: index)
            tools.setWidth(30, forSegment: index)
        }
        tools.target = self
        tools.action = #selector(toolClicked(_:))
        tools.setAccessibilityLabel("Field tools")
        done.target = self
        done.action = #selector(doneClicked(_:))
        done.controlSize = .small
        done.bezelStyle = .push
        let label = NSTextField(labelWithString: "Editing form fields")
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [label, tools, done])
        stack.orientation = .horizontal
        stack.spacing = 12
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
        root.setAccessibilityLabel("Form fields")
        view = root
        setTool(.select)
    }

    func setTool(_ tool: FieldTool) {
        guard isViewLoaded else { return }
        tools.selectedSegment = FieldTool.allCases.firstIndex(of: tool) ?? 0
    }

    @objc private func toolClicked(_ sender: NSSegmentedControl) {
        onToolChosen?(FieldTool.allCases[sender.selectedSegment])
    }

    @objc private func doneClicked(_ sender: Any?) {
        onDone?()
    }
}
