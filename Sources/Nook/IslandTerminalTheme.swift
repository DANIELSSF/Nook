import AppKit
import SwiftTerm

// The colours of the island's own terminal, the one a tmux session that Nook saved earlier shows (`TerminalSurface`). It has no card behind it, so it
// takes the island's own surface: black with light text in the dark theme, and in the light one the paper with ink, and a set of the sixteen ANSI colours
// made for a light background (the defaults are made for a dark one: yellow and white would vanish on paper).

enum IslandTerminalTheme {
    /// The paper's colour as AppKit's `NSColor`, which the terminal's background is set to. The same as `NookPalette.screenSolid` in the light theme.
    private static let paper = NSColor(srgbRed: 0.953, green: 0.941, blue: 0.914, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.110, green: 0.105, blue: 0.095, alpha: 1)

    private static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    /// SwiftTerm's own default sixteen, which the dark theme keeps.
    private static let darkColors: [SwiftTerm.Color] = [
        color(0, 0, 0), color(153, 0, 1), color(0, 166, 3), color(153, 153, 0), color(3, 0, 178), color(178, 0, 178), color(0, 165, 178), color(191, 191, 191),
        color(138, 137, 138), color(229, 0, 1), color(0, 216, 0), color(229, 229, 0), color(7, 0, 254), color(229, 0, 229), color(0, 229, 229), color(229, 229, 229),
    ]

    /// Sixteen colours that read on the paper (4.5 : 1 or more, but for the faint "white", which is a mid grey there): the dark ones a little deeper, the
    /// bright ones the same hues a step livelier, and the bright white (what a program uses to stress text) as the ink.
    private static let lightColors: [SwiftTerm.Color] = [
        color(28, 27, 24), color(178, 34, 34), color(28, 120, 50), color(140, 100, 0), color(30, 60, 190), color(150, 30, 150), color(0, 110, 130), color(110, 108, 100),
        color(90, 90, 86), color(200, 40, 40), color(30, 140, 60), color(160, 115, 0), color(40, 80, 215), color(170, 40, 170), color(0, 130, 150), color(40, 38, 34),
    ]

    /// Dresses `view` for the theme. A theme it already wears costs nothing: SwiftUI asks on every update.
    static func apply(to view: ActivityTerminalView, dark: Bool) {
        let background = dark ? NSColor.black : paper
        guard view.nativeBackgroundColor != background else { return }
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = dark ? NSColor(white: 0.93, alpha: 1) : ink
        view.installColors(dark ? darkColors : lightColors)
    }
}
