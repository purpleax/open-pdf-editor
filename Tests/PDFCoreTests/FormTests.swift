import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite struct FormTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    private func field(_ doc: EngineDocument, _ name: String, page: Int = 0) throws -> FormField {
        try #require(try doc.fields(page: page).first { $0.name == name })
    }

    @Test func listsEveryKind() throws {
        let doc = try Corpus.open("forms.pdf")
        let fields = try doc.fields(page: 0)
        func kind(_ name: String) -> FormField.Kind? { fields.first { $0.name == name }?.kind }
        #expect(kind("name") == .text && kind("agree") == .checkbox && kind("colour") == .dropdown)
        #expect(kind("fruits") == .listBox && kind("signature") == .signature && kind("size") == .radio)
        #expect(fields.filter { $0.name == "size" }.map(\.onState) == ["S", "M", "L"])

        let name = try field(doc, "name")
        #expect(name.value == "Ada" && name.tooltip == "Your name" && !name.isReadOnly)
        #expect(try field(doc, "notes").isMultiline)
        #expect(try field(doc, "zip").maxLength == 5)
        #expect(try field(doc, "pin").isPassword)
        #expect(try field(doc, "code").isComb)
        let colour = try field(doc, "colour")
        #expect(colour.value == "g" && colour.options.map(\.label) == ["Red", "Green", "Blue"])
        #expect(try field(doc, "fruits").isMultiSelect)
        #expect(try field(doc, "locked").isReadOnly)
        #expect(try field(doc, "signature").isReadOnly)
        let info = try doc.formInfo()
        #expect(info.hasFields && info.hasXFA && !info.isSigned)
    }

    @Test func fillInEveryKindAndSave() throws {
        let doc = try Corpus.open("forms.pdf")
        try doc.setText("Grace Hopper", page: 0, field: try field(doc, "name").id)
        try doc.setText("Line one\nLine two", page: 0, field: try field(doc, "notes").id)
        try doc.setText("b", page: 0, field: try field(doc, "colour").id)
        try doc.setChoices(["Apple", "Cherry"], page: 0, field: try field(doc, "fruits").id)
        try doc.toggle(page: 0, field: try field(doc, "agree").id)
        let medium = try #require(try doc.fields(page: 0).first { $0.name == "size" && $0.onState == "M" })
        try doc.toggle(page: 0, field: medium.id)

        let out = temporaryURL("filled.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let saved = try EngineDocument(url: out)
        #expect(try field(saved, "name").value == "Grace Hopper")
        #expect(try field(saved, "notes").value == "Line one\nLine two")
        #expect(try field(saved, "colour").value == "b")
        #expect(try field(saved, "fruits").selected == ["Apple", "Cherry"])
        #expect(try field(saved, "agree").isOn)
        #expect(try saved.fields(page: 0).filter { $0.name == "size" }.map(\.isOn) == [false, true, false])
        #expect(try field(saved, "size").value == "M")
        // Filling in removed the XFA, which would show the old data elsewhere.
        #expect(try saved.formInfo().hasXFA == false)
    }

    @Test func radioButtonsAreExclusive() throws {
        let doc = try Corpus.open("forms.pdf")
        let buttons = try doc.fields(page: 0).filter { $0.name == "size" }
        try doc.toggle(page: 0, field: buttons[0].id)
        try doc.toggle(page: 0, field: buttons[2].id)
        #expect(try doc.fields(page: 0).filter { $0.name == "size" }.map(\.isOn) == [false, false, true])
        // NoToggleToOff: clicking the chosen one leaves it on.
        try doc.toggle(page: 0, field: buttons[2].id)
        #expect(try doc.fields(page: 0).filter { $0.name == "size" }.map(\.isOn) == [false, false, true])
    }

    @Test func undoAndRedo() throws {
        let doc = try Corpus.open("forms.pdf")
        let id = try field(doc, "name").id
        try doc.setText("Changed", page: 0, field: id)
        #expect(doc.canUndo)
        try doc.undo()
        #expect(try field(doc, "name").value == "Ada")
        #expect(try doc.formInfo().hasXFA)
        try doc.redo()
        #expect(try field(doc, "name").value == "Changed")
    }

    @Test func refusesWhatTheFieldDoesNotTake() throws {
        let doc = try Corpus.open("forms.pdf")
        #expect(throws: EngineError.self) { try doc.setText("123456", page: 0, field: try field(doc, "zip").id) }
        try doc.setText("12345", page: 0, field: try field(doc, "zip").id)
        #expect(throws: EngineError.self) { try doc.setText("Purple", page: 0, field: try field(doc, "colour").id) }
        #expect(throws: EngineError.self) { try doc.setChoices(["Durian"], page: 0, field: try field(doc, "fruits").id) }
        #expect(throws: EngineError.self) { try doc.setText("x", page: 0, field: try field(doc, "agree").id) }
        #expect(throws: EngineError.self) { try doc.toggle(page: 0, field: try field(doc, "name").id) }
        #expect(throws: EngineError.self) { try doc.setText("x", page: 0, field: 99999) }
    }

    /// The calculate script on "total" would fill it in if JavaScript ran.
    @Test func formScriptsDoNotRun() throws {
        let doc = try Corpus.open("forms.pdf")
        try doc.setText("Someone", page: 0, field: try field(doc, "name").id)
        let out = temporaryURL("scripts.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(try field(EngineDocument(url: out), "total").value == "")
    }

    @Test func signedDocumentsKeepTheirBytes() throws {
        let source = Corpus.root.appendingPathComponent("forms.pdf")
        let original = try Data(contentsOf: source)
        let doc = try EngineDocument(url: source)
        try doc.toggle(page: 0, field: try field(doc, "agree").id)
        let out = temporaryURL("appended.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let saved = try Data(contentsOf: out)
        #expect(saved.count > original.count && saved.prefix(original.count) == original)
        #expect(try Corpus.open("signed.pdf").formInfo().isSigned)
    }
}

@Suite struct FormSecurityTests {
    @Test func readOnlyFieldsRefuseWrites() throws {
        let doc = try Corpus.open("forms.pdf")
        let locked = try #require(try doc.fields(page: 0).first { $0.name == "locked" })
        #expect(throws: EngineError.self) { try doc.setText("Changed", page: 0, field: locked.id) }
        let signature = try #require(try doc.fields(page: 0).first { $0.name == "signature" })
        #expect(throws: EngineError.self) { try doc.setText("x", page: 0, field: signature.id) }
        #expect(!doc.canUndo)
    }

    @Test func fieldsPerPageAreCapped() throws {
        let doc = try Corpus.open("formbomb.pdf")
        #expect(try doc.fields(page: 0).count == 2000)
    }

    @Test func oversizedFieldsAreReadOnly() throws {
        let doc = try Corpus.open("formloop.pdf")
        let fields = try doc.fields(page: 0)
        #expect(fields.count == 3)
        let many = try #require(fields.first { $0.name == "many" })
        #expect(many.options.count == 1000 && many.isReadOnly)
        // The 20 KB name is over MuPDF's limit: listed, nameless and read-only.
        #expect(fields.contains { $0.name.isEmpty && $0.isReadOnly })
        // A field that is its own grandparent still lists, and finishes.
        _ = try doc.formInfo()
    }
}
