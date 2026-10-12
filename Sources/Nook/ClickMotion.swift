import SwiftUI
import AppKit

// What a button does when it is clicked: its label gives under the finger, and its icon answers with a small movement of its own.
//
// Every button of the island wears `NookPressStyle` (through `nookPress(_:)`, which is what `.buttonStyle(.plain)` was, and looks the same at rest). Two things move:
//
//   the press      the label sinks a little while the button is held (`squash`) and springs back, with a touch of overshoot, when it is let go. It is the
//                  button saying "I felt that".
//   the answer     one movement of the icon, chosen for what the icon is (`ClickMotion`): the pin tilts, a chevron nudges the way it points, the send arrow
//                  flies up a bit, the mic swells, a ✕ or a + turns a quarter, a bell wiggles, anything else hops. It plays once per click, from the moment the
//                  button is released.
//
// The movements are pure curves (`ClickMotion.pose(at:)`: numbers in, numbers out) played by one `Animatable` modifier whose only state is a counter that goes up by
// one per click, so they are checked without a window, they run on the render server's animation clock only while they play, and they cost nothing at rest. They
// are one-shots: no timer, no repeat. With Reduce Motion, or with the pets' animations off (`\.nookMotion`), the buttons do not move at all: a pressed label is
// dimmed instead, so a click is still felt.

// MARK: - The movements

/// How a button's icon moves when it is clicked.
enum ClickMotion: Equatable, CaseIterable {
    /// Only the press: the label sinks and springs back.
    case none
    /// The icon swells and settles (the default).
    case pop
    /// The icon is squeezed wide and then tall, like a soft button pressed (the chips and the keys).
    case squeeze
    /// A hop the way the icon points: up for a chevron or the send arrow, down for the one that points down, up and right for «open elsewhere», sideways for an
    /// arrow that points sideways («Empezar →», a key's arrow).
    case nudgeUp, nudgeDown, nudgeUpRight, nudgeLeft, nudgeRight
    /// A tilt one way and back (the pin).
    case tilt
    /// A quarter turn (a ✕ or a +, which look the same turned): it ends where it began, as far as the eye can tell.
    case spin
    /// A quick shake (a bell).
    case wiggle
    /// A swell and back (the mic, the play buttons).
    case pulse

    /// How long it plays, in seconds.
    var duration: Double {
        switch self {
        case .none: 0
        case .pop: 0.42
        case .squeeze: 0.4
        case .nudgeUp, .nudgeDown, .nudgeUpRight, .nudgeLeft, .nudgeRight: 0.44
        case .tilt: 0.52
        case .spin: 0.38
        case .wiggle: 0.56
        case .pulse: 0.42
        }
    }

    /// The motion for an icon, by its SF Symbol: what the pointing and the meaning of the symbol call for.
    static func forSymbol(_ name: String) -> ClickMotion {
        switch name {
        case "pin", "pin.fill", "pin.slash": return .tilt
        case "chevron.up", "arrow.up", "arrow.up.circle", "arrow.up.circle.fill": return .nudgeUp
        case "chevron.down", "arrow.down": return .nudgeDown
        case "arrow.up.right", "arrow.up.right.square", "arrow.up.forward.square": return .nudgeUpRight
        case "chevron.right", "arrow.right", "arrow.forward", "arrow.right.to.line": return .nudgeRight
        case "chevron.left", "arrow.left", "arrow.backward", "arrow.uturn.backward": return .nudgeLeft
        case "xmark", "xmark.circle", "xmark.circle.fill", "plus", "plus.circle", "plus.circle.fill": return .spin
        case "mic", "mic.fill", "stop.fill", "speaker.wave.2", "speaker.wave.3", "play.fill": return .pulse
        case "bell", "bell.fill", "bell.badge", "bell.badge.fill", "bell.slash", "bell.slash.fill": return .wiggle
        case "keyboard", "ellipsis": return .squeeze
        default: return .pop
        }
    }

