import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What a tab's colour gives the island: the accent of each colour, the surfaces that lean toward it, and the user's message
/// block in the conversation, in the dark theme and in the light one. Mint is the default; it keeps the island's neutral surfaces.
@MainActor
final class TabStyleTests: XCTestCase {
    // MARK: Colour maths

    private func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }

    private func luminance(_ c: TabRGB) -> Double { 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue) }

    /// WCAG contrast of white on `c`.
    private func contrastWithWhite(_ c: TabRGB) -> Double { 1.05 / (luminance(c) + 0.05) }

    private func rgb(_ color: NSColor) -> TabRGB {
        let c = color.usingColorSpace(.sRGB)!
        return TabRGB(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private func rgb(_ color: Color) -> TabRGB { rgb(NSColor(color)) }

    /// Degrees, 0…360.
    private func hue(_ c: TabRGB) -> Double {
        let top = max(c.red, c.green, c.blue), bottom = min(c.red, c.green, c.blue)
        let spread = top - bottom
        guard spread > 0 else { return 0 }
        let degrees: Double
        if top == c.red { degrees = ((c.green - c.blue) / spread).truncatingRemainder(dividingBy: 6) }
        else if top == c.green { degrees = (c.blue - c.red) / spread + 2 }
        else { degrees = (c.red - c.green) / spread + 4 }
        return (degrees * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    private func hueGap(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 360 - d) }

    private func saturation(_ c: TabRGB) -> Double {
        let top = max(c.red, c.green, c.blue), bottom = min(c.red, c.green, c.blue)
        return top == 0 ? 0 : (top - bottom) / top
    }

    private func assertClose(_ a: TabRGB, _ b: TabRGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.004, message, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.004, message, file: file, line: line)
    }

    // MARK: Mint is the default

    /// Intentional change (the more vivid palette): mint's accent is deeper and livelier than the (0.32, 0.73, 0.61) it was, so the send button's white arrow
    /// reads at 3.1 : 1 where it read at 2.4 : 1.
    func testMintIsTheDefaultAndTheMirrorsAndTheButtonsAreOneColour() {
        let voice = TabTint.mint.voice
        XCTAssertEqual(voice, TabVoice(accent: TabRGB(0.182, 0.640, 0.512), marker: TabRGB(0.503, 0.850, 0.732), text: TabRGB(0.901, 0.975, 0.945)))
        XCTAssertEqual(voice, TabVoice.mint)
        XCTAssertEqual(TabTint.mint.accent, Color(red: 0.182, green: 0.640, blue: 0.512), "The send button's mint.")
        XCTAssertEqual(TranscriptPalette.mint, voice.accent.nsColor, "The mirror's mint and the button's are one colour.")
        XCTAssertEqual(TabTint.allCases.first, .mint)
        XCTAssertEqual(EnvironmentValues().tabTint, .mint, "Outside a tab the colour is mint.")
    }

    func testMintLeavesTheIslandsSurfacesAlone() {
        XCTAssertFalse(TabTint.mint.castsSurfaces)
        let surface = TabTint.mint.composerSurface
        XCTAssertEqual(surface.dim, Color(white: 0.055))
        XCTAssertEqual(surface.fill, Color.white.opacity(0.07))
        XCTAssertEqual(surface.stroke, Color.white.opacity(0.07))
        XCTAssertEqual(TabTint.mint.rim, Color.clear, "No rim: the default island is the one the island always was.")
        for tint in TabTint.allCases where tint != .mint { XCTAssertTrue(tint.castsSurfaces, tint.rawValue) }
    }

    func testTheDefaultPaletteIsMintAndBothThemesFollowTheTabsVoice() {
        let dark = TranscriptPalette(dark: true), mint = TranscriptPalette(dark: true, voice: .mint)
        XCTAssertEqual(dark.userText, mint.userText); XCTAssertEqual(dark.userMarker, mint.userMarker)
        XCTAssertEqual(dark.bubbleFill, TranscriptPalette.mint.withAlphaComponent(0.15))
        XCTAssertEqual(dark.bubbleStroke, TranscriptPalette.mint.withAlphaComponent(0.24))
        // Intentional change: the light island's mirror follows the tab's colour too (in its light shades), where it used to keep mint.
        let rose = TabTint.rose.voice(.light)
        let light = TranscriptPalette(dark: false, voice: rose), plain = TranscriptPalette(dark: false, voice: TabTint.mint.voice(.light))
        XCTAssertEqual(light.userText, rose.text.nsColor); XCTAssertEqual(light.userMarker, rose.marker.nsColor)
        XCTAssertEqual(light.accent, rose.accent.nsColor)
        XCTAssertNotEqual(light.userText, plain.userText, "Another colour, another voice.")
        XCTAssertEqual(light.bubbleFill, rose.accent.nsColor.withAlphaComponent(0.15))
    }

    // MARK: The accents

    /// Intentional change: every accent is at the same luminance, so the white arrow reads the same (3.1 : 1) on all of them, where it read from 2.4 to 3.2 : 1.
    func testEveryAccentTakesTheWhiteArrowEquallyWellAndAtLeastAtThreeToOne() {
        for tint in TabTint.allCases {
            let ratio = contrastWithWhite(tint.voice.accent)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(tint.rawValue): the arrow is a graphic, which needs 3 : 1 (\(ratio)).")
            XCTAssertLessThanOrEqual(ratio, 3.25, "\(tint.rawValue): a button far darker than the others stops looking like a sibling (\(ratio)).")
        }
    }

    func testEveryAccentIsItsPastelOneStepDeeper() {
        for tint in TabTint.allCases {
            let pastel = tint.shades.pastel, accent = tint.shades.accent
            XCTAssertLessThan(luminance(accent), luminance(pastel), "\(tint.rawValue): deeper than the pastel.")
            if tint == .gray {
                XCTAssertLessThan(saturation(accent), 0.12, "Gray stays gray.")
            } else {
                XCTAssertLessThan(hueGap(hue(accent), hue(pastel)), 15, "\(tint.rawValue): the same colour as its pastel, not another.")
                XCTAssertGreaterThan(saturation(accent), saturation(pastel), "\(tint.rawValue): a little more saturated.")
            }
        }
    }

    /// Twelve colours have to be told apart, in each of the shades a tab wears: no two are closer than the closest pair of the seven there were (peach and sand).
    func testNoTwoColoursAreCloserThanTheClosestPairOfTheOriginalSeven() {
        func distance(_ a: TabRGB, _ b: TabRGB) -> Double {
            ((a.red - b.red) * (a.red - b.red) + (a.green - b.green) * (a.green - b.green) + (a.blue - b.blue) * (a.blue - b.blue)).squareRoot()
        }
        let all = TabTint.allCases
        for (name, shade) in [("pastel", { (t: TabTint) in t.shades.pastel }), ("accent", { $0.shades.accent }), ("tone", { $0.shades.tone })] {
            for (i, a) in all.enumerated() {
                for b in all[(i + 1)...] {
                    XCTAssertGreaterThanOrEqual(distance(shade(a), shade(b)), 0.10, "\(a.rawValue) and \(b.rawValue) in their \(name)")
                }
            }
        }
    }

    /// There are twelve colours, the first seven are the ones that were there (their saved names cannot change) and the editor lays out all of them.
    func testThereAreTwelveColoursAndTheOriginalSevenKeepTheirNames() throws {
        XCTAssertEqual(TabTint.allCases.map(\.rawValue), ["mint", "blue", "lavender", "rose", "peach", "sand", "gray", "coral", "sky", "violet", "lime", "teal"])
        XCTAssertEqual(Set(TabTint.pickerOrder), Set(TabTint.allCases))
        XCTAssertEqual(TabTint.pickerOrder.count, TabTint.allCases.count, "Each shows once.")
        let names = TabTint.allCases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.suffix(5), ["Coral", "Cielo", "Violeta", "Lima", "Turquesa"])
        // A saved colour of a build that had more is mint, and no other entry is lost with it.
        let saved = try JSONDecoder().decode([String: TabAppearance].self, from: Data(#"{"a": {"title": "API", "tint": "teal"}, "b": {"title": "web", "tint": "not a colour"}}"#.utf8))
        XCTAssertEqual(saved["a"]?.tint, .teal)
        XCTAssertEqual(saved["b"]?.tint, .mint); XCTAssertEqual(saved["b"]?.title, "web")
    }

    // MARK: The light island

    /// The dot and the icon of a tab have to be seen on the paper: their tone keeps 3.5 : 1 or more on it, in every colour.
    func testEveryTonesDotReadsOnThePaper() {
        let paper = TabRGB(0.953, 0.941, 0.914)
        func contrast(_ a: TabRGB, _ b: TabRGB) -> Double { let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b))); return (hi + 0.05) / (lo + 0.05) }
        for tint in TabTint.allCases {
            XCTAssertGreaterThanOrEqual(contrast(tint.shades.tone, paper), 3.5, "\(tint.rawValue)'s dot on the paper")
        }
    }

    /// The user's message is read on a block of the colour at 15 %: its marker keeps 4.5 : 1 and its text 7 : 1 on it, on the paper.
    func testTheUsersWordsAreReadableOnTheirBlockOnThePaper() {
        let paper = TabRGB(0.953, 0.941, 0.914)
        func contrast(_ a: TabRGB, _ b: TabRGB) -> Double { let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b))); return (hi + 0.05) / (lo + 0.05) }
        for tint in TabTint.allCases {
            let voice = tint.voice(.light)
            let block = paper.mixed(with: voice.accent, by: 0.15)
            XCTAssertGreaterThanOrEqual(contrast(voice.marker, block), 4.5, "\(tint.rawValue)'s marker")
            XCTAssertGreaterThanOrEqual(contrast(voice.text, block), 7, "\(tint.rawValue)'s text")
            XCTAssertEqual(voice.accent, tint.voice(.dark).accent, "The solid is the same in both themes.")
            XCTAssertLessThan(luminance(voice.text), luminance(voice.marker), "On the paper the text is the deepest.")
        }
    }

    func testTheTabsColourIsDynamicAndEachThemeGetsItsOwnShade() {
        for tint in TabTint.allCases {
            let dark = NSAppearance(named: .darkAqua)!, light = NSAppearance(named: .aqua)!
            var inDark = NSColor.clear, inLight = NSColor.clear
            dark.performAsCurrentDrawingAppearance { inDark = NSColor(cgColor: tint.nsColor.cgColor)! }
            light.performAsCurrentDrawingAppearance { inLight = NSColor(cgColor: tint.nsColor.cgColor)! }
            assertClose(rgb(inDark), tint.shades.pastel, "\(tint.rawValue) on the dark island")
            assertClose(rgb(inLight), tint.shades.tone, "\(tint.rawValue) on the light one")
        }
    }

    func testTheComposerIsAWhiteCardOnThePaperWithAFaintCastOfTheColour() {
        let neutral = TabTint.mint.composerSurface(.light)
        XCTAssertEqual(rgb(neutral.fill), TabRGB(1, 1, 1))
        for tint in TabTint.allCases where tint != .mint {
            let surface = tint.composerSurface(.light), fill = rgb(surface.fill)
            XCTAssertGreaterThan(luminance(fill), 0.82, "\(tint.rawValue): still a light card")
            XCTAssertLessThan(luminance(fill), luminance(TabRGB(1, 1, 1)), "\(tint.rawValue): with a cast of its colour")
        }
    }

    func testTheMessageBlocksShadesStandToTheAccentAsMintsDo() {
        for tint in TabTint.allCases {
            let voice = tint.voice
            XCTAssertGreaterThan(luminance(voice.marker), luminance(voice.accent), "\(tint.rawValue): the marker is lighter than the accent.")
            XCTAssertGreaterThan(luminance(voice.text), luminance(voice.marker), "\(tint.rawValue): the text is lighter still.")
            XCTAssertGreaterThan(luminance(voice.text), 0.75, "\(tint.rawValue): the user's text stays near white on the island's black.")
            if tint != .gray { XCTAssertLessThan(hueGap(hue(voice.marker), hue(voice.accent)), 12, "\(tint.rawValue): one colour in three shades.") }
        }
    }

    // MARK: The surfaces

    func testOtherColoursLeanTheComposerTowardThemWithoutLightingIt() {
        let neutral = 0.055
        for tint in TabTint.allCases where tint != .mint && tint != .gray {
            let dim = rgb(tint.composerSurface.dim), accent = tint.voice.accent
            let brightness = (dim.red + dim.green + dim.blue) / 3
            XCTAssertEqual(brightness, neutral, accuracy: 0.012, "\(tint.rawValue): the composer does not get lighter or darker, only warmer or cooler.")
            // The channel the accent is strongest in is the one the surface leans to; the weakest is the one it leans away from.
            let strongest = [accent.red, accent.green, accent.blue].firstIndex(of: max(accent.red, accent.green, accent.blue))!
            let weakest = [accent.red, accent.green, accent.blue].firstIndex(of: min(accent.red, accent.green, accent.blue))!
            let channels = [dim.red, dim.green, dim.blue]
            XCTAssertGreaterThan(channels[strongest], channels[weakest], "\(tint.rawValue): leans toward its colour.")
            XCTAssertLessThan(channels[strongest] - channels[weakest], 0.06, "\(tint.rawValue): and only a little.")
        }
    }

    func testTheRimIsAHairlineOfTheColourForEveryColourButMint() {
        for tint in TabTint.allCases where tint != .mint {
            let rim = NSColor(tint.rim).usingColorSpace(.sRGB)!
            XCTAssertGreaterThan(rim.alphaComponent, 0.15, tint.rawValue)
            XCTAssertLessThan(rim.alphaComponent, 0.5, "\(tint.rawValue): a hairline, not an outline.")
            XCTAssertEqual(Double(rim.redComponent), tint.voice.accent.red, accuracy: 0.01, tint.rawValue)
        }
    }

    // MARK: The conversation

    private let font = DisplaySettings.chatFont(size: 11)

    private func styled(_ text: String, voice: TabVoice? = nil) -> NSTextStorage {
        let paragraph = NSMutableParagraphStyle()
        let storage = NSTextStorage(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        if let voice { TranscriptStyler.restyle(storage, from: 0, dark: true, font: font, voice: voice) }
        else { TranscriptStyler.restyle(storage, from: 0, dark: true, font: font) }
        return storage
    }

    private func bubble(in storage: NSTextStorage) -> TranscriptBubble? { storage.attribute(.transcriptBubble, at: 2, effectiveRange: nil) as? TranscriptBubble }

    func testTheUsersMessageBlockWearsTheTabsColourAndClaudesLinesDoNot() throws {
        let text = "> pásame el estado\n\n⏺ Todo en verde.\n"
        let rose = TabTint.rose.voice
        let storage = styled(text, voice: rose)
        let block = try XCTUnwrap(bubble(in: storage))
        XCTAssertEqual(block.fill, rose.accent.nsColor.withAlphaComponent(0.15))
        XCTAssertEqual(block.stroke, rose.accent.nsColor.withAlphaComponent(0.24))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, rose.marker.nsColor, "The > marker.")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, rose.text.nsColor, "The message's text.")
        let reply = (storage.string as NSString).range(of: "⏺").location
        XCTAssertEqual(storage.attribute(.foregroundColor, at: reply, effectiveRange: nil) as? NSColor, TranscriptPalette.terracotta, "Claude's marker is terracotta in every tab.")
        XCTAssertNil(storage.attribute(.transcriptBubble, at: reply, effectiveRange: nil), "Claude's replies have no block.")
    }

    func testWithoutAVoiceTheBlockIsTheMintItAlwaysWas() throws {
        let plain = styled("> hola\n"), mint = styled("> hola\n", voice: .mint)
        XCTAssertEqual(try XCTUnwrap(bubble(in: plain)), try XCTUnwrap(bubble(in: mint)))
        XCTAssertEqual(try XCTUnwrap(bubble(in: plain)).fill, TranscriptPalette.mint.withAlphaComponent(0.15))
    }

    func testTheTaskLabelWearsTheBlocksColour() throws {
        let storage = NSTextStorage(string: "> Revisa el notch\n", attributes: [.font: font])
        TranscriptStyler.restyle(storage, from: 0, dark: true, font: font, taskLabel: "Tarea", voice: TabTint.blue.voice)
        let block = try XCTUnwrap(bubble(in: storage))
        XCTAssertEqual(block.label, "Tarea")
        XCTAssertEqual(block.accent, TabTint.blue.voice.accent.nsColor)
    }

    func testChangingATabsColourRestylesTheMirrorOnceAndKeepsItsText() throws {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 160))
        scroll.setTheme(dark: true, transcript: true)
        scroll.setText("> hola\n\n⏺ ¿Qué tal?\n")
        func fill() -> NSColor? { (scroll.textView.textStorage?.attribute(.transcriptBubble, at: 2, effectiveRange: nil) as? TranscriptBubble)?.fill }
        XCTAssertEqual(fill(), TranscriptPalette.mint.withAlphaComponent(0.15))
        scroll.setVoice(TabTint.lavender.voice)
        XCTAssertEqual(fill(), TabTint.lavender.voice.accent.nsColor.withAlphaComponent(0.15))
        XCTAssertEqual(scroll.textView.string, "> hola\n\n⏺ ¿Qué tal?\n", "Only the look changes.")
        // Text that arrives later is dressed in the new colour from the start.
        scroll.setText("> hola\n\n⏺ ¿Qué tal?\n\n> otra cosa\n")
        let later = (scroll.textView.string as NSString).range(of: "otra").location
        let block = scroll.textView.textStorage?.attribute(.transcriptBubble, at: later, effectiveRange: nil) as? TranscriptBubble
        XCTAssertEqual(block?.fill, TabTint.lavender.voice.accent.nsColor.withAlphaComponent(0.15))
        // The same colour again changes nothing.
        scroll.setVoice(TabTint.lavender.voice)
        XCTAssertEqual(scroll.voice, TabTint.lavender.voice)
    }

    func testAMirrorShowingPlainOutputIgnoresTheVoice() {
        let scroll = LiveTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 160))
        scroll.setTheme(dark: true, transcript: false)
        scroll.setText("> hola\n")
        scroll.setVoice(TabTint.rose.voice)
        XCTAssertNil(scroll.textView.textStorage?.attribute(.transcriptBubble, at: 0, effectiveRange: nil), "A shell's output has no message blocks to dress.")
    }

    // MARK: The editor

    /// The popover is sized from its content. A line that asks for more room than the column gives would stretch it (a caption
    /// with `fixedSize` made it 540 pt tall), so the editor keeps the size it was built for: the grid of icons (eight to a row) and 16 pt of
    /// padding either side wide, and a handful of rows tall. Intentional changes: it holds twelve colours and sixteen icons now, in grids, so it is
    /// wider and taller than the 274 × 215 it was, and a row for the tab's alert sound under them.
    func testTheEditorStaysACompactPopover() {
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "nook", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        let size = NSHostingView(rootView: TabEditor(model: model, session: session)).fittingSize
        XCTAssertEqual(size.width, TabIconPicker.width + 32, accuracy: 4, "\(size)")
        XCTAssertLessThan(size.height, 380, "Name, colours, icons, the sound switch and the lines under them. \(size)")
        XCTAssertGreaterThan(size.height, 230, "\(size)")
    }

    // MARK: A new colour fades in

    private final class TintHolder: ObservableObject { @Published var tint = TabTint.mint }

    /// A view inside a tab: it paints with the tab's colour and notes the animation its updates carry.
    private struct TintProbe: View {
        @Environment(\.tabTint) private var tint
        var note: (Animation?) -> Void
        var body: some View { Rectangle().fill(tint.accent).transaction { note($0.animation) } }
    }

    private struct TintHost: View {
        @ObservedObject var holder: TintHolder
        var note: (Animation?) -> Void
        var body: some View { TintProbe(note: note).frame(width: 20, height: 20).tabTint(holder.tint) }
    }

    /// Changing a tab's colour reaches what is inside it as an animated update, so it fades instead of switching (the animation is
    /// attached once, at `tabTint`, and every colour below follows it). The first, unanimated render is not what is being asked.
    func testANewColourReachesTheViewsInsideAsAnAnimatedUpdate() {
        let holder = TintHolder()
        var seen: [Animation?] = []
        let host = NSHostingView(rootView: TintHost(holder: holder) { seen.append($0) })
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        seen.removeAll()
        holder.tint = .rose
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(seen.isEmpty, "The probe was updated by the new colour.")
        XCTAssertTrue(seen.contains { $0 != nil }, "...and the update carried an animation.")
    }

    // MARK: The environment

    func testViewsOutsideATabKeepMint() {
        XCTAssertEqual(EnvironmentValues().tabTint, .mint)
        var values = EnvironmentValues()
        values.tabTint = .peach
        XCTAssertEqual(values.tabTint, .peach)
    }

    /// What `AppModel.customize` hands the tab: the colour and, when one is given, the icon; without one the tab keeps its own.
    func testCustomizingATabKeepsItsIconUnlessOneIsChosen() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "tabAppearances")
        addTeardownBlock { defaults.set(saved, forKey: "tabAppearances") }
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys-\(UUID().uuidString.prefix(6))", customTitle: "nook", processes: ["login", "-zsh", "claude"],
                                      busy: false, selected: true, text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.customize(session, title: "api", tint: .blue, icon: .half)
        XCTAssertEqual(session.icon, .half); XCTAssertEqual(session.tint, .blue); XCTAssertEqual(session.customTitle, "api")
        model.customize(session, title: "api", tint: .rose)
        XCTAssertEqual(session.icon, .half, "A colour changed on its own leaves the icon.")
        XCTAssertEqual(session.tint, .rose)
    }
}
