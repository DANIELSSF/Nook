import SwiftUI
import AppKit

// The island's notices ("avisos"): what Nook says about its own doings (a pasted image, a permission that is missing, an error), as a card that floats
// over the conversation for a few seconds and goes by itself.
//
//   NoticeCountdown     where the five seconds stand. It runs while the island is on screen and the pointer is away from the card, and keeps what
//                       is left while it is held. A plain value on a clock it is handed, so the rules are checked without a window
//   NoticeToast         the card: the words, the way to the Permisos tab when the notice is about one, and the ✕ in its ring
//   NoticeCloseButton   the ✕ inside the ring that runs down: one control, the way to close the notice now and the picture of when it goes by itself
//   NoticeToastLayer    where the card stands: hanging from the top of the area a pane reports (`noticeArea`), centred across it and under whatever
//                       that pane keeps at its top, above whatever the pane floats
//   NoticeMotion        how the card comes and goes (and when it just appears)
//
// The text is `AppModel.notice`; the card never owns it. Closing (the ✕, the end of the countdown, "Ver permisos") sets it to nil only if it still is
// the text the card shows (`AppModel.closeNotice`), so the end of an old notice never closes a newer one. A different text is a different card, with
// a countdown of its own; the same text set again while it shows changes nothing.

// MARK: - The countdown

/// Where a notice's countdown stands. It counts `duration` seconds, but only while the island's content is on screen and the pointer is not on the
/// card: both let go of it (a notice that was set with the island shut, or read under the pointer, is not spent) and what was left when it stopped is
/// what it has when it runs again. It holds a clock's readings, never the clock: every question takes the moment it is asked at.
struct NoticeCountdown: Equatable {
    /// Five seconds: long enough to read a line, short enough not to wait on it.
    static let standard: TimeInterval = 5

    let duration: TimeInterval
    /// The island's content is on screen, and nothing covers the card.
    private(set) var onScreen: Bool
    /// The pointer is on the card.
    private(set) var hovering: Bool
    /// What was left when it last stopped, or when it was made.
    private var left: TimeInterval
    /// When it last began to run; nil while it is held.
    private var since: Date?

    init(duration: TimeInterval = NoticeCountdown.standard, onScreen: Bool = true, hovering: Bool = false, now: Date) {
        self.duration = max(duration, 0.001)
        self.onScreen = onScreen
        self.hovering = hovering
        left = self.duration
        since = onScreen && !hovering ? now : nil
    }

    /// It only counts while it is on screen with the pointer away.
    var runs: Bool { onScreen && !hovering }
    /// Whether the clock is going.
    var isRunning: Bool { since != nil }

    mutating func setOnScreen(_ shown: Bool, now: Date) {
        guard shown != onScreen else { return }
        onScreen = shown
        follow(now)
    }

    mutating func setHovering(_ over: Bool, now: Date) {
        guard over != hovering else { return }
        hovering = over
        follow(now)
    }

    /// Starts or stops the clock to match `runs`, keeping what is left.
    private mutating func follow(_ now: Date) {
        if runs {
            if since == nil { since = now }
        } else if since != nil {
            left = remaining(at: now)
            since = nil
        }
    }

    /// Seconds left at `now`. A reading from before the clock started (a frame's date can trail the event that started it) counts as no time gone.
    func remaining(at now: Date) -> TimeInterval {
        guard let since else { return left }
        return max(0, left - max(0, now.timeIntervalSince(since)))
    }

    /// How much of the ring is left, 1…0. `stepped` rounds it up to whole seconds, so with no motion it goes down a fifth at a time instead of gliding.
    func fraction(at now: Date, stepped: Bool = false) -> Double {
        let left = remaining(at: now)
        return min(1, max(0, (stepped ? left.rounded(.up) : left) / duration))
    }

    /// When it runs out, if it is left running; nil while it is held.
    var end: Date? { since.map { $0.addingTimeInterval(left) } }

    func isOver(at now: Date) -> Bool { remaining(at: now) <= 0 }
}

extension AppModel {
    /// Closes the notice the card shows, unless another has taken its place meanwhile: a card's end (or its ✕) is about its own text.
    func closeNotice(_ shown: String) {
        if notice == shown { notice = nil }
    }
}

// MARK: - Motion

enum NoticeMotion {
    static let duration = 0.16

    /// What the card comes and goes with, or nil to just appear and go: Reduce Motion, or the app's animations switched off, asks for no motion.
    static func animation(reduceMotion: Bool, animationsOn: Bool) -> Animation? {
        guard !reduceMotion, animationsOn else { return nil }
        return .easeOut(duration: duration)
    }

