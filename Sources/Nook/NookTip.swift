import SwiftUI
import AppKit

// Hover tooltips for the island's controls, drawn by Nook.
//
// The composer's chips, its keys and its mic say themselves in a symbol alone, so the pointer resting on one has to be answered with a word. AppKit's
// own tooltip (`.help`) is the key window's of an active app, and the island is neither while a hover has only just opened it: the pointer rested on a
// chip and nothing said what it was. So the island draws the tip itself, in its own glass, from what SwiftUI's hover reports.
//
//   NookTip          what a tip says: the control's name, its state after a dot, and one line under them
//   .nookTip(_:id:)  marks a control: once the pointer has rested on it a moment, it reports where it stands and what to say
//   NookTipLayer     one per pane: stands the bubble over the control that reports, keeps it between the pane's margins, and puts it away at a click or a key
//   NookTipBubble    the bubble: a small glass card, over the control and never on it
//   NookTipGeometry  where the bubble stands (plain values, so the rules are tested without a window)
//   NookTipTiming    how long the pointer rests before the tip shows, and the head start the next control's tip gets
//   NookTipMotion    how the bubble comes and goes (and when it just appears)
//
// The bubble takes no clicks and nothing under it is hidden from the pointer for longer than it lasts, which is until the pointer leaves the control.
// It marks itself a pointer hole (`pointerHole()`) because it floats over the message field's text.

// MARK: - What a tip says

struct NookTip: Equatable {
    /// What the control is: "Modelo", "Dictar".
    var title: String
    /// Its state, after a dot: "Opus 5.5", "adjunta".
    var value: String?
    /// A line under them: what it does, or why it cannot be used now.
    var detail: String?

    init(_ title: String, value: String? = nil, detail: String? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
    }
}

// MARK: - Timing

enum NookTipTiming {
    /// How long the pointer rests on a control before its tip shows.
    static let delay = 0.45
    /// Once a tip has been up, the next control's shows this soon: going along the row reads as one tip that changes, not as five that each make you wait.
    static let warmDelay = 0.06
    /// How long after a tip goes the row stays warm.
    static let warmWindow: TimeInterval = 0.7
}

/// When a tip was last on screen, which decides how long the next one waits. A plain value on a clock it is handed, as `NoticeCountdown` is.
struct NookTipWarmth: Equatable {
    private(set) var last: Date?
    /// How many tips are up right now. The pointer is one, so it is one at a time; the count is for the instant a tip is handed from a control to the next,
    /// when the next one's wait may begin before the first one has gone.
    private(set) var up = 0

    /// A tip came up at `now`.
    mutating func came(at now: Date) {
        up += 1
        last = now
    }

    /// A tip went at `now`.
    mutating func went(at now: Date) {
        up = max(0, up - 1)
        last = now
    }

    /// A tip that is up warms the row for as long as it stays, however long that is; one that has gone does for a moment more.
    func isWarm(at now: Date) -> Bool {
        if up > 0 { return true }
        guard let last else { return false }
        return now.timeIntervalSince(last) < NookTipTiming.warmWindow
    }

    /// How long a tip that is asked for at `now` waits before it shows.
    func delay(at now: Date) -> Double { isWarm(at: now) ? NookTipTiming.warmDelay : NookTipTiming.delay }
}

/// The row's warmth, shared by every control that has a tip: one pointer, one row.
@MainActor
final class NookTipWarmthClock {
    static let shared = NookTipWarmthClock()
    private(set) var warmth = NookTipWarmth()

    func came(at now: Date = Date()) { warmth.came(at: now) }
    func went(at now: Date = Date()) { warmth.went(at: now) }
    func delay(at now: Date = Date()) -> Double { warmth.delay(at: now) }
    /// For tests: a cold row.
    func reset() { warmth = NookTipWarmth() }
}

// MARK: - Motion

enum NookTipMotion {
    static let duration = 0.12

    /// What the bubble comes and goes with, or nil to just appear and go: Reduce Motion, or the app's animations switched off, asks for no motion.
    static func animation(reduceMotion: Bool, animationsOn: Bool) -> Animation? {
        guard !reduceMotion, animationsOn else { return nil }
        return .easeOut(duration: duration)
    }

    /// It rises the last few points into place, from the control it explains.
    static let transition: AnyTransition = .opacity.combined(with: .offset(y: 3))
}

// MARK: - Where it stands

enum NookTipGeometry {
    /// The air between the bubble and the control it explains.
    static let gap: CGFloat = 7
    /// How near the pane's edges the bubble may come.
    static let margin: CGFloat = 10
    /// The widest the bubble gets; a longer line wraps.
    static let maxWidth: CGFloat = 300

