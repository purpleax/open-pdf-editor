import CoreGraphics
import MuPDFBridge

/// Where a link made here goes.
public enum LinkTarget: Equatable, Sendable {
    /// An http, https or mailto address.
    case web(String)
    /// A page of this document (from 0).
    case page(Int)
}

extension EngineDocument {
    /// Makes a link; returns its id.
    @discardableResult
    public func createLink(page: Int, rect: CGRect, to target: LinkTarget) throws -> Int {
        var error = opdf_error()
        let id: Int32
        switch target {
        case let .web(uri): id = opdf_link_create(handle, Int32(page), opdf_rect(rect), uri, -1, &error)
        case let .page(p): id = opdf_link_create(handle, Int32(page), opdf_rect(rect), nil, Int32(p), &error)
        }
        guard id > 0 else { throw EngineError(error) }
        return Int(id)
    }

    /// Moves or resizes a link, and changes where it goes if `target` is given.
    public func updateLink(page: Int, id: Int, rect: CGRect, to target: LinkTarget? = nil) throws {
        var error = opdf_error()
        let ok: Bool
        switch target {
        case nil: ok = opdf_link_update(handle, Int32(page), Int32(id), opdf_rect(rect), false, nil, -1, &error)
        case let .web(uri)?: ok = opdf_link_update(handle, Int32(page), Int32(id), opdf_rect(rect), true, uri, -1, &error)
        case let .page(p)?: ok = opdf_link_update(handle, Int32(page), Int32(id), opdf_rect(rect), true, nil, Int32(p), &error)
        }
        guard ok else { throw EngineError(error) }
    }

    public func deleteLink(page: Int, id: Int) throws {
        var error = opdf_error()
        guard opdf_link_delete(handle, Int32(page), Int32(id), &error) else { throw EngineError(error) }
    }
}

