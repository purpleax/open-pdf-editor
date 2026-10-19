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
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
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
        file.addItem(withTitle: "New", action: #selector(AppDelegate.newBlankPDF(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = recentMenu
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        // With autosave: Duplicate, Rename, Move To and Revert To (versions);
        // without: Save As… and Revert to Saved (see FileMenuDelegate).
        file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S").tag = FileMenuDelegate.manualTag
        file.addItem(withTitle: "Duplicate", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "S").tag = FileMenuDelegate.autosaveTag
        file.addItem(withTitle: "Rename…", action: #selector(NSDocument.rename(_:)), keyEquivalent: "").tag = FileMenuDelegate.autosaveTag
        file.addItem(withTitle: "Move To…", action: #selector(NSDocument.move(_:)), keyEquivalent: "").tag = FileMenuDelegate.autosaveTag
        file.addItem(withTitle: "Revert To", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "").tag = FileMenuDelegate.revertTag
        file.delegate = FileMenuDelegate.shared
        file.addItem(withTitle: "Show in Finder", action: #selector(AppDelegate.showInFinder(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Create PDF from Files…", action: #selector(AppDelegate.createPDFFromFiles(_:)), keyEquivalent: "n")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(withTitle: "Reduce File Size…", action: #selector(DocumentWindowController.reduceFileSize(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Security…", action: #selector(DocumentWindowController.showSecurity(_:)), keyEquivalent: "")
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
        edit.addItem(withTitle: "Delete", action: #selector(PagesView.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Edit Content", action: #selector(DocumentWindowController.toggleEditContent(_:)), keyEquivalent: "e")
            .keyEquivalentModifierMask = [.command, .option]
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
        view.addItem(withTitle: "Highlight Form Fields", action: #selector(DocumentWindowController.toggleFieldHighlights(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(DocumentWindowController.zoomToActualSize(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Fit Width", action: #selector(DocumentWindowController.zoomToFitWidth(_:)), keyEquivalent: "8")
        view.addItem(withTitle: "Fit Page", action: #selector(DocumentWindowController.zoomToFitPage(_:)), keyEquivalent: "9")
        view.addItem(withTitle: "Zoom In", action: #selector(DocumentWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(DocumentWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: "Rotate View Left", action: #selector(DocumentWindowController.rotateViewLeft(_:)), keyEquivalent: "l")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Rotate View Right", action: #selector(DocumentWindowController.rotateViewRight(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        for (index, (title, action)) in [
            ("Thumbnails", #selector(DocumentWindowController.showThumbnails(_:))),
            ("Outline", #selector(DocumentWindowController.showOutline(_:))),
            ("Search Results", #selector(DocumentWindowController.showSearchResults(_:))),
            ("Comments", #selector(DocumentWindowController.showComments(_:))),
            ("Attachments", #selector(DocumentWindowController.showAttachments(_:))),
            ("Layers", #selector(DocumentWindowController.showLayers(_:))),
        ].enumerated() {
            view.addItem(withTitle: title, action: action, keyEquivalent: "\(index + 1)").keyEquivalentModifierMask = [.command, .option]
        }
        view.addItem(withTitle: "Document Info", action: #selector(DocumentWindowController.showDocumentInfo(_:)), keyEquivalent: "i")
            .keyEquivalentModifierMask = [.command, .option]
        view.addItem(.separator())
        view.addItem(withTitle: "Show Markup Toolbar", action: #selector(DocumentWindowController.toggleMarkupBar(_:)), keyEquivalent: "A")
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

        let pages = submenu(in: main, title: "Pages")
        pages.addItem(withTitle: "Rotate Left", action: #selector(DocumentWindowController.rotatePagesLeft(_:)), keyEquivalent: "l")
        pages.addItem(withTitle: "Rotate Right", action: #selector(DocumentWindowController.rotatePagesRight(_:)), keyEquivalent: "r")
        pages.addItem(withTitle: "Crop", action: #selector(DocumentWindowController.toggleCropMode(_:)), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command, .control]
        pages.addItem(.separator())
        pages.addItem(withTitle: "Insert Blank Page", action: #selector(DocumentWindowController.insertBlankPage(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Insert Pages from File…", action: #selector(DocumentWindowController.insertPagesFromFile(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Delete Pages", action: #selector(DocumentWindowController.deletePages(_:)), keyEquivalent: "")
        pages.addItem(.separator())
        pages.addItem(withTitle: "Extract Pages…", action: #selector(DocumentWindowController.extractPages(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Split Document…", action: #selector(DocumentWindowController.splitDocument(_:)), keyEquivalent: "")
        pages.addItem(.separator())
        pages.addItem(withTitle: "Add Headers & Footers…", action: #selector(DocumentWindowController.addHeadersAndFooters(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Add Page Numbers…", action: #selector(DocumentWindowController.addPageNumbers(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Add Watermark…", action: #selector(DocumentWindowController.addWatermark(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Remove Headers & Footers", action: #selector(DocumentWindowController.removeHeadersAndFooters(_:)), keyEquivalent: "")
        pages.addItem(withTitle: "Remove Watermarks", action: #selector(DocumentWindowController.removeWatermarks(_:)), keyEquivalent: "")

        let tools = submenu(in: main, title: "Tools")
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            let item = tools.addItem(withTitle: tool.title, action: #selector(DocumentWindowController.chooseTool(_:)),
                                     keyEquivalent: tool.keyEquivalent)
            item.keyEquivalentModifierMask = [.command, .control]
            item.tag = index
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            if tool == .select || tool == .note || tool == .signature || tool == .redact { tools.addItem(.separator()) }
        }
        tools.addItem(withTitle: "Signatures…", action: #selector(DocumentWindowController.manageSignatures(_:)), keyEquivalent: "")
        tools.addItem(withTitle: "Apply Redactions…", action: #selector(DocumentWindowController.applyRedactions(_:)), keyEquivalent: "")
        tools.addItem(.separator())
        tools.addItem(withTitle: "Recognise Text…", action: #selector(DocumentWindowController.recognizeText(_:)), keyEquivalent: "")
        tools.addItem(.separator())
        tools.addItem(withTitle: "Flatten Annotations…", action: #selector(DocumentWindowController.flattenAnnotations(_:)), keyEquivalent: "")

        let forms = submenu(in: main, title: "Forms")
        forms.addItem(withTitle: "Edit Fields", action: #selector(DocumentWindowController.toggleEditFields(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        forms.addItem(.separator())
        for (index, tool) in FieldTool.allCases.enumerated() {
            let item = forms.addItem(withTitle: tool.title, action: #selector(DocumentWindowController.chooseFieldTool(_:)), keyEquivalent: "")
            item.tag = index
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            if tool == .select { forms.addItem(.separator()) }
        }
        forms.addItem(.separator())
        forms.addItem(withTitle: "Flatten Form…", action: #selector(DocumentWindowController.flattenForm(_:)), keyEquivalent: "")

        // Format: for text being edited (the text view and the Fonts panel do the work).
        let format = submenu(in: main, title: "Format")
        let font = NSMenu(title: "Font")
        format.addItem(withTitle: "Font", action: nil, keyEquivalent: "").submenu = font
        font.addItem(withTitle: "Show Fonts", action: #selector(NSFontManager.orderFrontFontPanel(_:)), keyEquivalent: "t").target = NSFontManager.shared
        let bold = font.addItem(withTitle: "Bold", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b")
        bold.target = NSFontManager.shared
        bold.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        let italic = font.addItem(withTitle: "Italic", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i")
        italic.target = NSFontManager.shared
        italic.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
        font.addItem(withTitle: "Underline", action: #selector(NSText.underline(_:)), keyEquivalent: "u")
        font.addItem(.separator())
        let bigger = font.addItem(withTitle: "Bigger", action: #selector(NSFontManager.modifyFont(_:)), keyEquivalent: "")
        bigger.target = NSFontManager.shared
        bigger.tag = Int(NSFontAction.sizeUpFontAction.rawValue)
        let smaller = font.addItem(withTitle: "Smaller", action: #selector(NSFontManager.modifyFont(_:)), keyEquivalent: "")
        smaller.target = NSFontManager.shared
        smaller.tag = Int(NSFontAction.sizeDownFontAction.rawValue)
        font.addItem(.separator())
        font.addItem(withTitle: "Show Colors", action: #selector(NSApplication.orderFrontColorPanel(_:)), keyEquivalent: "C")
        let text = NSMenu(title: "Text")
        format.addItem(withTitle: "Text", action: nil, keyEquivalent: "").submenu = text
        text.addItem(withTitle: "Align Left", action: #selector(NSText.alignLeft(_:)), keyEquivalent: "{")
        text.addItem(withTitle: "Center", action: #selector(NSText.alignCenter(_:)), keyEquivalent: "|")
        text.addItem(withTitle: "Justify", action: #selector(NSTextView.alignJustified(_:)), keyEquivalent: "")
        text.addItem(withTitle: "Align Right", action: #selector(NSText.alignRight(_:)), keyEquivalent: "}")

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

/// Shows the File menu's saving items for the Settings choice: Duplicate,
/// Rename, Move To and Revert To with autosave, Save As… and Revert to Saved
/// without.
@MainActor
final class FileMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = FileMenuDelegate()
    static let manualTag = 9001
    static let autosaveTag = 9002
    static let revertTag = 9003

    func menuNeedsUpdate(_ menu: NSMenu) {
        let automatic = Settings.savesAutomatically
        for item in menu.items {
            switch item.tag {
            case Self.manualTag: item.isHidden = automatic
            case Self.autosaveTag: item.isHidden = !automatic
            case Self.revertTag: item.title = automatic ? "Revert To" : "Revert to Saved"
            default: break
            }
        }
    }
}
