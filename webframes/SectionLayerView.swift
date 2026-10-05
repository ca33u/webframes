import AppKit

/// One section as drawn on the canvas.
struct NativeSection: Equatable {
    let id: String
    let name: String
    /// World-space area (member frames plus padding).
    let worldRect: CGRect
    /// All member frames are selected.
    let selected: Bool
}

/// Which part of a section is being dragged to resize it.
enum SectionEdge: Equatable {
    case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

    /// New area for a move (`edge == nil`) or resize by a world delta,
    /// keeping at least `minimum`.
    static func apply(_ edge: SectionEdge?, to r: CGRect, dx: CGFloat, dy: CGFloat, minimum: CGSize) -> CGRect {
        guard let edge else { return r.offsetBy(dx: dx, dy: dy) }
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if [.left, .topLeft, .bottomLeft].contains(edge) { minX = min(r.minX + dx, maxX - minimum.width) }
        if [.right, .topRight, .bottomRight].contains(edge) { maxX = max(r.maxX + dx, minX + minimum.width) }
        if [.top, .topLeft, .topRight].contains(edge) { minY = min(r.minY + dy, maxY - minimum.height) }
        if [.bottom, .bottomLeft, .bottomRight].contains(edge) { maxY = max(r.maxY + dy, minY + minimum.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var cursor: NSCursor {
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft: return .frameResize(position: .topLeft, directions: .all)
        case .topRight: return .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
        }
    }
}

@MainActor
protocol SectionLayerViewDelegate: AnyObject {
    /// Press on a section's title (`edge == nil`: move it with its frames)
    /// or on an edge/corner (resize).
    func sectionLayer(_ layer: SectionLayerView, didBegin edge: SectionEdge?, section id: String, event: NSEvent)
    func sectionLayer(_ layer: SectionLayerView, didDragSection id: String, event: NSEvent)
    func sectionLayer(_ layer: SectionLayerView, didReleaseSection id: String, event: NSEvent)
    func sectionLayer(_ layer: SectionLayerView, didRenameSection id: String, to name: String)
    func sectionLayer(_ layer: SectionLayerView, menuForSection id: String) -> NSMenu?
}

/// Draws sections under the frame cards: a tinted rounded area and the
/// section name above its top-left corner, like Figma. The titles take
/// clicks (drag to move, double-click to rename, right-click for the menu)
/// and a thin band along the edges resizes; the inside passes clicks through
/// to the canvas and frames.
final class SectionLayerView: NSView {
    weak var delegate: SectionLayerViewDelegate?

    private var scale: CGFloat = 1
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0
    private var sections: [NativeSection] = []
    private var areaLayers: [String: CAShapeLayer] = [:]
    private var titles: [String: SectionTitleView] = [:]
    private var borders: [String: SectionBorderView] = [:]
    private var handleLayers: [String: CAShapeLayer] = [:]

    static let titleHeight: CGFloat = 22
    static let titleGap: CGFloat = 6

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func setView(scale: CGFloat, px: CGFloat, py: CGFloat) {
        guard scale != self.scale || px != panX || py != panY else { return }
        self.scale = scale; panX = px; panY = py
        layoutSections()
    }

    func setSections(_ next: [NativeSection]) {
        guard next != sections else { return }
        sections = next
        let ids = Set(next.map(\.id))
        for (id, layer) in areaLayers where !ids.contains(id) { layer.removeFromSuperlayer(); areaLayers[id] = nil }
        for (id, layer) in handleLayers where !ids.contains(id) { layer.removeFromSuperlayer(); handleLayers[id] = nil }
        for (id, view) in titles where !ids.contains(id) { view.removeFromSuperview(); titles[id] = nil }
        for (id, view) in borders where !ids.contains(id) { view.removeFromSuperview(); borders[id] = nil }
        for section in next {
            if areaLayers[section.id] == nil {
                let area = CAShapeLayer()
                area.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "strokeColor": NSNull()]
                area.lineWidth = 1
                layer?.addSublayer(area)
                areaLayers[section.id] = area
            }
            if handleLayers[section.id] == nil {
                let handles = CAShapeLayer()
                handles.actions = ["path": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
                handles.fillColor = NSColor.white.cgColor
                handles.strokeColor = WFDesign.accent.cgColor
                handles.lineWidth = 1.5
                handles.zPosition = 1
                layer?.addSublayer(handles)
                handleLayers[section.id] = handles
            }
            let title = titles[section.id] ?? makeTitle(id: section.id)
            title.setName(section.name, selected: section.selected)
            if borders[section.id] == nil {
                let border = SectionBorderView(sectionID: section.id)
                border.owner = self
                addSubview(border, positioned: .below, relativeTo: nil)
                borders[section.id] = border
            }
        }
        layoutSections()
    }

    /// A title or resize band is under `point` (this view's coordinates).
    func isInteractive(at point: NSPoint) -> Bool {
        guard let hit = hitTest(convert(point, to: superview)) else { return false }
        return hit is SectionTitleView || hit is SectionBorderView || hit.superview is SectionTitleView
    }

    func beginRenaming(sectionID id: String) {
        titles[id]?.beginEditing()
    }

    private func makeTitle(id: String) -> SectionTitleView {
        let view = SectionTitleView(sectionID: id)
        view.owner = self
        addSubview(view)
        titles[id] = view
        return view
    }

    override func layout() {
        super.layout()
        layoutSections()
    }

    private func layoutSections() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for section in sections {
            let r = section.worldRect
            let screen = CGRect(x: r.minX * scale + panX, y: r.minY * scale + panY,
                                width: r.width * scale, height: r.height * scale)
            if let area = areaLayers[section.id] {
                area.frame = bounds
                let radius = min(16, max(4, 16 * scale))
                area.path = CGPath(roundedRect: screen, cornerWidth: radius, cornerHeight: radius, transform: nil)
                area.fillColor = NSColor.white.withAlphaComponent(section.selected ? 0.06 : 0.035).cgColor
                area.strokeColor = (section.selected ? WFDesign.accent : NSColor.white.withAlphaComponent(0.12)).cgColor
                area.lineWidth = section.selected ? 2 : 1
            }
            // Selected: corner handles show it can be moved and resized.
            if let handles = handleLayers[section.id] {
                handles.frame = bounds
                if section.selected {
                    let s: CGFloat = 8
                    let path = CGMutablePath()
                    for c in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX, y: screen.minY),
                              CGPoint(x: screen.minX, y: screen.maxY), CGPoint(x: screen.maxX, y: screen.maxY)] {
                        path.addRect(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
                    }
                    handles.path = path
                    handles.isHidden = false
                } else {
                    handles.isHidden = true
                }
            }
            if let border = borders[section.id] {
                let band = SectionBorderView.band
                border.frame = screen.insetBy(dx: -band, dy: -band)
            }
            if let title = titles[section.id] {
                let width = min(max(60, title.preferredWidth), max(60, screen.width))
                title.frame = NSRect(x: screen.minX, y: screen.minY - Self.titleHeight - Self.titleGap,
                                     width: width, height: Self.titleHeight)
            }
        }
    }

