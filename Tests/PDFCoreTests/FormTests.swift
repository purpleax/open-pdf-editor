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

@Suite struct FieldEditingTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    /// Every kind made on a page with no form, saved and read back.
    @Test func createEveryKind() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(try !doc.formInfo().hasFields)
        let text = try doc.createField(.text, page: 0, rect: CGRect(x: 72, y: 600, width: 200, height: 20))
        let check = try doc.createField(.checkbox, page: 0, rect: CGRect(x: 72, y: 560, width: 14, height: 14))
        let first = try doc.createField(.radio, page: 0, rect: CGRect(x: 72, y: 520, width: 14, height: 14))
        let second = try doc.createField(.radio, page: 0, rect: CGRect(x: 100, y: 520, width: 14, height: 14), joining: first)
        let dropdown = try doc.createField(.dropdown, page: 0, rect: CGRect(x: 72, y: 480, width: 120, height: 20))
        let list = try doc.createField(.listBox, page: 0, rect: CGRect(x: 72, y: 400, width: 120, height: 60))
        try doc.createField(.signature, page: 0, rect: CGRect(x: 300, y: 400, width: 200, height: 50))

        var choices = FieldChange()
        choices.options = [.init(value: "r", label: "Red"), .init(value: "g", label: "Green")]
        try doc.updateField(page: 0, id: dropdown, choices)
        choices.options = [.init(value: "One", label: ""), .init(value: "Two", label: "")]
        choices.isMultiSelect = true
        try doc.updateField(page: 0, id: list, choices)
        var named = FieldChange()
        named.name = "email"
        named.tooltip = "Your email address"
        named.isRequired = true
        named.maxLength = 40
        try doc.updateField(page: 0, id: text, named)

        try doc.setText("ada@example.com", page: 0, field: text)
        try doc.toggle(page: 0, field: check)
        try doc.toggle(page: 0, field: second)
        try doc.setText("g", page: 0, field: dropdown)
        try doc.setChoices(["One", "Two"], page: 0, field: list)

        let out = temporaryURL("fields.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let saved = try EngineDocument(url: out)
        let fields = try saved.fields(page: 0)
        #expect(fields.map(\.kind) == [.text, .checkbox, .radio, .radio, .dropdown, .listBox, .signature])
        let email = try #require(fields.first { $0.kind == .text })
        #expect(email.name == "email" && email.tooltip == "Your email address" && email.isRequired && email.maxLength == 40)
        #expect(email.value == "ada@example.com")
        #expect(fields[1].isOn && !fields[2].isOn && fields[3].isOn)
        #expect(fields[2].name == fields[3].name && fields[2].onState != fields[3].onState)
        #expect(fields[4].value == "g" && fields[4].options.map(\.label) == ["Red", "Green"])
        #expect(fields[5].selected == ["One", "Two"] && fields[5].isMultiSelect)
        #expect(Set(fields.map(\.name)).count == 6)
        #expect(try saved.formInfo().hasFields)
    }

    @Test func namesStayUnique() throws {
        let doc = try Corpus.open("forms.pdf")
        let zip = try #require(try doc.fields(page: 0).first { $0.name == "zip" })
        var change = FieldChange()
        change.name = "name"
        #expect(throws: EngineError.self) { try doc.updateField(page: 0, id: zip.id, change) }
        change.name = "address.zip"
        #expect(throws: EngineError.self) { try doc.updateField(page: 0, id: zip.id, change) }
        change.name = "postcode"
        try doc.updateField(page: 0, id: zip.id, change)
        #expect(try doc.fields(page: 0).contains { $0.name == "postcode" })
    }

    @Test func moveAndDelete() throws {
        let doc = try Corpus.open("forms.pdf")
        let name = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        try doc.transformField(page: 0, id: name.id, by: CGAffineTransform(translationX: 10, y: -20))
        let moved = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        #expect(abs(moved.rect.minX - name.rect.minX - 10) < 0.5)
        try doc.deleteField(page: 0, id: name.id)
        #expect(try !doc.fields(page: 0).contains { $0.name == "name" })
        // Deleting every button of a group removes the group.
        for button in try doc.fields(page: 0).filter({ $0.name == "size" }) { try doc.deleteField(page: 0, id: button.id) }
        #expect(try !doc.fields(page: 0).contains { $0.name == "size" })
        try doc.undo()
        #expect(try doc.fields(page: 0).filter { $0.name == "size" }.count == 1)
    }

    @Test func combNeedsALength() throws {
        let doc = try Corpus.open("forms.pdf")
        let notes = try #require(try doc.fields(page: 0).first { $0.name == "pin" })
        var change = FieldChange()
        change.isComb = true
        #expect(throws: EngineError.self) { try doc.updateField(page: 0, id: notes.id, change) }
        change.maxLength = 4
        try doc.updateField(page: 0, id: notes.id, change)
    }
}

