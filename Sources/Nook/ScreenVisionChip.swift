import SwiftUI

// Screen vision's toggle in the composer's bottom row: a round chip, in the family of Claude's (mode, model, effort, usage), that makes each message
// carry a screenshot of the screen. The words are in its tooltip and in what VoiceOver says; the row only gets a symbol.
//
//   ScreenVisionChipCopy  when the row offers the chip, and the words it says (plain values, so the tests hold them to what the row promises)
//   ScreenVisionChip      the chip: an open eye in the tab's colour when each message goes with the screen, a slashed one in the island's neutral grey when
//                         it does not. While a message waits for its picture it shows the wait (once it is long enough to notice), and when the picture
//                         is taken for a message it flashes once, like a shutter
//
// The setting itself (`ScreenVision.enabled`) is in the settings card's "Pantalla" tab; the chip is only offered while it is on.

// MARK: - What it says

enum ScreenVisionChipCopy {
    static let label = "Adjuntar mi pantalla a cada mensaje"

    /// Whether the row offers the chip: screen vision is on and an agent that opens images (Claude, Codex) runs in the tab. Like Claude's chips it steps
    /// aside while the keys' strip is out, which needs the room.
    static func offers(_ vision: ScreenVision, agent: TerminalAgent?, keysOpen: Bool) -> Bool {
        !keysOpen && vision.offersToggle(for: agent)
    }

    /// The tooltip: what the chip is doing, what a click does, and what the picture is of.
    static func help(attaching: Bool, capturing: Bool, agent: TerminalAgent?) -> String {
        if capturing { return "Capturando tu pantalla para el mensaje…" }
        let who = agent?.title ?? "el agente"
        if attaching {
            return "Pantalla adjunta: cada mensaje para \(who) lleva una captura de la pantalla donde está el puntero, sin las ventanas de Nook.\nPulsa para dejar de adjuntarla."
        }
        return "Pantalla sin adjuntar. Pulsa para que cada mensaje para \(who) lleve una captura de la pantalla donde está el puntero, sin las ventanas de Nook."
    }

    /// The chip's tip over the row: what it is, whether the screen goes with each message, and what a click does. Shorter than `help`, which says it all.
    static func tip(attaching: Bool, capturing: Bool, agent: TerminalAgent?) -> NookTip {
        if capturing { return NookTip("Capturando tu pantalla…") }
        if attaching { return NookTip("Mi pantalla", value: "adjunta", detail: "Cada mensaje lleva una captura · pulsa para quitarla") }
        return NookTip("Mi pantalla", value: "sin adjuntar", detail: "Pulsa para adjuntar una captura a cada mensaje")
    }

    /// What VoiceOver says of the state.
    static func value(attaching: Bool, capturing: Bool) -> String {
        capturing ? "capturando" : attaching ? "activado" : "desactivado"
    }

    static func hint(attaching: Bool) -> String { attaching ? "Deja de adjuntar tu pantalla a los mensajes" : "Adjunta tu pantalla a cada mensaje que envíes" }
}

// MARK: - The chip

/// How the chip looks at the start; render tests and previews use it to show a state that is gone in a moment.
enum ScreenVisionChipLook { case resting, hovered, pressed, busy, flash }

