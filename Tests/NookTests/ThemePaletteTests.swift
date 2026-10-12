import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The theme's colours checked by arithmetic: that each one that is read keeps the contrast WCAG asks of it on the surface it sits on, in both themes and with
/// Increase Contrast on, and that the dynamic colours choose the value of the appearance they are drawn in. (The pictures are in `ThemeRenderTests`.)
final class ThemePaletteTests: XCTestCase {
    override func tearDown() {
        NookContrast.force(nil)
        super.tearDown()
    }

    // MARK: Colour arithmetic

    private typealias RGB = (r: Double, g: Double, b: Double)

    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!

    /// `color` as the appearance draws it: the sRGB components and the alpha.
    private func resolved(_ color: NSColor, in appearance: NSAppearance) -> (rgb: RGB, alpha: Double) {
        var out: (rgb: RGB, alpha: Double) = ((0, 0, 0), 1)
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? color
            out = ((Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)), Double(c.alphaComponent))
        }
        return out
    }

    /// The colour laid over `surface`, as it looks.
    private func flat(_ color: NSColor, over surface: RGB, in appearance: NSAppearance) -> RGB {
        let c = resolved(color, in: appearance)
        return (c.rgb.r * c.alpha + surface.r * (1 - c.alpha), c.rgb.g * c.alpha + surface.g * (1 - c.alpha), c.rgb.b * c.alpha + surface.b * (1 - c.alpha))
    }

    private func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// The contrast of `color` (over `surface`) with `surface`.
    private func ratio(_ color: NSColor, on surface: RGB, in appearance: NSAppearance) -> Double {
        contrast(flat(color, over: surface, in: appearance), surface)
    }

    private var paper: RGB { resolved(NookPalette.screen, in: aqua).rgb }
    private let white: RGB = (1, 1, 1)
    private let black: RGB = (0, 0, 0)
    private var darkCard: RGB { resolved(NookPalette.card, in: darkAqua).rgb }

    // MARK: Text

    func testTheSecondaryTextKeepsAAOnEveryLightSurface() {
        for (name, color) in [("secondary", NookPalette.secondary), ("placeholder", NookPalette.placeholder)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: white, in: aqua), 4.5, "\(name) on the card's white")
        }
        // The labels also sit on the paper and on the pale tints of the tabs' cards.
        XCTAssertGreaterThanOrEqual(ratio(NookPalette.secondary, on: paper, in: aqua), 4.5, "secondary on the paper")
        for tint in TabTint.allCases {
            let card = tint.voice(.light).accent.nsColor.withAlphaComponent(0.12)
            let surface = flat(card, over: paper, in: aqua)
            XCTAssertGreaterThanOrEqual(ratio(NookPalette.secondary, on: surface, in: aqua), 4.5, "secondary on \(tint.rawValue)'s card")
        }
    }

    func testTheSecondaryTextKeepsAAOnEveryDarkSurface() {
        for (name, color) in [("secondary", NookPalette.secondary), ("placeholder", NookPalette.placeholder)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: black, in: darkAqua), 4.5, "\(name) on the island's black")
            XCTAssertGreaterThanOrEqual(ratio(color, on: darkCard, in: darkAqua), 4.5, "\(name) on a card")
        }
    }

    func testTheStatusColoursAreReadableAsTextInTheirTheme() {
        for (name, color) in [("mint", NookPalette.mint), ("terracotta", NookPalette.terracotta), ("amber", NookPalette.amber), ("coral", NookPalette.coral), ("info", NookPalette.info)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: paper, in: aqua), 4.5, "\(name) on the paper")
            XCTAssertGreaterThanOrEqual(ratio(color, on: white, in: aqua), 4.5, "\(name) on a white card")
            XCTAssertGreaterThanOrEqual(ratio(color, on: black, in: darkAqua), 4.5, "\(name) on black")
            XCTAssertGreaterThanOrEqual(ratio(color, on: darkCard, in: darkAqua), 4.5, "\(name) on a dark card")
        }
        // On the black strip both themes share, the colours are the vivid ones.
        for (name, color) in [("mint", NookPalette.mintOnBlack), ("terracotta", NookPalette.terracottaOnBlack), ("amber", NookPalette.amberOnBlack), ("coral", NookPalette.coralOnBlack)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: black, in: aqua), 4.5, "\(name) on the black strip in the light theme")
        }
    }

    // MARK: Increase Contrast

    func testIncreaseContrastTakesTheTextToSevenToOne() {
        NookContrast.force(true)
        let texts: [(String, NSColor)] = [("secondary", NookPalette.secondary), ("placeholder", NookPalette.placeholder), ("mint", NookPalette.mint), ("terracotta", NookPalette.terracotta),
                                          ("amber", NookPalette.amber), ("coral", NookPalette.coral), ("info", NookPalette.info)]
        for (name, color) in texts {
            XCTAssertGreaterThanOrEqual(ratio(color, on: paper, in: aqua), 7, "\(name) on the paper")
            XCTAssertGreaterThanOrEqual(ratio(color, on: white, in: aqua), 7, "\(name) on a white card")
            XCTAssertGreaterThanOrEqual(ratio(color, on: black, in: darkAqua), 7, "\(name) on black")
            XCTAssertGreaterThanOrEqual(ratio(color, on: darkCard, in: darkAqua), 7, "\(name) on a dark card")
        }
        XCTAssertGreaterThanOrEqual(ratio(NookPalette.tertiary, on: paper, in: aqua), 4.5, "even the hints are text")
        XCTAssertGreaterThanOrEqual(ratio(NookPalette.tertiary, on: black, in: darkAqua), 4.5)
    }

    func testIncreaseContrastTakesTheFillsToThreeToOneAtLeast() {
        NookContrast.force(true)
        for (name, color) in [("mintFill", NookPalette.mintFill), ("coralFill", NookPalette.coralFill), ("terracottaFill", NookPalette.terracottaFill), ("amberFill", NookPalette.amberFill)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: paper, in: aqua), 3, "\(name) on the paper")
            XCTAssertGreaterThanOrEqual(ratio(color, on: black, in: darkAqua), 3, "\(name) on black")
        }
    }

    func testIncreaseContrastOnlyStrengthensTheWashes() {
        for opacity in stride(from: 0.02, through: 1.0, by: 0.02) {
            NookContrast.force(false)
            let standard = (dark: resolved(NSColor.nookWash(opacity), in: darkAqua).alpha, light: resolved(NSColor.nookWash(opacity), in: aqua).alpha)
            NookContrast.force(true)
            let increased = (dark: resolved(NSColor.nookWash(opacity), in: darkAqua).alpha, light: resolved(NSColor.nookWash(opacity), in: aqua).alpha)
            XCTAssertGreaterThanOrEqual(increased.dark, standard.dark - 1e-9, "dark wash \(opacity)")
            XCTAssertGreaterThanOrEqual(increased.light, standard.light - 1e-9, "light wash \(opacity)")
            XCTAssertLessThanOrEqual(increased.dark, 1)
            XCTAssertLessThanOrEqual(increased.light, 1)
        }
        // A hairline gets visibly stronger, and the order of the washes is kept: a stronger one never turns weaker than a lighter one.
        NookContrast.force(true)
        XCTAssertGreaterThan(resolved(NSColor.nookWash(0.09), in: darkAqua).alpha, 0.17)
        XCTAssertGreaterThan(resolved(NSColor.nookWash(0.09), in: aqua).alpha, 0.17)
        var last = (dark: 0.0, light: 0.0)
        for opacity in stride(from: 0.02, through: 1.0, by: 0.01) {
            let now = (dark: resolved(NSColor.nookWash(opacity), in: darkAqua).alpha, light: resolved(NSColor.nookWash(opacity), in: aqua).alpha)
            XCTAssertGreaterThanOrEqual(now.dark, last.dark - 1e-9, "dark washes keep their order at \(opacity)")
            XCTAssertGreaterThanOrEqual(now.light, last.light - 1e-9, "light washes keep their order at \(opacity)")
            last = now
        }
    }

    func testTheHighContrastAppearancesAreReadAsTheirThemes() {
        // Whatever name macOS gives these (it maps them to the plain ones on its newest versions), they are the same two themes.
        XCTAssertFalse(NSAppearance(named: .accessibilityHighContrastAqua)!.nookIsDark)
        XCTAssertTrue(NSAppearance(named: .accessibilityHighContrastDarkAqua)!.nookIsDark)
    }

    func testTheColoursFollowTheFlagInEveryAppearance() {
        for appearance in [aqua, darkAqua, NSAppearance(named: .vibrantDark)!, NSAppearance(named: .accessibilityHighContrastAqua)!] {
            NookContrast.force(false)
            let standard = resolved(NookPalette.secondary, in: appearance).alpha
            NookContrast.force(true)
            let increased = resolved(NookPalette.secondary, in: appearance).alpha
            XCTAssertGreaterThan(increased, standard, "\(appearance.name.rawValue)")
        }
    }

    func testTheFlagGoesBackToTheSystemsWhenItIsNoLongerForced() {
        NookContrast.force(true)
        XCTAssertTrue(NookContrast.increased)
        NookContrast.force(nil)
        XCTAssertEqual(NookContrast.increased, NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    // MARK: The preference

    func testThePreferencesAreNamedInSpanishAndResolveAgainstMacOS() {
        XCTAssertEqual(ThemePreference.allCases.map(\.title), ["Sistema", "Claro", "Oscuro"])
        XCTAssertEqual(Set(ThemePreference.allCases.map(\.symbol)).count, 3, "each has a symbol of its own")
        XCTAssertTrue(ThemePreference.allCases.allSatisfy { !$0.detail.isEmpty })
        XCTAssertEqual(ThemePreference.system.resolved(system: .dark), .dark)
        XCTAssertEqual(ThemePreference.system.resolved(system: .light), .light)
        XCTAssertEqual(ThemePreference.light.resolved(system: .dark), .light)
        XCTAssertEqual(ThemePreference.dark.resolved(system: .light), .dark)
        XCTAssertNil(ThemePreference.system.appearance, "no appearance of its own is what makes Sistema follow macOS as it changes")
        XCTAssertEqual(ThemePreference.light.appearance?.name, .aqua)
        XCTAssertEqual(ThemePreference.dark.appearance?.name, .darkAqua)
        XCTAssertEqual(ThemePreference.allCases.map(\.rawValue), ["system", "light", "dark"], "what is saved")
    }

    /// The red of the middle of `host` once it is in a window of no appearance of its own, which takes the application's: macOS's.
    @MainActor
    private func middleRed(of host: NSView, in window: NSWindow) throws -> Double {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Double(try XCTUnwrap(rep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB)).redComponent)
    }

    @MainActor
    private func themed(_ preference: ThemePreference) -> (NSHostingView<some View>, NSWindow) {
        let host = NSHostingView(rootView: Color.nookCard.frame(width: 20, height: 20).nookTheme(preference))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (host, window)
    }

    /// Sistema is whatever macOS is, as it changes; Claro and Oscuro are what they say whatever it is.
    @MainActor
    func testSistemaFollowsMacOSLiveAndTheOthersDoNot() throws {
        let app = NSApplication.shared
        let original = app.appearance
        addTeardownBlock { MainActor.assumeIsolated { app.appearance = original } }

        app.appearance = aqua
        let (system, systemWindow) = themed(.system)
        XCTAssertGreaterThan(try middleRed(of: system, in: systemWindow), 0.9, "macOS in light: the card is white")
        app.appearance = darkAqua
        XCTAssertLessThan(try middleRed(of: system, in: systemWindow), 0.25, "macOS switched to dark with the island open: the card follows, with no restart")
        app.appearance = aqua
        XCTAssertGreaterThan(try middleRed(of: system, in: systemWindow), 0.9, "and back")

        // Explicit themes: the window takes the theme's appearance (not the application's), and the island is that theme.
        for macOS in [aqua, darkAqua] {
            app.appearance = macOS
            let (light, lightWindow) = themed(.light)
            XCTAssertGreaterThan(try middleRed(of: light, in: lightWindow), 0.9, "Claro with macOS in \(macOS.name.rawValue)")
            XCTAssertEqual(lightWindow.appearance?.name, .aqua)
            let (dark, darkWindow) = themed(.dark)
            XCTAssertLessThan(try middleRed(of: dark, in: darkWindow), 0.25, "Oscuro with macOS in \(macOS.name.rawValue)")
            XCTAssertEqual(darkWindow.appearance?.name, .darkAqua)
        }
    }

    // MARK: Dynamic colours

    func testEachThemeDrawsItsOwnValue() {
        XCTAssertEqual(resolved(NookPalette.screen, in: aqua).alpha, 1, "the paper is opaque in the light theme")
        XCTAssertEqual(resolved(NookPalette.screen, in: darkAqua).alpha, 0, "and nothing in the dark one, where the island's black is the body")
        XCTAssertEqual(resolved(NookPalette.text, in: darkAqua).rgb.r, 1, accuracy: 0.001)
        XCTAssertLessThan(resolved(NookPalette.text, in: aqua).rgb.r, 0.2)
        XCTAssertEqual(resolved(NookPalette.card, in: aqua).rgb.r, 1, accuracy: 0.001)
        XCTAssertLessThan(resolved(NookPalette.card, in: darkAqua).rgb.r, 0.2)
        // The vibrancy variants are the same two themes.
        XCTAssertEqual(resolved(NookPalette.text, in: NSAppearance(named: .vibrantDark)!).rgb.r, 1, accuracy: 0.001)
    }

    func testTheShadowIsAThirdOfItsStrengthOnThePaper() {
        let dark = resolved(NookPalette.shadow(0.5), in: darkAqua).alpha
        let light = resolved(NookPalette.shadow(0.5), in: aqua).alpha
        XCTAssertEqual(dark, 0.5, accuracy: 0.001)
        XCTAssertEqual(light, 0.5 * 0.34, accuracy: 0.001)
    }

    // MARK: The transcript

    func testTheLightTranscriptIsReadOnThePaper() {
        let palette = TranscriptPalette(dark: false)
        let surface = paper
        let removed = flat(palette.removedFill, over: surface, in: aqua), added = flat(palette.addedFill, over: surface, in: aqua)
        let read: [(String, NSColor, RGB)] = [
            ("text", palette.text, surface), ("tool name", palette.toolName, surface), ("tool", palette.tool, surface), ("output", palette.output, surface),
            ("path", palette.changePath, surface), ("heading", palette.heading, surface), ("link", palette.link, surface),
            ("inline code", palette.inlineCode, flat(palette.inlineCodeFill, over: surface, in: aqua)),
            ("code on a removed row", palette.changedCode, removed), ("code on an added row", palette.changedCode, added),
            ("context code", palette.contextCode, surface),
            ("removed mark", palette.removedMark, removed), ("added mark", palette.addedMark, added),
        ]
        for (name, color, on) in read { XCTAssertGreaterThanOrEqual(ratio(color, on: on, in: aqua), 4.5, "\(name) on the paper") }
        for token in [SyntaxToken.keyword, .string, .number, .comment, .type, .function, .attribute, .variable, .inserted, .deleted] {
            XCTAssertGreaterThanOrEqual(ratio(palette.color(token), on: surface, in: aqua), 4.5, "\(token) on the paper")
        }
        // What is drawn and not read keeps 3 : 1.
        for (name, color) in [("tool marker", palette.toolMarker), ("output marker", palette.outputMarker), ("gutter", palette.gutter), ("Claude's marker", palette.assistantMarker)] {
            XCTAssertGreaterThanOrEqual(ratio(color, on: surface, in: aqua), 3, "\(name) on the paper")
        }
    }

    func testTheDarkTranscriptIsReadOnBlack() {
        let palette = TranscriptPalette(dark: true)
        let removed = flat(palette.removedFill, over: black, in: darkAqua), added = flat(palette.addedFill, over: black, in: darkAqua)
        let read: [(String, NSColor, RGB)] = [
            ("text", palette.text, black), ("tool name", palette.toolName, black), ("tool", palette.tool, black), ("output", palette.output, black),
            ("path", palette.changePath, black), ("heading", palette.heading, black), ("link", palette.link, black),
            ("inline code", palette.inlineCode, flat(palette.inlineCodeFill, over: black, in: darkAqua)),
            ("code on a removed row", palette.changedCode, removed), ("code on an added row", palette.changedCode, added), ("context code", palette.contextCode, black),
            ("removed mark", palette.removedMark, removed), ("added mark", palette.addedMark, added),
        ]
        for (name, color, on) in read { XCTAssertGreaterThanOrEqual(ratio(color, on: on, in: darkAqua), 4.5, "\(name) on black") }
        for token in [SyntaxToken.keyword, .string, .number, .comment, .type, .function, .attribute, .variable, .inserted, .deleted] {
            XCTAssertGreaterThanOrEqual(ratio(palette.color(token), on: black, in: darkAqua), 4.5, "\(token) on black")
        }
    }

    /// The text view paints a link with its own attributes over the ones the styler gave it, so they have to follow the theme: the dark theme's pale blue
    /// on the paper was 2 : 1.
    @MainActor
    func testALinkInTheMirrorIsPaintedInTheThemesOwnColour() throws {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        for (dark, appearance, surface) in [(true, darkAqua, black), (false, aqua, paper), (true, darkAqua, black)] {
            scroll.setTheme(dark: dark, transcript: true)
            let color = try XCTUnwrap(scroll.textView.linkTextAttributes?[.foregroundColor] as? NSColor)
            XCTAssertEqual(color, TranscriptPalette(dark: dark).link)
            XCTAssertGreaterThanOrEqual(ratio(color, on: surface, in: appearance), 4.5, "a link in the \(dark ? "dark" : "light") theme")
        }
    }

    // MARK: The chips

    func testTheModeChipsAreSeenOnTheComposersSurfaces() {
        let modes: [ClaudeMode] = [.standard] + [ClaudeMode.Kind.auto, .acceptEdits, .plan, .bypassPermissions].map { ClaudeMode(kind: $0, label: $0.rawValue, hints: []) }
            + [ClaudeMode(kind: nil, label: "a mode Nook does not know", hints: [])]
        for mode in modes {
            let style = ClaudeModeStyle(mode)
            XCTAssertGreaterThanOrEqual(ratio(style.lightColor.nsColor, on: white, in: aqua), 3, "\(style.title) in the light theme")
            XCTAssertGreaterThanOrEqual(ratio(style.color.nsColor, on: darkCard, in: darkAqua), 4.5, "\(style.title) in the dark theme")
        }
    }
}