    /// What the motion does to the icon `u` of the way through it (0 ... 1), at `strength` times its usual size. Rest at both ends (the quarter turn ends a quarter
    /// turned, which is rest for a symbol that looks the same turned).
    func pose(at u: Double, strength: Double = 1) -> ClickPose {
        let u = min(1, max(0, u)), s = strength
        var pose = ClickPose()
        switch self {
        case .none:
            break
        case .pop:
            let r = Self.ring(u, cycles: 0.85, decay: 2.5)
            pose.scaleX = 1 + 0.34 * s * r; pose.scaleY = pose.scaleX
        case .squeeze:
            let r = Self.ring(u, cycles: 1.0, decay: 3.0)
            pose.scaleX = 1 + 0.24 * s * r; pose.scaleY = 1 - 0.2 * s * r
        case .nudgeUp:
            let r = Self.ring(u, cycles: 0.8, decay: 2.3)
            pose.dy = -7 * s * r
        case .nudgeDown:
            let r = Self.ring(u, cycles: 0.8, decay: 2.3)
            pose.dy = 7 * s * r
        case .nudgeUpRight:
            let r = Self.ring(u, cycles: 0.8, decay: 2.3)
            pose.dx = 4.6 * s * r; pose.dy = -4.6 * s * r
        case .nudgeLeft:
            pose.dx = -6 * s * Self.ring(u, cycles: 0.8, decay: 2.3)
        case .nudgeRight:
            pose.dx = 6 * s * Self.ring(u, cycles: 0.8, decay: 2.3)
        case .tilt:
            pose.degrees = -26 * s * Self.ring(u, cycles: 1.2, decay: 2.8)
        case .spin:
            // Out and a little past the quarter, back to it: the overshoot is what makes it a flick and not a slide.
            let ease = 1 - pow(1 - u, 3) + 0.1 * sin(.pi * u) * u
            pose.degrees = 90 * ease
        case .wiggle:
            pose.degrees = 17 * s * Self.ring(u, cycles: 2.4, decay: 3.6)
        case .pulse:
            let swell = sin(.pi * u)
            pose.scaleX = 1 + 0.36 * s * swell * swell; pose.scaleY = pose.scaleX
        }
        return pose
    }

    /// A swing that starts at zero, rises first, rings down and is gone by the end: `cycles` full swings over the whole motion, damped at `decay`.
    static func ring(_ u: Double, cycles: Double, decay: Double) -> Double {
        let gone = u <= 0.78 ? 0 : (u >= 1 ? 1 : (u - 0.78) / 0.22)
        let fade = 1 - gone * gone * (3 - 2 * gone)
        return sin(2 * .pi * cycles * u) * exp(-decay * u) * fade
    }
}

/// What a motion does to an icon at one moment: where it is moved, how it is scaled and how far it is turned.
struct ClickPose: Equatable {
    var dx = 0.0, dy = 0.0
    var scaleX = 1.0, scaleY = 1.0
    var degrees = 0.0
}

// MARK: - Whether to move

private struct NookMotionKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// Whether the island's buttons and cards move when used: the app's own switch for animations (`AppModel.animations`), which each window's root hands down. Reduce
    /// Motion is asked of the system, where each view reads it.
    var nookMotion: Bool {
        get { self[NookMotionKey.self] }
        set { self[NookMotionKey.self] = newValue }
    }
}

/// Whether a view may move: the app's animations are on and the system has not asked for less motion.
struct NookMotionGate: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nookMotion) private var on

    var allows: Bool { on && !reduceMotion }
    /// Whether a fade may play: the app's animations are on. Reduce Motion asks for less movement, not for no change at all, so it keeps the fades that stand
    /// in for a movement it takes away.
    var fades: Bool { on }
}

extension View {
    /// What every window's root says once: whether the app's animations are on (`\.nookMotion`).
    func nookMotion(_ animations: Bool) -> some View { environment(\.nookMotion, animations) }
}

// MARK: - Playing a motion

/// The modifier that plays a motion: it turns a counter of clicks into one run of the curve. `phase` goes up by one for each click, animated; the curve reads its
/// fraction, so it begins at rest and is at rest again when the phase is whole.
private struct ClickAnimatable: ViewModifier, Animatable {
    var motion: ClickMotion
    var strength: Double
    var phase: Double
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func body(content: Content) -> some View {
        ClickMotionProbe.sample?(phase)
        let pose = motion.pose(at: phase - phase.rounded(.down), strength: strength)
        return content
            .scaleEffect(x: pose.scaleX, y: pose.scaleY)
            .rotationEffect(.degrees(pose.degrees))
            .offset(x: pose.dx, y: pose.dy)
    }
}

