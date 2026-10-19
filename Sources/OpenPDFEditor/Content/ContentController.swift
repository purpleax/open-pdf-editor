import AppKit
import PDFCore

/// Something on a page that Edit Content changes.
enum ContentRef: Hashable {
    case link(page: Int, id: Int)

    var page: Int {
        switch self {
        case let .link(page, _): page
        }
    }
}

/// The content tools in the content bar.
enum ContentTool: String, CaseIterable {
    case select, link

    var title: String {
        switch self {
        case .select: "Select"
        case .link: "Link"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .link: "link"
        }
    }
}

/// A piece of page content as Edit Content shows it.
struct ContentItem {
    let ref: ContentRef
    let rect: CGRect
    /// A link's target, for the inspector.
    var link: PageLink?
}

/// Finds and changes page content: links (and, as Phase 5 goes on, images
/// and text). Every change goes through `DocumentModel.edit`, so it is one
/// undoable step and the page is redrawn.
@MainActor
final class ContentController {
    let model: DocumentModel

    init(model: DocumentModel) {
        self.model = model
    }

    func items(page: Int) -> [ContentItem] {
        model.links(page: page).filter { $0.id != 0 }.map {
            ContentItem(ref: .link(page: page, id: $0.id), rect: $0.rect, link: $0)
        }
    }

    func item(_ ref: ContentRef) -> ContentItem? {
        items(page: ref.page).first { $0.ref == ref }
    }

    /// The topmost item at a point in page space.
    func hit(_ point: CGPoint, page: Int, tolerance: CGFloat) -> ContentItem? {
        items(page: page).last { $0.rect.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point) }
    }

    private func clamp(_ rect: CGRect, page: Int) -> CGRect {
        let bounds = model.pageBounds[page]
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    func createLink(page: Int, rect: CGRect, to target: LinkTarget) throws -> ContentRef {
        let r = clamp(rect, page: page)
        let id = try model.edit("New Link", pages: [page]) { try $0.createLink(page: page, rect: r, to: target) }
        return .link(page: page, id: id)
    }

    func setTarget(_ ref: ContentRef, _ target: LinkTarget) throws {
        guard case let .link(page, id) = ref, let item = item(ref) else { return }
        try model.edit("Change Link", pages: [page]) { try $0.updateLink(page: page, id: id, rect: item.rect, to: target) }
    }

    /// Moves or resizes an item to `rect` (page space).
    func setRect(_ ref: ContentRef, _ rect: CGRect, actionName: String) throws {
        switch ref {
        case let .link(page, id):
            let r = clamp(rect, page: page)
            try model.edit(actionName, pages: [page]) { try $0.updateLink(page: page, id: id, rect: r) }
        }
    }

    func delete(_ ref: ContentRef) throws {
        switch ref {
        case let .link(page, id):
            try model.edit("Delete Link", pages: [page]) { try $0.deleteLink(page: page, id: id) }
        }
    }

    /// Describes a link's target for people.
    static func describe(_ link: PageLink) -> String {
        if let page = link.targetPage { return "Page \(page + 1)" }
        return link.uri
    }
}
