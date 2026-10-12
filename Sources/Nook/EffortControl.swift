import SwiftUI

// The controls that go with Claude in the composer's bottom row: how hard it thinks, and how much of its limits it has used.
//
//   EffortChip     the level Claude last reported, as a symbol alone (`EffortGlyph`, in `ChipGlyphs.swift`); a click opens the picker
//   EffortPicker   the five levels side by side, in the row's own place (no popover: the island treats a window of its own as
//                  a click outside, and a card over the conversation would be taller than the room there is above the composer)
//   UsageButton    opens Claude's /usage, which Nook shows as its usage card
//
// Nothing here talks to Claude: the pane asks the model to send `/effort <level>` or `/usage`, as a message. The level on the chip is
// what Claude's screen last said, so it only changes once Claude has done it (or said it could not).
//
//   EffortSwap     the row's left side, where the levels take the status line's and the chip's place: one frame for both
//   EffortMotion   how they come and go (unfolding out of the chip's side, folding back into it) and when they just swap

extension ClaudeEffort {
    /// What the chip and the picker call it.
    var title: String {
        switch self {
        case .low: "Bajo"
        case .medium: "Medio"
        case .high: "Alto"
        case .xhigh: "Muy alto"
        case .max: "Máximo"
        }
    }

    /// One line for the tooltip: what the level is for.
    var detail: String {
        switch self {
        case .low: "Rápido y ligero"
        case .medium: "Equilibrado"
        case .high: "Razona con detalle"
        case .xhigh: "Razona todavía más"
        case .max: "El máximo razonamiento"
        }
    }

    /// Which of the five this level is, from 1 (the lowest) to 5: how much of the chip's ring it fills (`fill`).
    var steps: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// What the keyboard does while the levels are out: the highlight walks them, and stops at either end.
enum EffortPickerKey {
    /// Where the highlight goes for `key`, or nil for a key that does not walk (↵ chooses and Esc closes; the pane handles them).
    static func moved(from level: ClaudeEffort, by key: ComposerKey) -> ClaudeEffort? {
        let levels = ClaudeEffort.allCases
        let at = levels.firstIndex(of: level) ?? 0
        switch key {
        case .down, .right, .tab: return levels[min(at + 1, levels.count - 1)]
        case .up: return levels[max(at - 1, 0)]
        case .submit, .escape, .newline, .pasteImage, .letter: return nil
        }
    }

    /// Whether a draft is Claude's own /effort with no level, which Nook answers with its picker instead of sending it.
    static func asksForTheLevels(_ draft: String) -> Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/effort" }
}

/// How the levels come and go. They unfold out of the chip's side of the row: the item beside the chip comes first and the rest follow in
/// order, each fading in as it eases a few points into place; closing is the same backwards, a little quicker. The status line and the chips
/// are out of the way before the levels reach them. It is calm and short. With Reduce Motion, or the app's animations off, the row just
/// swaps. There is no timer in it: the one `withAnimation` that `EffortSwap` opens (with `animation`) drives the lot, and what moves is only
/// opacity and offset, so nothing is laid out again.
enum EffortMotion {
    static let openingDuration = 0.30
    static let closingDuration = 0.18

    /// What `EffortSwap` moves the row with, or nil to swap it at once: Reduce Motion, or the app's animations switched off, asks for no motion.
    /// Linear on purpose: each item eases into its own place (`arrival`), and the wait between one item and the next has to stay what it is.
    static func animation(opening: Bool, reduceMotion: Bool, animationsOn: Bool) -> Animation? {
        guard !reduceMotion, animationsOn else { return nil }
        return .linear(duration: opening ? openingDuration : closingDuration)
    }

    /// How much of the whole each item waits for the one before it (the item beside the chip is the first).
    static let stagger = 0.07
    /// How far to its right an item starts, in points; it eases into its place as it fades in.
    static let travel: CGFloat = 9
    /// The first share of the whole in which the status line and the chips go out (and the last in which they come back): the lowest levels
    /// and the word, which rise over the status line, begin after it (`stagger` × 4), and the chip is mostly gone when the first level reaches it.
    static let closedWindow = 0.25

    private static func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }

