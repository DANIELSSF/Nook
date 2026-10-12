import SwiftUI

// How the light island meets the black notch.
//
// The notch is hardware, and black. The island grows out of it, so it begins as that black, and in the dark theme it stays that black all the way:
// the island is one piece of it (that is what `Color.black` under everything in `NookPanel` is). In the light theme the island's body is paper, and
// the paper has to meet the notch somewhere. This is where.
//
//   the shell     the island's own silhouette, black, in both themes. It is the notch grown: the header strip (the notch's height, with the cat in
//                 its left wing and the activity glyph in its right), and a thin bezel round the body, 5 pt at the sides and the bottom.
//   the paper     the body, in the light theme: a sheet of paper laid into the shell under the header strip, with its corners rounded to follow the
//                 island's (concentric with it, so the bezel is the same width all round). It begins under the strip and never touches the notch.
//
// So the black the user knows (the collapsed island, the alert's peek, the strip the island grows from) is the same black at the top of the open one,
// and the light only begins below it, held in the island's own outline like a screen in a device. Nothing about the notch has to be drawn or
// guessed: the cutout, the cat, the collapsed island's badges and every pixel the hardware owns stay on black, whatever the theme is.
//
// It follows the island's own comings and goings with no animation of its own: the screen is part of the content, which fades in once the island
// has grown (and goes at once when it closes), so the island grows black, as it always did, and its light comes on once it is open.
//
// The header strip always draws in the dark scheme (`IslandSurface.headerScheme`): its icons, the cat's stage and the glyph are white on black.

enum IslandSurface {
    /// The black left round the screen, at the sides and the bottom.
    static let bezel: CGFloat = 5
    /// The island's own bottom corner radius (the window's mask, `IslandView`), and the screen's, concentric with it.
    static let outerRadius: CGFloat = 22
    static var screenBottomRadius: CGFloat { outerRadius - bezel }
    /// The screen's top corners, which turn under the header strip.
    static let screenTopRadius: CGFloat = 14
    /// The header strip is always dark: it is the notch's black.
    static let headerScheme = ColorScheme.dark
}

/// The island's body: paper in the light theme, nothing in the dark one (where the shell's black is the body). Laid in the shell, under the header strip.
struct IslandPaper: View {
    /// The header strip's height, which the screen starts under.
    var neck: CGFloat

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: IslandSurface.screenTopRadius, bottomLeadingRadius: IslandSurface.screenBottomRadius,
                               bottomTrailingRadius: IslandSurface.screenBottomRadius, topTrailingRadius: IslandSurface.screenTopRadius, style: .continuous)
            .fill(Color.nookScreen)
            .padding(EdgeInsets(top: neck, leading: IslandSurface.bezel, bottom: IslandSurface.bezel, trailing: IslandSurface.bezel))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - The island's outline as a clip

extension View {
    /// Clips to the island's outline: square at the top, against the screen's edge, and rounded at the bottom (`IslandSurface.outerRadius`).
    ///
    /// It is a rounded rectangle taller than the island by its radius, with the extra on top and cut off again, and not an `UnevenRoundedRectangle` with square
    /// top corners, which is what it looks like and what it replaces. The two clip the same pixels, but SwiftUI draws a clip that is not a plain rounded rectangle
    /// through an offscreen mask, and in that mask some of the symbols in the island (`info.circle`, `list.bullet`, `exclamationmark.triangle`, a
    /// dozen of the ones it uses) come out white whatever their colour is. On black that went unseen; on the paper it would be icons that are not there.
    func clippedToIslandOutline(radius: CGFloat = IslandSurface.outerRadius) -> some View {
        padding(.top, radius)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
            .padding(.top, -radius)
            .clipped()
    }
}