/// Tests look at the phase of every frame the modifier draws.
enum ClickMotionProbe {
    nonisolated(unsafe) static var sample: ((Double) -> Void)?
}

struct ClickMotionEffect: ViewModifier {
    var motion: ClickMotion
    var strength = 1.0
    /// Goes up by one for each click.
    var trigger: Int
    private let gate = NookMotionGate()
    @State private var phase = 0.0

    func body(content: Content) -> some View {
        content
            .modifier(ClickAnimatable(motion: motion, strength: strength, phase: phase))
            .onChange(of: trigger) { _, _ in
                guard motion != .none, gate.allows else { return }
                withAnimation(.linear(duration: motion.duration)) { phase += 1 }
            }
    }
}

extension View {
    /// Plays `motion` on this view each time `trigger` changes.
    func clickMotion(_ motion: ClickMotion, strength: Double = 1, trigger: Int) -> some View {
        modifier(ClickMotionEffect(motion: motion, strength: strength, trigger: trigger))
    }

    /// Plays `motion` on this view each time `condition` becomes true (a tab chosen, a chip lit): the thing that was chosen answers, not the one that was let go.
    func clickMotion(_ motion: ClickMotion, strength: Double = 1, whenBecomes condition: Bool) -> some View {
        modifier(ClickMotionOnCondition(motion: motion, strength: strength, condition: condition))
    }
}

private struct ClickMotionOnCondition: ViewModifier {
    var motion: ClickMotion
    var strength: Double
    var condition: Bool
    @State private var count = 0

    func body(content: Content) -> some View {
        content
            .clickMotion(motion, strength: strength, trigger: count)
            .onChange(of: condition) { _, now in if now { count += 1 } }
    }
}

// MARK: - Clicks that reach the icon inside a button

private struct NookClicksKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    /// How many times the button the view is in (`NookPressStyle`) has been clicked: what an icon inside it plays its own motion by (`nookIconMotion`).
    var nookClicks: Int {
        get { self[NookClicksKey.self] }
        set { self[NookClicksKey.self] = newValue }
    }
}

private struct NookIconMotion: ViewModifier {
    var motion: ClickMotion
    var strength: Double
    @Environment(\.nookClicks) private var clicks

    func body(content: Content) -> some View { content.clickMotion(motion, strength: strength, trigger: clicks) }
}

extension View {
    /// An icon inside a button that moves when the button is clicked, and the rest of the button (the disc behind it, the words beside it) does not: the send arrow flies up inside its
    /// circle, the mic swells inside its own. The button wears `NookPressStyle` (`nookPress`), which counts the clicks.
    func nookIconMotion(_ motion: ClickMotion = .pop, strength: Double = 1) -> some View {
        modifier(NookIconMotion(motion: motion, strength: strength))
    }
}

// MARK: - The button style

/// How far a label sinks while it is pressed, by what kind of control it is.
enum PressDepth {
    /// A small round or square control (an icon, a chip, a key).
    static let icon: CGFloat = 0.86
    /// A larger control: a card, a wide button.
    static let card: CGFloat = 0.975
    /// A row in a list: it hardly moves.
    static let row: CGFloat = 0.992
    /// No sinking: the icon's own movement is all.
    static let flat: CGFloat = 1
    /// How far a pressed label is dimmed where nothing may move (Reduce Motion, the animations off): the press without the motion.
    static let stillDim = 0.6
}

/// What `.buttonStyle(.plain)` was, plus the press and the answer (see the top of this file). At rest it is the label alone, dimmed to half when the button is
/// disabled, which is what the system's plain style does. Where nothing may move (Reduce Motion, the animations off) a pressed label is dimmed instead of sunk.
struct NookPressStyle: ButtonStyle {
    var motion: ClickMotion = .pop
    var depth: CGFloat = PressDepth.icon
    var strength = 1.0

    func makeBody(configuration: Configuration) -> some View {
        NookPressBody(configuration: configuration, motion: motion, depth: depth, strength: strength)
    }
}

private struct NookPressBody: View {
    let configuration: ButtonStyleConfiguration
    var motion: ClickMotion
    var depth: CGFloat
    var strength: Double
    @Environment(\.isEnabled) private var enabled
    private let gate = NookMotionGate()
    @State private var clicks = 0

