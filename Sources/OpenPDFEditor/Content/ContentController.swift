import AppKit
import PDFCore

/// Something on a page that Edit Content changes.
enum ContentRef: Hashable {
    case link(page: Int, id: Int)
    /// An image drawing, by its order on the page.
    case image(page: Int, op: Int)

    var page: Int {
        switch self {
        case let .link(page, _), let .image(page, _): page
        }
    }

    /// For undo names: "Move Image".
    var noun: String {
        switch self {
        case .link: "Link"
        case .image: "Image"
        }
    }
}

/// The content tools in the content bar.
enum ContentTool: String, CaseIterable {
    case select, image, link

    var title: String {
        switch self {
        case .select: "Select"
        case .image: "Image"
        case .link: "Link"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .image: "photo"
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
    var image: ImagePlacement?
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

    /// Images, then links (on top).
    func items(page: Int) -> [ContentItem] {
        let images = (model.content(page: page)?.images ?? []).map {
            ContentItem(ref: .image(page: page, op: $0.op), rect: $0.rect, image: $0)
        }
        let links = model.links(page: page).filter { $0.id != 0 }.map {
            ContentItem(ref: .link(page: page, id: $0.id), rect: $0.rect, link: $0)
        }
        return images + links
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

    /// Adds an image file's picture to a page, filling `rect`; the new drawing is selected.
    func addImage(_ image: ImageImport.Prepared, page: Int, rect: CGRect) throws -> ContentRef {
        let r = clamp(rect, page: page)
        try model.edit("Add Image", pages: [page]) { try $0.addImage(image, page: page, rect: r) }
        let op = (model.content(page: page)?.images.last?.op) ?? 0
        return .image(page: page, op: op)
    }

    func replaceImage(_ ref: ContentRef, with image: ImageImport.Prepared) throws {
        guard case let .image(page, op) = ref else { return }
        try model.edit("Replace Image", pages: [page]) { try $0.replaceImage(page: page, op: op, with: image) }
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
        case let .image(page, op):
            try model.edit(actionName, pages: [page]) { try $0.setImageRect(page: page, op: op, rect: rect) }
        }
    }

    func delete(_ ref: ContentRef) throws {
        switch ref {
        case let .link(page, id):
            try model.edit("Delete Link", pages: [page]) { try $0.deleteLink(page: page, id: id) }
        case let .image(page, op):
            try model.edit("Delete Image", pages: [page]) { try $0.deleteImage(page: page, op: op) }
        }
    }

    /// Describes a link's target for people.
    static func describe(_ link: PageLink) -> String {
        if let page = link.targetPage { return "Page \(page + 1)" }
        return link.uri
    }
}
