import SwiftUI
import AppKit

// The island's look in light and in dark, and the colours both are made of.
//
// Nook has two themes, and the user picks between them (or lets macOS pick): `ThemePreference`. The island is a piece of hardware first: the
// notch is black, so the collapsed island, the alert's peek and the strip the island grows from (its header, with the cat in it) stay black in
// both themes. What changes is the island's body, under that strip: black in the dark theme, a warm paper in the light one (see
// `IslandSurface.swift`, where the two meet).
//
// Colours are written once, for both themes. Each one in this file is a dynamic colour: it has a dark value and a light value, and the one
// that shows is the one the view's colour scheme asks for (`\.colorScheme`, or the `NSAppearance` of an AppKit view). So a view says what a
// colour is for, and never which theme it is in:
//
//   washes and ink      `Color.nookInk`, `Color.nookWash(0.09)`: white over black, warm near-black over paper. What the code used to write as
//                       `Color.white.opacity(0.09)`: a fill that lifts a control a little, a hairline, a hovered row.
//   text                `.primary` (the system's), `Color.nookSecondary` and `Color.nookTertiary`. The secondary one is darker in the light
//                       theme than the system's own, so small labels keep a contrast of 4.5 : 1 on the paper (macOS's is 3.9 : 1).
//   surfaces            `Color.nookCard` (lists, recap, notices), `.nookMenu`, `.nookPanel`, `.nookSettings`, `.nookTip`, `.nookScreen`.
//   what colours say    `Color.nookMint` (Nook, done, on), `.nookTerracotta` (Claude), `.nookAmber` (a question, attention), `.nookCoral`
//                       (an error), `.nookInfo`. Their dark values are the vivid ones that read on black; their light values are deeper, so
//                       they are readable as text on the paper (4.5 : 1 or more).
//   the user's voice    the tab's colour (`TabStyle.swift`), which has a dark and a light shade of its own.
//
// Increase Contrast (System Settings → Accessibility → Display) gets values of its own for the colours that carry text or draw an edge: the
// secondary and tertiary text, the placeholder, the washes (hairlines, fills) and the status colours on the paper (7 : 1 or more). The palette
// reads it from `NookContrast`, so a view needs to know nothing about it.
//
// The same names exist on `NSColor` for what AppKit draws (the message field, the mirror, the resize handles).
//
// A new screen (a home, a dialog, a card) takes its colours from here and its surfaces from `NookGlass.swift` (`nookGlassCard`, `nookGlassSurface`), sits on
// the island's paper when it is inside the island (it needs nothing to be themed), and wears `.nookTheme(model.display.theme)` at its root when it is a window of
// its own. Black strips the notch owns (the header, the collapsed island, the alert's peek) are the one place that is black in both themes: they use the
// `...OnBlack` colours and `IslandSurface.headerScheme`.

// MARK: - The preference

/// How the island chooses its theme: follow macOS, or stay light or dark whatever macOS does. Raw values are saved.
enum ThemePreference: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self { case .system: "Sistema"; case .light: "Claro"; case .dark: "Oscuro" }
    }

    /// The symbol on the picker's segment.
    var symbol: String {
        switch self { case .system: "circle.lefthalf.filled"; case .light: "sun.max"; case .dark: "moon" }
    }

    /// One line for the tooltip and VoiceOver.
    var detail: String {
        switch self {
        case .system: "La isla sigue la apariencia de macOS, también cuando cambia sola"
        case .light: "La isla se ve clara aunque macOS esté en oscuro"
        case .dark: "La isla se ve oscura aunque macOS esté en claro"
        }
    }

    /// The scheme the theme asks for; nil follows the surrounding one (macOS's).
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }

    /// The appearance AppKit windows take; nil is "whatever macOS has", which is what makes `.system` follow it live.
    var appearance: NSAppearance? {
        switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }

    /// The scheme the island is drawn in when macOS is in `system`.
    func resolved(system: ColorScheme) -> ColorScheme { colorScheme ?? system }
}

