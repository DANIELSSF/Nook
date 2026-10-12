import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The symbols of the composer's chips: the family a model is of and the symbol it wears (a family Nook has not met still gets one), the five levels of
/// effort as five rings that cannot be mistaken for one another, how the wash lifts, and the four chips as the equal round buttons they are, with
/// the words they left out in their tooltips and for VoiceOver.
@MainActor
final class ChipGlyphTests: XCTestCase {
    // MARK: The model

    func testTheFamilyIsReadFromTheNameClaudeGivesTheModel() {
        XCTAssertEqual(ClaudeModelFamily(model: "Sonnet 5.5"), .sonnet)
        XCTAssertEqual(ClaudeModelFamily(model: "Opus 4.6 (1M context)"), .opus)
        XCTAssertEqual(ClaudeModelFamily(model: "Haiku 4.5"), .haiku)
        XCTAssertEqual(ClaudeModelFamily(model: "Fable"), .fable)
        XCTAssertEqual(ClaudeModelFamily(model: "claude-opus-4-1-20250805"), .opus, "An id is read as the agents' lists read it.")
        XCTAssertEqual(ClaudeModelFamily(model: "  OPUS 4.1 "), .opus, "Case and spaces do not matter.")
        XCTAssertEqual(ClaudeModelFamily(model: "Claude Sonnet 4.5"), .sonnet, "The family is the word that names it, wherever it stands.")
        XCTAssertEqual(ClaudeModelFamily(model: "4.6 Opus"), .opus)
        XCTAssertEqual(ClaudeModelFamily(model: "Sonnetron 2"), .other, "Only the word itself is a family.")
    }

    func testAFamilyNookHasNotMetStillGetsAMarkAndNoNameGetsTheChipsOwn() {
        XCTAssertEqual(ClaudeModelFamily(model: "Mythos 2"), .other)
        XCTAssertEqual(ClaudeModelFamily(model: "gpt-9"), .other)
        XCTAssertNil(ClaudeModelFamily(model: nil))
        XCTAssertNil(ClaudeModelFamily(model: "   "))
        XCTAssertNil(ClaudeModelFamily(model: "(1M context)"), "A name that is only brackets names nothing.")
        XCTAssertEqual(ClaudeModelFamily.other.symbol, ClaudeModelFamily.generic)
        XCTAssertNotEqual(ClaudeModelFamily.unread, ClaudeModelFamily.generic, "A model not read yet is not the mark of one that is new.")
    }

