import AppKit
import PDFCore

enum SidebarTab: Int, CaseIterable {
    case thumbnails, outline, search, attachments, layers

    var title: String {
        switch self {
        case .thumbnails: "Thumbnails"
        case .outline: "Outline"
        case .search: "Search Results"
        case .attachments: "Attachments"
        case .layers: "Layers"
        }
    }

    var symbol: String {
        switch self {
        case .thumbnails: "square.grid.2x2"
        case .outline: "list.bullet.indent"
        case .search: "magnifyingglass"
        case .attachments: "paperclip"
        case .layers: "square.3.layers.3d"
        }
    }
}

/// The left sidebar: a row of tabs and the selected panel below.
@MainActor
final class SidebarViewController: NSViewController {
    let viewer: ViewerController
    private let tabs = NSSegmentedControl()
    private let container = NSView()
    private(set) var tab: SidebarTab

    private(set) lazy var thumbnails = ThumbnailsViewController(viewer: viewer)
    private(set) lazy var outline = OutlineViewController(viewer: viewer)
    private(set) lazy var searchResults = SearchResultsViewController(viewer: viewer)
    private(set) lazy var attachments = AttachmentsViewController(model: viewer.model)
    private(set) lazy var layers = LayersViewController(model: viewer.model)

    init(viewer: ViewerController) {
        self.viewer = viewer
        tab = SidebarTab(rawValue: UserDefaults.standard.integer(forKey: "SidebarTab")) ?? .thumbnails
        if tab == .search { tab = .thumbnails }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        tabs.segmentCount = SidebarTab.allCases.count
        tabs.trackingMode = .selectOne
        tabs.segmentStyle = .automatic
        for tab in SidebarTab.allCases {
            tabs.setImage(NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title), forSegment: tab.rawValue)
            tabs.setToolTip(tab.title, forSegment: tab.rawValue)
            tabs.setWidth(32, forSegment: tab.rawValue)
        }
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.setAccessibilityLabel("Sidebar")
        tabs.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabs)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            container.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        show(tab)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = SidebarTab(rawValue: sender.selectedSegment) else { return }
        show(tab)
    }

    func show(_ tab: SidebarTab) {
        self.tab = tab
        if tab != .search { UserDefaults.standard.set(tab.rawValue, forKey: "SidebarTab") }
        tabs.selectedSegment = tab.rawValue
        let controller = controller(for: tab)
        for child in children where child !== controller {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        if controller.parent == nil {
            addChild(controller)
            controller.view.frame = container.bounds
            controller.view.autoresizingMask = [.width, .height]
            container.addSubview(controller.view)
        }
    }

    private func controller(for tab: SidebarTab) -> NSViewController {
        switch tab {
        case .thumbnails: thumbnails
        case .outline: outline
        case .search: searchResults
        case .attachments: attachments
        case .layers: layers
        }
    }

    // MARK: Updates from the viewer

    func currentPageDidChange() {
        if tab == .thumbnails { thumbnails.showCurrentPage() }
    }

    func rotationDidChange() {
        thumbnails.reload()
    }

    func renderingDidChange() {
        thumbnails.reload()
        layers.reload()
    }

    func findDidChange() {
        searchResults.reload()
    }
}

/// A centred grey message for an empty panel.
@MainActor
func placeholderLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.alignment = .center
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

@MainActor
func embedPlaceholder(_ label: NSTextField, in view: NSView) {
    view.addSubview(label)
    NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
        label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -32),
    ])
}

@MainActor
func makeTableScrollView(_ table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    table.backgroundColor = .clear
    table.headerView = nil
    table.style = .sourceList
    return scroll
}