    /// How far along item `item` of `count` is (0…1) when the whole is `progress` along. The first leads and the others follow in order,
    /// every one taking the same stretch of the whole and easing at both ends; at 0 none has begun and at 1 all are in place.
    static func arrival(of item: Int, of count: Int, at progress: Double) -> Double {
        let lag = stagger * Double(item)
        let span = 1 - stagger * Double(max(count - 1, 0))
        return ease(min(max((progress - lag) / span, 0), 1))
    }

    /// How much of the status line and the chips shows when the levels are `progress` of the way out: all of it at 0, none from `closedWindow` on.
    static func closedOpacity(at progress: Double) -> Double { 1 - ease(min(max(progress / closedWindow, 0), 1)) }
}

extension EnvironmentValues {
    /// How far the levels have unfolded (0…1), for the items of the row to rise in turn. It is 1 at rest and wherever nothing animates it.
    var effortUnfold: Double {
        get { self[EffortUnfoldKey.self] }
        set { self[EffortUnfoldKey.self] = newValue }
    }
}

private struct EffortUnfoldKey: EnvironmentKey { static let defaultValue = 1.0 }

/// What the coming and going of the levels hands down: `unfold` (0 shut … 1 open), in the environment, for the items (`EffortRow`) to decide what
/// it means for each. It is Animatable, so while `EffortSwap` animates the number the items see every step of it.
struct EffortUnfold: ViewModifier, Animatable {
    var unfold: Double
    var animatableData: Double {
        get { unfold }
        set { unfold = newValue }
    }

    func body(content: Content) -> some View { content.environment(\.effortUnfold, unfold) }
}

/// The status line and the chips while the levels come and go (`EffortMotion.closedOpacity`). They take no clicks until they are all there.
struct EffortClosedFade: ViewModifier, Animatable {
    var unfold: Double
    var animatableData: Double {
        get { unfold }
        set { unfold = newValue }
    }

    func body(content: Content) -> some View {
        let shown = EffortMotion.closedOpacity(at: unfold)
        return content.opacity(shown).allowsHitTesting(shown >= 1)
    }
}

/// An item of the levels' row rising out of the chip's side: it fades in as it settles into its place, in its turn (`EffortMotion.arrival`).
/// Until it is there it takes no clicks, so a second click on the chip cannot land on a level that is still on its way.
private struct Rising: ViewModifier {
    var item: Int
    var count: Int
    @Environment(\.effortUnfold) private var unfold

    func body(content: Content) -> some View {
        let arrived = EffortMotion.arrival(of: item, of: count, at: unfold)
        content.opacity(arrived).offset(x: (1 - arrived) * EffortMotion.travel).allowsHitTesting(arrived >= 1)
    }
}

/// The left side of the controls row: what it says while the levels are shut (`closed`: the status line with Claude's chips) or, once the chip is
/// pressed, the levels in their place, unfolding out of that spot. One frame, as wide as the row leaves it, holds either and both while they swap,
/// so the keys, the mic and send beside it never move: only what stands inside rises and fades.
///
/// The move is a number (`unfold`, 0 shut … 1 open) that this view animates itself, for the items to read at every step; a SwiftUI transition
/// would hand them only its two ends. What the row is made of follows where the move is going (`open`), not `showsLevels` itself, so the
/// status line is not taken out a frame before the move begins; and both sides stay in it only while it lasts (`moving`), so a shut row has
/// no levels in it (nor tooltips, nor accessibility elements, nor keyboard focus for them) and an open one has no chip.
struct EffortSwap<Closed: View, Levels: View>: View {
    var showsLevels: Bool
    /// Reduce Motion, and the app's animations preference: either one makes the move a swap (`EffortMotion.animation`).
    var reduceMotion: Bool
    var animationsOn: Bool
    private let closed: Closed
    private let levels: Levels
    @State private var open: Bool
    @State private var unfold: Double
    @State private var moving = false
    /// Counts the moves, so the end of one that another has overtaken does not end the other.
    @State private var moves = 0

