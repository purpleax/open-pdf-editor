import AppKit
import Sparkle

/// The menu bar, built in code. Document actions go to the key window's
/// DocumentWindowController through the responder chain.
@MainActor
enum MainMenu {
    static func make(updater: SPUStandardUpdaterController) -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Open PDF Editor"
        let main = NSMenu()

        let app = submenu(in: main, title: name)
        app.addItem(withTitle: "About \(name)", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        let check = app.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updater
        app.addItem(.separator())
        let services = app.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(in: main, title: "File")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = recentMenu
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Show in Finder", action: #selector(AppDelegate.showInFinder(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Page Setup…", action: #selector(NSDocument.runPageLayout(_:)), keyEquivalent: "P")
        file.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "Find")
        findItem.submenu = find
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSFindPanelAction.showFindPanel),
            ("Find Next", "g", [.command], .next),
            ("Find Previous", "g", [.command, .shift], .previous),
            ("Use Selection for Find", "e", [.command], .setFindString),
        ] {
            let item = find.addItem(withTitle: title, action: #selector(DocumentWindowController.performFindPanelAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = Int(action.rawValue)
        }
        find.addItem(.separator())
        find.addItem(withTitle: "Match Case", action: #selector(DocumentWindowController.toggleMatchCase(_:)), keyEquivalent: "")
        find.addItem(withTitle: "Whole Words", action: #selector(DocumentWindowController.toggleWholeWords(_:)), keyEquivalent: "")

        let view = submenu(in: main, title: "View")
        view.addItem(withTitle: "Single Page", action: #selector(DocumentWindowController.displaySinglePage(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Single Page Continuous", action: #selector(DocumentWindowController.displaySinglePageContinuous(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Two Pages", action: #selector(DocumentWindowController.displayTwoPages(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Two Pages Continuous", action: #selector(DocumentWindowController.displayTwoPagesContinuous(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Show Cover Page Separately", action: #selector(DocumentWindowController.toggleCoverSeparately(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(DocumentWindowController.zoomToActualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Fit Width", action: #selector(DocumentWindowController.zoomToFitWidth(_:)), keyEquivalent: "8")
        view.addItem(withTitle: "Fit Page", action: #selector(DocumentWindowController.zoomToFitPage(_:)), keyEquivalent: "9")
        view.addItem(withTitle: "Zoom In", action: #selector(DocumentWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(DocumentWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Rotate Left", action: #selector(DocumentWindowController.rotateLeft(_:)), keyEquivalent: "l")
        view.addItem(withTitle: "Rotate Right", action: #selector(DocumentWindowController.rotateRight(_:)), keyEquivalent: "r")
        view.addItem(.separator())
        view.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        for (index, (title, action)) in [
            ("Thumbnails", #selector(DocumentWindowController.showThumbnails(_:))),
            ("Outline", #selector(DocumentWindowController.showOutline(_:))),
            ("Search Results", #selector(DocumentWindowController.showSearchResults(_:))),
            ("Attachments", #selector(DocumentWindowController.showAttachments(_:))),
            ("Layers", #selector(DocumentWindowController.showLayers(_:))),
        ].enumerated() {
            view.addItem(withTitle: title, action: action, keyEquivalent: "\(index + 1)").keyEquivalentModifierMask = [.command, .option]
        }
        view.addItem(withTitle: "Document Info", action: #selector(DocumentWindowController.showDocumentInfo(_:)), keyEquivalent: "i")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let go = submenu(in: main, title: "Go")
        go.addItem(withTitle: "Previous Page", action: #selector(DocumentWindowController.goToPreviousPage(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
            .keyEquivalentModifierMask = [.command, .option]
        go.addItem(withTitle: "Next Page", action: #selector(DocumentWindowController.goToNextPage(_:)), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
            .keyEquivalentModifierMask = [.command, .option]
        go.addItem(withTitle: "First Page", action: #selector(DocumentWindowController.goToFirstPage(_:)), keyEquivalent: String(UnicodeScalar(NSHomeFunctionKey)!))
            .keyEquivalentModifierMask = []
        go.addItem(withTitle: "Last Page", action: #selector(DocumentWindowController.goToLastPage(_:)), keyEquivalent: String(UnicodeScalar(NSEndFunctionKey)!))
            .keyEquivalentModifierMask = []
        go.addItem(withTitle: "Go to Page…", action: #selector(DocumentWindowController.goToPage(_:)), keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .option]
        go.addItem(.separator())
        go.addItem(withTitle: "Back", action: #selector(DocumentWindowController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(DocumentWindowController.goForward(_:)), keyEquivalent: "]")

        let window = submenu(in: main, title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control, .shift]
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "\t")
            .keyEquivalentModifierMask = [.control]
        window.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = submenu(in: main, title: "Help")
        help.addItem(withTitle: "\(name) on GitHub", action: #selector(AppDelegate.openWebsite(_:)), keyEquivalent: "")
        help.addItem(withTitle: "Acknowledgements", action: #selector(AppDelegate.showAcknowledgements(_:)), keyEquivalent: "")
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(in menu: NSMenu, title: String) -> NSMenu {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        item.submenu = sub
        return sub
    }
}
