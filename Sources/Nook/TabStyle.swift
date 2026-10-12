import SwiftUI
import AppKit

// What a tab's colour does besides tinting its pill.
//
// In Nook a colour says who is speaking: terracotta is Claude's, and the tab's colour is the user's. So the send button, the
// user's message block in the conversation, the row being highlighted in a menu or a question and the outline of a file
// being dropped all wear the colour of the tab they are in. Around them the island leans toward it, very little: the
// composer's surface, and a hairline along the island's lower edge.
//
// Mint is Nook's own colour and the default. With it the island adds nothing around the voice: its surfaces stay the neutral ones. Mint also
// stays where it does not mean "you": an agent that finished, a permission that is on, the connection's dot, Nook's own notices and its settings.
//
// Every colour has shades for both themes (`NookTheme.swift`): on the dark island the tab's colour is a vivid pastel and its voice is light on
// black; on the light one the same hue is deeper, so its dot, its icon and the user's words are readable on the paper. The solid `accent` is the
// same in both, and takes the send button's white arrow at 3.1 : 1 or more.
//
// The colour reaches the views through `\.tabTint`. `SessionPane` sets it for the tab it shows; anything outside a tab (the
// welcome screen, the settings card) keeps mint.

// MARK: - Palette

/// Red, green and blue in 0…1, written the way the island's other colours are. It makes the SwiftUI colour and the AppKit one
/// from the same numbers, so a value reads the same in the send button and in the conversation.
struct TabRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(red: red, green: green, blue: blue, alpha: 1) }

    func scaled(by factor: Double) -> TabRGB { TabRGB(red * factor, green * factor, blue * factor) }

    /// The same hue and balance at a chosen brightness: the channels scaled so they average `mean` (none goes past 1).
    func normalized(toMean mean: Double) -> TabRGB {
        let average = (red + green + blue) / 3
        guard average > 0 else { return self }
        let factor = mean / average
        return TabRGB(min(1, red * factor), min(1, green * factor), min(1, blue * factor))
    }

    /// `amount` of `other` over `self`: 0 is `self`, 1 is `other`.
    func mixed(with other: TabRGB, by amount: Double) -> TabRGB {
        TabRGB(red + (other.red - red) * amount, green + (other.green - green) * amount, blue + (other.blue - blue) * amount)
    }
}

/// The colours one tab colour gives the user's voice. `accent` is a solid that takes white on top (the send button) and tints
/// a highlighted row; `marker` and `text` are the shades the user's message block wears in the conversation: lighter than the accent on the
/// dark island, deeper than it on the light one.
struct TabVoice: Equatable {
    var accent: TabRGB
    var marker: TabRGB
    var text: TabRGB

    /// The mint voice on the dark island.
    static let mint = TabTint.mint.voice(.dark)
}

/// All the shades of one tab colour, for both themes.
struct TabShades: Equatable {
    /// Dark island: the tab's own colour (its dot, its icon, its pill), a vivid pastel.
    var pastel: TabRGB
    /// Both: the solid that takes the send button's white arrow (3.1 : 1) and fills a highlighted row.
    var accent: TabRGB
    /// Dark: a lighter shade of the accent for the `>` of the user's message and its tag; and the message's own text, nearly white.
    var marker: TabRGB
    var text: TabRGB
    /// Light island: the tab's own colour, deep enough to be a dot or an icon on the paper (3.8 : 1).
    var tone: TabRGB
    /// Light: the `>` of the user's message (4.7 : 1 on its block) and the message's text (10 : 1).
    var deepMarker: TabRGB
    var deepText: TabRGB
}

