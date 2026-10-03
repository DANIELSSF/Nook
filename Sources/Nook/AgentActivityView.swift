import SwiftUI
import AppKit

/// Colors for subagents, taken from the island's palette.
enum AgentPalette {
    /// Claude's own spinner color (same value as `PetView.claudeSpinner`): agents at work read as Claude's work.
    static let running = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// Nook's mint accent: finished.
    static let done = Color(red: 0.32, green: 0.73, blue: 0.61)
    /// The amber of the bell: something needs a look.
    static let failed = Color(red: 0.91, green: 0.79, blue: 0.54)

    static func color(_ state: SubagentActivity.State) -> Color {
        switch state { case .running: running; case .done: done; case .failed: failed }
    }
}

/// Words for the capsule, in Spanish.
extension SubagentSummary {
    private static func agents(_ count: Int) -> String { count == 1 ? "1 agente" : "\(count) agentes" }

    /// Short on purpose: the composer's control row also holds Claude's status and the keys. The dots beside it tell the rest.
    /// "2 agentes" while any runs, then "3 agentes listos", or "1 con error" when something failed.
    var label: String {
        if running > 0 { return Self.agents(running) }
        if failed > 0 { return "\(failed) con error" }
        return Self.agents(done) + (done == 1 ? " listo" : " listos")
    }
}

// MARK: - Composer capsule

/// A small capsule in the composer's text row, at its right edge: one dot per subagent and a count. It appears while
/// agents run and lingers a little after the last one finishes; clicking it opens the list above it.
/// Takes no space when there is nothing to show.
struct SubagentCapsule: View {
    var agents: [SubagentActivity]
    var animated: Bool
    /// Keeps the capsule on screen after the agents finish; previews and tests turn it on.
    var alwaysVisible: Bool
    /// Sends ↓ to Claude, whose own task list ("↓ to manage") opens there. Hides the button when nil.
    var onManage: (() -> Void)?
    /// The tallest the list opening above the capsule may be; it follows the island's size (`PaneLayout.capsuleListMaxHeight`).
    var listMaxHeight = SubagentCapsule.listMaxHeight
    /// A click on an agent's row enters its conversation; rows are not clickable when nil.
    var onOpen: ((SubagentActivity) -> Void)?
    @State private var visible = false
    @State private var open: Bool
    @State private var overCapsule = false
    @State private var overList = false

    init(agents: [SubagentActivity], animated: Bool = true, alwaysVisible: Bool = false, initiallyOpen: Bool = false, listMaxHeight: CGFloat = SubagentCapsule.listMaxHeight,
         onManage: (() -> Void)? = nil, onOpen: ((SubagentActivity) -> Void)? = nil) {
        self.agents = agents
        self.animated = animated
        self.alwaysVisible = alwaysVisible
        self.listMaxHeight = listMaxHeight
        self.onManage = onManage
        self.onOpen = onOpen
        _open = State(initialValue: initiallyOpen)
    }

    static let height: CGFloat = 22
    /// How long the capsule stays after the last agent finishes.
    static let lingerSeconds = 25.0
    /// The tallest the list opening above the capsule may be: its bottom sits 6 pt over the capsule, and the tab row's
    /// bottom edge is about 132 pt above that, so a taller list would slide under the tabs.
    static let listMaxHeight: CGFloat = 130
    private var summary: SubagentSummary { SubagentSummary(agents) }
    private var shown: Bool { summary.total > 0 && (visible || alwaysVisible) }