@Suite struct FlattenFormTests {
    @Test func flattenKeepsWhatWasFilledIn() throws {
        let doc = try Corpus.open("forms.pdf")
        let name = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        try doc.setText("WWWWWWWWWWWW", page: 0, field: name.id)
        func ink(_ doc: EngineDocument) throws -> Int {
            // Dark pixels where the name field is (page space is pixels at scale 1).
            let pixels = try Pixels(doc.renderPage(0, bounds: try doc.pageBounds()[0], scale: 1))
            var dark = 0
            for y in Int(name.rect.minY)..<Int(name.rect.maxY) {
                for x in Int(name.rect.minX)..<Int(name.rect.maxX) where pixels.rgb(x, y).allSatisfy({ $0 < 100 }) { dark += 1 }
            }
            return dark
        }
        let before = try ink(doc)
        try doc.flattenForm()
        #expect(try doc.fields(page: 0).isEmpty)
        #expect(try !doc.formInfo().hasFields)
        #expect(try ink(doc) >= before / 2 && before > 0)
        try doc.undo()
        #expect(try doc.fields(page: 0).count == 14)
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

    /// A field that is its own descendant: MuPDF's walks would recurse
    /// until the stack ran out, so the field is listed read-only and refused.
    @Test func cyclicFieldsAreRefused() throws {
        let doc = try Corpus.open("formcycle.pdf")
        let fields = try doc.fields(page: 0)
        let radio = try #require(fields.first { $0.kind == .radio })
        let text = try #require(fields.first { $0.name.hasPrefix("looptext") })
        #expect(radio.isReadOnly && text.isReadOnly)
        #expect(throws: EngineError.self) { try doc.toggle(page: 0, field: radio.id) }
        #expect(throws: EngineError.self) { try doc.setText("x", page: 0, field: text.id) }
        #expect(throws: EngineError.self) { try doc.deleteField(page: 0, id: radio.id) }
        #expect(throws: EngineError.self) { try doc.createField(.text, page: 0, rect: CGRect(x: 72, y: 500, width: 100, height: 20)) }
    }

    /// /Parent and /Kids that disagree: MuPDF walks down from the widget
    /// or its group, which the top field's tree doesn't show.
    @Test func disagreeingTreesAreRefused() throws {
        let doc = try Corpus.open("formbypass.pdf")
        let fields = try doc.fields(page: 0)
        #expect(fields.count == 3)
        #expect(fields.allSatisfy { $0.isReadOnly })
        let start = Date()
        for field in fields {
            if field.kind == .radio {
                #expect(throws: EngineError.self) { try doc.toggle(page: 0, field: field.id) }
            } else {
                #expect(throws: EngineError.self) { try doc.setText("x", page: 0, field: field.id) }
            }
        }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// A large but sound form stays fillable, and new fields are named quickly.
    @Test func largeFormsWork() throws {
        let doc = try Corpus.open("formbig.pdf")
        let fields = try doc.fields(page: 0)
        #expect(fields.count == 1001 && fields.allSatisfy { !$0.isReadOnly })
        try doc.setText("filled", page: 0, field: fields[500].id)
        let start = Date()
        try doc.createField(.text, page: 0, rect: CGRect(x: 72, y: 700, width: 100, height: 20))
        #expect(Date().timeIntervalSince(start) < 1)
    }

    /// Fields reached many times over: looking a name up would take
    /// 2^60 steps, so making or renaming fields is refused at once.
    @Test func sharedFieldsAreRefused() throws {
        let doc = try Corpus.open("formdag.pdf")
        let start = Date()
        #expect(throws: EngineError.self) { try doc.createField(.text, page: 0, rect: CGRect(x: 72, y: 500, width: 100, height: 20)) }
        let plain = try #require(try doc.fields(page: 0).first { $0.name == "plain" })
        var change = FieldChange()
        change.name = "renamed"
        #expect(throws: EngineError.self) { try doc.updateField(page: 0, id: plain.id, change) }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// Big or many options that cost little in the file: listing stays small and quick.
    @Test func heavyOptionsAreCapped() throws {
        let doc = try Corpus.open("formheavy.pdf")
        // Loading the page the first time makes the fields' appearances
        // (MuPDF, slow for 2,000 lists); the listing is what's timed.
        _ = try doc.displayList(page: 0)
        let start = Date()
        let fields = try doc.fields(page: 0)
        #expect(Date().timeIntervalSince(start) < 2)
        let bytes = fields.reduce(0) { $0 + $1.options.reduce(0) { $0 + $1.value.utf8.count + $1.label.utf8.count } }
        #expect(bytes <= 2 << 20)
        let options = fields.reduce(0) { $0 + $1.options.count }
        #expect(options < 100_000)
        #expect(try #require(fields.first { $0.name == "big" }).isReadOnly)
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
