import AppKit
import SwiftUI

// The way back to the end of the conversation.
//
// The mirror follows the output while the reader is at its end; scrolled up it stays where they are, and getting back down was a scroll of
// its own. Once the reader is a few lines up, a small round bubble of glass stands over the bottom edge of the text, its arrow in the tab's
// colour (the user's), and takes them to the last message, sent or received, from where the mirror follows the output again.
//
//   JumpToLatest        when the button shows: from 5 lines up, and until the reader is back within 2 (two thresholds, so a reader
//                       resting near one of them does not make it blink)
//   MirrorGlide         the scroll there: quick at first, settling on the last lines; it reads where the end is on every frame, so text
//                       that arrives meanwhile is reached too (`LiveTerminalScrollView.jumpToEnd`)
//   JumpToLatestButton  the button: up from the bottom edge with a little spring as it comes, back down as it goes, and the arrow nods
//                       toward the end once it is in. With Reduce Motion it fades, and the text cross-fades to its end instead of gliding
//   MirrorEnd           what the end of the text is, which names the button: a conversation's last message, or a shell's last output

// MARK: - When it shows

enum JumpToLatest {
    /// Lines of the mirror's font between what shows and the end of the text from which the button comes.
    static let showLines: CGFloat = 5
    /// And within which it goes again.
    static let hideLines: CGFloat = 2

    /// Whether the button shows with the reader `linesAway` lines up from the end, `showing` being whether it shows now.
    static func shows(linesAway: CGFloat, showing: Bool) -> Bool {
        showing ? linesAway > hideLines : linesAway >= showLines
    }
}

// MARK: - The glide

/// The scroll to the end of the text: most of the way at once and the last lines slowly, so the eye lands on the latest message. Plain values on
/// a clock it is handed, so it is checked frame by frame without a screen.
struct MirrorGlide: Equatable {
    /// Where the glide starts: where the reader was, or a few screens above the end when they were further up (`plan`).
    var from: CGFloat
    var start: CFTimeInterval
    var duration: CFTimeInterval

    /// At most this many screens of text go by: a reader a thousand lines up is not dragged through all of them, the glide starts this far above the end.
    static let maxScreens: CGFloat = 3
    /// How long it takes, from a few lines to the most it travels.
    static let shortest: CFTimeInterval = 0.28
    static let longest: CFTimeInterval = 0.5

    /// The glide from `offset` to `end` (both the clip view's offsets) in a viewport `viewport` points tall, starting at `now`.
    static func plan(from offset: CGFloat, end: CGFloat, viewport: CGFloat, at now: CFTimeInterval) -> MirrorGlide {
        let reach = maxScreens * max(1, viewport)
        let travel = min(max(0, end - offset), reach)
        return MirrorGlide(from: end - travel, start: now, duration: shortest + (longest - shortest) * Double(travel / reach))
    }

    /// How far through the glide `now` is, from 0 to 1.
    func progress(at now: CFTimeInterval) -> Double {
        duration > 0 ? min(1, max(0, (now - start) / duration)) : 1
    }

    /// Where the reader is at `now`, toward the end as it is now (text that arrives during the glide moves it, and the glide follows), and whether
    /// the glide is over: then it is at the end exactly.
    func offset(at now: CFTimeInterval, end: CGFloat) -> (y: CGFloat, done: Bool) {
        let u = progress(at: now)
        guard u < 1 else { return (end, true) }
        return (from + (end - from) * CGFloat(Self.ease(u)), false)
    }

    /// A cubic ease-out: it leaves at once and settles gently.
    static func ease(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
}

// MARK: - What the end is

/// What the end of the mirror's text is: what the button is called and what it says it does.
enum MirrorEnd: Equatable {
    /// A conversation (Claude's, an agent's, Codex's): its last message, sent or received.
    case latestMessage
    /// A shell's output: its last lines.
    case latestOutput

    var title: String {
        switch self {
        case .latestMessage: "Ir al último mensaje"
        case .latestOutput: "Ir al final"
        }
    }

    var detail: String {
        switch self {
        case .latestMessage: "Baja hasta el final y sigue lo que vaya llegando"
        case .latestOutput: "Baja hasta la salida más reciente y sigue la que vaya llegando"
        }
    }

