import CoreGraphics
import Foundation
import Vision

/// Stops a recognition in progress: the page's render and Vision's request.
public final class RecognitionCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    private var cookie: RenderCookie?

    public init() {}

    public func cancel() {
        let (request, cookie) = lock.withLock {
            cancelled = true
            return (self.request, self.cookie)
        }
        request?.cancel()
        cookie?.cancel()
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs `body` with the cookie and request it can cancel; throws
    /// CancellationError if cancelled before or during.
    fileprivate func track<T>(cookie: RenderCookie? = nil, request: VNRequest? = nil, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            self.cookie = cookie
            self.request = request
        }
        defer { lock.withLock { self.cookie = nil; self.request = nil } }
        let result = try body()
        if isCancelled { throw CancellationError() }
        return result
    }
}

/// Text recognition (OCR) with Apple's Vision framework, on this Mac: a
/// page is drawn as an image and Vision reads the words on it.
public enum TextRecognizer {
    /// The resolution pages are read at.
    public static let dpi: CGFloat = 300

    /// Language codes Vision can read ("en-US", "fr-FR", ...).
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// Reads one page's text. Only the page's own contents are read (not its
    /// comments or form fields). `languages` empty means automatic.
    public static func recognize(_ doc: EngineDocument, page: Int, bounds: CGRect, languages: [String] = [],
                                 cancel: RecognitionCancel? = nil) throws -> RecognizedPage {
        let cancel = cancel ?? RecognitionCancel()
        let scale = renderScale(for: bounds)
        let cookie = RenderCookie()
        let image = try cancel.track(cookie: cookie) {
            try doc.renderPage(page, bounds: bounds, scale: scale, rotation: 0, contentsOnly: true, cookie: cookie)
        }
        let lines = try read(image, languages: languages, cancel: cancel)
        // Image pixels (Vision's normalised coordinates, origin bottom left)
        // to page space.
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func toPage(_ p: CGPoint) -> CGPoint {
            CGPoint(x: bounds.minX + p.x * width / scale, y: bounds.minY + (1 - p.y) * height / scale)
        }
        var words: [RecognizedWord] = []
        for line in lines {
            let start = words.count
            for word in line {
                words.append(RecognizedWord(text: word.text, upperLeft: toPage(word.quad[0]), upperRight: toPage(word.quad[1]),
                                            lowerLeft: toPage(word.quad[2]), lowerRight: toPage(word.quad[3])))
                if words.count >= RecognizedPage.maxWords { break }
            }
            // Each space reaches to the next word, along the baseline.
            for i in start..<max(start, words.count - 1) {
                let w = words[i], next = words[i + 1]
                let base = CGPoint(x: w.lowerRight.x - w.lowerLeft.x, y: w.lowerRight.y - w.lowerLeft.y)
                let length = (base.x * base.x + base.y * base.y).squareRoot()
                guard length > 0 else { continue }
                let gap = ((next.lowerLeft.x - w.lowerRight.x) * base.x + (next.lowerLeft.y - w.lowerRight.y) * base.y) / length
                words[i].spaceWidth = max(gap, 0.01)
            }
            if words.count >= RecognizedPage.maxWords { break }
        }
        return RecognizedPage(page: page, words: words)
    }

    /// The scale for `dpi`, made smaller for pages too big to render at it.
    public static func renderScale(for bounds: CGRect) -> CGFloat {
        let w = max(bounds.width, 1), h = max(bounds.height, 1)
        let side = CGFloat(EngineDocument.maxRenderSide) - 2
        let pixels = CGFloat(EngineDocument.maxRenderPixels) * 0.98
        return min(dpi / 72, side / w, side / h, (pixels / (w * h)).squareRoot())
    }

    /// A word in Vision's normalised coordinates: upper-left, upper-right,
    /// lower-left, lower-right.
    struct Word {
        var text: String
        var quad: [CGPoint]
    }

    /// Vision's lines, each split into words at whitespace (punctuation
    /// stays with its word), with a space after every word but a line's last.
    static func read(_ image: CGImage, languages: [String], cancel: RecognitionCancel) throws -> [[Word]] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try cancel.track(request: request) { try handler.perform([request]) }
        var lines: [[Word]] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = [observation.topLeft, observation.topRight, observation.bottomLeft, observation.bottomRight]
            let words = split(candidate, line: line)
            if !words.isEmpty { lines.append(words) }
        }
        return lines
    }

    /// The candidate's words with their boxes: Vision's own box for each word
    /// when it is believable, otherwise the line divided by characters.
    static func split(_ candidate: VNRecognizedText, line: [CGPoint]) -> [Word] {
        let string = candidate.string
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in string.indices {
            if string[index].isWhitespace {
                if let s = start { ranges.append(s..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<string.endIndex) }
        guard !ranges.isEmpty else { return [] }
        let total = max(1, string.count)
        // Along the line by share of characters: top and bottom edges.
        func along(_ t: CGFloat) -> (top: CGPoint, bottom: CGPoint) {
            (interpolate(line[0], line[1], t), interpolate(line[2], line[3], t))
        }
        let fallback = ranges.map { range -> [CGPoint] in
            let a = CGFloat(string.distance(from: string.startIndex, to: range.lowerBound)) / CGFloat(total)
            let b = CGFloat(string.distance(from: string.startIndex, to: range.upperBound)) / CGFloat(total)
            let (ul, ll) = along(a), (ur, lr) = along(b)
            return [ul, ur, ll, lr]
        }
        var quads = fallback
        if ranges.count > 1 {
            let own = ranges.map { range -> [CGPoint]? in
                guard let box = try? candidate.boundingBox(for: range) else { return nil }
                return [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight]
            }
            if own.allSatisfy({ $0 != nil }), believable(own.map { $0! }, line: line) { quads = own.map { $0! } }
        }
        var words: [Word] = []
        for (i, range) in ranges.enumerated() {
            var text = String(string[range])
            if i + 1 < ranges.count { text += " " }
            words.append(Word(text: text, quad: quads[i]))
        }
        return words
    }

    /// True when every word's box lies within the line (give or take 10% of
    /// its height), they run in order along it, and none is the whole line.
    static func believable(_ quads: [[CGPoint]], line: [CGPoint]) -> Bool {
        let base = CGPoint(x: line[3].x - line[2].x, y: line[3].y - line[2].y)
        let length = (base.x * base.x + base.y * base.y).squareRoot()
        guard length > 0 else { return false }
        let dir = CGPoint(x: base.x / length, y: base.y / length)
        let up = CGPoint(x: -dir.y, y: dir.x)
        let lineHeight = dot(CGPoint(x: line[0].x - line[2].x, y: line[0].y - line[2].y), up)
        let slack = abs(lineHeight) * 0.1 + 0.001
        func position(_ p: CGPoint) -> (along: CGFloat, across: CGFloat) {
            let v = CGPoint(x: p.x - line[2].x, y: p.y - line[2].y)
            return (dot(v, dir), dot(v, up))
        }
        var last = -CGFloat.infinity
        for quad in quads {
            let points = quad.map(position)
            for p in points {
                guard p.along >= -slack, p.along <= length + slack,
                      p.across >= min(0, lineHeight) - slack, p.across <= max(0, lineHeight) + slack else { return false }
            }
            let start = min(points[0].along, points[2].along), end = max(points[1].along, points[3].along)
            // The whole line again, or out of order.
            if end - start > length * 0.95 { return false }
            if start < last - slack { return false }
            last = end
        }
        return true
    }

    private static func interpolate(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
}