    var body: some View {
        // The zero-size anchor keeps the tasks alive while the capsule itself is hidden (modifiers on an empty
        // view never run).
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
                // The capsule shows while something runs and lingers briefly once everything finished. A tab opened
                // with only old, finished agents in its history stays quiet.
                .task(id: summary) {
                    if summary.running > 0 { visible = true; return }
                    guard visible else { return }
                    try? await Task.sleep(for: .seconds(Self.lingerSeconds))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { visible = false; open = false } }
                }
                // Moving from the capsule to the list leaves both for a moment; leaving them for good closes the list.
                .task(id: overCapsule || overList) {
                    guard open, !(overCapsule || overList) else { return }
                    try? await Task.sleep(for: .seconds(0.6))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.16)) { open = false } }
                }
            if shown {
                capsule
                    .overlay(alignment: .bottomTrailing) {
                        if open {
                            SubagentList(agents: agents, animated: animated, onManage: onManage, maxHeight: listMaxHeight,
                                         onOpen: onOpen.map { open in { agent in
                                             // Entering an agent's view puts the list away with it.
                                             withAnimation(.easeOut(duration: 0.16)) { self.open = false }
                                             open(agent)
                                         } })
                                .onHover { overList = $0 }
                                // Bottom-aligned with the capsule, then lifted by its height plus a gap: the list floats above it.
                                .offset(y: -(Self.height + 6))
                                .transition(.opacity.combined(with: .offset(y: 4)))
                        }
                    }
                    .zIndex(1)
            }
        }
    }

    private var capsule: some View {
        Button { withAnimation(.easeOut(duration: 0.16)) { open.toggle() } } label: {
            HStack(spacing: 6) {
                SubagentDots(agents: agents.filter { $0.role == .agent }, animated: animated)
                Text(summary.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0)).opacity(0.7)
            }
            .foregroundStyle(summary.running > 0 ? Color.primary.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 8).frame(height: Self.height)
            .background(Color.white.opacity(open ? 0.14 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AgentPalette.running.opacity(summary.running > 0 ? 0.32 : 0), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { overCapsule = $0 }
        .help(helpText)
        .accessibilityLabel("Agentes de Claude: \(summary.label)")
    }

    private var helpText: String {
        let lines = agents.filter { $0.role == .agent }.map { agent in
            let model = AgentModelName.short(agent.model).map { " (\($0))" } ?? ""
            return "\(agent.state == .running ? "●" : agent.state == .done ? "✓" : "!") \(agent.name)\(model) — \(agent.detail)"
        }
        return lines.isEmpty ? "Agentes de Claude" : lines.joined(separator: "\n")
    }
}

/// One dot per agent, at most five: terracotta and breathing while it works, mint when done, amber when it failed.
struct SubagentDots: View {
    var agents: [SubagentActivity]
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = Array(agents.prefix(5))
        TimelineView(.animation(minimumInterval: 0.1, paused: !animated || reduceMotion || !shown.contains(where: \.isRunning))) { context in
            HStack(spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, agent in
                    let pulse = agent.isRunning && animated && !reduceMotion ? 0.62 + 0.38 * sin(context.date.timeIntervalSinceReferenceDate * 3.2 + Double(index) * 1.1) : 1
                    Circle().fill(AgentPalette.color(agent.state)).frame(width: 5.5, height: 5.5)
                        .opacity(agent.state == .done ? 0.8 : pulse)
                }
            }
        }
    }
}

// MARK: - Words for the list

/// The model a subagent runs on, as the list shows it.
enum AgentModelName {
    /// "sonnet" becomes "Sonnet" and a full id such as "claude-sonnet-4-5-20250929" becomes "Sonnet 4.5". Nil when the
    /// launch named no model, or said to use the parent's ("inherit").
    static func short(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard !lower.isEmpty, lower != "inherit", lower != "default" else { return nil }
        for family in ["opus", "sonnet", "haiku"] where lower.contains(family) {
            return family.capitalized + (version(in: lower, family: family).map { " " + $0 } ?? "")
        }
        // An unknown model keeps its own name, capitalised and kept short for the chip.
        let name = text.prefix(1).uppercased() + text.dropFirst()
        return name.count > 16 ? String(name.prefix(15)) + "…" : name
    }

    /// "claude-sonnet-4-5-20250929" gives "4.5", "claude-3-5-haiku-20241022" gives "3.5", "claude-opus-4-20250514" gives "4".
    /// A date stamp is never a minor version: the match must not be followed by another digit.
    private static func version(in id: String, family: String) -> String? {
        let patterns = ["\(family)-(\\d{1,2})(?:[-.](\\d{1,2}))?(?!\\d)", "(\\d{1,2})(?:[-.](\\d{1,2}))?-\(family)"]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
                  let major = Range(match.range(at: 1), in: id) else { continue }
            if match.numberOfRanges > 2, let minor = Range(match.range(at: 2), in: id) { return "\(id[major]).\(id[minor])" }
            return String(id[major])
        }
        return nil
    }
}

