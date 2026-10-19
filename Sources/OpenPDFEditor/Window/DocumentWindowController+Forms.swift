import AppKit
import PDFCore

/// Forms menu: editing the form's fields, and flattening the form.
extension DocumentWindowController {
    func setUpFieldBar() {
        guard fieldAccessory == nil, let window, let viewer else { return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = fieldBar.view
        accessory.isHidden = true
        window.addTitlebarAccessoryViewController(accessory)
        fieldAccessory = accessory
        fieldBar.onToolChosen = { [weak self] tool in self?.viewer?.pagesView.fieldTool = tool }
        fieldBar.onDone = { [weak self] in self?.setEditingFields(false) }
        viewer.onFieldToolChange = { [weak self] tool in self?.fieldBar.setTool(tool) }
        viewer.onFieldSelectionChange = { [weak self] ref in self?.inspector?.show(field: ref) }
    }

    func setEditingFields(_ editing: Bool) {
        guard let viewer else { return }
        viewer.pagesView.isCropping = false
        viewer.pagesView.editingFields = editing
        fieldBar.setTool(.select)
        fieldAccessory?.animator().isHidden = !editing
        // Fields are set up in the inspector.
        if editing, inspectorItem?.isCollapsed == true { inspectorItem?.animator().isCollapsed = false }
    }

    @objc func toggleEditFields(_ sender: Any?) {
        guard let viewer else { return }
        setEditingFields(!viewer.pagesView.editingFields)
    }

    /// Forms menu: the menu item's tag is the tool's index.
    @objc func chooseFieldTool(_ sender: NSMenuItem) {
        guard FieldTool.allCases.indices.contains(sender.tag), let viewer else { return }
        if !viewer.pagesView.editingFields { setEditingFields(true) }
        let tool = FieldTool.allCases[sender.tag]
        viewer.pagesView.fieldTool = tool
        fieldBar.setTool(tool)
    }
}