    var body: some View {
        let sunk = configuration.isPressed && gate.allows
        configuration.label
            // The icons inside the label that move by themselves (`nookIconMotion`) are told how many times it has been clicked.
            .environment(\.nookClicks, clicks)
            .scaleEffect(sunk ? depth : 1)
            // In quickly, out with a spring that overshoots a little: the label bounces back past rest.
            .animation(sunk ? .easeOut(duration: 0.07) : .spring(response: 0.3, dampingFraction: 0.52), value: sunk)
            .clickMotion(motion, strength: strength, trigger: clicks)
            .opacity(enabled ? (configuration.isPressed && !gate.allows ? PressDepth.stillDim : 1) : 0.5)
            .onChange(of: configuration.isPressed) { _, pressed in if !pressed { clicks += 1 } }
    }
}

extension View {
    /// `.buttonStyle(.plain)` with the press and the icon's answer (`NookPressStyle`).
    func nookPress(_ motion: ClickMotion = .pop, depth: CGFloat = PressDepth.icon, strength: Double = 1) -> some View {
        buttonStyle(NookPressStyle(motion: motion, depth: depth, strength: strength))
    }

    /// The same for a button whose icon is `symbol`: the motion that icon calls for.
    func nookPress(symbol: String, depth: CGFloat = PressDepth.icon, strength: Double = 1) -> some View {
        nookPress(ClickMotion.forSymbol(symbol), depth: depth, strength: strength)
    }
}

// MARK: - Menus

extension View {
    /// A `Menu` whose label is drawn as it is written, pressed like the island's buttons. The system's borderless menu (`.borderlessButton`) draws its label itself,
    /// from the label's image and title alone: it drops the label's colours, its background and every effect on it, the motion of `NookMenuGlyph` included (seen in the
    /// renders: a pill of a label came out as a bare title with its chevron in front). A button-style menu with Nook's press style draws the label as SwiftUI does.
    /// The menu's chevron goes too: a label that wants one draws it (`NookMenuChevron`).
    func nookMenu(depth: CGFloat = PressDepth.icon) -> some View {
        menuStyle(.button).buttonStyle(NookPressStyle(motion: .none, depth: depth)).menuIndicator(.hidden).fixedSize()
    }
}

/// The small chevron beside a menu's icon that says a menu opens there, as the system's borderless menu drew it.
struct NookMenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).accessibilityHidden(true)
    }
}

/// The label of a `Menu`, which has no press of its own to hear: the icon answers when the menu opens under the pointer that is on it. AppKit says when a menu begins
/// to be tracked (`NSMenu.didBeginTrackingNotification`); the label counts it as its own click if the pointer is on it, or has just left it as the menu took the pointer.
/// The menu wears `nookMenu()`, or nothing it does shows. The motion plays on the glyph; what sits beside it (a chevron, a title) holds still.
struct NookMenuGlyph<Glyph: View, Beside: View>: View {
    var motion: ClickMotion = .pop
    /// A wash under the label while the pointer is on it, as the island's icon buttons light: for a bare icon; a label with a pill of its own lights that.
    var highlight = false
    var label: Glyph
    var beside: Beside
    @State private var hovering = false
    @State private var leftAt: Date?
    @State private var opens = 0

    init(motion: ClickMotion = .pop, highlight: Bool = false, @ViewBuilder label: () -> Glyph, @ViewBuilder beside: () -> Beside) {
        self.motion = motion
        self.highlight = highlight
        self.label = label()
        self.beside = beside()
    }

    var body: some View {
        HStack(spacing: 3) {
            label.clickMotion(motion, trigger: opens)
            beside
        }
            // A part of the label may answer on its own (`nookIconMotion`), the rest of it holding still.
            .environment(\.nookClicks, opens)
            .padding(.horizontal, highlight ? 6 : 0)
            .background(Color.nookWash(highlight && hovering ? 0.1 : 0, light: highlight && hovering ? 0.08 : 0), in: Capsule())
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.14), value: hovering)
            .onHover { inside in
                hovering = inside
                leftAt = inside ? nil : Date()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                if hovering || (leftAt.map { Date().timeIntervalSince($0) < 0.4 } ?? false) { opens += 1 }
            }
    }
}

extension NookMenuGlyph where Beside == EmptyView {
    init(motion: ClickMotion = .pop, highlight: Bool = false, @ViewBuilder label: () -> Glyph) {
        self.init(motion: motion, highlight: highlight, label: label, beside: { EmptyView() })
    }
}