    // MARK: Title callbacks

    fileprivate func titlePressed(_ id: String, event: NSEvent) { delegate?.sectionLayer(self, didBegin: nil, section: id, event: event) }
    fileprivate func edgePressed(_ id: String, edge: SectionEdge, event: NSEvent) { delegate?.sectionLayer(self, didBegin: edge, section: id, event: event) }
    fileprivate func titleDragged(_ id: String, event: NSEvent) { delegate?.sectionLayer(self, didDragSection: id, event: event) }
    fileprivate func titleReleased(_ id: String, event: NSEvent) { delegate?.sectionLayer(self, didReleaseSection: id, event: event) }
    fileprivate func titleRenamed(_ id: String, name: String) { delegate?.sectionLayer(self, didRenameSection: id, to: name) }
    fileprivate func titleMenu(_ id: String) -> NSMenu? { delegate?.sectionLayer(self, menuForSection: id) }
}

/// Invisible band along a section's border that resizes it. The view
/// covers the area plus `band` on each side; only points within two bands
/// of the border hit-test, so the inside stays clickable.
final class SectionBorderView: NSView {
    static let band: CGFloat = 6
    let sectionID: String
    fileprivate weak var owner: SectionLayerView?
    private var activeEdge: SectionEdge?

    override var isFlipped: Bool { true }