extension ColorScheme {
    var isDark: Bool { self == .dark }
}

extension NSAppearance {
    /// Whether this is one of the dark appearances (vibrant and high contrast ones included).
    var nookIsDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

// MARK: - Increase Contrast

/// Whether Increase Contrast is on, as the palette's colours read it. It is the system's setting (macOS gives it to every app the same). The colours ask for
/// it each time they are resolved, which is often and from any thread, so it is kept here, and `follow()` keeps it up to date.
///
/// A change shows in what is drawn again: SwiftUI resolves a dynamic colour when it draws the view that has it, so the island picks the change up as it opens
/// and in the parts of it that change as the conversation moves; what was painted already is not touched. Nothing forces a repaint on purpose: the one way
/// found to make SwiftUI resolve a dynamic colour again with nothing else changed is to flip the window's appearance for a frame, which would flash.
enum NookContrast {
    private static let lock = NSLock()
    private static var system: Bool?
    private static var forced: Bool?
    private static var observer: NSObjectProtocol?

    static var increased: Bool {
        lock.lock()
        let pretended = forced, known = system
        lock.unlock()
        if let pretended { return pretended }
        if let known { return known }
        // AppKit is asked outside the lock: nothing it does may come back here while it is held.
        let now = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        lock.lock(); system = now; lock.unlock()
        return now
    }

    /// Reads the setting again.
    static func refresh() {
        let now = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        lock.lock(); system = now; lock.unlock()
    }

    /// Starts following the setting: macOS says when the display options change (this one, Reduce Transparency, Reduce Motion…). Idempotent.
    @MainActor
    static func follow() {
        lock.lock()
        let following = observer != nil
        lock.unlock()
        guard !following else { return }
        let token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in refresh() }
        let now = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        lock.lock(); observer = token; system = now; lock.unlock()
    }

    /// For tests and renders: pretend the setting is `value`; nil goes back to the system's.
    static func force(_ value: Bool?) {
        lock.lock(); forced = value; lock.unlock()
    }
}

// MARK: - Dynamic colours