/// An agent's current tool call ("Read(Sources/Nook/Pet.swift)") split into the tool and what it works on.
enum AgentActivityLine {
    struct Parts: Equatable {
        var tool: String
        var argument: String?
        /// A path reads best cut in the middle (its end is the file); a command or a pattern, at its end.
        var isPath: Bool { argument.map { $0.contains("/") && !$0.contains(" ") } ?? false }
    }

    static func parse(_ activity: String) -> Parts {
        guard activity.hasSuffix(")"), let open = activity.firstIndex(of: "("), open != activity.startIndex else { return Parts(tool: activity) }
        let argument = String(activity[activity.index(after: open)..<activity.index(before: activity.endIndex)])
        return Parts(tool: String(activity[..<open]), argument: argument.isEmpty ? nil : argument)
    }
}

extension SubagentActivity {
    /// Whether the list gives the agent a second line, for what it is doing right now. Running agents always have
    /// it (even between tool calls), so a row never changes height as calls start and end.
    var showsActivityLine: Bool { role == .agent && state == .running }
}

// MARK: - The list

/// How the list is measured. Rows have fixed heights so the card's height is known before it draws: a card that
/// scrolls needs it, and a row that grew with every tool call would make the list jump.
enum SubagentListLayout {
    static let headerHeight: CGFloat = 24
    /// Above and below the rows.
    static let verticalPadding: CGFloat = 5
    static let rowHeight: CGFloat = 25
    /// A running agent: its name and, under it, what it is doing.
    static let workingRowHeight: CGFloat = 37

    static func rowHeight(of agent: SubagentActivity) -> CGFloat { agent.showsActivityLine ? workingRowHeight : rowHeight }

    /// The card's height with every row showing.
    static func height(of agents: [SubagentActivity]) -> CGFloat {
        headerHeight + verticalPadding * 2 + agents.reduce(0) { $0 + rowHeight(of: $1) }
    }