    var tip: NookTip { NookTip(title, detail: detail) }
}

// MARK: - The button

extension TabTint {
    /// The arrow, which is all the colour the button has (the bubble is glass, or the island's neutral chip): the tab's own colour, light on the
    /// dark island (its vivid pastel) and deep on the paper (the shade of the user's message's `>`, which keeps 4.4 : 1 on a light glass that
    /// has dark text blurred behind it). With Increase Contrast, where the bubble is always the solid chip, a step further each way: 8 : 1 or
    /// more on the dark chip, 9 : 1 or more on the white one.
    var jumpArrow: NSColor {
        let shades = self.shades
        return .nook(dark: shades.pastel.nsColor, light: shades.deepMarker.nsColor,
                     darkIncreased: shades.marker.nsColor, lightIncreased: shades.deepMarker.mixed(with: shades.deepText, by: 0.5).nsColor)
    }
}

/// The round button over the bottom edge of the mirror that takes the reader to the end of the text. A bubble of Liquid Glass with an arrow in
/// the tab's colour: the glass the system's floating controls are made of, clear of any tint, so it reads as a control over the text and not as
/// a coloured blot on it. Where glass is not used (Reduce Transparency, Increase Contrast, macOS before 26) it is the island's neutral chip with
/// a hairline and a light shadow. It floats over live text, so it marks itself a pointer hole (the arrow over it, the text's I-beam around it).
struct JumpToLatestButton: View {
    var end = MirrorEnd.latestMessage
    var action: () -> Void
    @Environment(\.tabTint) private var tint
    private let gate = NookMotionGate()
    private let glassGate = NookGlassGate()
    @State private var hovering = false
    /// Goes up once the button has come in: the arrow nods toward the end, as if to say where it goes.
    @State private var arrived = 0

    static let diameter: CGFloat = 26
    /// Between the button and the bottom edge of the mirror.
    static let margin: CGFloat = 8
    /// The bubble where glass is not used: the island's raised neutral surface (the welcome's chip), never a colour.
    static let bubble = NookPalette.chip

    /// Whether the bubble is glass here: macOS 26, and nothing that asks for the flat look.
    private var glass: Bool {
        if #available(macOS 26.0, *) { return glassGate.allows(overMirror: true) }
        return false
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(nsColor: tint.jumpArrow))
                .clickMotion(.nudgeDown, strength: 0.5, trigger: arrived)
                // The same nod, a full one, when it is clicked.
                .nookIconMotion(.nudgeDown)
                .frame(width: Self.diameter, height: Self.diameter)
                // Untinted glass with nothing laid over it; the glass draws its own rim and depth. The flat bubble has a hairline instead.
                .nookGlassSurface(in: Circle(), interactive: true, overMirror: true, fill: Color(nsColor: Self.bubble), stroke: Color.nookWash(0.12, light: 0.14))
                // A touch lighter under the pointer (glass also answers it by itself).
                .overlay { Circle().fill(Color.nookWash(hovering ? 0.08 : 0, light: hovering ? 0.05 : 0)) }
                // Lifted off the text a little. Glass has its own depth, and a shadow under it would show through it.
                .shadow(color: glass ? .clear : Color.nookShadow(0.35), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .nookPress(.none)
        .scaleEffect(hovering && gate.allows ? 1.08 : 1)
        .animation(.spring(response: 0.26, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
        // The arrow, not the text's I-beam, over the button.
        .pointerHole()
        .nookTip(end.tip, id: "jumpToLatest")
        .accessibilityLabel(end.title)
        .accessibilityHint(end.detail)
        .task {
            // Once it has risen into place (`JumpPresence`).
            try? await Task.sleep(for: .seconds(0.24))
            if !Task.isCancelled { arrived += 1 }
        }
    }
}

// MARK: - Coming and going

/// How the button comes and goes: it rises from just under where it stands, growing into place, and goes back down the same way. `shown` 0 is
/// gone and 1 in place; the spring it comes in with takes it a touch past 1, which is the little pop.
struct JumpPresence: ViewModifier, Animatable {
    var shown: Double
    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        JumpPresenceProbe.sample?(shown)
        return content
            .scaleEffect(0.6 + 0.4 * shown)
            .offset(y: 9 * CGFloat(1 - min(1, shown)))
            .opacity(min(1, max(0, shown * 1.5)))
    }

    /// The transition and its animation for the island's motion settings: the rise and the spring; a fade where Reduce Motion asks for less
    /// movement (it keeps fades); nothing with the app's animations off.
    static func transition(moves: Bool, fades: Bool) -> (transition: AnyTransition, animation: Animation?) {
        if moves {
            let rise = AnyTransition.modifier(active: JumpPresence(shown: 0), identity: JumpPresence(shown: 1))
            return (.asymmetric(insertion: rise.animation(.spring(response: 0.36, dampingFraction: 0.66)), removal: rise.animation(.easeIn(duration: 0.16))),
                    .spring(response: 0.36, dampingFraction: 0.66))
        }
        if fades { return (.opacity, .easeOut(duration: 0.18)) }
        return (.identity, nil)
    }
}

/// Tests look at every step of the button's coming and going.
enum JumpPresenceProbe {
    nonisolated(unsafe) static var sample: ((Double) -> Void)?
}
