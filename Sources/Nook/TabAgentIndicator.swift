import SwiftUI
import Combine

// A session tab shows when its Claude has subagents: a small badge after the tab's title (a spinner and the number
// of agents working, in Claude's terracotta; a quiet mint check for finished ones, an amber mark for failed ones).
// Pointing at it, or clicking it, opens that tab's list (`SubagentList`) under the tab row.
//
// The list is drawn by `TabAgentListHost`, an overlay of the tab row, and not by the badge itself: the tabs sit in a
// horizontal ScrollView, which would clip a card hanging from one of them. The badge only tells the shared
// `TabAgentListPresenter` where it is and when the pointer is over it.
//
// Cheap on purpose: the badge is driven by `TabAgentState`, which changes when an agent starts or ends and not
// when a counter ticks, and nothing here owns a repeating timer. The only schedules are SwiftUI's own, for the
// spinner, and they pause with Reduce Motion, with the animations preference and while the island is collapsed.

// MARK: - State

/// What a tab shows of its agent's subagents: working ones clearly, finished or failed ones quietly for a while after
/// the last one ends.
struct TabAgentState: Equatable {
    enum Kind: Equatable { case running, failed, done }

    private(set) var running = 0
    private(set) var failed = 0
    private(set) var done = 0
    /// The last working agent ended a moment ago, so finished and failed ones may still show.
    private(set) var lingering = false

    init(_ summary: SubagentSummary = SubagentSummary([]), lingering: Bool = false) {
        running = summary.running; failed = summary.failed; done = summary.done
        self.lingering = lingering
    }

    init(_ agents: [SubagentActivity], lingering: Bool = false) {
        self.init(SubagentSummary(agents), lingering: lingering)
    }

    /// What the badge says, or nil when the tab shows nothing. Working beats failed beats finished.
    var kind: Kind? {
        if running > 0 { return .running }
        guard lingering else { return nil }
        if failed > 0 { return .failed }
        return done > 0 ? .done : nil
    }

    /// The number beside the symbol: the agents of the state the badge shows.
    var count: Int {
        switch kind { case .running: running; case .failed: failed; case .done: done; case nil: 0 }
    }

    var countText: String { count > 9 ? "9+" : "\(count)" }

    /// Something failed while others still work: the working badge carries a small amber dot.
    var warns: Bool { running > 0 && failed > 0 }

    private static func agents(_ count: Int) -> String { count == 1 ? "1 agente" : "\(count) agentes" }

    /// The badge in words, for VoiceOver.
    var label: String {
        switch kind {
        case .running: Self.agents(running) + " trabajando" + (failed > 0 ? ", \(failed) con error" : "")
        case .failed: failed == 1 ? "1 agente con error" : "\(failed) agentes con error"
        case .done: Self.agents(done) + (done == 1 ? " listo" : " listos")
        case nil: ""
        }
    }
}

/// Follows one session's subagents and says what its tab should show. Finished agents show for a minute after the last
/// working one ends; a tab that is only ever seen with old, finished agents stays quiet. It publishes only when the
/// badge would change, so the tab does not redraw for every counter that ticks.
@MainActor
final class TabAgentTracker: ObservableObject {
    /// How long finished and failed agents show after the last working one ends.
    nonisolated static let lingerSeconds = 60.0

    @Published private(set) var state = TabAgentState()
    private var summary = SubagentSummary([])
    private var lingering = false
    private var lingerTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private let linger: Double

    init(agents: AnyPublisher<[SubagentActivity], Never>, linger: Double = lingerSeconds) {
        self.linger = linger
        // Only a change in how many agents are in each state matters; durations and activity lines tick on their own.
        subscription = agents.map(SubagentSummary.init).removeDuplicates().sink { [weak self] summary in
            // The session publishes on the main thread; anything else hops there instead of touching the state from outside.
            if Thread.isMainThread { MainActor.assumeIsolated { self?.update(summary) } }
            else { DispatchQueue.main.async { self?.update(summary) } }
        }
    }

    convenience init(session: TerminalSession, linger: Double = lingerSeconds) {
        self.init(agents: session.$subagents.eraseToAnyPublisher(), linger: linger)
    }

    deinit { lingerTask?.cancel() }

    private func update(_ next: SubagentSummary) {
        let wasWorking = summary.running > 0
        summary = next
        if next.running > 0 {
            lingerTask?.cancel(); lingering = false
        } else if wasWorking {
            startLingering()
        }
        publish()
    }

    private func startLingering() {
        lingering = true
        lingerTask?.cancel()
        lingerTask = Task { [weak self, linger] in
            try? await Task.sleep(for: .seconds(linger))
            guard !Task.isCancelled else { return }
            self?.lingering = false
            self?.publish()
        }
    }

