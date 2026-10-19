import CoreGraphics
import Foundation
import PDFCore
import Testing

@Suite struct RebaseTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    private func revisions(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        var count = 0, from = data.startIndex
        while let r = data.range(of: Data("%%EOF".utf8), in: from..<data.endIndex) { count += 1; from = r.upperBound }
        return count
    }

    @Test func keepsTheDocumentAndDropsHistory() throws {
        let doc = try Corpus.open("forms.pdf")
        let name = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        try doc.setText("Grace", page: 0, field: name.id)
        var note = AnnotationChange(kind: .text)
        note.rect = CGRect(x: 400, y: 100, width: 20, height: 20)
        note.contents = "kept"
        try doc.createAnnotation(page: 0, note, actionName: "Note")
        try doc.rebase()
        #expect(!doc.canUndo)
        #expect(try doc.fields(page: 0).first { $0.name == "name" }?.value == "Grace")
        #expect(try doc.annotations(page: 0).contains { $0.contents == "kept" })
        // Editing and saving go on from the new bytes, in one revision plus changes.
        try doc.setText("Ada", page: 0, field: name.id)
        let out = temporaryURL("rebased.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(try revisions(out) == 2)
        #expect(try EngineDocument(url: out).fields(page: 0).first { $0.name == "name" }?.value == "Ada")
    }

    @Test func scrubRemovesLeftovers() throws {
        let doc = try Corpus.open("xmp.pdf")
        try doc.rebase(scrub: true)
        let out = temporaryURL("scrubbed.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        #expect(try revisions(out) == 1)
        let text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        #expect(!text.contains("make-corpus") || text.contains("<pdf:Producer>make-corpus"))   // XMP rebuilt from Info
    }

    @Test func encryptedDocumentsKeepTheirPassword() throws {
        let doc = try Corpus.open("encrypted.pdf")
        #expect(doc.authenticate(password: "secret"))
        try doc.rebase(openPassword: "secret")
        let out = temporaryURL("still-encrypted.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        #expect(reopened.needsPassword && reopened.authenticate(password: "secret"))
    }

    @Test func setChangeAndRemoveAPassword() throws {
        let doc = try Corpus.open("text.pdf")
        try doc.rebase(encryption: .aes256(user: "pässwört", owner: "owner", permissions: [.print]))
        let out = temporaryURL("locked.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        var reopened = try EngineDocument(url: out)
        #expect(reopened.needsPassword && !reopened.authenticate(password: "wrong"))
        #expect(reopened.authenticate(password: "pässwört"))
        #expect(reopened.metadata("encryption")?.contains("AES") == true)
        #expect(try reopened.text(page: 0).string.contains("Chapter One"))
        try doc.rebase(encryption: .none, openPassword: "owner")
        try doc.save(to: out)
        reopened = try EngineDocument(url: out)
        #expect(!reopened.needsPassword)
    }
}

@Suite struct PermissionTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    @Test func userAndOwnerAccess() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(doc.isOwner && doc.allowed == .everything && !doc.isEncrypted)
        try doc.rebase(encryption: .aes256(user: "user", owner: "owner", permissions: [.print, .annotate]))
        #expect(doc.isOwner && doc.isEncrypted)
        let out = temporaryURL("restricted.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)

        let asUser = try EngineDocument(url: out)
        #expect(asUser.authenticate(password: "user"))
        #expect(!asUser.isOwner)
        #expect(asUser.allowed.contains(.print) && asUser.allowed.contains(.annotate))
        #expect(!asUser.allowed.contains(.copy) && !asUser.allowed.contains(.edit) && !asUser.allowed.contains(.assemble))

        let asOwner = try EngineDocument(url: out)
        #expect(asOwner.authenticate(password: "owner"))
        #expect(asOwner.isOwner && asOwner.allowed == .everything)
        // The user can become the owner by giving its password.
        #expect(asUser.authenticate(password: "owner") && asUser.isOwner)
    }

    @Test func whatTheSheetReadsBack() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(!doc.needsPasswordToOpen && doc.ownerAllowedToUser == .all)
        // Restricted, but opens without a password: no password is asked for,
        // and the user's access is the granted bits.
        try doc.rebase(encryption: .aes256(user: "", owner: "владелец", permissions: [.print, .fillForms]))
        #expect(!doc.needsPasswordToOpen && doc.ownerAllowedToUser == [.print, .fillForms])
        let out = temporaryURL("opens-freely.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        #expect(!reopened.needsPassword && !reopened.needsPasswordToOpen)
        #expect(!reopened.isOwner && reopened.allowed.contains(.fillForms) && !reopened.allowed.contains(.annotate))
        #expect(reopened.ownerAllowedToUser == [.print, .fillForms])
        #expect(reopened.authenticate(password: "владелец") && reopened.isOwner)

        try doc.rebase(encryption: .aes256(user: "密码", owner: "владелец", permissions: .all), openPassword: "владелец")
        #expect(doc.needsPasswordToOpen)
        try doc.save(to: out)
        let locked = try EngineDocument(url: out)
        #expect(locked.needsPassword && locked.needsPasswordToOpen && locked.authenticate(password: "密码"))
    }
}