    /// Running agents first, then the ones that failed, then the finished ones, and messages to other agents last.
    /// Each group keeps Claude's order.
    static func ordered(_ agents: [SubagentActivity]) -> [SubagentActivity] {
        func rank(_ agent: SubagentActivity) -> Int {
            if agent.role == .message { return 3 }
            switch agent.state { case .running: return 0; case .failed: return 1; case .done: return 2 }
        }
        return agents.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// The list of a session's agents: one row per agent with its model, kind, live activity and counters. It opens above
/// the composer's capsule, or under a tab's indicator (then `title` names the tab).
struct SubagentList: View {
    var agents: [SubagentActivity]
    var animated = true
    var onManage: (() -> Void)?
    /// The tab the agents belong to, when the list does not sit beside its own composer.
    var title: String?
    var tint: Color?
    var width: CGFloat = 470
    /// The tallest the card may be; past it the rows scroll.
    var maxHeight: CGFloat?
    /// How much of the card's own dark surface lies over the glass: more where the card covers the conversation's text.
    var dim: Double = 0.6
    /// A click on a row enters that agent's own conversation (see `TerminalSession.viewedAgent`); rows are plain when nil.
    var onOpen: ((SubagentActivity) -> Void)?

    private var summary: SubagentSummary { SubagentSummary(agents) }
    private static let surface = Color(white: 0.115)

    var body: some View {
        let rows = SubagentListLayout.ordered(agents)
        let limit = maxHeight ?? .infinity
        let scrolls = SubagentListLayout.height(of: rows) > limit
        VStack(alignment: .leading, spacing: 0) {
            header
            if scrolls {
                ScrollView(.vertical) { rowStack(rows) }
                    .scrollIndicators(.automatic)
                    .frame(height: limit - SubagentListLayout.headerHeight - SubagentListLayout.verticalPadding * 2)
                    // The fade tells there is more below.
                    .nookScrollFade(active: true, surface: Self.surface)
            } else {
                rowStack(rows)
            }
        }
        .padding(.vertical, SubagentListLayout.verticalPadding)
        .frame(width: width)
        .nookGlassCard(radius: 11, dim: dim, clipsContent: scrolls, fill: Self.surface)
        .shadow(color: .black.opacity(0.55), radius: 14, y: 5)
    }

    private func rowStack(_ rows: [SubagentActivity]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { agent in SubagentRow(agent: agent, animated: animated, onOpen: agent.role == .agent ? onOpen : nil) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Agentes").font(.system(size: 10.5, weight: .semibold))
            if let title {
                HStack(spacing: 4) {
                    Circle().fill(tint ?? Color.secondary).frame(width: 5, height: 5)
                    Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            }
            if !headline.isEmpty { Text(headline).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
            Spacer(minLength: 8)
            if let onManage {
                Button(action: onManage) {
                    HStack(spacing: 4) {
                        Text("Gestionar").font(.system(size: 10))
                        Image(systemName: "arrow.down").font(.system(size: 8, weight: .semibold)).frame(width: 18, height: 14)
                            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 3))
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Abre la lista de Claude (↓ para gestionar)")
            }
        }.padding(.horizontal, 12).frame(height: SubagentListLayout.headerHeight)
    }

    private var headline: String {
        let working = summary.running
        return working > 0 ? (working == 1 ? "1 trabajando" : "\(working) trabajando") : ""
    }
}

struct SubagentRow: View {
    var agent: SubagentActivity
    var animated = true
    /// Makes the row a button that enters the agent's conversation.
    var onOpen: ((SubagentActivity) -> Void)?
    @State private var hovered = false

    private static let lineHeight: CGFloat = 14
    private static let activityHeight: CGFloat = 13

    var body: some View {
        if let onOpen {
            Button { onOpen(agent) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .background(Color.white.opacity(hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: 3))
                .onHover { hovered = $0 }
                .accessibilityHint("Abre la conversación de este agente")
        } else { content }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if agent.role == .message {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                } else { SubagentStateGlyph(state: agent.state, animated: animated) }
            }.frame(width: 13, height: Self.lineHeight)
            VStack(alignment: .leading, spacing: 1) {
                firstLine.frame(height: Self.lineHeight)
                if agent.showsActivityLine {
                    HStack(spacing: 8) {
                        activity.frame(maxWidth: .infinity, alignment: .leading)
                        counters
                    }.frame(height: Self.activityHeight)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: SubagentListLayout.rowHeight(of: agent))
        .help(helpText)
    }

    /// The name, its model and its type. A working agent's counters sit on the line below, so all three always show and a
    /// long name is cut. A finished agent's counters share the line: when everything does not fit, the type goes first and
    /// then the model, so the name is not squeezed to nothing (both tags are in the row's tooltip).
    @ViewBuilder private var firstLine: some View {
        let model = AgentModelName.short(agent.model)
        if agent.showsActivityLine {
            nameLine(model: model, kind: agent.kind)
        } else {
            ViewThatFits(in: .horizontal) {
                nameLine(model: model, kind: agent.kind)
                nameLine(model: model, kind: nil)
                nameLine(model: nil, kind: nil)
            }
        }
    }

    private func nameLine(model: String?, kind: String?) -> some View {
        HStack(spacing: 6) {
            Text(agent.name).font(.system(size: 10.5, weight: agent.state == .running ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(agent.state == .running ? Color.primary : Color.secondary)
            if let model { AgentChip(text: model, prominent: true) }
            if let kind { AgentChip(text: kind, prominent: false) }
            Spacer(minLength: 6)
            // A finished agent has one line: its counters take the end of it.
            if !agent.showsActivityLine { counters }
        }
    }

    /// The counters are short and worth more than the tail of a long description.
    private var counters: some View {
        Text(agent.detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(agent.state == .failed ? AgentPalette.failed : Color.secondary)
            .lineLimit(1).fixedSize().layoutPriority(1)
    }

    /// What the agent is doing right now, dimmed, like Claude's own nested tool lines. Between tool calls it is thinking.
    @ViewBuilder private var activity: some View {
        if let current = agent.activity {
            let parts = AgentActivityLine.parse(current)
            HStack(spacing: 4) {
                Text("⎿").font(.system(size: 9)).foregroundStyle(Color.secondary.opacity(0.7))
                Text(parts.tool).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Color.secondary).lineLimit(1).fixedSize()
                if let argument = parts.argument {
                    Text(argument).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color.secondary.opacity(0.8))
                        .lineLimit(1).truncationMode(parts.isPath ? .middle : .tail)
                }
            }
        } else if agent.toolUses != nil {
            Text("Pensando…").font(.system(size: 9.5)).foregroundStyle(Color.secondary.opacity(0.7)).lineLimit(1)
        }
    }

    var helpText: String {
        if agent.role == .message { return "Mensaje a \(agent.name)" }
        let tags = [AgentModelName.short(agent.model), agent.kind].compactMap { $0 }
        var lines = [agent.name + (tags.isEmpty ? "" : " (" + tags.joined(separator: " · ") + ")")]
        if let current = agent.activity { lines.append(current) }
        lines.append(agent.detail + (agent.background && agent.state == .running && agent.toolUses != nil ? " · en segundo plano" : ""))
        if onOpen != nil { lines.append("Clic para ver su conversación") }
        return lines.joined(separator: "\n")
    }
}

/// A small tag beside an agent's name: its model (a little brighter) or its type.
struct AgentChip: View {
    var text: String
    var prominent: Bool

    var body: some View {
        Text(text).font(.system(size: 8.5, weight: .medium)).foregroundStyle(prominent ? Color.primary.opacity(0.78) : Color.secondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(Color.white.opacity(prominent ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Claude's own spinner while an agent works, so it reads like the terminal; a check or a mark when it is over.
struct SubagentStateGlyph: View {
    var state: SubagentActivity.State
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The symbols Claude's spinner cycles through, there and back.
    private static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let interval = 0.16

    /// The spinner's symbol at `date`; `still` holds the resting frame (Reduce Motion, animations off, a hidden island).
    static func symbol(at date: Date, still: Bool) -> String {
        frames[still ? 4 : Int(date.timeIntervalSinceReferenceDate / interval) % frames.count]
    }

    var body: some View {
        switch state {
        case .running:
            let still = !animated || reduceMotion
            // Paused while still: no schedule runs for a glyph that cannot change.
            TimelineView(.animation(minimumInterval: Self.interval, paused: still)) { context in
                Text(Self.symbol(at: context.date, still: still)).font(.system(size: 13, weight: .bold)).foregroundStyle(AgentPalette.running)
            }
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AgentPalette.done.opacity(0.85))
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentPalette.failed)
        }
    }
}

// MARK: - Collapsed notch

/// A small count for the collapsed island's right wing: how many agents are running right now, next to the
/// activity symbol. `PetView` can call `AgentNotchBadge.draw` after it draws the indicator; the SwiftUI twin
/// serves the panel's own collapsed copy of the wing.
enum AgentNotchBadge {
    /// Where the badge sits relative to the wing: the symbol's top right corner, inside the 30 pt wing.
    static let size = CGSize(width: 9, height: 9)
    static let wideSize = CGSize(width: 13, height: 9)

    static func text(_ running: Int) -> String { running > 9 ? "9+" : "\(running)" }

    /// The badge's rectangle in view coordinates (origin bottom left, as `PetView` draws), or nil when nothing runs.
    static func rect(running: Int, in bounds: NSRect) -> NSRect? {
        guard running > 0 else { return nil }
        let pill = running > 9 ? wideSize : size
        return NSRect(x: bounds.width - 5 - pill.width, y: bounds.midY + 2.5, width: pill.width, height: pill.height)
    }

    /// Draws the badge: a mint pill with the count in black. Call it inside `draw(_:)`.
    static func draw(running: Int, in bounds: NSRect) {
        guard let rect = rect(running: running, in: bounds) else { return }
        // A hairline of the wing's black keeps the pill clear of the symbol it overlaps.
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -1.2, dy: -1.2), xRadius: rect.height / 2 + 1.2, yRadius: rect.height / 2 + 1.2).fill()
        NSColor(red: 0.32, green: 0.73, blue: 0.61, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7, weight: .heavy), .foregroundColor: NSColor.black]
        let label = text(running) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 0.3), withAttributes: attributes)
    }
}

/// The SwiftUI twin of `AgentNotchBadge`, for `ActivityGlyph`'s collapsed copy in `NookPanel`.
struct AgentCountBadge: View {
    var running: Int
    var body: some View {
        if running > 0 {
            Text(AgentNotchBadge.text(running))
                .font(.system(size: 7, weight: .heavy)).foregroundStyle(.black)
                .frame(width: running > 9 ? AgentNotchBadge.wideSize.width : AgentNotchBadge.size.width, height: AgentNotchBadge.size.height)
                .background(AgentPalette.done, in: Capsule())
                .overlay(Capsule().stroke(Color.black, lineWidth: 1.2).padding(-1.2))
                .accessibilityLabel(running == 1 ? "1 agente trabajando" : "\(running) agentes trabajando")
        }
    }
}