    private func publish() {
        let next = TabAgentState(summary, lingering: lingering)
        if next != state { state = next }
    }
}

// MARK: - The list's place

/// Where the list opens and how big it may be.
enum TabAgentListLayout {
    static let width: CGFloat = 440
    /// The list may not be taller than this: under the tab row there are about 190 pt of island left.
    static let maxHeight: CGFloat = 178
    /// The tab row's height; the list hangs just below it.
    static let rowHeight: CGFloat = 30
    static let gap: CGFloat = 3
    /// Space kept between the list and the island's sides.
    static let margin: CGFloat = 12
    /// The list covers the conversation and sometimes the composer, so its glass is darker than the composer capsule's.
    static let dim = 0.94

    static var originY: CGFloat { rowHeight + gap }

    /// The list's left edge: centred under the badge, kept inside the island.
    static func originX(badge: CGRect, width: CGFloat = width, container: CGFloat) -> CGFloat {
        let centred = badge.midX - width / 2
        return min(max(centred, margin), max(margin, container - margin - width))
    }
}

/// Which tab's list is open, shared by the tabs' badges and the card. Opening waits a moment so a pointer sweeping
/// across the tabs opens nothing; moving from one badge to another follows at once; leaving both the badge and the
/// card closes it after a short grace, so the pointer can cross the gap between them.
@MainActor
final class TabAgentListPresenter: ObservableObject {
    struct Open: Equatable {
        var id: String
        /// The badge's frame in the tab row's coordinates.
        var frame: CGRect
    }

    /// The tab row's coordinate space: badges report their frames in it, and the list is placed in it.
    nonisolated static let space = "nookTabRow"

    @Published private(set) var open: Open?
    /// The latest frame each badge reported, so a list can be opened for a tab without waiting for the pointer.
    private var frames: [String: CGRect] = [:]
    var openDelay: Double
    var closeDelay: Double
    private var overBadge: String?
    private var overCard = false
    private var pending: Task<Void, Never>?

    init(openDelay: Double = 0.2, closeDelay: Double = 0.5) {
        self.openDelay = openDelay
        self.closeDelay = closeDelay
    }

    deinit { pending?.cancel() }

    func badgeHover(_ id: String, frame: CGRect, over: Bool) {
        if over {
            overBadge = id
            pending?.cancel()
            if open != nil { show(id, frame: frame) }
            else { later(openDelay) { [self] in if overBadge == id { show(id, frame: frame) } } }
        } else {
            if overBadge == id { overBadge = nil }
            pending?.cancel()
            scheduleClose()
        }
    }

    func cardHover(_ over: Bool) {
        overCard = over
        if over { pending?.cancel() } else { scheduleClose() }
    }

    /// A click on the badge: opens its list now, or closes it when it is the one showing.
    func toggle(_ id: String, frame: CGRect) {
        pending?.cancel()
        if open?.id == id { close() } else { show(id, frame: frame) }
    }

    /// Opens a tab's list now, under its badge where it was last seen (the collapsed island's agent pill asks for it).
    func openList(_ id: String) {
        pending?.cancel()
        show(id, frame: frames[id] ?? .zero)
    }

    /// The badge moved (the tab row scrolled, a tab changed width): the list follows it.
    func move(_ id: String, to frame: CGRect) {
        frames[id] = frame
        guard var current = open, current.id == id, current.frame != frame else { return }
        current.frame = frame
        open = current
    }

    func close() {
        pending?.cancel()
        // A card that goes away under the pointer sends no "left" event of its own.
        overCard = false
        if open != nil { open = nil }
    }

    /// The tab has nothing to list any more, or is gone: its list goes with it.
    func close(ifShowing id: String) {
        if overBadge == id { overBadge = nil }
        if open?.id == id { close() }
    }

    private func show(_ id: String, frame: CGRect) {
        let next = Open(id: id, frame: frame)
        if open != next { open = next }
    }

    private func scheduleClose() {
        guard open != nil else { return }
        later(closeDelay) { [self] in if overBadge == nil, !overCard { close() } }
    }

    private func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

// MARK: - Badge

/// The badge on a tab. Working agents: Claude's spinner and their number on a terracotta wash. Failed ones: a mark and
/// their number on amber. Finished ones, for a minute after the last ends: a mint check and their number, with no wash.
struct TabAgentBadge: View {
    var state: TabAgentState
    /// False holds the spinner still (the preference, a collapsed island); Reduce Motion does the same.
    var animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 14

