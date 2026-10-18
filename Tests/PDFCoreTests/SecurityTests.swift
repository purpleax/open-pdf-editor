import CoreGraphics
import Foundation
import PDFCore
import Testing

/// Regression tests for the 0.1.0 security review.
@Suite struct SecurityTests {
    @Test func absurdPageSizesAreCapped() throws {
        let doc = try Corpus.open("huge.pdf")
        let bounds = try doc.pageBounds()
        #expect(bounds.count == 2)
        for rect in bounds {
            #expect(rect.width.isFinite && rect.height.isFinite)
            #expect(rect.width >= 1 && rect.height >= 1)
            #expect(rect.width <= EngineDocument.maxPageSide && rect.height <= EngineDocument.maxPageSide)
        }
        // A preview-sized render of the capped strip works.
        let strip = bounds[0]
        let scale = min(320 / strip.width, 512 / strip.height)
        let image = try doc.renderPage(0, bounds: strip, scale: scale)
        #expect(image.width >= 1 && image.height <= 513)
    }

    @Test func oversizedOrInvalidRendersAreRefused() throws {
        let doc = try Corpus.open("text.pdf")
        let bounds = try doc.pageBounds()[0]
        let list = try doc.displayList(page: 0)
        for rect in [
            CGRect(x: 0, y: 0, width: 20_000, height: 10),                // too wide
            CGRect(x: 0, y: 0, width: 10_000, height: 10_000),            // too many pixels
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),          // not finite
            CGRect(x: 3e9, y: 0, width: 10, height: 10),                  // past Int32
            CGRect(x: CGFloat(Int32.max) - 5, y: 0, width: 10, height: 10),
        ] {
            #expect(throws: EngineError.self) {
                _ = try doc.render(list, bounds: bounds, scale: 1, rotation: 0, rect: rect)
            }
        }
        #expect(throws: EngineError.self) {
            _ = try doc.render(list, bounds: bounds, scale: .infinity, rotation: 0, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        }
    }

    @Test func sanitizedBounds() {
        #expect(EngineDocument.sanitized(CGRect(x: 0, y: 0, width: 612, height: 792)) == CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(EngineDocument.sanitized(CGRect(x: 0, y: 0, width: 1e22, height: 10)).width == EngineDocument.maxPageSide)
        #expect(EngineDocument.sanitized(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)) == CGRect(x: 0, y: 0, width: 612, height: 792))
        #expect(EngineDocument.sanitized(CGRect(x: 0, y: 0, width: 0, height: 10)) == CGRect(x: 0, y: 0, width: 612, height: 792))
    }

    /// The outline is loaded on a thread with a 512 KB stack, as dispatch
    /// threads have: the depth check must stop it before MuPDF recurses.
    @Test func deepOutlineDoesNotOverflowTheStack() async throws {
        let doc = try Corpus.open("deep-outline.pdf")
        let result: Bool = await withCheckedContinuation { continuation in
            let thread = Thread {
                let threw = (try? doc.outline()) == nil
                continuation.resume(returning: threw)
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(result, "a 5,000-level outline should be refused, not loaded")
        // A normal outline still loads on a small stack.
        let normal = try Corpus.open("text.pdf")
        let count: Int = await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: (try? normal.outline())?.count ?? -1) }
            thread.stackSize = 512 * 1024
            thread.start()
        }
        #expect(count == 3)
    }

    @Test func onlyPDFsOpen() {
        // An HTML file named .pdf must not open in MuPDF's HTML engine.
        #expect(throws: EngineError.self) {
            let doc = try Corpus.open("not-a-pdf.pdf")
            _ = try doc.pageCount()
            _ = try doc.displayList(page: 0)
        }
    }

    @Test func attachmentNames() {
        #expect(AttachmentSafety.cleanFilename("invoice\u{202E}fdp.app") == "invoicefdp.app")
        #expect(AttachmentSafety.cleanFilename("../../etc/passwd") == "_.._etc_passwd")
        #expect(AttachmentSafety.cleanFilename("\u{0007}\u{0000}") == "attachment")
        #expect(AttachmentSafety.cleanFilename("  .hidden.txt ") == "hidden.txt")
        #expect(AttachmentSafety.cleanFilename("report.pdf") == "report.pdf")
    }

    @Test func riskyAttachments() {
        for name in ["Invoice.app", "run.command", "setup.pkg", "image.dmg", "files.zip", "script.sh", "tool", "macro.docm"] {
            #expect(AttachmentSafety.isRisky(name), "\(name) should be risky")
        }
        for name in ["notes.txt", "photo.jpg", "report.pdf", "data.csv"] {
            #expect(!AttachmentSafety.isRisky(name), "\(name) should not be risky")
        }
    }

    @Test func executorRunsWorkOnLargeStacks() async {
        let size: Int = await withCheckedContinuation { continuation in
            EngineExecutor.background.async(.high) {
                continuation.resume(returning: Thread.current.stackSize)
            }
        }
        #expect(size >= EngineExecutor.stackSize)
    }
}

@Suite struct PDFDateTests {
    @Test func validDates() throws {
        let date = try #require(PDFDate.parse("D:20240315103000+02'00'"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts.year == 2024 && parts.month == 3 && parts.day == 15 && parts.hour == 8 && parts.minute == 30)
        #expect(PDFDate.parse("D:2024") != nil)
        #expect(PDFDate.parse("20240315") != nil)
        #expect(PDFDate.parse("D:20240315103000Z") != nil)
        #expect(PDFDate.parse("D:20240315103000-05'30") != nil)
    }

    /// Hostile or broken dates give nil (the raw text is shown), never a crash.
    @Test func hostileDates() {
        for text in [
            "D:20240101000000+9999999999999999'00'",
            "D:20240101000000+99'00'",
            "D:20240101000000+05'99'",
            "D:20241399",
            "D:20240132",
            "D:20240101256000",
            "D:999999999999999999999999",
            "D:",
            "",
            "not a date",
            "D:٢٠٢٤٠١٠١",
        ] {
            #expect(PDFDate.parse(text) == nil, "\(text) should not parse")
        }
    }
}
