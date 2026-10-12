import SwiftUI

// The chips of the composer's bottom row (Claude's permission mode, its model, its effort and its usage) say themselves in a symbol alone, each
// in a round chip of the same size, so they read as one set. What a symbol means is in its tooltip and in what VoiceOver says; the words never
// take room in the row.
//
//   EffortGlyph        how hard Claude thinks: a ring that fills up, a fifth of it for the lowest level and all of it for the highest
//   ClaudeModelFamily  which family a model is of (Opus, Sonnet, Haiku, Fable, or one Nook has not met), and the symbol it wears
//   ModelGlyph         that symbol, drawn
//   ChipWash           how the neutral chips' wash lifts under the pointer and the mouse
//   chipSurface        the round chip itself

enum ChipMetrics {
    /// A chip is a circle this wide and this tall.
    static let side: CGFloat = 24
}

// MARK: - Effort

/// A wedge of a disc, from twelve o'clock and clockwise: `fraction` of it (1 is the whole disc). Animatable, so a level that changes grows or
/// shrinks the wedge instead of swapping it.
struct EffortWedge: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(max(fraction, 0), 1)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

extension ClaudeEffort {
    /// How much of the ring the level fills (0…1): a fifth for the lowest of the five, the whole for the highest.
    var fill: Double { Double(steps) / Double(Self.allCases.count) }
}

/// How hard Claude thinks, as a ring with a wedge inside it that grows with the level. Each of the five is its own shape (a sliver, two fifths, three,
/// four, and a full disc), which no neighbour shares, and none looks like the signal bars it replaces. The highest is the only one that is a disc, so it
/// is not taken for the one below it. With no level read the ring is dashed and empty.
struct EffortGlyph: View {
    var effort: ClaudeEffort?
    var color: Color = Color.primary
    var size: CGFloat = 13.5

    var body: some View {
        ZStack {
            if let effort {
                Circle().strokeBorder(color, lineWidth: 1.15)
                EffortWedge(fraction: effort.fill).fill(color).padding(size * 0.18)
            } else {
                Circle().strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 1.15, dash: [1.7, 1.9]))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Model

/// The family a model belongs to, read from the name Claude gives it ("Sonnet 5.5", "Opus 4.6 (1M context)", an id like "claude-haiku-4-5"). The
/// families Nook knows get a symbol each, from nature and from the small to the grand as the models go (a leaf for Haiku, a flower for Sonnet, mountains
/// for Opus; a book for Fable); a family it has not met (new ones come out between releases of the app) gets the generic mark of Claude's, so the chip
/// is never blank or wrong.
///
/// The symbols are all of one layer: the system draws a symbol made of several (a tree, a gauge) in white whatever colour it is given when it stands
/// inside the island's rounded clip, which would make that family's chip brighter than the others'.
enum ClaudeModelFamily: Equatable, CaseIterable {
    case opus, sonnet, haiku, fable
    /// Any other name.
    case other

    /// nil when Claude has not named a model.
    init?(model name: String?) {
        guard let short = ClaudeModelName.short(name) else { return nil }
        let words = short.lowercased().split { !$0.isLetter }.map(String.init)
        self = words.lazy.compactMap { Self.known[$0] }.first ?? .other
    }

    private static let known: [String: ClaudeModelFamily] = ["opus": .opus, "sonnet": .sonnet, "haiku": .haiku, "fable": .fable]

    /// What the family is called, as the chip's tooltip says it.
    var title: String {
        switch self {
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .fable: "Fable"
        case .other: "otro modelo"
        }
    }

    /// The symbol the family wears: what the system has of the ones meant for it, else the generic mark.
    var symbol: String { Self.available[self] ?? Self.generic }

    /// What the chip shows while Claude has not named a model.
    static let unread = "cpu"
    static let generic = "sparkle"

    private static let preferred: [ClaudeModelFamily: String] = [.opus: "mountain.2.fill", .sonnet: "camera.macro", .haiku: "leaf.fill", .fable: "book.closed.fill", .other: generic]

    /// The symbols the system has, found once.
    private static let available: [ClaudeModelFamily: String] = preferred.filter { NSImage(systemSymbolName: $0.value, accessibilityDescription: nil) != nil }
}

extension ClaudeModelChoice {
    /// The family whose symbol the row wears: its own ("Opus 5.5", the alias "Sonnet"); for "Default (recommended)" the one it stands for, which its
    /// description names first ("Sonnet 5.5 · Efficient for routine tasks"). Any other row Nook cannot place gets the generic mark.
    var family: ClaudeModelFamily {
        if argument == "default" || label.lowercased().hasPrefix("default") {
            return ClaudeModelFamily(model: detail?.components(separatedBy: " · ").first) ?? .other
        }
        return ClaudeModelFamily(model: label) ?? .other
    }
}

/// The model's symbol: its family's, or the chip's own mark while the model is not known yet.
struct ModelGlyph: View {
    var family: ClaudeModelFamily?
    var color: Color = Color.primary.opacity(0.9)

    var body: some View {
        Image(systemName: family?.symbol ?? ClaudeModelFamily.unread)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

// MARK: - The chip

/// How light the wash of a neutral chip (the model's, the effort's, the usage's) is: the pointer over it, the mouse down and a state that is on
/// (a list open, an answer awaited) raise it. A chip that cannot be pressed stays as it is.
enum ChipWash {
    static let resting = 0.09
    static let hovered = 0.13
    static let lit = 0.16
    static let pressed = 0.2

    static func fill(hovered: Bool, pressed: Bool, lit: Bool, blocked: Bool = false) -> Double {
        guard !blocked else { return resting }
        if pressed { return Self.pressed }
        if lit { return Self.lit }
        return hovered ? Self.hovered : resting
    }
}

extension View {
    /// The round chip of the row: the glyph in the middle of a circle that is `ChipMetrics.side` across, in a wash that is also what takes the click.
    func chipSurface(fill: Double, ring: Bool = false) -> some View {
        frame(width: ChipMetrics.side, height: ChipMetrics.side)
            .background(Color.primary.opacity(fill), in: Circle())
            .overlay { if ring { Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.8) } }
            .contentShape(Circle())
    }
}
