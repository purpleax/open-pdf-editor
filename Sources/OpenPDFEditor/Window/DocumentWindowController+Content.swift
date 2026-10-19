import AppKit
import PDFCore

/// Edit › Edit Content: the content bar, and making links.
extension DocumentWindowController {
    func setUpContentBar() {
        guard contentAccessory == nil, let window, let viewer else { return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        contentBar.formatControls = formatBar.view
        accessory.view = contentBar.view
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)
        contentAccessory = accessory
        contentBar.onToolChosen = { [weak self] tool in self?.viewer?.pagesView.contentTool = tool }
        contentBar.onDone = { [weak self] in self?.setEditingContent(false) }
        viewer.onContentSelectionChange = { [weak self] ref in self?.inspector?.show(content: ref) }
        viewer.onMakeLink = { [weak self] rect, page in self?.makeLink(in: rect, onPage: page) }
        viewer.onMakeImage = { [weak self] rect, page in self?.makeImage(in: rect, onPage: page) }
        viewer.pagesView.onTextEditorChange = { [weak self] editor in self?.formatBar.editor = editor }
        viewer.pagesView.onEditText = { [weak self] paragraph, point in
            guard let self, let viewer = self.viewer else { return }
            self.setEditingContent(true)
            viewer.pagesView.beginParagraphEdit(paragraph, at: point)
        }
    }

    func setEditingContent(_ editing: Bool) {
        guard let viewer else { return }
        if editing, viewer.pagesView.editingFields { setEditingFields(false) }
        viewer.pagesView.editingContent = editing
        contentBar.setTool(.edit)
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
                let ref = try viewer.content.createLink(page: page, rect: rect, to: target)
                viewer.pagesView.contentTool = .edit
                self.contentBar.setTool(.edit)
                viewer.pagesView.selectedContent = ref
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Asks for an image file and adds it: filling `rect`, or at its own
    /// proportions (200 points across, within the page) from a clicked point.
    private func makeImage(in rect: CGRect, onPage page: Int) {
        chooseImage { [weak self] image in
            guard let self, let viewer = self.viewer, let window = self.window else { return }
            var r = rect
            if r.isEmpty {
                let width = min(200, viewer.model.pageBounds[page].width)
                r.size = CGSize(width: width, height: width * image.size.height / max(image.size.width, 1))
            }
            do {
                let ref = try viewer.content.addImage(image, page: page, rect: r)
                viewer.pagesView.contentTool = .edit
                self.contentBar.setTool(.edit)
                viewer.pagesView.selectedContent = ref
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Replaces the selected image's picture with another file's.
    func replaceImage(_ ref: ContentRef) {
        chooseImage { [weak self] image in
            guard let self, let viewer = self.viewer, let window = self.window else { return }
            do {
                try viewer.content.replaceImage(ref, with: image)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// An open panel for an image file, read and checked off the main thread.
    private func chooseImage(_ then: @escaping @MainActor (ImageImport.Prepared) -> Void) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image (at most 100 MB and 40 megapixels)."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ImageImport.prepare(contentsOf: url) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch result {
                        case let .success(image): then(image)
                        case let .failure(error): NSAlert(error: error).beginSheetModal(for: window)
                        }
                    }
                }
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