extension TabTint {
    /// The shades of this colour, written once for both themes. Made in OKLCH from the hue each colour has always had, a little more chroma than
    /// before (the pastels are about a third more vivid, the accents about as much but deeper): the accent's luminance is the same for every
    /// colour, which is what makes the white arrow read about equally well (3.1 : 1) on all of them, and the light shades are the same hue taken
    /// to fixed contrasts on the paper. The tests check every number that matters (`TabStyleTests`).
    var shades: TabShades {
        switch self {
        case .mint:
            TabShades(pastel: TabRGB(0.433, 0.833, 0.702), accent: TabRGB(0.182, 0.640, 0.512), marker: TabRGB(0.503, 0.850, 0.732), text: TabRGB(0.901, 0.975, 0.945),
                      tone: TabRGB(0.156, 0.531, 0.425), deepMarker: TabRGB(0.123, 0.429, 0.342), deepText: TabRGB(0.024, 0.214, 0.163))
        case .blue:
            TabShades(pastel: TabRGB(0.580, 0.756, 0.983), accent: TabRGB(0.249, 0.575, 0.967), marker: TabRGB(0.651, 0.780, 0.947), text: TabRGB(0.917, 0.959, 1.000),
                      tone: TabRGB(0.132, 0.473, 0.858), deepMarker: TabRGB(0.080, 0.380, 0.709), deepText: TabRGB(0.101, 0.183, 0.286))
        case .lavender:
            TabShades(pastel: TabRGB(0.833, 0.662, 0.962), accent: TabRGB(0.719, 0.460, 0.896), marker: TabRGB(0.842, 0.705, 0.947), text: TabRGB(0.972, 0.940, 1.000),
                      tone: TabRGB(0.617, 0.359, 0.787), deepMarker: TabRGB(0.506, 0.280, 0.653), deepText: TabRGB(0.213, 0.147, 0.260))
        case .rose:
            TabShades(pastel: TabRGB(0.967, 0.624, 0.763), accent: TabRGB(0.898, 0.396, 0.626), marker: TabRGB(0.951, 0.677, 0.784), text: TabRGB(1.000, 0.932, 0.958),
                      tone: TabRGB(0.785, 0.293, 0.527), deepMarker: TabRGB(0.649, 0.220, 0.427), deepText: TabRGB(0.262, 0.131, 0.187))
        case .peach:
            TabShades(pastel: TabRGB(0.957, 0.673, 0.435), accent: TabRGB(0.830, 0.486, 0.136), marker: TabRGB(0.949, 0.713, 0.521), text: TabRGB(1.000, 0.943, 0.898),
                      tone: TabRGB(0.693, 0.402, 0.105), deepMarker: TabRGB(0.563, 0.322, 0.076), deepText: TabRGB(0.258, 0.151, 0.055))
        case .sand:
            TabShades(pastel: TabRGB(0.854, 0.732, 0.393), accent: TabRGB(0.687, 0.555, 0.138), marker: TabRGB(0.873, 0.758, 0.444), text: TabRGB(0.977, 0.954, 0.891),
                      tone: TabRGB(0.572, 0.461, 0.108), deepMarker: TabRGB(0.463, 0.371, 0.080), deepText: TabRGB(0.222, 0.174, 0.026))
        case .gray:
            TabShades(pastel: TabRGB(0.725, 0.745, 0.780), accent: TabRGB(0.548, 0.572, 0.616), marker: TabRGB(0.759, 0.783, 0.824), text: TabRGB(0.945, 0.955, 0.971),
                      tone: TabRGB(0.449, 0.475, 0.522), deepMarker: TabRGB(0.357, 0.383, 0.428), deepText: TabRGB(0.162, 0.180, 0.212))
        case .coral:
            TabShades(pastel: TabRGB(0.984, 0.637, 0.613), accent: TabRGB(0.934, 0.398, 0.386), marker: TabRGB(0.950, 0.694, 0.674), text: TabRGB(1.000, 0.934, 0.927),
                      tone: TabRGB(0.819, 0.293, 0.291), deepMarker: TabRGB(0.679, 0.219, 0.222), deepText: TabRGB(0.273, 0.133, 0.126))
        case .sky:
            TabShades(pastel: TabRGB(0.427, 0.795, 0.964), accent: TabRGB(0.171, 0.612, 0.788), marker: TabRGB(0.533, 0.812, 0.947), text: TabRGB(0.899, 0.967, 1.000),
                      tone: TabRGB(0.144, 0.508, 0.655), deepMarker: TabRGB(0.112, 0.410, 0.530), deepText: TabRGB(0.025, 0.198, 0.267))
        case .violet:
            TabShades(pastel: TabRGB(0.717, 0.711, 0.983), accent: TabRGB(0.553, 0.512, 0.968), marker: TabRGB(0.747, 0.746, 0.947), text: TabRGB(0.947, 0.948, 1.000),
                      tone: TabRGB(0.461, 0.410, 0.863), deepMarker: TabRGB(0.372, 0.325, 0.718), deepText: TabRGB(0.169, 0.162, 0.283))
        case .lime:
            TabShades(pastel: TabRGB(0.645, 0.808, 0.422), accent: TabRGB(0.448, 0.623, 0.135), marker: TabRGB(0.671, 0.833, 0.455), text: TabRGB(0.938, 0.967, 0.906),
                      tone: TabRGB(0.370, 0.518, 0.109), deepMarker: TabRGB(0.296, 0.418, 0.081), deepText: TabRGB(0.148, 0.200, 0.074))
        case .teal:
            TabShades(pastel: TabRGB(0.405, 0.817, 0.853), accent: TabRGB(0.192, 0.626, 0.661), marker: TabRGB(0.503, 0.832, 0.862), text: TabRGB(0.892, 0.973, 0.980),
                      tone: TabRGB(0.164, 0.519, 0.549), deepMarker: TabRGB(0.129, 0.419, 0.443), deepText: TabRGB(0.000, 0.210, 0.227))
        }
    }

