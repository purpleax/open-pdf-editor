// Draws the app icon and writes an .icns file:
//   swift scripts/make-icon.swift Resources/AppIcon.icns
// A page with a folded corner, a "PDF" band and a pencil, on a red tile.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // macOS icon grid: an 824/1024 body with a soft shadow.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(red: 0.80, green: 0.16, blue: 0.16, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(red: 0.96, green: 0.36, blue: 0.30, alpha: 1),
               ending: NSColor(red: 0.74, green: 0.10, blue: 0.20, alpha: 1))!
        .draw(in: tile, angle: -90)

    // The page, with a folded top-right corner.
    let pw = body.width * 0.52, ph = body.height * 0.66
    let page = NSRect(x: body.midX - pw / 2 - body.width * 0.04, y: body.midY - ph / 2, width: pw, height: ph)
    let fold = pw * 0.24
    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: page.minX, y: page.minY))
    sheet.line(to: NSPoint(x: page.maxX, y: page.minY))
    sheet.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    sheet.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    sheet.line(to: NSPoint(x: page.minX, y: page.maxY))
    sheet.close()
    NSGraphicsContext.saveGraphicsState()
    let pageShadow = NSShadow()
    pageShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    pageShadow.shadowBlurRadius = s * 0.015
    pageShadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
    pageShadow.set()
    NSColor.white.setFill()
    sheet.fill()
    NSGraphicsContext.restoreGraphicsState()
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(white: 0.80, alpha: 1).setFill()
    corner.fill()

    // Lines of text.
    NSColor(white: 0.78, alpha: 1).setFill()
    let lineHeight = ph * 0.035
    for (i, width) in [0.62, 0.70, 0.55, 0.70, 0.48].enumerated() {
        let y = page.maxY - fold - ph * 0.10 - CGFloat(i) * ph * 0.085
        NSBezierPath(roundedRect: NSRect(x: page.minX + pw * 0.14, y: y, width: pw * width, height: lineHeight),
                     xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }

    // The "PDF" band across the lower part of the page.
    let band = NSRect(x: page.minX - pw * 0.08, y: page.minY + ph * 0.10, width: pw * 0.70, height: ph * 0.20)
    NSColor(red: 0.80, green: 0.12, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: band, xRadius: band.height * 0.18, yRadius: band.height * 0.18).fill()
    let label = NSAttributedString(string: "PDF", attributes: [
        .font: NSFont.systemFont(ofSize: band.height * 0.62, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: band.height * 0.04,
    ])
    let labelSize = label.size()
    label.draw(at: NSPoint(x: band.midX - labelSize.width / 2, y: band.midY - labelSize.height / 2))

    // A pencil leaning across the bottom-right corner.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: page.maxX - pw * 0.02, yBy: page.minY + ph * 0.22)
    transform.rotate(byDegrees: 45)
    transform.concat()
    let length = body.width * 0.46, thick = body.width * 0.085
    let shaft = NSRect(x: -thick / 2, y: -length * 0.15, width: thick, height: length)
    NSGraphicsContext.saveGraphicsState()
    let pencilShadow = NSShadow()
    pencilShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    pencilShadow.shadowBlurRadius = s * 0.012
    pencilShadow.shadowOffset = NSSize(width: s * 0.004, height: -s * 0.006)
    pencilShadow.set()
    NSColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 1).setFill()
    NSBezierPath(rect: shaft).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(red: 0.95, green: 0.62, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: shaft.minX, y: shaft.minY, width: thick / 3, height: length)).fill()
    // Eraser and ferrule.
    NSColor(red: 0.95, green: 0.55, blue: 0.60, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: shaft.minX, y: shaft.maxY - thick * 0.2, width: thick, height: thick * 0.7),
                 xRadius: thick * 0.2, yRadius: thick * 0.2).fill()
    NSColor(white: 0.75, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: shaft.minX, y: shaft.maxY - thick * 0.45, width: thick, height: thick * 0.35)).fill()
    // Sharpened wood and the lead.
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: shaft.minX, y: shaft.minY))
    tip.line(to: NSPoint(x: shaft.maxX, y: shaft.minY))
    tip.line(to: NSPoint(x: 0, y: shaft.minY - thick * 1.3))
    tip.close()
    NSColor(red: 0.96, green: 0.84, blue: 0.66, alpha: 1).setFill()
    tip.fill()
    let lead = NSBezierPath()
    lead.move(to: NSPoint(x: -thick * 0.17, y: shaft.minY - thick * 0.86))
    lead.line(to: NSPoint(x: thick * 0.17, y: shaft.minY - thick * 0.86))
    lead.line(to: NSPoint(x: 0, y: shaft.minY - thick * 1.3))
    lead.close()
    NSColor(white: 0.2, alpha: 1).setFill()
    lead.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.contains("--preview") {
    try render(512).write(to: URL(fileURLWithPath: output + ".png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(output)" : "iconutil failed")
exit(task.terminationStatus)