    /// It hangs from the top of its area, so it fades in settling down from a little above its place, and goes the same way back: the 4 pt and the short
    /// ease the island's other cards that hang from an edge come and go with (the startup warnings').
    static let transition: AnyTransition = .opacity.combined(with: .offset(y: -4))
}

// MARK: - Measures

enum NoticeMetrics {
    /// The widest the card gets: a short notice is as wide as its words, a long one wraps at this.
    static let maxWidth: CGFloat = 420
    /// The gap between the card and what it hangs from (the top of its area, or the bar or toolbar there), and between the card and the area's sides: the island's
    /// own 6 pt, the one between its tabs and between the conversation and the composer.
    static let margin: CGFloat = 6
    /// The least height the card is given: a line of words, the ring's row and the padding round them. The room under a bar can be shorter than that in the
    /// smallest island; the card then reaches down into the gap above the composer rather than hide a line.
    static let minHeight: CGFloat = 38
    /// Where the bar over an agent's conversation or a shell's output ends (`ShellViewBar` is `AgentViewBar`'s height, and both have 2 pt of air above them): the
    /// card hangs from there, so the way back to Claude stays in view.
    static let viewBar: CGFloat = 2 + AgentViewBar.height
    /// The ring as drawn, its line, and the target round it that takes the click: a comfortable 24 pt, as the composer's round chips are.
    static let ring: CGFloat = 20
    static let line: CGFloat = 2
    static let target: CGFloat = 24
    /// The card's own surface, which the glass is dimmed toward and the scroll fade ends in.
    static let surface = Color.nookCardRaised
}

/// Lays its one child out as wide as it wants up to `width` and no taller than `height`, whatever room it is offered. A flexible frame would fill the
/// room instead; the card has to be as wide as its words.
private struct NoticeCardSizing: Layout {
    var width: CGFloat
    var height: CGFloat

    private func offered(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height == nil ? nil : height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(offered(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - The ✕ in its ring

/// The ✕ inside a ring that runs down as the notice's time does: it is the way to close the notice now and the picture of when it goes by itself, in
/// one control. The ring is a track with an arc of the island's mint on it, which the countdown eats clockwise from the top. While the pointer holds the
/// card the arc stops and dims. The click lands anywhere in a 24 pt circle.
struct NoticeCloseButton: View {
    var countdown: NoticeCountdown
    /// With Reduce Motion or the app's animations off the arc goes down a step a second instead of gliding.
    var stepped: Bool
    var action: () -> Void
    @State private var hovered = false
    @State private var pressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                NoticeRing(countdown: countdown, stepped: stepped)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.primary.opacity(hovered || pressed ? 1 : 0.7))
            }
            .frame(width: NoticeMetrics.ring, height: NoticeMetrics.ring)
            // The wash the island's round chips take (`ChipWash`), inside the ring.
            .background(Color.primary.opacity(pressed ? ChipWash.pressed : (hovered ? ChipWash.hovered : 0)), in: Circle())
            .frame(width: NoticeMetrics.target, height: NoticeMetrics.target)
            .contentShape(Circle())
        }
        .buttonStyle(PressReporter(pressed: $pressed))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
        .help("Cerrar aviso. Se cierra solo; con el puntero encima, espera.")
        .accessibilityLabel("Cerrar aviso")
    }
}

/// The ring itself: redrawn with the display while the clock goes, and not at all while it is held.
private struct NoticeRing: View {
    var countdown: NoticeCountdown
    var stepped: Bool
    /// Nobody can see the island (`\.islandSeen`): what moves here pauses.
    @Environment(\.islandSeen) private var seen