    /// The tab's own colour in `scheme`: the vivid pastel on the dark island, the deeper tone on the light one. What its dot, its icon and its
    /// pill are made of.
    func tone(_ scheme: ColorScheme) -> TabRGB { scheme == .dark ? shades.pastel : shades.tone }

    /// The user's voice in `scheme` (see `TabVoice`). The same hue in both: light on black, deep on the paper.
    func voice(_ scheme: ColorScheme) -> TabVoice {
        let shades = self.shades
        return scheme == .dark ? TabVoice(accent: shades.accent, marker: shades.marker, text: shades.text)
                               : TabVoice(accent: shades.accent, marker: shades.deepMarker, text: shades.deepText)
    }

    /// The voice on the dark island.
    var voice: TabVoice { voice(.dark) }

    /// The tab's solid colour, for what the user touches: the send button, a highlighted row, a drop outline.
    var accent: Color { voice.accent.color }

    /// The tab's colour for small text and thin marks (the user's answer, a ticked tab, a check): the accent itself on the dark island, and on the light one the
    /// deep shade of the user's message, which is readable on the paper (4.7 : 1) where the accent is only a fill.
    var ink: Color { Color(nsColor: .nook(dark: shades.accent.nsColor, light: shades.deepMarker.nsColor)) }

    /// The shades of the user's message block as colours that follow the theme: the `>` and what is said beside it (a plan's icon, an active toggle's glyph), lighter than
    /// the accent on the dark island and deep on the light one; and the words, nearly white on black and nearly ink on paper. What `voice(_:)` gives AppKit code, for views.
    var marker: Color { Color(nsColor: .nook(dark: shades.marker.nsColor, light: shades.deepMarker.nsColor)) }
    var voiceText: Color { Color(nsColor: .nook(dark: shades.text.nsColor, light: shades.deepText.nsColor)) }

    // MARK: Around the voice

    /// Whether the island's own surfaces lean toward this colour. Mint is the island's original look, so it leaves them alone.
    var castsSurfaces: Bool { self != .mint }

    /// The glass of the composer, and of the question's card that takes its place, leaning toward the tab's colour.
    var composerSurface: TabSurface { composerSurface(.dark) }

