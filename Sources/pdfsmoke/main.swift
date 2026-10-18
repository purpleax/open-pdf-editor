// Checks that MuPDF opens and renders a document:
//   pdfsmoke <in.pdf> <out.png> [page, from 1] [scale, default 2]
import Foundation
import ImageIO
import PDFCore
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pdfsmoke: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: pdfsmoke <in.pdf> <out.png> [page] [scale]") }
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
let page = (args.count > 3 ? Int(args[3]) : nil) ?? 1
let scale = (args.count > 4 ? Double(args[4]) : nil) ?? 2

do {
    let document = try EngineDocument(url: input)
    if document.needsPassword { fail("the document needs a password") }
    let count = try document.pageCount()
    guard (1...count).contains(page) else { fail("page \(page) is out of range (1-\(count))") }
    let size = try document.pageSize(page - 1)
    let start = Date()
    let image = try document.render(page: page - 1, scale: scale)
    let elapsed = Date().timeIntervalSince(start) * 1000
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(output.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(output.path)") }
    print("MuPDF \(EngineDocument.mupdfVersion): \(count) pages; page \(page) is \(Int(size.width))x\(Int(size.height)) pt;"
        + " rendered \(image.width)x\(image.height) px in \(String(format: "%.0f", elapsed)) ms -> \(output.path)")
} catch {
    fail("\(error)")
}
