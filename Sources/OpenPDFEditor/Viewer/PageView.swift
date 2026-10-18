import AppKit
import PDFCore

/// One page on screen. Its frame is the page's size in points (after the
/// view rotation); the scroll view's magnification does the zooming.
///
/// The page is drawn with layers: a low-resolution preview of the whole
/// page, then sharp tiles rendered for the current scale on top. Tiles of
/// the previous scale stay until the new ones cover the visible area, so
/// zooming never flashes blank. Highlights and the text selection are
/// shape layers above the tiles. Mouse events go to the PagesView.
@MainActor
final class PageView: NSView {
    static let previewWidth = 320

    private(set) var page = -1
    private var rotation = 0
    private var revision = 0
    private let renderer: TileRenderer

    private let previewLayer = CALayer()
    private let tileContainer = CALayer()
    private let searchLayer = CAShapeLayer()
    private let currentMatchLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let draftLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()

    private var tileLayers: [RenderKey: CALayer] = [:]
    private var tickets: [RenderKey: RenderTicket] = [:]
    private var previewTicket: RenderTicket?
    private var currentLevel: Int?

    init(renderer: TileRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        guard let layer else { return }
        layer.backgroundColor = NSColor.white.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
        previewLayer.contentsGravity = .resize
        previewLayer.magnificationFilter = .linear
        for sub in [previewLayer, tileContainer] {
            sub.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.addSublayer(sub)
        }
        for (shape, color, multiply) in [
            (searchLayer, NSColor.systemYellow.withAlphaComponent(0.55), true),
            (currentMatchLayer, NSColor.systemOrange.withAlphaComponent(0.75), true),
            (selectionLayer, NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6), true),
        ] {
            shape.fillColor = color.cgColor
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            if multiply { shape.compositingFilter = "multiplyBlendMode" }
            layer.addSublayer(shape)
        }
        // Annotation editing: a shape being drawn, and the selection outline and grips.
        for shape in [draftLayer, outlineLayer, handleLayer] {
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
            shape.fillColor = nil
            shape.zPosition = 10
            layer.addSublayer(shape)
        }
        outlineLayer.lineDashPattern = [4, 3]
        outlineLayer.lineWidth = 1
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.lineWidth = 1
        applyAccentColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in [previewLayer, tileContainer, searchLayer, currentMatchLayer, selectionLayer, draftLayer, outlineLayer, handleLayer] {
            sub.frame = bounds
        }
        CATransaction.commit()
    }

    /// Shows a page (when a view is reused, everything from the last page
    /// goes). True when anything changed, so highlights must be set again.
    @discardableResult
    func configure(page: Int, rotation: Int, revision: Int) -> Bool {
        guard page != self.page || rotation != self.rotation || revision != self.revision else { return false }
        if page == self.page && rotation == self.rotation {
            // The same page, redrawn after an edit: keep showing the old
            // images until the new ones arrive, so nothing flickers.
            previewTicket?.cancel()
            for ticket in tickets.values { ticket.cancel() }
            tickets.removeAll()
        } else {
            clear()
        }
        self.page = page
        self.rotation = rotation
        self.revision = revision
        let key = RenderKey.preview(page: page, width: Self.previewWidth, rotation: rotation, revision: revision)
        previewTicket = renderer.request(key, priority: .high) { [weak self] image in
            guard let self, self.page == page else { return }
            self.previewTicket = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.previewLayer.contents = image
            CATransaction.commit()
        }
        return true
    }

    /// Cancels renders and forgets the page's images.
    func clear() {
        previewTicket?.cancel()
        previewTicket = nil
        for ticket in tickets.values { ticket.cancel() }
        tickets.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tileLayers.values { layer.removeFromSuperlayer() }
        tileLayers.removeAll()
        previewLayer.contents = nil
        searchLayer.path = nil
        currentMatchLayer.path = nil
        selectionLayer.path = nil
        draftLayer.path = nil
        outlineLayer.path = nil
        handleLayer.path = nil
        CATransaction.commit()
        currentLevel = nil
        page = -1
    }

    /// Renders the tiles needed to show `visible` (in this view's
    /// coordinates) sharply at `deviceScale` pixels per point.
    func updateTiles(visible: CGRect, deviceScale: CGFloat) {
        guard page >= 0 else { return }
        let size = bounds.size
        let level = TileRenderer.level(forScale: deviceScale)
        let scale = TileRenderer.scale(forLevel: level)
        let pixelSize = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        // Page sizes are capped by the engine; this keeps the integer maths
        // below safe whatever happens.
        guard pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width < 1e9, pixelSize.height < 1e9 else { return }
        let tilePoints = CGFloat(TileRenderer.tileSize) / scale
        let area = visible.intersection(bounds).insetBy(dx: -tilePoints / 2, dy: -tilePoints / 2).intersection(bounds)

        // Small enough that the preview is as sharp as tiles would be.
        let previewIsEnough = pixelSize.width <= CGFloat(Self.previewWidth) && pixelSize.height <= CGFloat(Self.previewWidth) * 1.6
        var needed = Set<RenderKey>()
        if !area.isNull && !area.isEmpty && !previewIsEnough {
            let columns = Int((pixelSize.width / CGFloat(TileRenderer.tileSize)).rounded(.up))
            let rows = Int((pixelSize.height / CGFloat(TileRenderer.tileSize)).rounded(.up))
            let c0 = max(0, Int(area.minX / tilePoints)), c1 = min(columns - 1, Int((area.maxX - 0.001) / tilePoints))
            let r0 = max(0, Int(area.minY / tilePoints)), r1 = min(rows - 1, Int((area.maxY - 0.001) / tilePoints))
            if c0 <= c1 && r0 <= r1 {
                for row in r0...r1 {
                    for column in c0...c1 {
                        needed.insert(.tile(page: page, level: level, column: column, row: row, rotation: rotation, revision: revision))
                    }
                }
            }
        }
        currentLevel = level

        for (key, ticket) in tickets where !needed.contains(key) {
            ticket.cancel()
            tickets[key] = nil
        }
        for key in needed where tileLayers[key] == nil && tickets[key] == nil {
            if let image = renderer.cached(key) {
                install(key, image)
            } else {
                tickets[key] = renderer.request(key, priority: .high) { [weak self] image in
                    guard let self else { return }
                    self.tickets[key] = nil
                    if case let .tile(page, level, _, _, rotation, revision) = key,
                       page == self.page, level == self.currentLevel, rotation == self.rotation, revision == self.revision {
                        self.install(key, image)
                        self.pruneStaleTiles()
                    }
                }
            }
        }
        pruneStaleTiles(keeping: needed)
    }

    private func install(_ key: RenderKey, _ image: CGImage) {
        guard case let .tile(_, level, column, row, _, _) = key else { return }
        let scale = TileRenderer.scale(forLevel: level)
        let tilePoints = CGFloat(TileRenderer.tileSize) / scale
        let layer = CALayer()
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.contents = image
        layer.contentsGravity = .resize
        layer.zPosition = 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: CGFloat(column) * tilePoints, y: CGFloat(row) * tilePoints,
                             width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        tileContainer.addSublayer(layer)
        CATransaction.commit()
        tileLayers[key] = layer
    }

    /// Removes tiles that are no longer wanted. Tiles of another level stay
    /// while any wanted tile of the current level is still rendering.
    private func pruneStaleTiles(keeping needed: Set<RenderKey>? = nil) {
        let waiting = !tickets.isEmpty
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, layer) in tileLayers {
            guard case let .tile(_, level, _, _, _, revision) = key else { continue }
            let isCurrent = level == currentLevel && revision == self.revision
            let drop: Bool
            if isCurrent {
                drop = needed.map { !$0.contains(key) } ?? false
            } else {
                layer.zPosition = 0
                drop = !waiting
            }
            if drop {
                layer.removeFromSuperlayer()
                tileLayers[key] = nil
            }
        }
        CATransaction.commit()
    }

    // MARK: Highlights

    /// Search matches and the current match, in page space.
    func setSearchHighlights(_ rects: [CGRect], current: [CGRect], transform: CGAffineTransform) {
        searchLayer.path = path(rects, transform)
        currentMatchLayer.path = path(current, transform)
    }

    /// The text selection, in page space.
    func setSelection(_ rects: [CGRect], transform: CGAffineTransform) {
        selectionLayer.path = path(rects, transform)
    }

    private func path(_ rects: [CGRect], _ transform: CGAffineTransform) -> CGPath? {
        guard !rects.isEmpty else { return nil }
        let path = CGMutablePath()
        for rect in rects { path.addRect(rect.applying(transform).insetBy(dx: -0.5, dy: -0.5)) }
        return path
    }

    // MARK: Annotation editing

    /// The selected annotation's outline and grips (page space), or none.
    /// `zoom` keeps the grips the same size on screen.
    func setAnnotationSelection(outline: CGPath?, handles: [CGPoint], transform: CGAffineTransform, zoom: CGFloat) {
        var t = transform
        outlineLayer.path = outline?.copy(using: &t)
        guard !handles.isEmpty else {
            handleLayer.path = nil
            return
        }
        let size = 7 / max(zoom, 0.05)
        let path = CGMutablePath()
        for point in handles {
            let p = point.applying(transform)
            path.addRect(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
        }
        handleLayer.path = path
        outlineLayer.lineWidth = 1 / max(zoom, 0.05)
        handleLayer.lineWidth = 1 / max(zoom, 0.05)
        outlineLayer.lineDashPattern = [NSNumber(value: 4 / max(zoom, 0.05)), NSNumber(value: 3 / max(zoom, 0.05))]
    }

    /// A shape being drawn or moved (page space), in the tool's colour.
    func setDraft(_ path: CGPath?, color: NSColor, lineWidth: CGFloat, transform: CGAffineTransform, dashed: Bool = false) {
        var t = transform
        draftLayer.path = path?.copy(using: &t)
        draftLayer.strokeColor = color.cgColor
        draftLayer.lineWidth = max(lineWidth, 0.5)
        draftLayer.lineDashPattern = dashed ? [4, 3] : nil
        draftLayer.lineCap = .round
        draftLayer.lineJoin = .round
    }

    private func applyAccentColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outlineLayer.strokeColor = NSColor.controlAccentColor.cgColor
            handleLayer.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.fillColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).cgColor
        }
        applyAccentColor()
    }
}
