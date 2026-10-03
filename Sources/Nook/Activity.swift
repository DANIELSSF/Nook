import AppKit
import SwiftUI

enum TaskState { case idle, working, finished, attention }

enum TabTint: String, Codable, CaseIterable {
    case mint, blue, lavender, rose, peach, sand, gray
    var name: String {
        switch self { case .mint: "Menta"; case .blue: "Azul"; case .lavender: "Lavanda"; case .rose: "Rosa"; case .peach: "Durazno"; case .sand: "Arena"; case .gray: "Gris" }
    }
    var color: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor {
        switch self {
        case .mint: .init(red: 0.58, green: 0.81, blue: 0.71, alpha: 1)
        case .blue: .init(red: 0.57, green: 0.72, blue: 0.89, alpha: 1)
        case .lavender: .init(red: 0.74, green: 0.64, blue: 0.87, alpha: 1)
        case .rose: .init(red: 0.87, green: 0.65, blue: 0.74, alpha: 1)
        case .peach: .init(red: 0.9, green: 0.72, blue: 0.59, alpha: 1)
        case .sand: .init(red: 0.85, green: 0.8, blue: 0.58, alpha: 1)
        case .gray: .init(red: 0.72, green: 0.74, blue: 0.77, alpha: 1)
        }
    }
}

struct TabAppearance: Codable { let title: String; let tint: TabTint }

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
