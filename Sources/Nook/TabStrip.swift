import SwiftUI

// The tab strip's arithmetic, apart from the tabs themselves, so dragging a tab along the strip is checked without a window.
//
// A tab that is carried follows the pointer. The model's order changes live as it passes each neighbour (`AppModel.moveSession`), but the row does not lay itself out again
// meanwhile: it holds the order the tabs had when the drag began, and shows the others where they would stand in the new one by moving them aside (`TabStrip.shifts`), with springs. A
// layout that really reordered would move the carried tab as well, under whatever animates the others, and it would be seen to jump for a frame at each swap; held still, each tab is
// moved by its own offset and nothing else decides where it is. When the carried tab is let go it slides into the place it has been given, and only then does the row follow the
// model's order again, which is the order it has been showing all along.
//
//   TabStrip      plain numbers: where each tab stands, which place the carried tab takes, how far the others move aside, where it may go, when the strip scrolls
//   TabCarry      what the row knows of the tab that is being carried

/// What the strip says about moving its tabs.
enum TabStripCopy {
    static let dragHint = "Arrastra la pestaña para cambiarla de sitio"
    static let moveLeft = "Mover a la izquierda"
    static let moveRight = "Mover a la derecha"
}

enum TabStrip {
    /// The air between tabs.
    static let spacing: CGFloat = 6
    /// A tab's width until it has told its own: tabs measure themselves as they are laid out.
    static let assumedWidth: CGFloat = 96
    /// The name of the coordinate space the tab strip's viewport is in (the scroll view that holds the tabs).
    static let viewport = "nookTabViewport"
    /// How far the pointer must go before a press on a tab is a drag and not a click.
    static let dragThreshold: CGFloat = 5
    /// How far above and below the strip a lifted tab's shadow may reach.
    static let liftRoom: CGFloat = 12
    /// How near the viewport's edge the carried tab must come for the strip to scroll, and how often it moves a step while it stays there.
    static let edgeZone: CGFloat = 30
    static let scrollEvery: TimeInterval = 0.24

    /// Where each tab's left edge is, in order, when they stand side by side.
    static func origins(of widths: [CGFloat], spacing: CGFloat = TabStrip.spacing) -> [CGFloat] {
        var x: CGFloat = 0
        return widths.map { width in
            defer { x += width + spacing }
            return x
        }
    }

    /// How wide the strip is.
    static func contentWidth(of widths: [CGFloat], spacing: CGFloat = TabStrip.spacing) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }

    /// `items` with the one at `from` moved to `to`.
    static func moved<Item>(_ items: [Item], from: Int, to: Int) -> [Item] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var result = items
        result.insert(result.remove(at: from), at: to)
        return result
    }

    /// The place the carried tab takes in the order. `index` is where it is now among `widths` (the tabs' widths in their present order, its own included) and `minX` the left edge
    /// it is carried at. It passes a neighbour once its leading edge has crossed that neighbour's middle: as it goes right its right edge, as it goes left its left one. After the
    /// swap the neighbour stands where the carried tab was, and the carried tab has to come back past that neighbour's middle to swap again, which the spacing between them keeps
    /// from being the very same point: a tab does not flicker between two places.
    static func target(of index: Int, minX: CGFloat, widths: [CGFloat], spacing: CGFloat = TabStrip.spacing) -> Int {
        guard widths.indices.contains(index) else { return index }
        var order = widths, at = index
        let width = widths[index]
        while at < order.count - 1 {
            let middle = origins(of: order, spacing: spacing)[at + 1] + order[at + 1] / 2
            guard minX + width > middle else { break }
            order.swapAt(at, at + 1); at += 1
        }
        while at > 0 {
            let middle = origins(of: order, spacing: spacing)[at - 1] + order[at - 1] / 2
            guard minX < middle else { break }
            order.swapAt(at, at - 1); at -= 1
        }
        return at
    }

    /// How far each tab of `widths` (in the order the row shows) stands from where it is laid out, once the tab at `from` has been carried to `to`: the ones it passed move aside by its
    /// width and the gap, so the place it left is filled and the place it goes to is open. The carried tab's own entry is 0 (it follows the pointer, or its slot: `slot`).
    static func shifts(widths: [CGFloat], from: Int, to: Int, spacing: CGFloat = TabStrip.spacing) -> [CGFloat] {
        var result = [CGFloat](repeating: 0, count: widths.count)
        guard widths.indices.contains(from), widths.indices.contains(to), from != to else { return result }
        let room = widths[from] + spacing
        if to > from { for index in (from + 1)...to { result[index] = -room } } else { for index in to..<from { result[index] = room } }
        return result
    }

    /// How far the carried tab's place is from where it is laid out (its left edge), once it has been carried from `from` to `to`: where it settles when it is let go.
    static func slot(widths: [CGFloat], from: Int, to: Int, spacing: CGFloat = TabStrip.spacing) -> CGFloat {
        guard widths.indices.contains(from), widths.indices.contains(to) else { return 0 }
        return origins(of: moved(widths, from: from, to: to), spacing: spacing)[to] - origins(of: widths, spacing: spacing)[from]
    }

    /// The carried tab's left edge, kept inside the strip.
    static func clamped(minX: CGFloat, width: CGFloat, content: CGFloat) -> CGFloat {
        min(max(minX, 0), max(0, content - width))
    }

    /// Which way the strip scrolls for a carried tab whose left and right edges, in the viewport, are `leading` and `trailing`: -1 toward the start, 1 toward the end, 0 not at all.
    /// Only toward tabs there are: `canScrollBack` and `canScrollForward` say whether any lie out of sight on that side.
    static func scrollDirection(leading: CGFloat, trailing: CGFloat, viewport: CGFloat, canScrollBack: Bool, canScrollForward: Bool, zone: CGFloat = TabStrip.edgeZone) -> Int {
        if canScrollBack, leading < zone { return -1 }
        if canScrollForward, trailing > viewport - zone { return 1 }
        return 0
    }
}

/// What the row knows of the tab it carries.
struct TabCarry: Equatable {
    var id: String
    /// Where it was in the order the row shows (which is the order the tabs had when the drag began), and where it has been carried to.
    var from: Int
    var to: Int
    /// How far the pointer is from the tab's left edge, so the tab does not jump under it.
    var grab: CGFloat
    /// The tab's left edge in the strip's own coordinates, as the pointer holds it; once it is let go, where it is settling.
    var minX: CGFloat
    /// The pointer in the viewport's coordinates, which the strip's scrolling looks at.
    var pointer: CGFloat
    /// The tab has been let go and is sliding into its place.
    var released = false
}