    init(showsLevels: Bool, reduceMotion: Bool, animationsOn: Bool, @ViewBuilder closed: () -> Closed, @ViewBuilder levels: () -> Levels) {
        self.showsLevels = showsLevels
        self.reduceMotion = reduceMotion
        self.animationsOn = animationsOn
        self.closed = closed()
        self.levels = levels()
        _open = State(initialValue: showsLevels)
        _unfold = State(initialValue: showsLevels ? 1 : 0)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Mounting and unmounting happen at once, never as a fade of their own (`.identity`): the fading is `unfold`'s.
            if !open || moving { closed.modifier(EffortClosedFade(unfold: unfold)).transition(.identity) }
            if open || moving { levels.modifier(EffortUnfold(unfold: unfold)).transition(.identity) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: showsLevels) { _, opening in go(opening) }
    }

    private func go(_ opening: Bool) {
        guard opening != open else { return }
        open = opening
        moves += 1
        let move = moves
        let target = opening ? 1.0 : 0.0
        guard let animation = EffortMotion.animation(opening: opening, reduceMotion: reduceMotion, animationsOn: animationsOn) else {
            moving = false
            unfold = target
            return
        }
        moving = true
        withAnimation(animation) { unfold = target } completion: { if moves == move { moving = false } }
    }
}

/// The chip in the composer's row: Claude's effort as a symbol alone, in a round chip like the others'. `effort` is nil until Claude has said it. The
/// level's name and what it means are in its tooltip and in what VoiceOver says, and the pointer and the mouse lift its wash as they do on the
/// model's chip.
struct EffortChip: View {
    var effort: ClaudeEffort?
    /// The level just asked for and not confirmed yet: shown as if it were Claude's, until the screen says otherwise.
    var asking = false
    var action: () -> Void
    @State private var hovered: Bool
    @State private var pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(effort: ClaudeEffort?, asking: Bool = false, look: ModeChipLook = .resting, action: @escaping () -> Void) {
        self.effort = effort
        self.asking = asking
        self.action = action
        _hovered = State(initialValue: look == .hovered)
        _pressed = State(initialValue: look == .pressed)
    }

    /// The tooltip: the level, what it is for, and that a click changes it.
    static func help(effort: ClaudeEffort?, asking: Bool = false) -> String {
        guard let effort else { return "Esfuerzo de Claude: aún sin leer.\nPulsa para elegir un nivel." }
        return "Esfuerzo de Claude: \(effort.title). \(effort.detail).\n" + (asking ? "Esperando a que Claude lo confirme…" : "Pulsa para cambiarlo.")
    }

    /// The tip over the chip: the level, what it is for, and that a click changes it.
    static func tip(effort: ClaudeEffort?, asking: Bool = false) -> NookTip {
        guard let effort else { return NookTip("Esfuerzo", value: "sin leer", detail: "Pulsa para elegir un nivel") }
        return NookTip("Esfuerzo", value: effort.title, detail: asking ? "Esperando a que Claude lo confirme…" : effort.detail + " · pulsa para cambiarlo")
    }

    /// What VoiceOver says of the level: its name and what it means.
    static func spoken(effort: ClaudeEffort?) -> String { effort.map { "\($0.title): \($0.detail.lowercased())" } ?? "sin leer" }

    var body: some View {
        Button(action: action) {
            EffortGlyph(effort: effort, color: Color.primary.opacity(asking ? 0.6 : (effort == nil ? 0.7 : 1)))
                .chipSurface(fill: ChipWash.fill(hovered: hovered, pressed: pressed, lit: asking))
        }
        .buttonStyle(PressReporter(pressed: $pressed))
        .onHover { hovered = $0 }
        .nookTip(Self.tip(effort: effort, asking: asking), id: "effort")
        .accessibilityLabel("Esfuerzo de Claude").accessibilityValue(Self.spoken(effort: effort)).accessibilityHint("Abre los niveles de esfuerzo")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
        // A level that changes grows or shrinks the ring's wedge.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: effort)
    }
}

/// The five levels, side by side, where the status line and the chips stand. `current` is Claude's (or the one just asked for);
/// `highlighted` is where the keyboard is.
struct EffortPicker: View {
    var current: ClaudeEffort?
    var highlighted: ClaudeEffort
    var onPick: (ClaudeEffort) -> Void
    var onClose: () -> Void

