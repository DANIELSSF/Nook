import AppKit
import SwiftUI

enum TaskState { case idle, working, finished, attention }

/// The colours a tab can have, and what each one is called. Raw values are saved, so a case is never renamed or removed: new colours are appended.
/// What each one is made of, in both themes, is in `TabStyle.swift` (`TabTint.shades`).
enum TabTint: String, Codable, CaseIterable {
    case mint, blue, lavender, rose, peach, sand, gray
    /// Added with the light theme.
    case coral, sky, violet, lime, teal

    var name: String {
        switch self {
        case .mint: "Menta"; case .blue: "Azul"; case .lavender: "Lavanda"; case .rose: "Rosa"; case .peach: "Durazno"; case .sand: "Arena"; case .gray: "Gris"
        case .coral: "Coral"; case .sky: "Cielo"; case .violet: "Violeta"; case .lime: "Lima"; case .teal: "Turquesa"
        }
    }

    /// The order the editor lays them out in: round the colour wheel, so neighbours are neighbours, and the gray last.
    static let pickerOrder: [TabTint] = [.mint, .teal, .sky, .blue, .violet, .lavender, .rose, .coral, .peach, .sand, .lime, .gray]

    /// The tab's own colour: its dot, its icon, its pill. A vivid pastel on the dark island and a deeper tone on the light one, so it is the same
    /// colour on both and readable on each; the view's colour scheme decides which shows.
    var color: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor { .nook(dark: shades.pastel.nsColor, light: shades.tone.nsColor) }
}

/// The mark a tab wears beside its name, chosen with its name and colour. Raw values are saved, so a case is never renamed or removed: new icons are appended.
/// How each one looks and moves is in `TabIcons.swift`.
enum TabIcon: String, Codable, CaseIterable {
    /// The plain dot every tab had before icons could be chosen. It never moves.
    case dot
    /// A circle, half filled, that turns.
    case half
    /// A small moon circling a core.
    case orbit
    /// Four bars that rise and fall.
    case bars
    /// A four-pointed star that twinkles.
    case spark
    /// A diamond that turns on its axis.
    case gem
    /// A heart that beats.
    case heart
    /// A lightning bolt whose charge runs down it.
    case bolt
    /// A leaf that sways.
    case leaf
    /// A crescent moon whose shadow drifts, with a star that twinkles.
    case moon
    /// Two waves that roll.
    case wave
    /// A cat's paw whose toes tap one after another.
    case paw
    /// A flame that flickers.
    case flame
    /// A five-pointed star that turns slowly.
    case star
    /// `</>` whose brackets breathe.
    case code
    /// A sun whose rays turn.
    case sun
}

struct TabAppearance: Codable, Equatable {
    let title: String
    let tint: TabTint
    let icon: TabIcon

    init(title: String, tint: TabTint, icon: TabIcon = .dot) {
        self.title = title; self.tint = tint; self.icon = icon
    }

    /// One unreadable entry would lose every tab's name: one saved before icons existed, or with a colour or an icon this build
    /// no longer has, keeps its name and falls back to the default for the rest.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        tint = (try? container.decode(TabTint.self, forKey: .tint)) ?? .mint
        icon = (try? container.decodeIfPresent(TabIcon.self, forKey: .icon)).flatMap { $0 } ?? .dot
    }
}

/// BEL outside OSC is an alert; BEL terminating an OSC title/color is not.
struct TerminalSignalParser {
    private enum State { case text, escape, osc, oscEscape }
    private var state: State = .text
    private var bytes: [UInt8] = []
    mutating func feed(_ data: ArraySlice<UInt8>) -> [String] {
        var alerts: [String] = []
        for byte in data {
            switch state {
            case .text:
                if byte == 7 { alerts.append("La terminal solicita tu atención.") }
                else if byte == 27 { state = .escape }
            case .escape:
                if byte == 93 { state = .osc; bytes = [] }
                else { state = .text }
            case .osc:
                if byte == 7 { if let message = finishOSC() { alerts.append(message) }; state = .text }
                else if byte == 27 { state = .oscEscape }
                else if bytes.count < 16384 { bytes.append(byte) }
                else { bytes = []; state = .text }
            case .oscEscape:
                if byte == 92 { if let message = finishOSC() { alerts.append(message) }; state = .text }
                else { bytes.append(27); bytes.append(byte); state = .osc }
            }
        }
        return alerts
    }
    private mutating func finishOSC() -> String? {
        let text = String(decoding: bytes, as: UTF8.self); bytes = []
        if text.hasPrefix("9;"), !text.hasPrefix("9;4;") { return String(text.dropFirst(2).prefix(180)) }
        if text.hasPrefix("777;notify;") { return String(text.dropFirst(11).replacingOccurrences(of: ";", with: " · ").prefix(180)) }
        return nil
    }
}