    init(sectionID: String) {
        self.sectionID = sectionID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Edge or corner under a point in this view's coordinates.
    func edge(at p: NSPoint) -> SectionEdge? {
        let b = Self.band * 2
        let left = p.x <= b, right = p.x >= bounds.width - b
        let top = p.y <= b, bottom = p.y >= bounds.height - b
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return edge(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func resetCursorRects() {
        let b = Self.band * 2, w = bounds.width, h = bounds.height
        let zones: [(NSRect, SectionEdge)] = [
            (NSRect(x: b, y: 0, width: max(0, w - 2 * b), height: b), .top),
            (NSRect(x: b, y: h - b, width: max(0, w - 2 * b), height: b), .bottom),
            (NSRect(x: 0, y: b, width: b, height: max(0, h - 2 * b)), .left),
            (NSRect(x: w - b, y: b, width: b, height: max(0, h - 2 * b)), .right),
            (NSRect(x: 0, y: 0, width: b, height: b), .topLeft),
            (NSRect(x: w - b, y: 0, width: b, height: b), .topRight),
            (NSRect(x: 0, y: h - b, width: b, height: b), .bottomLeft),
            (NSRect(x: w - b, y: h - b, width: b, height: b), .bottomRight),
        ]
        for (rect, edge) in zones { addCursorRect(rect, cursor: edge.cursor) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let edge = edge(at: convert(event.locationInWindow, from: nil)) else { return }
        activeEdge = edge
        owner?.edgePressed(sectionID, edge: edge, event: event)
    }
    override func mouseDragged(with event: NSEvent) {
        if activeEdge != nil { owner?.titleDragged(sectionID, event: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if activeEdge != nil { owner?.titleReleased(sectionID, event: event) }
        activeEdge = nil
    }
}

/// Section name above the section area. Click selects the section's frames,
/// drag moves them, double-click renames, right-click opens the menu.
final class SectionTitleView: NSView, NSTextFieldDelegate {
    let sectionID: String
    fileprivate weak var owner: SectionLayerView?
    private let label = NSTextField(labelWithString: "")
    private var editor: NSTextField?
    private var name = ""

    override var isFlipped: Bool { true }

    init(sectionID: String) {
        self.sectionID = sectionID
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        toolTip = "Click to select the section's frames, drag to move them, double-click to rename"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat { label.intrinsicContentSize.width + 8 }

    func setName(_ name: String, selected: Bool) {
        self.name = name
        label.stringValue = name
        label.textColor = selected ? WFDesign.accent : WFDesign.text2
        setAccessibilityLabel("Section \(name)")
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { beginEditing(); return }
        owner?.titlePressed(sectionID, event: event)
    }
    override func mouseDragged(with event: NSEvent) { owner?.titleDragged(sectionID, event: event) }
    override func mouseUp(with event: NSEvent) { owner?.titleReleased(sectionID, event: event) }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.titleMenu(sectionID) }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func beginEditing() {
        guard editor == nil else { return }
        let field = NSTextField(string: name)
        field.font = label.font
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = WFDesign.bg3
        field.textColor = WFDesign.text
        field.delegate = self
        field.frame = NSRect(x: 0, y: 1, width: max(160, bounds.width), height: bounds.height - 2)
        label.isHidden = true
        addSubview(field)
        editor = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { finishEditing(commit: true) }

    private func finishEditing(commit: Bool) {
        guard let field = editor else { return }
        editor = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        label.isHidden = false
        if commit, !text.isEmpty, text != name { owner?.titleRenamed(sectionID, name: text) }
    }
}
