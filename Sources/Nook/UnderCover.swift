import AppKit
import SwiftUI

// A view that something covers, and that has been faded out under it, still counts for AppKit: its cursor rects stay where they were, so a
// text view under a card shows its I-beam over the card's buttons. The conversation is faded out (not taken out: its text, its scroll and
// the draft stay where they are) while Claude's panel is open, and the mirror is while a question's card takes the pane.
//
//   underCover(_:)   says that what is inside lies under a cover while it is true. The AppKit text views in it give up the pointer
//                    (`\.nookCovered`) once the fade that hides them has run its course, so the fade is not cut short, and take it back the
//                    moment the cover starts to go. They are not hidden: a hidden text view swallows the keys, and the keyboard may be in one
//                    (Esc has to reach the island from the field whatever covers it)
//   (the text views that give the pointer up, and `NSScrollView.setClaimsPointer`, are in PointerHoles.swift)

extension EnvironmentValues {
    /// What is inside lies under a cover that has hidden it completely. Its AppKit text views give up the pointer, because a view that is merely
    /// transparent still claims it where it stands, and take it back as soon as the cover starts to go.
    var nookCovered: Bool {
        get { self[NookCoveredKey.self] }
        set { self[NookCoveredKey.self] = newValue }
    }
}

private struct NookCoveredKey: EnvironmentKey { static let defaultValue = false }

/// `faded` follows `covers` (0 to 1) under whatever animation fades the covered view out, so it reaches 1 only when that fade is over; with no
/// fade (Reduce Motion) it is there at once. The environment says "covered" only then, and stops saying it the moment `covers` ends, without
/// waiting for the fade back in.
private struct UnderCover: ViewModifier, Animatable {
    var covers: Bool
    var faded: Double
    var animatableData: Double {
        get { faded }
        set { faded = newValue }
    }
    /// A cover further out (the panel's) still holds when this one (the question's) lets go.
    @Environment(\.nookCovered) private var outer

    func body(content: Content) -> some View { content.environment(\.nookCovered, outer || (covers && faded >= 1)) }
}

extension View {
    /// What is inside lies under a cover while `covers`. Put it where the covered view's own fade is animated, so it can tell when it is over.
    func underCover(_ covers: Bool) -> some View { modifier(UnderCover(covers: covers, faded: covers ? 1 : 0)) }
}