    var body: some View {
        // Nobody can see the island (`\.islandSeen`): the ring is not redrawn; drawn from the clock, it is right again on its first frame back.
        TimelineView(.animation(minimumInterval: stepped ? 0.2 : nil, paused: !countdown.isRunning || !seen)) { context in
            let left = countdown.fraction(at: context.date, stepped: stepped)
            ZStack {
                Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: NoticeMetrics.line)
                // What is left is the arc that ends at the top; time takes it from its other end, so the ring is eaten clockwise like a clock's hand
                // passing over it.
                Circle().inset(by: NoticeMetrics.line / 2).trim(from: 1 - left, to: 1)
                    .stroke(PermissionPalette.mint.opacity(countdown.hovering ? 0.5 : 1), style: StrokeStyle(lineWidth: NoticeMetrics.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(left > 0 ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The card

/// Where the pointer starts, for previews and render tests.
enum NoticeToastLook { case resting, hovered }

/// One notice, as a card. It counts its own time (`NoticeCountdown`): a new notice is a new card (the layer gives it its text as identity), which
/// begins with the whole of it. The pointer on the card holds the countdown, so the words can be read and "Ver permisos" pressed; the island going
/// out of sight holds it too.
struct NoticeToast: View {
    var text: String
    /// The island's content is on screen and nothing covers the card; the countdown only runs then.
    var onScreen: Bool
    var stepped: Bool
    var maxWidth: CGFloat
    /// The height of the room it floats in; a card taller than that scrolls its words.
    var maxHeight: CGFloat
    var onClose: () -> Void
    var onSeePermissions: () -> Void
    @State private var countdown: NoticeCountdown

    init(text: String, duration: TimeInterval = NoticeCountdown.standard, onScreen: Bool = true, stepped: Bool = false, maxWidth: CGFloat = NoticeMetrics.maxWidth,
         maxHeight: CGFloat = .infinity, look: NoticeToastLook = .resting, onClose: @escaping () -> Void = {}, onSeePermissions: @escaping () -> Void = {}) {
        self.text = text
        self.onScreen = onScreen
        self.stepped = stepped
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.onClose = onClose
        self.onSeePermissions = onSeePermissions
        _countdown = State(initialValue: NoticeCountdown(duration: duration, onScreen: onScreen, hovering: look == .hovered, now: Date()))
    }

    var body: some View {
        NoticeCardSizing(width: maxWidth, height: maxHeight) {
            HStack(alignment: .top, spacing: 6) {
                // As much of the words as the room allows, and never less of the way to the Permisos tab, which is what the notice may be for.
                ViewThatFits(in: .vertical) {
                    // With room to spare: the words, and the way under them.
                    VStack(alignment: .leading, spacing: 7) {
                        words
                        if offersPermissions { permissions.padding(.leading, Self.iconWidth + Self.gap) }
                    }.padding(.vertical, 5)
                    // A short room: the way beside the words, so that it takes none of their height.
                    HStack(alignment: .top, spacing: 8) {
                        words.padding(.vertical, 5)
                        if offersPermissions { permissions.padding(.top, 1) }
                    }
                    // Not even then: the words scroll, with the way and the ring staying where they are.
                    HStack(alignment: .top, spacing: 8) {
                        ScrollView(.vertical) { words.padding(.vertical, 5) }.nookScrollFade(active: true, surface: NoticeMetrics.surface)
                        if offersPermissions { permissions.padding(.top, 1) }
                    }
                }
                NoticeCloseButton(countdown: countdown, stepped: stepped, action: onClose)
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 7)
            // It covers the conversation's text, so its glass is as dark as the lists' that do too (`TabAgentListLayout.dim`), not the 0.6 it had at the bottom.
            .nookGlassCard(radius: 12, tint: PermissionPalette.mint.opacity(0.14), dim: TabAgentListLayout.dim, dimColor: NoticeMetrics.surface, fill: NoticeMetrics.surface,
                           stroke: PermissionPalette.mint.opacity(0.2))
            // It floats over the conversation: the arrow shows over it, not the text's I-beam.
            .pointerHole()
            .nookCardShadow(0.5, radius: 10, y: 4)
        }
        // The card's own shape is where the pointer holds the countdown, whatever the surface behind it is made of.
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { over in countdown.setHovering(over, now: Date()) }
        .onChange(of: onScreen) { _, shown in countdown.setOnScreen(shown, now: Date()) }
        // Whenever the clock starts or stops there is a new end to wait for (none while it is held).
        .task(id: countdown) {
            guard let end = countdown.end else { return }
            let wait = end.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { onClose() }
        }
        .onAppear { Self.announce(text) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aviso")
    }

    private static let iconWidth: CGFloat = 12
    private static let gap: CGFloat = 7

    /// A notice about a missing permission offers the Permisos tab.
    private var offersPermissions: Bool { PermissionHelp.opensPermissions(text) }

    private var permissions: some View { SeePermissionsButton(action: onSeePermissions) }

    /// The icon on the first line of the words (which line up with the ring's middle), and the words, wrapped at the room there is.
    private var words: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(PermissionPalette.mint).frame(width: Self.iconWidth).accessibilityHidden(true)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A card that goes by itself cannot wait for VoiceOver to reach it: it is read out as it comes.
    private static func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

// MARK: - Where it stands

/// Where a pane says the notice hangs from: the room it has for it, and how far under that room's top the card starts, which is what the pane keeps up there
/// that the card must not cover (the bar over an agent's conversation or a shell's output, Claude's panel's toolbar, a question's header).
struct NoticeArea {
    var bounds: Anchor<CGRect>
    var below: CGFloat
}

/// The pane on show's own area: the conversation's, the panel's, the question's card's when it has taken the pane, or the welcome's. Nothing reported (no pane on
/// show) means the whole island.
struct NoticeAreaKey: PreferenceKey {
    static var defaultValue: NoticeArea? { nil }
    static func reduce(value: inout NoticeArea?, nextValue: () -> NoticeArea?) { value = nextValue() ?? value }
}

extension View {
    /// The notice hangs from the top of what this view fills, centred across it, while `active`, and `below` points lower when the view has something at its
    /// top that the notice must not cover. The chat area says so (not the composer, nor the tabs: the card never covers them), and so does the panel Claude has
    /// open while it takes the pane, a question's card while it does, and the welcome.
    func noticeArea(_ active: Bool = true, below: CGFloat = 0) -> some View {
        anchorPreference(key: NoticeAreaKey.self, value: .bounds) { active ? NoticeArea(bounds: $0, below: below) : nil }
    }
}

extension EnvironmentValues {
    /// How long a notice counts, in seconds. Tests make it short; nothing else sets it.
    var noticeDuration: TimeInterval {
        get { self[NoticeDurationKey.self] }
        set { self[NoticeDurationKey.self] = newValue }
    }
}

private struct NoticeDurationKey: EnvironmentKey { static let defaultValue = NoticeCountdown.standard }

/// The card for `AppModel.notice`, hanging from the top of `area` (or of the whole island without one), centred across it: at the top it stays out of the way of
/// what is being read, as a banner does, and never in the middle of the screen. It stands in the island's content, above its panes, so it is there whichever
/// pane is on show and keeps its countdown when the tab changes; and it is out of the way of everything it does not cover, which is everything: only the card
/// itself takes the pointer.
struct NoticeToastLayer: View {
    @ObservedObject var model: AppModel
    var area: NoticeArea?
    var look: NoticeToastLook = .resting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noticeDuration) private var duration

    /// Where the card stands: `room` is the area's (or the island's), `top` where the card begins (a margin under the area's top, or under what the pane keeps
    /// there) and `free` what is left of the room from there down, which is as tall as the card may be (never less than `NoticeMetrics.minHeight`).
    private struct Placement {
        var room: CGRect
        var top: CGFloat
        var free: CGFloat { max(0, room.maxY - top) }
    }

    private func placement(in proxy: GeometryProxy) -> Placement {
        guard let area else { return Placement(room: CGRect(origin: .zero, size: proxy.size), top: NoticeMetrics.margin) }
        let room = proxy[area.bounds]
        return Placement(room: room, top: room.minY + area.below + NoticeMetrics.margin)
    }

    var body: some View {
        let animation = NoticeMotion.animation(reduceMotion: reduceMotion, animationsOn: model.animations)
        GeometryReader { proxy in
            let place = placement(in: proxy)
            ZStack(alignment: .top) {
                if let notice = model.notice {
                    NoticeToast(text: notice, duration: duration, onScreen: model.islandContentVisible && !model.connectionSheet, stepped: animation == nil,
                                maxWidth: min(NoticeMetrics.maxWidth, max(0, place.room.width - 2 * NoticeMetrics.margin)),
                                maxHeight: max(NoticeMetrics.minHeight, place.free), look: look,
                                onClose: { model.closeNotice(notice) },
                                onSeePermissions: { model.closeNotice(notice); model.showPermissions() })
                        // Another text is another card, with its own countdown: the old one goes as the new one comes.
                        .id(notice)
                        .transition(animation == nil ? .identity : NoticeMotion.transition)
                }
            }
            // The frame is what is left of the room, from the card's top down; a card that needs more hangs out of its bottom, never out of its top.
            .frame(width: place.room.width, height: place.free, alignment: .top)
            .position(x: place.room.midX, y: place.top + place.free / 2)
            .animation(animation, value: model.notice)
            // The connection sheet covers the island (its glass would let the card show through it): the card waits behind it, with its time held.
            .opacity(model.connectionSheet ? 0 : 1).allowsHitTesting(!model.connectionSheet)
        }
    }
}
