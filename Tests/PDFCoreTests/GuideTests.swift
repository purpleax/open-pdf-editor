import CoreGraphics
import Foundation
import PDFCore
import Testing

/// The user guide, as `make guide` builds it from docs/guide.
@Suite struct GuideTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardizedFileURL
    static let guide = repository.appendingPathComponent("build/guide/Guide.pdf")

    private func open() throws -> EngineDocument {
        guard FileManager.default.fileExists(atPath: Self.guide.path) else {
            throw EngineError(code: -1, message: "build/guide/Guide.pdf is missing: run make guide")
        }
        return try EngineDocument(url: Self.guide)
    }

    /// All the guide's text, with line breaks as spaces.
    private func text(_ doc: EngineDocument) throws -> String {
        try (0..<doc.pageCount()).map { try doc.text(page: $0).string }.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func chaptersAndLinks() throws {
        let doc = try open()
        #expect(try doc.pageCount() >= 20)
        let chapters = try doc.outline().map(\.title)
        for chapter in ["Getting started", "Reading PDFs", "Comments and markup", "Working with pages", "Forms",
                        "Editing text and images", "Redaction", "Passwords and permissions", "Signatures",
                        "Recognising text in scans", "Exporting", "Saving and undo", "Settings", "Keyboard shortcuts",
                        "Privacy, updates and help"] {
            #expect(chapters.contains(chapter), "no bookmark for \(chapter)")
        }
        #expect(try doc.outline().allSatisfy { $0.page != nil })
        // The contents page links to every chapter, and every link inside the
        // guide goes to a page.
        let contents = try doc.links(page: 1)
        #expect(contents.filter { !$0.isExternal }.count >= 15)
        for page in 0..<(try doc.pageCount()) {
            for link in try doc.links(page: page) where !link.isExternal {
                #expect(link.targetPage != nil, "a link on page \(page + 1) goes nowhere")
            }
        }
        #expect(doc.metadata("info:Title")?.hasPrefix("Open PDF Editor Guide") == true)
    }

    @Test func searchable() throws {
        let doc = try open()
        let all = try text(doc)
        for phrase in ["Tools › Recognise Text…", "Apply Redactions…", "Check certificates online", "⌥⌘E"] {
            #expect(all.contains(phrase), "\(phrase) isn't in the guide")
        }
    }

    @Test func screenshotsAreThere() throws {
        let doc = try open()
        let bounds = try doc.pageBounds()
        // The getting-started chapter (page 3) has the welcome window: a
        // page with a picture has far more ink than text alone.
        let image = try doc.renderPage(2, bounds: bounds[2], scale: 0.5)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let coloured = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 200 || pixels[$0 + 2] < 200 }.count
        #expect(coloured > image.width * image.height / 20)
        // Every picture the HTML names is in the repository.
        let html = try String(contentsOf: Self.repository.appendingPathComponent("docs/guide/guide.html"), encoding: .utf8)
        let names = html.matches(of: /src="(images\/[^"]+)"/).map { String($0.1) }
        #expect(names.count >= 15)
        for name in names {
            #expect(FileManager.default.fileExists(atPath: Self.repository.appendingPathComponent("docs/guide/" + name).path), "\(name) is missing")
        }
    }

    /// Every command in the app's menus is named in the guide, so the guide
    /// keeps up as menus change.
    @Test func everyMenuCommandIsInTheGuide() throws {
        let all = try text(try open())
        let sources = Self.repository.appendingPathComponent("Sources/OpenPDFEditor")
        let menu = try String(contentsOf: sources.appendingPathComponent("App/MainMenu.swift"), encoding: .utf8)
        var titles = menu.matches(of: /withTitle: "([^"]+)"/).map { String($0.1) }
        titles += menu.matches(of: /\(\s*"([^"]+)",\s*(?:"|#selector)/).map { String($0.1) }
        for file in ["Annotating/AnnotationTool.swift", "Forms/FieldTool.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            let titleBlock = source.components(separatedBy: "var title: String {").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
            titles += titleBlock.matches(of: /: "([^"]+)"/).map { String($0.1) }
        }
        let standard: Set<String> = ["Services", "Hide \\(name)", "Hide Others", "Show All", "Quit \\(name)", "Open Recent", "Clear Menu",
                                     "Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "Find", "Font", "Text",
                                     "Minimize", "Zoom", "Bring All to Front", "Close", "Duplicate", "Rename…", "Move To…", "Revert To",
                                     "About \\(name)", "Status", "Done"]
        let checked = Set(titles).subtracting(standard).map { $0.replacingOccurrences(of: "\\(name)", with: "Open PDF Editor") }
        #expect(checked.count > 80)
        for title in checked.sorted() {
            #expect(all.contains(title), "the guide doesn't mention “\(title)”")
        }
    }
}