    /// The same in `scheme`. On the dark island it is a little lighter than black (a touch of the tab's colour in it); on the light one it is a white card
    /// on the paper, with a faint cast of the colour.
    func composerSurface(_ scheme: ColorScheme) -> TabSurface {
        let accent = voice.accent
        if scheme == .dark {
            guard castsSurfaces else {
                return TabSurface(dim: Color(white: 0.055), fill: Color.white.opacity(0.07), stroke: Color.white.opacity(0.07))
            }
            // The same brightness as the neutral surface, with the colour's cast on it: the island does not get lighter, it gets warmer or cooler. (The cast is
            // the colour at one fixed brightness, whatever its own is: a yellow is brighter than a blue, and neither should light the composer more.)
            let lean = accent.normalized(toMean: Self.castBrightness)
            return TabSurface(dim: TabRGB(0.055, 0.055, 0.055).mixed(with: lean.scaled(by: 0.085), by: Self.cast).color,
                              fill: TabRGB(0.07, 0.07, 0.07).mixed(with: lean.scaled(by: 0.11), by: Self.cast).color,
                              stroke: accent.color.opacity(0.14))
        }
        let paper = TabRGB(1, 1, 1)
        guard castsSurfaces else {
            return TabSurface(dim: paper.color, fill: paper.color, stroke: Color.nookInk.opacity(0.11))
        }
        // White with the colour's cast in it, about as light as the neutral card: the colour shows in the hairline round it more than in the card.
        let tinted = paper.mixed(with: accent, by: 0.07).color
        return TabSurface(dim: tinted, fill: tinted, stroke: accent.color.opacity(0.30))
    }

    /// The hairline along the island's lower edge.
    var rim: Color { castsSurfaces ? voice.accent.color.opacity(0.36) : .clear }

    /// How far toward its colour a surface goes (0 stays neutral, 1 takes the colour at the neutral surface's brightness).
    static let cast = 0.8
    /// The brightness the colour is brought to before it leans a surface (the average of its channels): the one at which the cast keeps the neutral surface's.
    static let castBrightness = 0.64
}

/// What a surface is made of: the colour laid over the glass (see `nookGlassSurface`'s `dimColor`), and the flat look it falls
/// back to (Reduce Transparency, Increase Contrast, an older macOS).
struct TabSurface {
    var dim: Color
    var fill: Color
    var stroke: Color
}

// MARK: - Reaching the views

private struct TabTintKey: EnvironmentKey {
    static let defaultValue = TabTint.mint
}

extension EnvironmentValues {
    /// The colour of the tab the views below belong to. Mint outside any tab.
    var tabTint: TabTint {
        get { self[TabTintKey.self] }
        set { self[TabTintKey.self] = newValue }
    }
}

private struct TabTintScope: ViewModifier {
    var tint: TabTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // A new colour fades in instead of switching. With Reduce Motion it switches.
        content.environment(\.tabTint, tint)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
    }
}

extension View {
    /// Hands `tint` to everything inside (`\.tabTint`).
    func tabTint(_ tint: TabTint) -> some View { modifier(TabTintScope(tint: tint)) }
}

private struct ComposerSurface: ViewModifier {
    @Environment(\.tabTint) private var tint
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat

    func body(content: Content) -> some View {
        let surface = tint.composerSurface(scheme)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.nookGlassSurface(in: shape, dim: scheme == .dark ? 0.55 : 0.72, dimColor: surface.dim, fill: surface.fill, stroke: surface.stroke)
            // On the paper the card is lifted a little (on black there is nothing to cast a shadow on).
            .shadow(color: scheme == .dark ? .clear : Color.black.opacity(0.07), radius: 3, y: 1)
    }
}

extension View {
    /// The composer's glass (the one the question's card shares), in the colour of its tab.
    func composerSurface(radius: CGFloat = 18) -> some View { modifier(ComposerSurface(radius: radius)) }
}

// MARK: - The island's rim

/// A hairline of the tab's colour along the island's lower edge and up its sides, fading before it reaches the notch. It sits
/// inside the island's own outline (the same radius `NookPanel` clips to), so it is the island's edge that is tinted.
struct IslandRim: View {
    var tint: TabTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
            .strokeBorder(tint.rim, lineWidth: 1)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0.1), .init(color: .black, location: 0.65)], startPoint: .top, endPoint: .bottom))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tint)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The rim of the selected tab. It watches the session itself: the panel does not, and a new colour has to show at once.
struct SelectedIslandRim: View {
    @ObservedObject var session: TerminalSession

    var body: some View { IslandRim(tint: session.tint) }
}