extension NSColor {
    /// A colour that is `dark` on the dark theme and `light` on the light one.
    static func nook(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.nookIsDark ? dark : light }
    }

    /// The same, and `darkIncreased` / `lightIncreased` for the two themes while Increase Contrast is on.
    static func nook(dark: NSColor, light: NSColor, darkIncreased: NSColor, lightIncreased: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let increased = NookContrast.increased
            return appearance.nookIsDark ? (increased ? darkIncreased : dark) : (increased ? lightIncreased : light)
        }
    }

    static func nookSRGB(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension Color {
    /// A colour that is `dark` on the dark theme and `light` on the light one.
    static func nook(dark: NSColor, light: NSColor) -> Color { Color(nsColor: .nook(dark: dark, light: light)) }
}

/// The island's palette: every role of colour with its dark and its light value, as `NSColor`. The `Color` ones below are made from these,
/// so AppKit and SwiftUI draw the same colours.
enum NookPalette {
    // MARK: Ink

    /// What washes and hairlines are made of: white on the dark island, a warm near-black on the paper.
    static let ink = NSColor.nook(dark: .white, light: .nookSRGB(0.110, 0.105, 0.095))
    /// The island's text at full strength (the system's `.primary` is at 85 %).
    static let text = NSColor.nook(dark: .white, light: .nookSRGB(0.110, 0.105, 0.095))
    /// Small labels. Dark: the system's secondary white (55 %). Light: 66 % of the ink, which is 5.2 : 1 on the paper. Increase Contrast: 78 % and 84 % (9 : 1).
    static let secondary = NSColor.nook(dark: NSColor(white: 1, alpha: 0.55), light: .nookSRGB(0.110, 0.105, 0.095, 0.66),
                                        darkIncreased: NSColor(white: 1, alpha: 0.78), lightIncreased: .nookSRGB(0.110, 0.105, 0.095, 0.84))
    /// Mint for what is drawn and not read (a bar, a dot, a fill): the vivid mint on both islands, the tab's own accent on the paper. With Increase Contrast
    /// the paper's one is the deep mint of the text.
    static let mintFill = NSColor.nook(dark: mintOnBlack, light: .nookSRGB(0.182, 0.640, 0.512), darkIncreased: mintOnBlack, lightIncreased: mintIncreased)
    /// Coral for what is drawn and not read.
    static let coralFill = NSColor.nook(dark: coralOnBlack, light: .nookSRGB(0.847, 0.275, 0.275), darkIncreased: coralOnBlack, lightIncreased: coralIncreased)
    /// What the message field says while it is empty (Claude's suggestion, or what to write): a little under the secondary text, and still 4.5 : 1 on the
    /// composer's white (4.4 : 1 on the paper itself, where it never sits).
    static let placeholder = NSColor.nook(dark: NSColor(white: 1, alpha: 0.46), light: .nookSRGB(0.110, 0.105, 0.095, 0.63),
                                          darkIncreased: NSColor(white: 1, alpha: 0.66), lightIncreased: .nookSRGB(0.110, 0.105, 0.095, 0.76))
    /// Hints that carry nothing the screen does not say elsewhere.
    static let tertiary = NSColor.nook(dark: NSColor(white: 1, alpha: 0.38), light: .nookSRGB(0.110, 0.105, 0.095, 0.48),
                                       darkIncreased: NSColor(white: 1, alpha: 0.60), lightIncreased: .nookSRGB(0.110, 0.105, 0.095, 0.68))

    // MARK: Surfaces

    /// The island's body in the light theme (a warm paper). In the dark theme the island's own black is the body, so this is clear.
    static let screen = NSColor.nook(dark: .clear, light: .nookSRGB(0.953, 0.941, 0.914))
    /// The paper as an opaque colour, in both themes, for what has to cover it (a scrim, a fade into it).
    static let screenSolid = NSColor.nook(dark: .black, light: .nookSRGB(0.953, 0.941, 0.914))
    /// Floating cards: the agents' list, the recap, the warnings'.
    static let card = NSColor.nook(dark: NSColor(white: 0.115, alpha: 1), light: .nookSRGB(1, 1, 1))
    /// A card that sits above another one (a notice, the joined-message warning).
    static let cardRaised = NSColor.nook(dark: NSColor(white: 0.13, alpha: 1), light: .nookSRGB(1, 1, 1))
    /// The "/" menu's surface.
    static let menu = NSColor.nook(dark: NSColor(white: 0.08, alpha: 1), light: .nookSRGB(1, 1, 1))
    /// Claude's panel: a little off the card, so the card's rows on it read.
    static let panel = NSColor.nook(dark: NSColor(white: 0.05, alpha: 1), light: .nookSRGB(0.985, 0.980, 0.968))
    /// A control that is a card of its own over the island (the welcome's suggestion): a little lighter than the cards, so it reads as pressable.
    static let chip = NSColor.nook(dark: NSColor(white: 0.16, alpha: 1), light: .nookSRGB(1, 1, 1))
    /// The settings card.
    static let settings = NSColor.nook(dark: NSColor(white: 0.105, alpha: 1), light: .nookSRGB(0.985, 0.980, 0.968))
    /// The cartelito over a control that explains it.
    static let tip = NSColor.nook(dark: NSColor(white: 0.12, alpha: 1), light: .nookSRGB(1, 1, 1))

    /// A well sunk into a card (the preview box of a question): darker than the card, a shade of black on the dark island and of ink on the paper.
    static let inset = NSColor.nook(dark: NSColor(white: 0, alpha: 0.3), light: .nookSRGB(0.110, 0.105, 0.095, 0.045),
                                    darkIncreased: NSColor(white: 0, alpha: 0.5), lightIncreased: .nookSRGB(0.110, 0.105, 0.095, 0.09))

    /// What is laid over a glass surface, under its content, to keep the text clean and pull the glass toward the island's own surface: black on the dark
    /// island, white on the paper.
    static let glassDim = NSColor.nook(dark: .black, light: .white)

    // MARK: What colours say

    /// Nook, done, on. Dark: the vivid mint that reads on black. Light: deep enough to be text on paper (5.0 : 1; 7.7 : 1 with Increase Contrast).
    static let mint = NSColor.nook(dark: .nookSRGB(0.316, 0.852, 0.679), light: .nookSRGB(0.110, 0.455, 0.351), darkIncreased: mintOnBlack, lightIncreased: mintIncreased)
    /// Claude. Dark: the terracotta of its terminal spinner, a little livelier. Light: a rust that is text on paper (4.6 : 1).
    static let terracotta = NSColor.nook(dark: .nookSRGB(0.900, 0.469, 0.335), light: .nookSRGB(0.716, 0.288, 0.148), darkIncreased: terracottaBrighter, lightIncreased: terracottaIncreased)
    /// Terracotta for what is drawn and not read (a marker, a bar, a fill): the same colour a step brighter on paper (3.4 : 1).
    static let terracottaFillLight = NSColor.nookSRGB(0.816, 0.384, 0.239)
    static let terracottaFill = NSColor.nook(dark: terracottaOnBlack, light: terracottaFillLight, darkIncreased: terracottaOnBlack, lightIncreased: terracottaIncreased)
    /// A question, attention.
    static let amber = NSColor.nook(dark: .nookSRGB(0.991, 0.784, 0.378), light: .nookSRGB(0.541, 0.401, 0.091), darkIncreased: amberOnBlack, lightIncreased: amberIncreased)
    /// Amber for what is drawn and not read: a dot, a bar, a fill.
    static let amberFill = NSColor.nook(dark: .nookSRGB(0.991, 0.784, 0.378), light: .nookSRGB(0.875, 0.620, 0.090), darkIncreased: amberOnBlack, lightIncreased: amberIncreased)
    /// An error.
    static let coral = NSColor.nook(dark: .nookSRGB(0.973, 0.417, 0.404), light: .nookSRGB(0.751, 0.228, 0.236), darkIncreased: coralBrighter, lightIncreased: coralIncreased)
    /// Information that is neither Claude's nor the user's.
    static let info = NSColor.nook(dark: .nookSRGB(0.499, 0.740, 0.986), light: .nookSRGB(0.093, 0.421, 0.700), darkIncreased: .nookSRGB(0.499, 0.740, 0.986), lightIncreased: .nookSRGB(0.050, 0.300, 0.560))

    /// The deeper values of the four on the paper while Increase Contrast is on: 7 : 1 or more.
    static let mintIncreased = NSColor.nookSRGB(0.040, 0.335, 0.250)
    static let terracottaIncreased = NSColor.nookSRGB(0.540, 0.190, 0.085)
    static let amberIncreased = NSColor.nookSRGB(0.400, 0.285, 0.040)
    static let coralIncreased = NSColor.nookSRGB(0.600, 0.140, 0.155)
    /// And the brighter terracotta and coral on the dark island's cards (7 : 1 on them; the black strip's own values already are on black).
    static let terracottaBrighter = NSColor.nookSRGB(0.960, 0.580, 0.450)
    static let coralBrighter = NSColor.nookSRGB(1.000, 0.560, 0.545)

    /// The same four on the black strip, which is dark in both themes (the header's bell, the collapsed island's badges).
    static let mintOnBlack = NSColor.nookSRGB(0.316, 0.852, 0.679)
    static let terracottaOnBlack = NSColor.nookSRGB(0.900, 0.469, 0.335)
    static let amberOnBlack = NSColor.nookSRGB(0.991, 0.784, 0.378)
    static let coralOnBlack = NSColor.nookSRGB(0.973, 0.417, 0.404)

    // MARK: Shadows

    /// A shadow's black: as strong as asked on the dark island, a third of it on the paper, where it only has to lift a card.
    static func shadow(_ opacity: Double) -> NSColor {
        NSColor.nook(dark: NSColor(white: 0, alpha: opacity), light: NSColor(white: 0, alpha: opacity * 0.34))
    }
}

extension Color {
    static let nookInk = Color(nsColor: NookPalette.ink)
    static let nookText = Color(nsColor: NookPalette.text)
    static let nookSecondary = Color(nsColor: NookPalette.secondary)
    static let nookTertiary = Color(nsColor: NookPalette.tertiary)

    static let nookScreen = Color(nsColor: NookPalette.screen)
    static let nookScreenSolid = Color(nsColor: NookPalette.screenSolid)
    static let nookCard = Color(nsColor: NookPalette.card)
    static let nookCardRaised = Color(nsColor: NookPalette.cardRaised)
    static let nookMenu = Color(nsColor: NookPalette.menu)
    static let nookPanel = Color(nsColor: NookPalette.panel)
    static let nookSettings = Color(nsColor: NookPalette.settings)
    static let nookTip = Color(nsColor: NookPalette.tip)
    static let nookChip = Color(nsColor: NookPalette.chip)
    static let nookGlassDim = Color(nsColor: NookPalette.glassDim)
    static let nookInset = Color(nsColor: NookPalette.inset)

    static let nookMint = Color(nsColor: NookPalette.mint)
    static let nookTerracotta = Color(nsColor: NookPalette.terracotta)
    static let nookTerracottaFill = Color(nsColor: NookPalette.terracottaFill)
    static let nookAmber = Color(nsColor: NookPalette.amber)
    static let nookAmberFill = Color(nsColor: NookPalette.amberFill)
    static let nookCoral = Color(nsColor: NookPalette.coral)
    static let nookMintFill = Color(nsColor: NookPalette.mintFill)
    static let nookCoralFill = Color(nsColor: NookPalette.coralFill)
    static let nookInfo = Color(nsColor: NookPalette.info)

    /// The ink at `opacity`: what `Color.white.opacity(opacity)` was on the dark island. On paper the same opacity is a little less visible
    /// than white on black, so `light` can ask for more there.
    static func nookWash(_ opacity: Double, light: Double? = nil) -> Color {
        Color(nsColor: NookWashes.color(opacity, light: light ?? opacity))
    }

    /// A shadow colour (`NookPalette.shadow`).
    static func nookShadow(_ opacity: Double) -> Color { Color(nsColor: NookWashes.shadow(opacity)) }
}

/// The washes, made once each: SwiftUI compares the colours a view is given, and a new dynamic colour for every pass would look like a change.
private enum NookWashes {
    private static var washes: [String: NSColor] = [:]
    private static var shadows: [Double: NSColor] = [:]
    private static let lock = NSLock()

    static func color(_ dark: Double, light: Double) -> NSColor {
        let key = "\(dark)/\(light)"
        lock.lock(); defer { lock.unlock() }
        if let found = washes[key] { return found }
        let made = NSColor.nook(dark: NSColor(white: 1, alpha: dark), light: .nookSRGB(0.110, 0.105, 0.095, min(1, light)),
                                darkIncreased: NSColor(white: 1, alpha: increased(dark, structure: 1.6, content: 0.22)),
                                lightIncreased: .nookSRGB(0.110, 0.105, 0.095, increased(light, structure: 1.5, content: 0.2)))
        washes[key] = made
        return made
    }

    /// A wash with Increase Contrast on. What is structure (a hairline, a fill under 25 %) gets a stronger share of the ink and a floor; what is content (an
    /// icon, a label drawn as a wash) gets a fixed amount more. The two meet at 25 %, so a wash never gets weaker than one that was lighter.
    static func increased(_ opacity: Double, structure: Double, content: Double) -> Double {
        opacity < 0.25 ? min(1, opacity * structure + 0.05) : min(1, opacity + content)
    }

    static func shadow(_ opacity: Double) -> NSColor {
        lock.lock(); defer { lock.unlock() }
        if let found = shadows[opacity] { return found }
        let made = NookPalette.shadow(opacity)
        shadows[opacity] = made
        return made
    }
}

extension NSColor {
    static var nookInk: NSColor { NookPalette.ink }
    static var nookText: NSColor { NookPalette.text }
    static var nookSecondary: NSColor { NookPalette.secondary }
    static var nookTertiary: NSColor { NookPalette.tertiary }

    /// The ink at `opacity` (white on the dark island).
    static func nookWash(_ opacity: Double, light: Double? = nil) -> NSColor { NookWashes.color(opacity, light: light ?? opacity) }
}

// MARK: - Putting the theme on a view

/// Gives the views below the theme the user chose, and the window it lives in the matching appearance. Put it once on the root of each hosting
/// view (the island, the settings card, the cue, the tab editor): the scheme goes down as `\.colorScheme` for SwiftUI, and the window takes the
/// appearance for what AppKit draws (menus, the pointer's popovers, the message field's scrollers) and for the surrounding colour scheme, which is
/// what `.system` reads to follow macOS live.
///
/// When the user switches the theme, the window cross-fades from the old look to the new one (`NookAppearanceView.crossfade`) instead of flipping
/// in one frame: a fade, which Reduce Motion keeps; with the app's animations off it flips.
private struct NookThemeScope: ViewModifier {
    var preference: ThemePreference
    /// The scheme around the view: macOS's while the window follows it, which is the only time it is read (an explicit theme overrides it).
    @Environment(\.colorScheme) private var surrounding
    @Environment(\.nookMotion) private var animated

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, preference.resolved(system: surrounding))
            .background(NookAppearanceProbe(preference: preference, animated: animated))
    }
}