struct ScreenVisionChip: View {
    @ObservedObject var vision: ScreenVision
    var agent: TerminalAgent?
    /// The app's animation preference (`AppModel.animations`): with it off, like Reduce Motion, the chip changes without moving.
    var animated = true
    var busyAfter = ScreenVisionChip.busyAfter
    /// A previewed look keeps its busy state although no message is waiting.
    private let pinnedBusy: Bool
    @State private var hovered: Bool
    @State private var pressed: Bool
    /// The wait for the picture has gone on long enough to show.
    @State private var busy: Bool
    /// The shutter: how bright the chip is (1 as the picture is taken, then gone) and how far the ring has spread (0 to 1).
    @State private var flash: Double
    @State private var ripple: Double
    @State private var fired = 0
    @Environment(\.tabTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = ChipMetrics.side
    static let glyphSize: CGFloat = 11
    /// A capture takes a fraction of a second, so a wait shorter than this is not shown: a ring that flashed for an instant on every message would only
    /// flicker.
    static let busyAfter: TimeInterval = 0.25
    static let flashSeconds = 0.6
    /// With no motion the flash is a held brightness, this long.
    static let heldSeconds = 0.8

    init(vision: ScreenVision, agent: TerminalAgent?, animated: Bool = true, busyAfter: TimeInterval = ScreenVisionChip.busyAfter, look: ScreenVisionChipLook = .resting) {
        self.vision = vision
        self.agent = agent
        self.animated = animated
        self.busyAfter = busyAfter
        pinnedBusy = look == .busy
        _hovered = State(initialValue: look == .hovered)
        _pressed = State(initialValue: look == .pressed)
        _busy = State(initialValue: look == .busy)
        _flash = State(initialValue: look == .flash ? 0.7 : 0)
        _ripple = State(initialValue: look == .flash ? 0.4 : 0)
    }

    private var motion: Bool { animated && !reduceMotion }

    var body: some View {
        let attaching = vision.attachToMessages, capturing = vision.capturing || busy
        Button { vision.attachToMessages.toggle() } label: { chip(on: attaching) }
            .buttonStyle(PressReporter(pressed: $pressed))
            .onHover { hovered = $0 }
            .nookTip(ScreenVisionChipCopy.tip(attaching: attaching, capturing: capturing, agent: agent), id: "screen")
            .accessibilityLabel(ScreenVisionChipCopy.label)
            .accessibilityValue(ScreenVisionChipCopy.value(attaching: attaching, capturing: capturing))
            .accessibilityHint(ScreenVisionChipCopy.hint(attaching: attaching))
            .accessibilityAddTraits(.isToggle)
            // The wait is shown only when it lasts; the picture's arrival ends it.
            .task(id: vision.capturing) {
                guard vision.capturing else { busy = pinnedBusy; return }
                try? await Task.sleep(for: .seconds(busyAfter))
                if !Task.isCancelled { busy = true }
            }
            // A picture taken for a message from this composer: the shutter.
            .onChange(of: vision.lastCapture) { _, capture in if capture?.origin == .composer { fired += 1 } }
            .task(id: fired) {
                guard fired > 0 else { return }
                if motion {
                    ripple = 0; flash = 1
                    withAnimation(.easeOut(duration: Self.flashSeconds)) { ripple = 1; flash = 0 }
                } else {
                    flash = 1
                    try? await Task.sleep(for: .seconds(Self.heldSeconds))
                    if !Task.isCancelled { flash = 0 }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: attaching)
    }

    /// How much of the tab's colour the wash takes while the chip is on: the pointer over it raises it a little, the mouse down more.
    static func onWash(hovered: Bool, pressed: Bool) -> Double { pressed ? 0.38 : hovered ? 0.3 : 0.22 }

    private func chip(on: Bool) -> some View {
        let shape = Circle()
        let accent = tint.accent, marker = tint.marker
        return ZStack {
            Image(systemName: on ? "eye" : "eye.slash").font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(on ? marker : Color.primary.opacity(0.78))
                .opacity(busy ? 0.5 : 1)
            if busy { BusyArc(color: marker, spinning: motion) }
        }
        .frame(width: Self.side, height: Self.side)
        .background(on ? accent.opacity(Self.onWash(hovered: hovered, pressed: pressed)) : Color.primary.opacity(ChipWash.fill(hovered: hovered, pressed: pressed, lit: busy)), in: shape)
        .overlay(shape.strokeBorder(accent.opacity(on ? 0.7 : 0), lineWidth: 0.8))
        .overlay { if flash > 0 { shape.fill(Color.nookWash(0.3 * flash)) } }
        .overlay { if ripple > 0, ripple < 1 { shape.strokeBorder(marker.opacity(0.55 * (1 - ripple)), lineWidth: 1.2).scaleEffect(1 + 0.7 * ripple) } }
        .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
        .contentShape(shape)
    }
}

/// An arc that goes round the chip while a picture is awaited. With no motion it stands at the top, which still says "waiting".
private struct BusyArc: View {
    var color: Color
    var spinning: Bool
    /// Nobody can see the island (`\.islandSeen`): what moves here pauses.
    @Environment(\.islandSeen) private var seen

    var body: some View {
        // Nobody can see the island (`\.islandSeen`): the arc holds until someone can.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning || !seen)) { context in
            let turn = spinning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360 : 0
            Circle().inset(by: 1.2).trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .rotationEffect(.degrees(turn - 90))
        }
        .accessibilityHidden(true)
    }
}
