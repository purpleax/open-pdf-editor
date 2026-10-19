import AppKit
import PDFCore

/// Edit › Edit Content: the content bar, and making links.
extension DocumentWindowController {
    func setUpContentBar() {
        guard contentAccessory == nil, let window, let viewer else { return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = contentBar.view
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)
        contentAccessory = accessory
        contentBar.onToolChosen = { [weak self] tool in self?.viewer?.pagesView.contentTool = tool }
        contentBar.onDone = { [weak self] in self?.setEditingContent(false) }
        viewer.onContentSelectionChange = { [weak self] ref in self?.inspector?.show(content: ref) }
        viewer.onMakeLink = { [weak self] rect, page in self?.makeLink(in: rect, onPage: page) }
    }

    func setEditingContent(_ editing: Bool) {
        guard let viewer else { return }
        if editing, viewer.pagesView.editingFields { setEditingFields(false) }
        viewer.pagesView.editingContent = editing
        contentBar.setTool(.select)
        contentAccessory?.animator().isHidden = !editing
        if editing, inspectorItem?.isCollapsed == true { inspectorItem?.animator().isCollapsed = false }
    }

    @objc func toggleEditContent(_ sender: Any?) {
        guard let viewer else { return }
        setEditingContent(!viewer.pagesView.editingContent)
    }

    private func makeLink(in rect: CGRect, onPage page: Int) {
        guard let viewer, let window else { return }
        LinkTargetSheet.ask(on: window, pageCount: viewer.model.pageCount, current: nil, title: "Where does the link go?") { [weak self] target in
            guard let self, let target, let viewer = self.viewer else { return }
            do {
                viewer.pagesView.selectedContent = try viewer.content.createLink(page: page, rect: rect, to: target)
                viewer.pagesView.contentTool = .select
                self.contentBar.setTool(.select)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Asks again where the selected link goes.
    func changeLinkTarget(_ ref: ContentRef) {
        guard let viewer, let window, let item = viewer.content.item(ref) else { return }
        LinkTargetSheet.ask(on: window, pageCount: viewer.model.pageCount, current: item.link, title: "Where does the link go?") { target in
            guard let target else { return }
            do {
                try viewer.content.setTarget(ref, target)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}