    var body: some View {
        // The word that says what the levels are goes first when the island is narrow: the five names still say it.
        ViewThatFits(in: .horizontal) {
            EffortRow(named: true, current: current, highlighted: highlighted, onPick: onPick, onClose: onClose)
            EffortRow(named: false, current: current, highlighted: highlighted, onPick: onPick, onClose: onClose)
        }
    }
}

/// The levels in a row, with the word that says what they are or without it. Its own view so the tests can measure both.
struct EffortRow: View {
    var named: Bool
    var current: ClaudeEffort?
    var highlighted: ClaudeEffort
    var onPick: (ClaudeEffort) -> Void
    var onClose: () -> Void
    @State private var hovered: ClaudeEffort?
    @Environment(\.tabTint) private var tint

    /// What rises in the row, counted from the chip's side (the right): the ✕ is the first, then the levels from the highest down, then the word.
    private var risingCount: Int { ClaudeEffort.allCases.count + 1 + (named ? 1 : 0) }
    private func rising(_ item: Int) -> Rising { Rising(item: item, count: risingCount) }

    var body: some View {
        HStack(spacing: 3) {
            if named {
                Text("Esfuerzo").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.nookSecondary).padding(.trailing, 4)
                    .nookTip(NookTip("Esfuerzo de Claude", detail: "Cada modelo admite unos niveles; Claude avisa si el elegido no está disponible."), id: "levels-label")
                    .modifier(rising(ClaudeEffort.allCases.count + 1))
            }
            ForEach(Array(ClaudeEffort.allCases.enumerated()), id: \.element) { index, level in
                segment(level).modifier(rising(ClaudeEffort.allCases.count - index))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.primary.opacity(0.62))
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }.nookPress(.spin).nookTip(NookTip("Cerrar", detail: "Esc también cierra los niveles"), id: "levels-close").accessibilityLabel("Cerrar los niveles de esfuerzo")
                .modifier(rising(0))
        }
    }

    private func segment(_ level: ClaudeEffort) -> some View {
        let isCurrent = level == current
        let shape = Capsule()
        return Button { onPick(level) } label: {
            Text(level.title).font(.system(size: 10.5, weight: isCurrent ? .semibold : .medium)).lineLimit(1).fixedSize()
                .foregroundStyle(Color.primary.opacity(isCurrent ? 1 : 0.78))
                .padding(.horizontal, 8.5).frame(height: 24)
                .background(shape.fill(isCurrent ? tint.accent.opacity(0.30) : Color.primary.opacity(hovered == level || highlighted == level ? 0.14 : 0.07)))
                .overlay(shape.strokeBorder(isCurrent ? tint.accent.opacity(0.65) : (highlighted == level ? Color.primary.opacity(0.28) : Color.clear), lineWidth: 0.8))
                .contentShape(shape)
        }.nookPress(.none, depth: PressDepth.card)
            .onHover { inside in hovered = inside ? level : (hovered == level ? nil : hovered) }
            .nookTip(NookTip(level.title, value: isCurrent ? "actual" : nil, detail: level.detail + " · envía /effort \(level.rawValue)"), id: "level-\(level.rawValue)")
            .accessibilityLabel(level.title).accessibilityValue(isCurrent ? "actual" : "")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Opens Claude's usage panel without typing /usage.
struct UsageButton: View {
    /// What the tip says when Claude's status line has given Nook the limits (`UsageGlance`): where the session and the week stand, without opening the panel. Nil: the button's own.
    var glance: NookTip?
    var action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    /// The symbol, kept here so a test can hold it to an image the system has.
    static let symbol = "gauge.with.dots.needle.50percent"

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol).font(.system(size: 11.5)).foregroundStyle(Color.primary.opacity(0.78))
                .chipSurface(fill: ChipWash.fill(hovered: hovered, pressed: pressed, lit: false))
        }.buttonStyle(PressReporter(pressed: $pressed))
            .onHover { hovered = $0 }
            .nookTip(glance ?? NookTip("Uso y límites", detail: "Lo que llevas gastado y cuándo se reinicia (/usage)"), id: "usage")
            .accessibilityLabel("Ver el uso de Claude")
            .accessibilityHint("Muestra lo que llevas gastado de cada límite y cuándo se reinicia")
    }
}
