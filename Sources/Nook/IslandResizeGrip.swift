import AppKit

// Dragging the open island's size directly: a handle on each bottom corner (it shows when the pointer is near it), where the
// island grows or shrinks around the notch's axis, so the corner under the pointer follows it. The settings card sets the
// same numbers; this is the quick way.
//
//   IslandResizeDrag   the drag's arithmetic (plain values)
//   IslandResizeGrip   the AppKit view with the two handles; it answers clicks only on them and is invisible elsewhere

/// What a drag from a bottom corner asks for. Measured from where the drag started (the island's size and the pointer then),
/// not from where the corner is, so the size does not depend on the window that changes under the pointer meanwhile.
struct IslandResizeDrag: Equatable {
    enum Corner: Equatable { case left, right }

    var corner: Corner
    var startSize: CGSize
    /// The pointer when the drag began, in screen coordinates (origin at the bottom left).
    var startPointer: CGPoint

    /// The size for a pointer at `pointer`. The island hangs from the top edge and is centred on the notch, so a corner moving
    /// by Δ sideways changes the width by 2Δ; dragging down makes it taller.
    func size(at pointer: CGPoint) -> CGSize {
        let sideways = pointer.x - startPointer.x
        return CGSize(width: startSize.width + 2 * (corner == .right ? sideways : -sideways),
                      height: startSize.height + (startPointer.y - pointer.y))
    }
}

final class IslandResizeGrip: NSView {
    /// The handle's reach from the island's corner, in points. The shape of the handle is the island's own rounded corner
    /// (radius 22): a point counts when it is inside it, so nothing outside the island's shape can be grabbed. Smaller than the
    /// corner's radius, so the composer's send button next to it stays clear.
    static let reach: CGFloat = 20

    /// Whether the island's content is up; a handle on an island that is opening or closing answers nothing.
    var isActive: () -> Bool = { true }
    /// The drag began on `corner`: the island's current size, or nil to refuse it.
    var onBegin: ((IslandResizeDrag.Corner) -> CGSize?)?
    /// The size the drag asks for now; the owner clamps and applies it.
    var onResize: ((CGSize) -> Void)?
    var onEnd: (() -> Void)?

    private var drag: IslandResizeDrag?
    private var hovered: IslandResizeDrag.Corner?
    private var areas: [NSTrackingArea] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A handle that is drawn only on hover, and invisible to the accessibility tree: the settings card has the same numbers.
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    // MARK: Where the handles are

    private func square(_ corner: IslandResizeDrag.Corner) -> NSRect {
        NSRect(x: corner == .left ? 0 : bounds.width - Self.reach, y: 0, width: Self.reach, height: Self.reach)
    }

    /// The corner whose handle holds `point` (in this view's coordinates).
    func corner(at point: NSPoint) -> IslandResizeDrag.Corner? {
        for corner in [IslandResizeDrag.Corner.left, .right] where square(corner).contains(point) {
            // The quarter disc of the island's own corner: its centre is `reach` in from both edges.
            let centre = NSPoint(x: corner == .left ? Self.reach : bounds.width - Self.reach, y: Self.reach)
            if hypot(point.x - centre.x, point.y - centre.y) <= Self.reach { return corner }
        }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive() || drag != nil else { return nil }
        return corner(at: convert(point, from: superview)) == nil ? nil : self
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        areas.forEach(removeTrackingArea)
        areas = [IslandResizeDrag.Corner.left, .right].map { corner in
            let area = NSTrackingArea(rect: square(corner), options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways], owner: self, userInfo: ["corner": corner == .left ? "left" : "right"])
            addTrackingArea(area)
            return area
        }
        super.updateTrackingAreas()
    }

    /// The resize cursor only where a drag would do something: not on a corner of an island that has the size a card gave it (the owner invalidates the rects when that
    /// changes).
    override func resetCursorRects() {
        guard isActive() else { return }
        for corner in [IslandResizeDrag.Corner.left, .right] { addCursorRect(square(corner), cursor: Self.cursor(for: corner)) }
    }

    private static func cursor(for corner: IslandResizeDrag.Corner) -> NSCursor {
        if #available(macOS 15.0, *) { return NSCursor.frameResize(position: corner == .left ? .bottomLeft : .bottomRight, directions: [.inward, .outward]) }
        return .crosshair
    }

    /// The island is a panel that need not be key (a hover opened it), where cursor rects alone are not applied.
    override func cursorUpdate(with event: NSEvent) {
        guard isActive(), let corner = corner(at: convert(event.locationInWindow, from: nil)) else { super.cursorUpdate(with: event); return }
        Self.cursor(for: corner).set()
    }

    private func updateHover(_ event: NSEvent) {
        let corner = isActive() ? corner(at: convert(event.locationInWindow, from: nil)) : nil
        if corner != hovered { hovered = corner; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { if drag == nil { hovered = nil; needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        guard let corner = corner(at: convert(event.locationInWindow, from: nil)), let size = onBegin?(corner) else { return }
        drag = IslandResizeDrag(corner: corner, startSize: size, startPointer: NSEvent.mouseLocation)
        hovered = corner; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        onResize?(drag.size(at: NSEvent.mouseLocation))
    }
    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        hovered = corner(at: convert(event.locationInWindow, from: nil)); needsDisplay = true
        onEnd?()
    }

    // MARK: Drawing

    /// Three short diagonal strokes in the corner, the way a window's resize corner looks, only while the pointer is on the
    /// handle or the drag is under way.
    override func draw(_ dirtyRect: NSRect) {
        guard let corner = hovered ?? drag?.corner else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        let edge: CGFloat = 7   // from the island's edges to the nearest stroke
        for step in 0..<3 {
            let reach = 4 + CGFloat(step) * 3.5
            let x0 = corner == .right ? bounds.width - edge : edge
            let sign: CGFloat = corner == .right ? -1 : 1
            path.move(to: NSPoint(x: x0 + sign * reach, y: edge))
            path.line(to: NSPoint(x: x0, y: edge + reach))
        }
        // The strokes lie on the island's body: white on the black one, ink on the paper (the view's appearance is the island's theme).
        NSColor.nookWash(drag == nil ? 0.38 : 0.6, light: drag == nil ? 0.45 : 0.65).setStroke()
        path.stroke()
    }
}
