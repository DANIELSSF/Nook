import AppKit
import SwiftUI

// Chrome that floats over a text view that is on show (the "/" menu, the agents' lists, a card over the composer) is SwiftUI, which AppKit
// cannot tell from the hosting view that holds it: a text view under it keeps claiming the pointer there, and the I-beam shows over the
// chrome's rows. Nothing says which of two overlapping claims wins, so none is left to win: the text view claims the pointer over the
// text less the places the chrome stands, and the arrow is what is left there.
//
//   pointerHole()   marks where a piece of chrome stands: an invisible AppKit view behind it, which takes the place SwiftUI gives it
//   PointerClaiming the text views that can give the pointer up (the mirror, the message field), and TextClipView, their clip view, which
//                   makes the claim: the I-beam over the text, less the holes, and nothing while a card covers it
//   PointerHoles    where the holes are, and the arithmetic of leaving them out

enum PointerHoles {
    /// `area` less `holes`, as rectangles that do not overlap. Works in any coordinates, flipped or not.
    static func carve(_ area: NSRect, around holes: [NSRect]) -> [NSRect] {
        var pieces = [area]
        for hole in holes {
            pieces = pieces.flatMap { piece -> [NSRect] in
                guard piece.intersects(hole) else { return [piece] }
                let cut = piece.intersection(hole)
                var rest: [NSRect] = []
                // Whole-width bands above and below the hole, and what stands beside it.
                if cut.minY > piece.minY { rest.append(NSRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY)) }
                if cut.maxY < piece.maxY { rest.append(NSRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY)) }
                if cut.minX > piece.minX { rest.append(NSRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height)) }
                if cut.maxX < piece.maxX { rest.append(NSRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height)) }
                return rest
            }
        }
        return pieces.filter { !$0.isEmpty }
    }

    private static func visit(_ view: NSView, _ body: (NSView) -> Void) {
        body(view)
        view.subviews.forEach { visit($0, body) }
    }

    /// Where the chrome in `window` stands that has marked itself (`pointerHole()`), in window coordinates. A marker that is hidden stands nowhere.
    static func frames(in window: NSWindow?) -> [NSRect] {
        guard let root = window?.contentView else { return [] }
        var found: [NSRect] = []
        visit(root) { view in
            if let hole = view as? PointerHoleView, !hole.isHiddenOrHasHiddenAncestor { found.append(hole.convert(hole.bounds, to: nil)) }
        }
        return found
    }

    static func contains(_ point: NSPoint, in window: NSWindow?) -> Bool { frames(in: window).contains { $0.contains(point) } }

    /// A hole came, went or moved: the text views of this window claim the pointer again, round the holes as they stand now.
    static func changed(in window: NSWindow?) {
        guard let window, let root = window.contentView else { return }
        visit(root) { view in if view is TextClipView { window.invalidateCursorRects(for: view) } }
    }
}

/// The invisible mark behind a piece of chrome. It is where the chrome is (SwiftUI sizes and places it, offsets included) and tells the text views
/// under it whenever that changes.
final class PointerHoleView: NSView {
    private weak var lastWindow: NSWindow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// It never takes a click: the chrome in front of it, and what is behind, answer as they did.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Arriving, or leaving (then the window it left is told, which is no longer `window`).
        let leaving = lastWindow
        lastWindow = window
        PointerHoles.changed(in: window ?? leaving)
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); PointerHoles.changed(in: window) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); PointerHoles.changed(in: window) }
    override func viewDidHide() { super.viewDidHide(); PointerHoles.changed(in: window) }
    override func viewDidUnhide() { super.viewDidUnhide(); PointerHoles.changed(in: window) }
}

private struct PointerHole: NSViewRepresentable {
    func makeNSView(context: Context) -> PointerHoleView { PointerHoleView() }
    func updateNSView(_ view: PointerHoleView, context: Context) {}
}

extension View {
    /// This view floats over text that is on show: the text under it gives up the pointer where it stands, so the arrow shows over it and not
    /// the text's I-beam. Put it on the view whose frame is the chrome's (a card, not the padding round it).
    func pointerHole() -> some View { background(PointerHole()) }
}

/// A text view that can give the pointer up: while a card covers it (`\.nookCovered`), and where chrome floats over it.
protocol PointerClaiming: NSTextView {
    var claimsPointer: Bool { get set }
}

extension PointerClaiming {
    /// The pointer is not this text view's at `event`: a card covers the text, or chrome floats over that spot. (A text view answers the pointer
    /// itself as well as through its clip view's claim: it tracks the mouse and sets the I-beam, or the link hand, when it enters.)
    func pointerHeldBack(at event: NSEvent) -> Bool { !claimsPointer || PointerHoles.contains(event.locationInWindow, in: window) }
}

/// The clip view of a text view that claims the pointer: the I-beam over what shows of the text, less the holes of the chrome that floats over it,
/// and nothing at all while the text is covered. It is the claim a text view's own scroll view would make through `documentCursor`, which is
/// kept from being set so the only claim is this one.
final class TextClipView: NSClipView {
    override var documentCursor: NSCursor? {
        get { nil }
        set {}
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard (documentView as? PointerClaiming)?.claimsPointer == true else { return }
        let holes = PointerHoles.frames(in: window).map { convert($0, from: nil) }
        for rect in PointerHoles.carve(bounds, around: holes) { addCursorRect(rect, cursor: .iBeam) }
    }
}

extension NSScrollView {
    /// Whether the text view in this scroll view claims the pointer at all. It gives it up while a card covers it, and takes it back as the
    /// card goes; the text view stays what it was in every other way (where the keyboard is, what is selected, what it says).
    func setClaimsPointer(_ claims: Bool) {
        guard let text = documentView as? PointerClaiming, text.claimsPointer != claims else { return }
        text.claimsPointer = claims
        window?.invalidateCursorRects(for: contentView)
    }
}