    func testEachFamilyHasASymbolOfItsOwnAndTheSystemHasThemAll() {
        let families = ClaudeModelFamily.allCases
        XCTAssertEqual(Set(families.map(\.symbol)).count, families.count, "Each can be told from the others (a system without a symbol would give two the generic one).")
        for family in families { XCTAssertNotNil(NSImage(systemSymbolName: family.symbol, accessibilityDescription: nil), "\(family): \(family.symbol)") }
        for name in [ClaudeModelFamily.unread, ClaudeModelFamily.generic] { XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name) }
    }

    /// The brightest pixel of a view drawn on black, 0…1.
    private func brightest(_ view: some View) throws -> Double {
        let host = NSHostingView(rootView: view.frame(width: 40, height: 40).background(Color.black).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var best = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { best = max(best, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent) }
            }
        }
        return best
    }

    /// The system draws a symbol made of several layers (a tree, a gauge) in white whatever colour it is given once it stands inside a rounded clip,
    /// as the island's content does: that family's chip would be brighter than the others'. Every family's symbol is of one layer.
    func testEveryFamilysSymbolTakesItsColourInsideTheIslandsClip() throws {
        let clip = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
        for family in ClaudeModelFamily.allCases.map(Optional.init) + [nil] {
            let glyph = ModelGlyph(family: family, color: Color(white: 0.5))
            let plain = try brightest(glyph), clipped = try brightest(glyph.clipShape(clip))
            XCTAssertLessThan(plain, 0.7, "\(String(describing: family)) is grey on its own.")
            XCTAssertEqual(clipped, plain, accuracy: 0.03, "\(String(describing: family)) (\(family?.symbol ?? ClaudeModelFamily.unread)) stays as grey inside the clip.")
        }
    }

    func testARowOfTheListWearsItsFamilysSymbolAndDefaultTheOneItStandsFor() {
        XCTAssertEqual(ClaudeModelChoice(label: "Opus 5.5").family, .opus)
        XCTAssertEqual(ClaudeModelChoice(label: "Fable 5.1", argument: "claude-fable-5-1").family, .fable)
        XCTAssertEqual(ClaudeModelChoice(label: "Default (recommended)", detail: "Sonnet 5.5 · Efficient for routine tasks", argument: "default").family, .sonnet,
                       "«Default» shows what it resolves to: its description opens with the model's name.")
        XCTAssertEqual(ClaudeModelChoice(label: "Default (recommended)", detail: "Opus 5.5 with 1M context · Most capable", argument: "default").family, .opus)
        XCTAssertEqual(ClaudeModelChoice(label: "Default", argument: "default", isAlias: true).family, .other, "With nothing to say what it stands for, the generic mark.")
        XCTAssertEqual(ClaudeModelChoice(label: "Sonnet", argument: "sonnet", isAlias: true).family, .sonnet)
        XCTAssertEqual(ClaudeModelChoice(label: "Mythos 2").family, .other, "A family that comes out after this version of Nook still has a mark.")
    }

    // MARK: The effort

    func testEachLevelFillsMoreOfTheRingThanTheOneBelow() {
        let fills = ClaudeEffort.allCases.map(\.fill)
        XCTAssertEqual(fills.count, 5)
        XCTAssertEqual(fills, [0.2, 0.4, 0.6, 0.8, 1.0])
        XCTAssertEqual(fills, fills.sorted())
    }

    /// The glyph as pixels: what a chip draws, at four times its size, white on black.
    private func pixels(_ effort: ClaudeEffort?) throws -> [UInt8] {
        let renderer = ImageRenderer(content: EffortGlyph(effort: effort, color: .white).frame(width: 18, height: 18).background(Color.black))
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.cgImage)
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    func testTheFiveLevelsAndNoLevelAreSixGlyphsThatLookDifferent() throws {
        let levels: [ClaudeEffort?] = ClaudeEffort.allCases + [nil]
        let drawn = try levels.map(pixels)
        XCTAssertGreaterThan(drawn[0].filter { $0 > 40 }.count, 100, "The glyph draws something.")
        for first in drawn.indices {
            for second in drawn.indices where second > first {
                let differing = zip(drawn[first], drawn[second]).filter { abs(Int($0) - Int($1)) > 60 }.count
                // A wedge a fifth of the ring bigger changes about a twentieth of the chip's pixels at the least; two glyphs that differ by less would be one.
                XCTAssertGreaterThan(Double(differing) / Double(drawn[first].count), 0.02, "\(String(describing: levels[first])) against \(String(describing: levels[second])) differ by \(differing) pixels")
            }
        }
    }

    func testTheWedgeGrowsFromTwelveOClockAndKeepsItsPlaceWhateverItsSize() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let quarter = EffortWedge(fraction: 0.25).path(in: rect).boundingRect
        XCTAssertEqual(quarter.minX, 5, accuracy: 0.01, "It starts at the top and goes round clockwise: a quarter is the upper right.")
        XCTAssertEqual(quarter.maxX, 10, accuracy: 0.01)
        XCTAssertEqual(quarter.minY, 0, accuracy: 0.01)
        XCTAssertEqual(quarter.maxY, 5, accuracy: 0.01)
        XCTAssertEqual(EffortWedge(fraction: 1).path(in: rect).boundingRect.width, 10, accuracy: 0.01)
        XCTAssertEqual(EffortWedge(fraction: 7).path(in: rect).boundingRect.width, 10, accuracy: 0.01, "More than all of it is all of it.")
    }

    // MARK: The wash

    func testTheWashLiftsInTheSameOrderOnEveryChip() {
        func fill(hovered: Bool = false, pressed: Bool = false, lit: Bool = false, blocked: Bool = false) -> Double {
            ChipWash.fill(hovered: hovered, pressed: pressed, lit: lit, blocked: blocked)
        }
        XCTAssertLessThan(fill(), fill(hovered: true))
        XCTAssertLessThan(fill(hovered: true), fill(lit: true), "A state that is on is lighter than the pointer's.")
        XCTAssertLessThan(fill(lit: true), fill(pressed: true))
        XCTAssertEqual(fill(hovered: true, pressed: true, lit: true), ChipWash.pressed, "The mouse down wins over the rest.")
        XCTAssertEqual(fill(hovered: true, pressed: true, lit: true, blocked: true), ChipWash.resting, "A chip that cannot be pressed stays as it is.")
    }

    // MARK: The chips

    func testEveryChipIsARound24PointButton() {
        let chips: [(String, AnyView)] = [
            ("mode", AnyView(ClaudeModeChip(mode: .standard) {})),
            ("mode (bypass)", AnyView(ClaudeModeChip(mode: ClaudeMode(kind: .bypassPermissions, label: "bypass permissions on", hints: [])) {})),
            ("model", AnyView(ClaudeModelChip(model: "Opus 4.6 (1M context)") {})),
            ("model (unread)", AnyView(ClaudeModelChip(model: nil) {})),
            ("effort", AnyView(EffortChip(effort: .xhigh) {})),
            ("effort (unread)", AnyView(EffortChip(effort: nil) {})),
            ("usage", AnyView(UsageButton {})),
        ]
        for (name, chip) in chips {
            let size = NSHostingView(rootView: chip).fittingSize
            XCTAssertEqual(size.width, ChipMetrics.side, accuracy: 0.5, "\(name): \(size)")
            XCTAssertEqual(size.height, ChipMetrics.side, accuracy: 0.5, "\(name): \(size)")
        }
    }

    func testTheFourChipsTakeNoMoreThanTheirSymbolsAndGapsSoTheStatusKeepsTheRoom() {
        let row = HStack(spacing: 6) {
            ClaudeModeChip(mode: .standard) {}
            ClaudeModelChip(model: "Sonnet 5.5") {}
            EffortChip(effort: .xhigh) {}
            UsageButton {}
        }
        XCTAssertEqual(NSHostingView(rootView: row).fittingSize.width, 4 * ChipMetrics.side + 3 * 6, accuracy: 0.5,
                       "114 pt, where the words took about 310: in the narrowest island (440 pt) the status line has some 145 pt, not its floor.")
    }

    // MARK: The words that left the chips

    func testTheEffortsTooltipAndVoiceOverSayTheLevelAndWhatItMeans() {
        for level in ClaudeEffort.allCases {
            let help = EffortChip.help(effort: level)
            XCTAssertTrue(help.contains(level.title), "\(level): \(help)")
            XCTAssertTrue(help.contains(level.detail), "\(level): \(help)")
            XCTAssertTrue(help.contains("Pulsa para cambiarlo"))
            XCTAssertTrue(EffortChip.spoken(effort: level).hasPrefix(level.title))
        }
        XCTAssertEqual(EffortChip.spoken(effort: .max), "Máximo: el máximo razonamiento")
        XCTAssertEqual(EffortChip.spoken(effort: nil), "sin leer")
        XCTAssertTrue(EffortChip.help(effort: nil).contains("sin leer"))
        XCTAssertTrue(EffortChip.help(effort: .high, asking: true).contains("Esperando"), "While a level is asked for, the tooltip says it waits.")
    }

    func testTheModelsTooltipNamesTheModelWithItsVersionAndSaysWhatStandsInTheWay() {
        XCTAssertTrue(ClaudeModelChip.help(model: "Sonnet 5.5").hasPrefix("Modelo de Claude: Sonnet 5.5."))
        XCTAssertTrue(ClaudeModelChip.help(model: "Opus 4.6 (1M context)").contains("Opus 4.6."))
        XCTAssertTrue(ClaudeModelChip.help(model: nil).contains("sin leer"))
        XCTAssertTrue(ClaudeModelChip.help(model: "Sonnet 5.5").contains("todos los modelos"))
        let blocked = ClaudeModelChip.help(model: "Sonnet 5.5", blocked: "Claude está trabajando; podrás cambiar el modelo cuando termine.")
        XCTAssertTrue(blocked.hasSuffix("podrás cambiar el modelo cuando termine."))
        XCTAssertFalse(blocked.contains("Pulsa para ver"), "What stands in the way replaces the invitation.")
    }

    func testTheModesTooltipNamesTheModeNowThatItsNameIsNotOnTheChip() {
        let modes: [ClaudeMode] = [.standard, ClaudeMode(kind: .auto, label: "auto mode on", hints: []), ClaudeMode(kind: .acceptEdits, label: "accept edits on", hints: []),
                                   ClaudeMode(kind: .plan, label: "plan mode on", hints: []), ClaudeMode(kind: .bypassPermissions, label: "bypass permissions on", hints: []),
                                   ClaudeMode(kind: nil, label: "yolo mode on", hints: [])]
        for mode in modes {
            let style = ClaudeModeStyle(mode)
            XCTAssertTrue(style.tooltip().lowercased().contains(style.title.lowercased()), "\(style.title): \(style.tooltip())")
        }
    }
}
