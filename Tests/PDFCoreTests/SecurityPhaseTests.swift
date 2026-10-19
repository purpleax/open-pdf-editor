import CoreGraphics
import Foundation
import ImageIO
import PDFCore
import Security
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

@Suite struct RedactionTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    /// The saved file with every stream decompressed (by mutool), as text.
    private func uncompressed(_ url: URL) throws -> String {
        let out = temporaryURL("plain.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        let mutool = Process()
        mutool.executableURL = Corpus.root.appendingPathComponent("../mupdf/arm64/mutool").standardizedFileURL
        mutool.arguments = ["clean", "-d", url.path, out.path]
        try mutool.run()
        mutool.waitUntilExit()
        #expect(mutool.terminationStatus == 0)
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }

    private func mark(_ doc: EngineDocument, page: Int, quads: [Quad]? = nil, rect: CGRect? = nil) throws {
        var change = AnnotationChange(kind: .redact)
        change.quads = quads
        change.rect = rect
        _ = try doc.createAnnotation(page: page, change, actionName: "Redact")
    }

    @Test func textUnderMarksIsGone() throws {
        let doc = try Corpus.open("text.pdf")
        let text = try doc.text(page: 0)
        let fox = try #require(text.search("quick brown fox").first)
        try mark(doc, page: 0, quads: text.rects(for: fox).map(Quad.init))
        // An area over the web link's line.
        let visit = try #require(text.search("Visit example.com").first)
        try mark(doc, page: 0, rect: try #require(text.rects(for: visit).first).insetBy(dx: -2, dy: -2))
        try doc.applyRedactions()
        #expect(!doc.canUndo)
        #expect(try doc.annotations(page: 0).allSatisfy { $0.kind != .redact })
        let after = try doc.text(page: 0).string
        #expect(!after.contains("quick") && !after.contains("example.com"))
        #expect(after.contains("Chapter One") && after.contains("lazy dog"))   // the rest of the line stays
        #expect(try doc.links(page: 0).allSatisfy { !$0.uri.contains("example.com") })

        let out = temporaryURL("redacted.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let bytes = try uncompressed(out)
        #expect(!bytes.contains("quick") && !bytes.contains("example.com"))
        #expect(bytes.contains("Chapter Two"))
        #expect(try EngineDocument(url: out).text(page: 0).string.contains("lazy dog"))
    }

    @Test func annotationsAndFieldsUnderMarksAreGone() throws {
        let doc = try Corpus.open("forms.pdf")
        let name = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        try doc.setText("Grace Hopper", page: 0, field: name.id)
        var note = AnnotationChange(kind: .text)
        note.rect = CGRect(x: name.rect.midX, y: name.rect.minY, width: 20, height: 20)
        note.contents = "secret note"
        let id = try doc.createAnnotation(page: 0, note, actionName: "Note")
        _ = try doc.reply(page: 0, to: id, author: "Ada", contents: "secret reply")
        var kept = AnnotationChange(kind: .text)
        kept.rect = CGRect(x: 500, y: 20, width: 20, height: 20)
        kept.contents = "kept note"
        _ = try doc.createAnnotation(page: 0, kept, actionName: "Note")
        try mark(doc, page: 0, rect: name.rect.insetBy(dx: -4, dy: -4))
        try doc.applyRedactions()

        #expect(try doc.fields(page: 0).allSatisfy { $0.name != "name" })
        let contents = try doc.annotations(page: 0).map(\.contents)
        #expect(contents.contains("kept note") && !contents.contains("secret note") && !contents.contains("secret reply"))
        let out = temporaryURL("redacted-form.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let bytes = try uncompressed(out)
        #expect(!bytes.contains("Grace") && !bytes.contains("Ada)") && !bytes.contains("secret"))
        #expect(bytes.contains("kept note"))
    }

    @Test func encryptedDocumentsStayEncrypted() throws {
        let doc = try Corpus.open("encrypted.pdf")
        #expect(doc.authenticate(password: "secret"))
        let text = try doc.text(page: 0)
        let fox = try #require(text.search("quick brown fox").first)
        try mark(doc, page: 0, quads: text.rects(for: fox).map(Quad.init))
        try doc.applyRedactions(openPassword: "secret")
        let out = temporaryURL("redacted-locked.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        #expect(reopened.needsPassword && reopened.authenticate(password: "secret"))
        #expect(try !reopened.text(page: 0).string.contains("quick"))
    }

    @Test func nothingMarkedChangesNoText() throws {
        let doc = try Corpus.open("text.pdf")
        let before = try doc.text(page: 0).string
        try doc.applyRedactions()
        #expect(try doc.text(page: 0).string == before)
    }
}

@Suite struct SignatureTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-\(name)")
    }

    private func identity() throws -> SecIdentity { try Self.testIdentity() }

    /// The corpus's self-signed test identity, kept in memory only.
    static func testIdentity(_ name: String = "signer.p12") throws -> SecIdentity {
        guard #available(macOS 15, *) else { throw EngineError(code: -1, message: "needs macOS 15") }
        let data = try Data(contentsOf: Corpus.root.appendingPathComponent(name))
        let options: [String: Any] = [kSecImportExportPassphrase as String: "test", kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw EngineError(code: Int(status), message: "the test identity couldn't be imported")
        }
        return identity as! SecIdentity
    }

    private func signatureField(_ doc: EngineDocument) throws -> FormField {
        try #require(try doc.fields(page: 0).first { $0.kind == .signature })
    }

    @Test func signsAndVerifies() throws {
        let doc = try Corpus.open("forms.pdf")
        #expect(try doc.signatures().map(\.isSigned) == [false])
        let name = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        try doc.setText("Grace", page: 0, field: name.id)   // an unsaved change, signed with the rest
        let field = try signatureField(doc)
        try doc.sign(page: 0, field: field.id, identity: identity(), reason: "Approved", location: "London")
        #expect(!doc.canUndo)
        let signature = try #require(try doc.signatures().first)
        #expect(signature.isSigned && signature.integrity == .valid && signature.trust == .selfSigned)
        #expect(signature.signer == "Open PDF Editor Test" && signature.email == "test@example.com")
        #expect(signature.reason == "Approved" && signature.location == "London" && !signature.changedAfter)
        #expect(abs((signature.signingTime ?? .distantPast).timeIntervalSinceNow) < 120)
        #expect(throws: EngineError.self) { try doc.sign(page: 0, field: field.id, identity: try identity()) }

        // Saving without changes writes the signed bytes as they are.
        let out = temporaryURL("signed.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        let again = try #require(try reopened.signatures().first)
        #expect(again.integrity == .valid && !again.changedAfter)
        #expect(try reopened.fields(page: 0).first { $0.name == "name" }?.value == "Grace")
    }

    @Test func changesAfterSigningAndTampering() throws {
        let doc = try Corpus.open("forms.pdf")
        try doc.sign(page: 0, field: try signatureField(doc).id, identity: identity())
        let name = try #require(try doc.fields(page: 0).first { $0.name == "name" })
        try doc.setText("Changed", page: 0, field: name.id)
        let out = temporaryURL("changed.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let changed = try #require(try EngineDocument(url: out).signatures().first)
        #expect(changed.integrity == .valid && changed.changedAfter)

        // One byte changed inside the signed part.
        var bytes = try Data(contentsOf: out)
        let at = try #require(bytes.range(of: Data("Your name".utf8)))
        bytes[at.lowerBound + 5] = UInt8(ascii: "N")
        try bytes.write(to: out)
        let tampered = try #require(try EngineDocument(url: out).signatures().first)
        #expect(tampered.integrity == .invalid)
    }

    @Test func certificatesForOtherUsesArentForSigning() throws {
        let doc = try Corpus.open("forms.pdf")
        try doc.sign(page: 0, field: try signatureField(doc).id, identity: Self.testIdentity("website.p12"))
        let signature = try #require(try doc.signatures().first)
        #expect(signature.integrity == .valid && signature.trust == .notForSigning)
    }

    @Test func emailCertificatesMaySign() throws {
        let doc = try Corpus.open("forms.pdf")
        try doc.sign(page: 0, field: try signatureField(doc).id, identity: Self.testIdentity("email.p12"))
        let signature = try #require(try doc.signatures().first)
        #expect(signature.integrity == .valid && signature.trust == .selfSigned && signature.signer == "Ada Lovelace")
    }

    @Test func encryptedDocumentsSign() throws {
        let doc = try Corpus.open("forms.pdf")
        try doc.rebase(encryption: .aes256(user: "", owner: "owner", permissions: .all))
        try doc.sign(page: 0, field: try signatureField(doc).id, identity: identity(), picture: ImageStampTests.picture(),
                     openPassword: "owner")
        let out = temporaryURL("signed-encrypted.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        #expect(reopened.isEncrypted)
        let signature = try #require(try reopened.signatures().first)
        #expect(signature.integrity == .valid && signature.trust == .selfSigned)
    }
}

@Suite struct ImageStampTests {
    /// A 40 × 20 PNG: black on transparent, as a drawn signature is.
    static func picture() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func roundTripsAndDraws() throws {
        let doc = try Corpus.open("text.pdf")
        let rect = CGRect(x: 300, y: 400, width: 120, height: 60)
        let id = try doc.createImageStamp(page: 0, rect: rect, image: Self.picture(), author: "Ada", actionName: "Signature")
        #expect(doc.canUndo)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-stamp.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let reopened = try EngineDocument(url: out)
        let stamp = try #require(try reopened.annotations(page: 0).first { $0.id == id })
        #expect(stamp.kind == .stamp && stamp.author == "Ada")
        #expect(abs(stamp.rect.midX - rect.midX) < 1 && abs(stamp.rect.midY - rect.midY) < 1)
        // Drawn: the middle of the stamp is dark.
        let bounds = try reopened.pageBounds()[0]
        let image = try reopened.renderPage(0, bounds: bounds, scale: 1)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -rect.midX, y: -(bounds.height - rect.midY), width: CGFloat(image.width), height: CGFloat(image.height)))
        let pixel = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        #expect(pixel[0] < 80 && pixel[1] < 80 && pixel[2] < 80)
    }

    @Test func refusesNonImages() throws {
        let doc = try Corpus.open("text.pdf")
        #expect(throws: EngineError.self) {
            try doc.createImageStamp(page: 0, rect: CGRect(x: 10, y: 10, width: 50, height: 50), image: Data("not an image".utf8),
                                     author: nil, actionName: "Signature")
        }
    }
}

@Suite struct SignatureForgeryTests {
    /// A signature over `content` by the test identity, detached or carrying
    /// the content inside it.
    private func cms(_ content: Data, detached: Bool, identity: SecIdentity) throws -> Data {
        var encoder: CMSEncoder?
        #expect(CMSEncoderCreate(&encoder) == errSecSuccess)
        let e = try #require(encoder)
        #expect(CMSEncoderAddSigners(e, identity) == errSecSuccess)
        #expect(CMSEncoderSetHasDetachedContent(e, detached) == errSecSuccess)
        _ = content.withUnsafeBytes { CMSEncoderUpdateContent(e, $0.baseAddress!, content.count) }
        var out: CFData?
        #expect(CMSEncoderCopyEncodedContent(e, &out) == errSecSuccess)
        return try #require(out) as Data
    }

    /// The signed file with its signature swapped for another (padded with zeros).
    private func swapped(_ signed: Data, for signature: Data) throws -> Data {
        var bytes = signed
        let start = try #require(bytes.range(of: Data("/Contents<".utf8))).upperBound
        let end = try #require(bytes[start...].firstIndex(of: UInt8(ascii: ">")))
        var hex = Array(signature.map { String(format: "%02x", $0) }.joined().utf8)
        #expect(hex.count <= end - start)
        hex += Array(repeating: UInt8(ascii: "0"), count: end - start - hex.count)
        bytes.replaceSubrange(start..<end, with: hex)
        return bytes
    }

    @Test func signaturesCarryingTheirOwnContentAreRejected() throws {
        let identity = try SignatureTests.testIdentity()
        let doc = try Corpus.open("forms.pdf")
        try doc.sign(page: 0, field: try #require(try doc.fields(page: 0).first { $0.kind == .signature }).id, identity: identity)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-forged.pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try doc.save(to: out)
        let signed = try Data(contentsOf: out)

        // Signed content inside the signature: checked against that, it would pass.
        try swapped(signed, for: cms(Data("something else entirely".utf8), detached: false, identity: identity)).write(to: out)
        let attached = try #require(try EngineDocument(url: out).signatures().first)
        #expect(attached.integrity == .malformed)
        // Even with nothing inside.
        try swapped(signed, for: cms(Data(), detached: false, identity: identity)).write(to: out)
        #expect(try EngineDocument(url: out).signatures().first?.integrity == .malformed)
        // A detached signature over other bytes doesn't match.
        try swapped(signed, for: cms(Data("other bytes".utf8), detached: true, identity: identity)).write(to: out)
        #expect(try EngineDocument(url: out).signatures().first?.integrity == .invalid)
    }
}

@Suite struct RedactionLeftoverTests {
    @Test func siblingWidgetsReferencedNotesAndXFA() throws {
        let doc = try Corpus.open("redact.pdf")
        for rect in [CGRect(x: 70, y: 70, width: 232, height: 24), CGRect(x: 398, y: 70, width: 24, height: 24),
                     CGRect(x: 398, y: 170, width: 104, height: 24)] {
            var mark = AnnotationChange(kind: .redact)
            mark.rect = rect
            _ = try doc.createAnnotation(page: 0, mark, actionName: "Redact")
        }
        try doc.applyRedactions()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-leftovers.pdf")
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("opdf-\(UUID().uuidString)-plain.pdf")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: plain)
        }
        try doc.save(to: out)
        let mutool = Process()
        mutool.executableURL = Corpus.root.appendingPathComponent("../mupdf/arm64/mutool").standardizedFileURL
        mutool.arguments = ["clean", "-d", out.path, plain.path]
        try mutool.run()
        mutool.waitUntilExit()
        let bytes = String(decoding: try Data(contentsOf: plain), as: UTF8.self)
        #expect(!bytes.contains("secret-sibling"))
        #expect(!bytes.contains("secret-in-struct"))
        #expect(!bytes.contains("xfa-secret"))
        #expect(!bytes.contains("secret-link"))
        #expect(try !doc.formInfo().hasXFA)
    }
}