extension View {
    /// `preference`'s theme for everything inside, and for the window the view is in.
    func nookTheme(_ preference: ThemePreference) -> some View { modifier(NookThemeScope(preference: preference)) }
}

/// The AppKit half of the theme: a view with no size that sets its window's appearance. The island's windows (`NotchPanel`) also set the application's, so
/// the menus they open and the panels they ask for (the folder's) agree with the theme; a window of a test or a preview only sets its own.
private struct NookAppearanceProbe: NSViewRepresentable {
    var preference: ThemePreference
    var animated: Bool

    func makeNSView(context: Context) -> NookAppearanceView { NookAppearanceView() }
    func updateNSView(_ view: NookAppearanceView, context: Context) {
        view.animated = animated
        view.preference = preference
    }
}

final class NookAppearanceView: NSView {
    /// How long the window takes to cross-fade from one theme to the other.
    static let fadeDuration: CFTimeInterval = 0.3
    /// The key of the fade on the window's root layer: Core Animation keeps a transition under its own key, whatever it is added with.
    static let fadeKey = kCATransition

    var preference = ThemePreference.system {
        didSet {
            guard preference != oldValue else { return }
            // Only a change the user can see: not the theme a window takes as it is first put together.
            if animated, applied { crossfade() }
            apply()
        }
    }
    /// Whether a change of theme cross-fades (the app's animations, `\.nookMotion`).
    var animated = true
    /// The window has had its appearance from this view at least once.
    private var applied = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The window's root layer fades from what it shows now to what it shows once the new theme is drawn. Core Animation keeps the picture of the old look and
    /// fades it into the live layers, so whatever SwiftUI and AppKit draw anew in this pass (and anything that moves meanwhile) comes in under it. One fade, on the
    /// render server: nothing runs on the app's side while it plays.
    private func crossfade() {
        guard let layer = window?.contentView?.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: Self.fadeKey)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NookContrast.follow()
        apply()
    }

    private func apply() {
        guard let window else { return }
        applied = true
        let appearance = preference.appearance
        if window.appearance != appearance { window.appearance = appearance }
        if window is NotchPanel, NSApp.appearance != appearance { NSApp.appearance = appearance }
    }
}
