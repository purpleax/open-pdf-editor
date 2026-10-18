import AppKit
import PDFCore

struct SearchMatch {
    let page: Int
    let range: Range<Int>
    /// In page space.
    let rects: [CGRect]
    /// Text around the match: before, match, after (on one line).
    let context: (before: String, match: String, after: String)
}

/// Searches the whole document in the background, streaming matches in
/// page order, and keeps track of the current match.
@MainActor
final class FindController {
    let model: DocumentModel

    private(set) var query = ""
    var options: SearchOptions = []
    private(set) var matches: [SearchMatch] = []
    private(set) var matchesByPage: [Int: [Int]] = [:]
    private(set) var currentIndex: Int?
    private(set) var isSearching = false
    private(set) var pagesSearched = 0

    /// Called after matches, the current match or progress change.
    var onChange: (() -> Void)?

    private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
    private var token: Token?

    init(model: DocumentModel) {
        self.model = model
    }

    var currentMatch: SearchMatch? { currentIndex.map { matches[$0] } }

    func search(_ text: String) {
        token?.cancel()
        token = nil
        query = text
        matches = []
        matchesByPage = [:]
        currentIndex = nil
        pagesSearched = 0
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            isSearching = false
            onChange?()
            return
        }
        isSearching = true
        onChange?()
        let token = Token()
        self.token = token
        let model = self.model
        let options = self.options
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [SearchMatch] = []
            var lastFlush = Date()
            let count = model.pageCount
            for page in 0..<count {
                if token.isCancelled { return }
                let pageText = model.text(page: page)
                for range in pageText.search(needle, options: options) {
                    batch.append(SearchMatch(page: page, range: range, rects: pageText.rects(for: range),
                                             context: Self.context(pageText, range)))
                }
                let done = page == count - 1
                if done || Date().timeIntervalSince(lastFlush) > 0.15 {
                    let found = batch
                    batch = []
                    lastFlush = Date()
                    DispatchQueue.main.async {
                        guard let self, self.token === token else { return }
                        self.receive(found, searched: page + 1, done: done)
                    }
                }
            }
        }
    }

    func cancel() {
        token?.cancel()
        token = nil
        isSearching = false
    }

    private func receive(_ found: [SearchMatch], searched: Int, done: Bool) {
        for match in found {
            matchesByPage[match.page, default: []].append(matches.count)
            matches.append(match)
        }
        pagesSearched = searched
        if done {
            isSearching = false
            token = nil
        }
        onChange?()
    }

    /// Moves to the next (or previous) match, starting from `page` when there
    /// is no current match yet. Nil when there are no matches.
    func step(forward: Bool, from page: Int) -> SearchMatch? {
        guard !matches.isEmpty else { return nil }
        if let index = currentIndex {
            currentIndex = forward ? (index + 1) % matches.count : (index - 1 + matches.count) % matches.count
        } else if forward {
            currentIndex = matches.firstIndex { $0.page >= page } ?? 0
        } else {
            currentIndex = matches.lastIndex { $0.page <= page } ?? matches.count - 1
        }
        onChange?()
        return currentMatch
    }

    func select(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        currentIndex = index
        onChange?()
    }

    func highlights(onPage page: Int) -> (all: [CGRect], current: [CGRect]) {
        guard let indices = matchesByPage[page] else { return ([], []) }
        var all: [CGRect] = []
        var current: [CGRect] = []
        for index in indices {
            if index == currentIndex { current += matches[index].rects } else { all += matches[index].rects }
        }
        return (all, current)
    }

    private nonisolated static func context(_ text: PageText, _ range: Range<Int>) -> (String, String, String) {
        let string = text.string as NSString
        let match = text.utf16Range(of: range)
        let start = max(0, match.location - 40)
        let end = min(string.length, match.location + match.length + 60)
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ")
        }
        var before = clean(string.substring(with: NSRange(location: start, length: match.location - start)))
        if start > 0 { before = "…" + String(before.drop(while: { $0 != " " }).dropFirst()) }
        let after = clean(string.substring(with: NSRange(location: match.location + match.length,
                                                         length: end - match.location - match.length)))
        return (before, clean(string.substring(with: match)), after)
    }
}