    /// The bubble's frame for a bubble of `size` explaining the control at `anchor`, in a pane of `pane`: centred over the control, kept between the margins
    /// (so a control at the edge has a bubble that reaches over it and no further), and above it. Only where there is no room above does it stand below,
    /// so it is never on the control.
    static func frame(of size: CGSize, over anchor: CGRect, in pane: CGSize) -> CGRect {
        let slack = max(margin, pane.width - margin - size.width)
        let x = min(max(anchor.midX - size.width / 2, margin), slack)
        var y = anchor.minY - gap - size.height
        if y < margin { y = anchor.maxY + gap }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Stands its one child, as wide as its words (up to `maxWidth`), where `NookTipGeometry` says. A frame and an offset would need the child's size before
/// it is measured; here the child is measured first and placed once.
private struct NookTipPlacing: Layout {
    var anchor: CGRect
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let width = min(maxWidth, max(0, bounds.width - 2 * NookTipGeometry.margin))
        let size = bubble.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let frame = NookTipGeometry.frame(of: size, over: anchor, in: bounds.size)
        bubble.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

// MARK: - Marking a control

/// A control that has a tip to show now, and where it stands in the space of whatever shows the tip.
struct NookTipEntry: Equatable {
    var id: String
    var tip: NookTip
    var bounds: Anchor<CGRect>
}

struct NookTipKey: PreferenceKey {
    static var defaultValue: NookTipEntry? { nil }
    static func reduce(value: inout NookTipEntry?, nextValue: () -> NookTipEntry?) { value = nextValue() ?? value }
}

extension EnvironmentValues {
    /// The control whose tip is always shown, whatever the pointer does: its id. Previews and render tests use it to see a state that is gone in a moment.
    var nookTipPinned: String? {
        get { self[NookTipPinnedKey.self] }
        set { self[NookTipPinnedKey.self] = newValue }
    }

    /// The control a pointer that is not real rests on: its id. A test moves it from control to control to see the tips come after their wait and go as it leaves,
    /// which the real pointer can only be made to do by a person.
    var nookTipPointer: String? {
        get { self[NookTipPointerKey.self] }
        set { self[NookTipPointerKey.self] = newValue }
    }
}

private struct NookTipPinnedKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct NookTipPointerKey: EnvironmentKey { static let defaultValue: String? = nil }

private struct NookTipModifier: ViewModifier {
    var tip: NookTip?
    var id: String
    /// The pointer is on the control.
    @State private var hovering = false
    /// It has rested there long enough.
    @State private var shown = false
    @Environment(\.nookTipPinned) private var pinned
    @Environment(\.nookTipPointer) private var pointer

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .onChange(of: pointer == id) { _, over in hovering = over }
            .anchorPreference(key: NookTipKey.self, value: .bounds) { bounds in
                guard let tip, shown || pinned == id else { return nil }
                return NookTipEntry(id: id, tip: tip, bounds: bounds)
            }
            // A new rest is a new wait; leaving ends it, and cancels the one that was running.
            .task(id: hovering) {
                guard hovering else {
                    withdraw()
                    return
                }
                try? await Task.sleep(for: .seconds(NookTipWarmthClock.shared.delay()))
                guard !Task.isCancelled else { return }
                shown = true
                NookTipWarmthClock.shared.came()
            }
            // The control left the pane (the picker took its place) with the pointer on it: its tip goes with it.
            .onDisappear {
                hovering = false
                withdraw()
            }
    }

    /// Takes the tip away, and tells the row so that the next control's comes without its whole wait.
    private func withdraw() {
        guard shown else { return }
        shown = false
        NookTipWarmthClock.shared.went()
    }
}

extension View {
    /// A tip for this control: after the pointer has rested on it a moment, `NookTipLayer` (the pane's) shows it over the control. A nil tip says there is
    /// none now (a menu is open from it, say). `id` names the control; it is what a click or a key puts away, and what previews pin.
    func nookTip(_ tip: NookTip?, id: String) -> some View {
        modifier(NookTipModifier(tip: tip, id: id))
    }
}

// MARK: - The bubble

struct NookTipBubble: View {
    var tip: NookTip

    /// The card's own surface: the one of the island's other floating cards (dark on the dark island, white on the paper).
    private static let surface = Color.nookTip

    var body: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            heading.fixedSize(horizontal: false, vertical: true)
            if let detail = tip.detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6.5)
        // It floats over the message field's text, so its glass is as opaque as the lists' that do too.
        .nookGlassCard(radius: 9, dim: 0.88, dimColor: Self.surface, fill: Self.surface, stroke: Color.nookWash(0.12, light: 0.14))
        .nookCardShadow(0.5, radius: 8, y: 3)
        // The arrow, not the text's I-beam, over a card that is drawn there.
        .pointerHole()
        .allowsHitTesting(false)
    }

    private var heading: Text {
        var text = Text(tip.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.96))
        if let value = tip.value {
            text = text + Text("  ·  ").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.28))
                + Text(value).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.82))
        }
        return text
    }
}

// MARK: - The layer

/// The pane's one bubble: over the control that has a tip to show (`NookTipKey`), above everything the pane draws. It takes no clicks and VoiceOver
/// skips it (each control says itself, with its label, value and hint). A click, a key or the wheel puts it away, and it stays away until the pointer
/// comes to rest on a control again.
struct NookTipLayer: View {
    var entry: NookTipEntry?
    /// The island is on screen and nothing stands between the pointer and the controls (a list open over the row).
    var enabled = true
    /// The app's animation preference (`AppModel.animations`).
    var animated = true
    /// The tip a click or a key sent away.
    @State private var spent: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animation = NookTipMotion.animation(reduceMotion: reduceMotion, animationsOn: animated)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if enabled, let entry, spent != entry.id {
                    NookTipPlacing(anchor: proxy[entry.bounds], maxWidth: NookTipGeometry.maxWidth) {
                        NookTipBubble(tip: entry.tip)
                    }
                    .id(entry.id)
                    .transition(animation == nil ? .identity : NookTipMotion.transition)
                    .background { NookTipInputWatcher { spent = entry.id } }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(animation, value: entry?.id)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Gone (the pointer left): the next time is a fresh one.
        .onChange(of: entry?.id) { _, _ in spent = nil }
    }
}

/// Tells its owner when the user does something that puts a tip away: a click, a key, the wheel. It lives only as long as the bubble does, and takes nothing
/// from what it hears (every event goes on to where it was going).
private struct NookTipInputWatcher: NSViewRepresentable {
    var onInput: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onInput = onInput
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) { view.onInput = onInput }

    final class WatcherView: NSView {
        var onInput: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                if let self, event.window === self.window { self.onInput?() }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