    var body: some View {
        if let kind = state.kind {
            HStack(spacing: 2.5) {
                symbol(kind).frame(width: 9)
                Text(state.countText).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(kind == .running ? Color.primary.opacity(0.92) : tint(kind))
            }
            .padding(.horizontal, 5).frame(height: Self.height)
            .background(wash(kind), in: Capsule())
            .overlay(alignment: .topTrailing) {
                // Something failed while the others still work.
                if state.warns {
                    Circle().fill(AgentPalette.failed).frame(width: 5, height: 5)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1).padding(-1))
                        .offset(x: 1.5, y: -1.5)
                }
            }
            .fixedSize()
        }
    }

    private func tint(_ kind: TabAgentState.Kind) -> Color {
        switch kind { case .running: AgentPalette.running; case .failed: AgentPalette.failed; case .done: AgentPalette.done.opacity(0.9) }
    }

    private func wash(_ kind: TabAgentState.Kind) -> Color {
        switch kind { case .running: AgentPalette.running.opacity(0.22); case .failed: AgentPalette.failed.opacity(0.16); case .done: .clear }
    }

    @ViewBuilder private func symbol(_ kind: TabAgentState.Kind) -> some View {
        switch kind {
        case .running:
            let still = !animated || reduceMotion
            TimelineView(.animation(minimumInterval: 0.16, paused: still)) { context in
                Text(SubagentStateGlyph.symbol(at: context.date, still: still)).font(.system(size: 10, weight: .bold)).foregroundStyle(tint(kind))
            }
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(tint(kind))
        case .done:
            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(tint(kind))
        }
    }
}

/// The badge as a control: clicking it opens the tab's list, and so does pointing at it for a moment. It reports its
/// place to the presenter, which positions the list under it.
struct TabAgentIndicator: View {
    var sessionID: String
    var state: TabAgentState
    var animated: Bool
    var presenter: TabAgentListPresenter
    @State private var frame: CGRect = .zero

    var body: some View {
        Button { presenter.toggle(sessionID, frame: frame) } label: {
            // The badge is 14 pt tall; the taller hit area matches the tab's close button next to it.
            TabAgentBadge(state: state, animated: animated)
                .padding(.vertical, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { presenter.badgeHover(sessionID, frame: frame, over: $0) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(TabAgentListPresenter.space)) } action: { new in
            frame = new
            presenter.move(sessionID, to: new)
        }
        .accessibilityLabel("Agentes de Claude")
        .accessibilityValue(state.label)
    }
}

// MARK: - The list under the tab row

/// The open list, as an overlay of the tab row: placed under the badge, above the conversation. It takes up no room of
/// its own, so nothing else moves, and where there is no list it has no content to catch a click meant for a tab.
struct TabAgentListHost: View {
    @ObservedObject var presenter: TabAgentListPresenter
    var sessions: [TerminalSession]
    /// The island's width, to keep the list inside it.
    var containerWidth: CGFloat
    var animated: Bool
    /// The list's width and the tallest it may be; they follow the island's size (`PaneLayout`).
    var width: CGFloat = TabAgentListLayout.width
    var maxHeight: CGFloat = TabAgentListLayout.maxHeight
    /// A click on an agent's row: its conversation opens (the tab's list goes away with it).
    var onOpen: ((TerminalSession, SubagentActivity) -> Void)?

    var body: some View {
        Group {
            if let open = presenter.open, let session = sessions.first(where: { $0.id == open.id }) {
                TabAgentListCard(session: session, animated: animated, width: width, maxHeight: maxHeight, onOpen: onOpen.map { open in { agent in open(session, agent) } })
                    .onHover { presenter.cardHover($0) }
                    .offset(x: TabAgentListLayout.originX(badge: open.frame, width: width, container: containerWidth), y: TabAgentListLayout.originY)
                    // A fade only: it is no motion, so Reduce Motion keeps it.
                    .transition(.opacity)
            }
        }
        // Keyed on which tab is open, so the list fading in or out is animated and its following a scrolled badge is not.
        .animation(.easeOut(duration: 0.14), value: presenter.open?.id)
    }
}

/// One tab's list; it observes the session so the counters and the activity lines stay live while it is open.
private struct TabAgentListCard: View {
    @ObservedObject var session: TerminalSession
    var animated: Bool
    var width: CGFloat
    var maxHeight: CGFloat
    var onOpen: ((SubagentActivity) -> Void)?

    var body: some View {
        SubagentList(agents: session.subagents, animated: animated, title: session.displayTitle, tint: session.tint.color,
                     width: width, maxHeight: maxHeight, dim: TabAgentListLayout.dim, onOpen: onOpen)
    }
}
