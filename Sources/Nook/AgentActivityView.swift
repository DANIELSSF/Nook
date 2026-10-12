import SwiftUI
import AppKit

/// Colors for subagents, taken from the island's palette (`NookTheme.swift`): each is the vivid one on the dark island and a deeper one on the light.
enum AgentPalette {
    /// Claude's own spinner color (the terracotta of `PetView.claudeSpinner`): agents at work read as Claude's work. This is the one for what is drawn.
    static let running = Color.nookTerracottaFill
    /// Nook's mint accent: finished.
    static let done = Color.nookMint
    /// The amber of the bell: something needs a look. This is the one for text and icons that are read.
    static let failed = Color.nookAmber
    /// The same amber for what is only drawn (a dot, a mark): brighter on paper than the text's, which has to be deep enough to read.
    static let failedFill = Color.nookAmberFill

    /// What the state's mark is drawn in.
    static func color(_ state: SubagentActivity.State) -> Color {
        switch state { case .running: running; case .done: done; case .failed: failedFill }
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

/// A small capsule in the composer's text row, at its right edge: one dot per subagent (and one square per background shell) and a count. It appears
/// while anything runs and lingers a little after the last thing finishes; clicking it opens the list above it.
/// Takes no space when there is nothing to show.
struct SubagentCapsule: View {
    var agents: [SubagentActivity]
    /// The session's background shells, and how many Claude's mode line counts (`TerminalSession.screenShellCount`): the capsule counts them with the
    /// agents, and its list gets a section for them. Shells the record does not name are told as a hint (`ShellHint`).
    var shells: [ShellActivity]
    var screenShellCount: Int?
    var animated: Bool
    /// Keeps the capsule on screen after the agents finish; previews and tests turn it on.
    var alwaysVisible: Bool
    /// Sends ↓ to Claude, whose own task list ("↓ to manage") opens there. Hides the button when nil.
    var onManage: (() -> Void)?
    /// The tallest the list opening above the capsule may be; it follows the island's size (`PaneLayout.capsuleListMaxHeight`).
    var listMaxHeight = SubagentCapsule.listMaxHeight
    /// A click on an agent's row enters its conversation, and one on a shell's its output; rows are not clickable when nil.
    var onOpen: ((SubagentActivity) -> Void)?
    var onOpenShell: ((ShellActivity) -> Void)?
    /// How long the capsule stays once everything in it finished, and how long a count of unnamed shells waits before it is believed (tests make both short).
    var linger: Double
    var hintSettle: Double
    @State private var visible = false
    @State private var open: Bool
    @State private var overCapsule = false
    @State private var overList = false
    /// How many unnamed shells the capsule goes by: Claude's count once it has held for a moment (`ShellHint.settle`).
    @State private var believed: Int

    init(agents: [SubagentActivity], shells: [ShellActivity] = [], screenShellCount: Int? = nil, animated: Bool = true, alwaysVisible: Bool = false,
         initiallyOpen: Bool = false, listMaxHeight: CGFloat = SubagentCapsule.listMaxHeight, linger: Double = SubagentCapsule.lingerSeconds,
         hintSettle: Double = ShellHint.settle, onManage: (() -> Void)? = nil, onOpen: ((SubagentActivity) -> Void)? = nil,
         onOpenShell: ((ShellActivity) -> Void)? = nil) {
        self.agents = agents
        self.shells = shells
        self.screenShellCount = screenShellCount
        self.animated = animated
        self.alwaysVisible = alwaysVisible
        self.listMaxHeight = listMaxHeight
        self.linger = linger
        self.hintSettle = hintSettle
        self.onManage = onManage
        self.onOpen = onOpen
        self.onOpenShell = onOpenShell
        _open = State(initialValue: initiallyOpen)
        // Previews and tests show the capsule as it settles.
        _believed = State(initialValue: alwaysVisible ? ShellHint.unseen(rows: shells, screen: screenShellCount) : 0)
    }

    static let height: CGFloat = 22
    /// How long the capsule stays after the last agent or shell finishes.
    static let lingerSeconds = 25.0
    /// The tallest the list opening above the capsule may be: its bottom sits 6 pt over the capsule, and the tab row's
    /// bottom edge is about 132 pt above that, so a taller list would slide under the tabs.
    static let listMaxHeight: CGFloat = 130
    /// What Claude's line counts that the record does not name, now; it only counts for the capsule once it has held (`believed`), and stops counting at once.
    private var heard: Int { ShellHint.unseen(rows: shells, screen: screenShellCount) }
    private var unseen: Int { min(believed, heard) }
    private var summary: BackgroundSummary { BackgroundSummary(agents, shells: shells, unseen: unseen) }
    private var shown: Bool { summary.total > 0 && (visible || alwaysVisible) }

    var body: some View {
        // The zero-size anchor keeps the tasks alive while the capsule itself is hidden (modifiers on an empty
        // view never run).
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0)
                // The capsule shows while something runs and lingers briefly once everything finished. A tab opened
                // with only old, finished agents or shells in its history stays quiet.
                .task(id: summary) {
                    if summary.running > 0 { visible = true; return }
                    guard visible else { return }
                    try? await Task.sleep(for: .seconds(linger))
                    if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { visible = false; open = false } }
                }
                // A count of shells the record does not name is a hint from a line read on its own clock: it is believed once it holds, and dropped at once.
                .task(id: heard) {
                    if heard <= believed { believed = heard; return }
                    try? await Task.sleep(for: .seconds(hintSettle))
                    if !Task.isCancelled { believed = heard }
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
                            SubagentList(agents: agents, shells: shells, unseenShells: unseen, animated: animated, onManage: onManage, maxHeight: listMaxHeight,
                                         onOpen: onOpen.map { open in { agent in
                                             // Entering an agent's view puts the list away with it.
                                             withAnimation(.easeOut(duration: 0.16)) { self.open = false }
                                             open(agent)
                                         } },
                                         onOpenShell: onOpenShell.map { open in { shell in
                                             // So does entering a shell's output.
                                             withAnimation(.easeOut(duration: 0.16)) { self.open = false }
                                             open(shell)
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
                SubagentDots(agents: agents.filter { $0.role == .agent }, shells: shells, unseen: unseen, animated: animated)
                Text(summary.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0)).opacity(0.7)
            }
            .foregroundStyle(summary.running > 0 ? Color.primary.opacity(0.85) : Color.nookSecondary)
            .padding(.horizontal, 8).frame(height: Self.height)
            .background(Color.nookWash(open ? 0.14 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(AgentPalette.running.opacity(summary.running > 0 ? 0.32 : 0), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .nookPress(.squeeze, depth: PressDepth.card, strength: 0.5)
        .onHover { overCapsule = $0 }
        .help(helpText)
        .accessibilityLabel("\(summary.title): \(summary.label)")
    }

    private var helpText: String {
        var lines = agents.filter { $0.role == .agent }.map { agent in
            let model = AgentModelName.short(agent.model).map { " (\($0))" } ?? ""
            var line = "\(agent.state == .running ? "●" : agent.state == .done ? "✓" : "!") \(agent.name)\(model) — \(agent.detail)"
            // Several agents of one type read the same; what each does now tells them apart.
            if agent.isRunning, let activity = agent.activity, !activity.isEmpty { line += "\n    ⎿ \(activity)" }
            return line
        }
        lines += ShellWords.capsuleLines(shells, unseen: unseen)
        return lines.isEmpty ? "Agentes de Claude" : lines.joined(separator: "\n")
    }
}

/// One dot per agent, at most five: terracotta and breathing while it works, mint when done, amber when it failed. A background shell is a little
/// square in the same colours (grey once it was stopped); the shells Claude counts and Nook cannot name are outlined squares, which breathe in no one's
/// colour: nobody knows how they are doing. The agents come first and the shells after them, and neither crowds the other out of the five.
struct SubagentDots: View {
    var agents: [SubagentActivity]
    var shells: [ShellActivity] = []
    /// Shells Claude's mode line counts that its record does not name.
    var unseen = 0
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nobody can see the island (`\.islandSeen`): what moves here pauses.
    @Environment(\.islandSeen) private var seen

    /// One mark of the capsule.
    struct Mark: Identifiable, Equatable {
        enum Kind: Equatable { case agent, shell, unnamedShell }
        var id: String
        var kind: Kind
        var color: Color
        var running: Bool
        /// A finished agent is drawn a little dimmer.
        var dim = false
    }

    static let limit = 5

    /// The marks the capsule shows: at most five, the agents first. The shells keep room for two when there are agents beside them (more when the agents
    /// leave places free), and an agent that does not fit is left out before a shell is.
    static func marks(agents: [SubagentActivity], shells: [ShellActivity], unseen: Int) -> [Mark] {
        let ordered = ShellListLayout.ordered(shells)
        let wanted = ordered.count + unseen
        let shellPlaces = min(wanted, max(2, limit - agents.count))
        let agentPlaces = min(agents.count, limit - shellPlaces)
        var marks = agents.prefix(agentPlaces).map { agent in
            Mark(id: "a:" + agent.id, kind: .agent, color: AgentPalette.color(agent.state), running: agent.isRunning, dim: agent.state == .done)
        }
        let named = min(ordered.count, shellPlaces)
        marks += ordered.prefix(named).map { shell in
            Mark(id: "s:" + shell.id, kind: .shell, color: ShellPalette.color(shell.state), running: shell.isRunning, dim: shell.state != .running && shell.state != .failed)
        }
        marks += (0..<min(unseen, shellPlaces - named)).map { Mark(id: "u:\($0)", kind: .unnamedShell, color: AgentPalette.running, running: false) }
        return marks
    }

    var body: some View {
        // The marks pulse by themselves, ten times a second while one works: each is an AppKit view of its own in the row (`AgentMarkView`), so a
        // frame repaints only them; and nothing runs while nobody can see the island (`\.islandSeen`).
        Self.markRow(Self.marks(agents: agents, shells: shells, unseen: unseen), pulsing: animated && !reduceMotion, seen: seen)
    }

    /// The marks side by side, three points apart, each an AppKit view in the place its shape had.
    static func markRow(_ marks: [Mark], pulsing: Bool, seen: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                AgentMark(mark: mark, index: index, pulsing: pulsing, seen: seen)
            }
        }
    }

    /// How opaque the mark at `index` is at `time`: a running one pulses (each a little after the one before), a finished agent is dimmer.
    static func opacity(of mark: Mark, at index: Int, time: Double, pulsing: Bool) -> Double {
        if mark.dim { return 0.8 }
        return mark.running && pulsing ? 0.62 + 0.38 * sin(time * 3.2 + Double(index) * 1.1) : 1
    }

    /// The side of a mark's square.
    static func side(_ kind: Mark.Kind) -> CGFloat { kind == .shell ? 5 : 5.5 }

    @ViewBuilder static func shape(_ mark: Mark) -> some View {
        switch mark.kind {
        case .agent:
            Circle().fill(mark.color).frame(width: side(.agent), height: side(.agent))
        case .shell:
            RoundedRectangle(cornerRadius: 1.4, style: .continuous).fill(mark.color).frame(width: side(.shell), height: side(.shell))
        case .unnamedShell:
            RoundedRectangle(cornerRadius: 1.4, style: .continuous).strokeBorder(mark.color.opacity(0.85), lineWidth: 1).frame(width: side(.unnamedShell), height: side(.unnamedShell))
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
        /// Words and not a call: no argument, and more than one word ("Reading NotchController expand…"). A bare tool name ("Read") is a call.
        var isPhrase: Bool { argument == nil && tool.contains(" ") }
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
    var showsActivityLine: Bool { role == .agent && state == .running && !showsInlineActivity }

    /// A working agent of Claude's own list: its name is only its type and what it does is the point, so both go on one line, and three of them
    /// fit where two with a line each would not.
    var showsInlineActivity: Bool { isListOnly && role == .agent && state == .running && !(activity ?? "").isEmpty }

    /// The agent's type, when it says something the name does not. A row of the list Claude draws under its mode line has no description:
    /// its name is its type ("fork", "coder"), and a tag repeating the name would only be noise.
    var distinctKind: String? {
        guard let kind, !kind.isEmpty, kind.caseInsensitiveCompare(name) != .orderedSame else { return nil }
        return kind
    }

    /// Read from that list alone, with no record behind it: there is no conversation of its own to open, and it may lack a model and counters.
    var isListOnly: Bool { id.hasPrefix("tree:") }

    /// The agent in a line that names several (the collapsed island's tooltip): its name, and, for one read from Claude's list, what it does,
    /// because its name is only its type and would read the same three times ("fork · Reading NotchController expand…").
    var pillLabel: String {
        guard isListOnly, let activity, !activity.isEmpty else { return name }
        return "\(name) · \(activity)"
    }
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

    /// The card's height with every row showing. The shells (`ShellListLayout`) come after the agents, with a title of their own when agents stand above
    /// them; and `unseen`, the shells Claude counts and Nook cannot name, are one more row.
    static func height(of agents: [SubagentActivity], shells: [ShellActivity] = [], unseen: Int = 0) -> CGFloat {
        var height = headerHeight + verticalPadding * 2 + agents.reduce(0) { $0 + rowHeight(of: $1) }
        if !agents.isEmpty, !shells.isEmpty || unseen > 0 { height += ShellListLayout.sectionHeight }
        height += shells.reduce(0) { $0 + ShellListLayout.rowHeight(of: $1) }
        if unseen > 0 { height += ShellListLayout.rowHeight }
        return height
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

/// The list of a session's agents: one row per agent with its model, kind, live activity and counters; under them, when there are any, a section for
/// its background shells (`ShellRow`). It opens above the composer's capsule, or under a tab's indicator (then `title` names the tab).
struct SubagentList: View {
    var agents: [SubagentActivity]
    /// The session's background shells, and how many more Claude's mode line counts than its record names (one row says so). With no agents the list's
    /// own title says "Shells".
    var shells: [ShellActivity] = []
    var unseenShells = 0
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
    /// A click on a shell's row shows its output (see `TerminalSession.viewedShell`); rows are plain when nil.
    var onOpenShell: ((ShellActivity) -> Void)?

    private var summary: SubagentSummary { SubagentSummary(agents) }
    private static let surface = Color.nookCard

    var body: some View {
        let rows = SubagentListLayout.ordered(agents)
        let shellRows = ShellListLayout.ordered(shells)
        let limit = maxHeight ?? .infinity
        let scrolls = SubagentListLayout.height(of: rows, shells: shellRows, unseen: unseenShells) > limit
        VStack(alignment: .leading, spacing: 0) {
            header
            if scrolls {
                ScrollView(.vertical) { rowStack(rows, shellRows) }
                    .scrollIndicators(.automatic)
                    .frame(height: limit - SubagentListLayout.headerHeight - SubagentListLayout.verticalPadding * 2)
                    // The fade tells there is more below.
                    .nookScrollFade(active: true, surface: Self.surface)
            } else {
                rowStack(rows, shellRows)
            }
        }
        .padding(.vertical, SubagentListLayout.verticalPadding)
        .frame(width: width)
        .nookGlassCard(radius: 11, dim: dim, clipsContent: scrolls, fill: Self.surface)
        // It floats over the conversation (above the composer, or from the tab row): the arrow shows over it, not the text's I-beam.
        .pointerHole()
        .nookCardShadow(0.55, radius: 14, y: 5)
    }

    private func rowStack(_ rows: [SubagentActivity], _ shellRows: [ShellActivity]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // An agent read from Claude's own list has no record to open: its row is plain, and its tooltip says how to reach it.
            ForEach(rows) { agent in SubagentRow(agent: agent, animated: animated, onOpen: agent.role == .agent && !agent.isListOnly ? onOpen : nil) }
            if !shellRows.isEmpty || unseenShells > 0 {
                // Under agents the shells have a title of their own; alone they have the list's.
                if !rows.isEmpty { ShellSectionHeader(active: shellSummary.active) }
                ForEach(shellRows) { shell in ShellRow(shell: shell, animated: animated, onOpen: onOpenShell) }
                // Nobody knows which these are, so the row is plain: it says how many, and its tooltip why they cannot be entered.
                if unseenShells > 0 { ShellUnseenRow(count: unseenShells, alongside: !shellRows.isEmpty) }
            }
        }
    }

    private var shellSummary: ShellSummary { ShellSummary(shells, unseen: unseenShells) }

    private var header: some View {
        HStack(spacing: 6) {
            Text(agents.isEmpty && (!shells.isEmpty || unseenShells > 0) ? "Shells" : "Agentes").font(.system(size: 10.5, weight: .semibold))
            if let title {
                HStack(spacing: 4) {
                    Circle().fill(tint ?? Color.nookSecondary).frame(width: 5, height: 5)
                    Text(title).font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).lineLimit(1).truncationMode(.tail)
                }.frame(maxWidth: 180, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            }
            if !headline.isEmpty { Text(headline).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1).fixedSize() }
            Spacer(minLength: 8)
            if let onManage {
                Button(action: onManage) {
                    HStack(spacing: 4) {
                        Text("Gestionar").font(.system(size: 10))
                        Image(systemName: "arrow.down").font(.system(size: 8, weight: .semibold)).frame(width: 18, height: 14)
                            .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 3))
                    }.foregroundStyle(Color.nookSecondary)
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).help("Abre la lista de Claude (↓ para gestionar)")
            }
        }.padding(.horizontal, 12).frame(height: SubagentListLayout.headerHeight)
    }

    private var headline: String {
        // Agents give the list its headline; with none, it is the shells'.
        if agents.isEmpty { return shellSummary.active > 0 ? ShellWords.running(shellSummary.active) : "" }
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
                .nookPress(.none, depth: PressDepth.row)
                .background(Color.nookWash(hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: 3))
                .onHover { hovered = $0 }
                .accessibilityHint("Abre la conversación de este agente")
        } else { content }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 7) {
            Group {
                if agent.role == .message {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.nookSecondary)
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
            nameLine(model: model, kind: agent.distinctKind)
        } else {
            ViewThatFits(in: .horizontal) {
                nameLine(model: model, kind: agent.distinctKind)
                nameLine(model: model, kind: nil)
                nameLine(model: nil, kind: nil)
            }
        }
    }

    private func nameLine(model: String?, kind: String?) -> some View {
        HStack(spacing: 6) {
            Text(agent.name).font(.system(size: 10.5, weight: agent.state == .running ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(agent.state == .running ? Color.primary : Color.nookSecondary)
                .layoutPriority(agent.showsInlineActivity ? 1 : 0)
            if let model { AgentChip(text: model, prominent: true) }
            if let kind { AgentChip(text: kind, prominent: false) }
            // Claude's words for what it does, as its own list prints them after the name; they give way before anything else on the line.
            if agent.showsInlineActivity, let phrase = agent.activity {
                Text(phrase).font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            // A finished agent has one line: its counters take the end of it.
            if !agent.showsActivityLine { counters }
        }
    }

    /// The counters are short and worth more than the tail of a long description.
    private var counters: some View {
        Text(agent.detail).font(.system(size: 10).monospacedDigit()).foregroundStyle(agent.state == .failed ? AgentPalette.failed : Color.nookSecondary)
            .lineLimit(1).fixedSize().layoutPriority(1)
    }

    /// What the agent is doing right now, dimmed, like Claude's own nested tool lines. Between tool calls it is thinking.
    @ViewBuilder private var activity: some View {
        if let current = agent.activity {
            let parts = AgentActivityLine.parse(current)
            HStack(spacing: 4) {
                Text("⎿").font(.system(size: 9)).foregroundStyle(Color.nookSecondary.opacity(0.7))
                if parts.isPhrase {
                    // Claude's own words for what an agent of its list does ("Reading NotchController expand and keepIslandWithTerminal"): a sentence, not a call.
                    Text(parts.tool).font(.system(size: 9.5)).foregroundStyle(Color.nookSecondary).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(parts.tool).font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Color.nookSecondary).lineLimit(1).fixedSize()
                    if let argument = parts.argument {
                        Text(argument).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color.nookSecondary.opacity(0.8))
                            .lineLimit(1).truncationMode(parts.isPath ? .middle : .tail)
                    }
                }
            }
        } else if agent.toolUses != nil {
            Text("Pensando…").font(.system(size: 9.5)).foregroundStyle(Color.nookSecondary.opacity(0.7)).lineLimit(1)
        }
    }

    var helpText: String {
        if agent.role == .message { return "Mensaje a \(agent.name)" }
        let tags = [AgentModelName.short(agent.model), agent.kind].compactMap { $0 }
        var lines = [agent.name + (tags.isEmpty ? "" : " (" + tags.joined(separator: " · ") + ")")]
        if let current = agent.activity { lines.append(current) }
        lines.append(agent.detail + (agent.background && agent.state == .running && agent.toolUses != nil ? " · en segundo plano" : ""))
        if onOpen != nil { lines.append("Clic para ver su conversación") }
        else if agent.isListOnly, agent.role == .agent { lines.append("Claude no guarda su conversación aparte: ábrela en Claude con Gestionar (↓).") }
        return lines.joined(separator: "\n")
    }
}

/// A small tag beside an agent's name: its model (a little brighter) or its type.
struct AgentChip: View {
    var text: String
    var prominent: Bool

    var body: some View {
        Text(text).font(.system(size: 8.5, weight: .medium)).foregroundStyle(prominent ? Color.primary.opacity(0.78) : Color.nookSecondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(Color.nookWash(prominent ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Claude's own spinner while an agent works, so it reads like the terminal; a check or a mark when it is over.
struct SubagentStateGlyph: View {
    var state: SubagentActivity.State
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nobody can see the island (`\.islandSeen`): what moves here pauses.
    @Environment(\.islandSeen) private var seen
    /// The symbols Claude's spinner cycles through, there and back.
    static let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    static let interval = 0.16

    /// The spinner's symbol at `date`; `still` holds the resting frame (Reduce Motion, animations off, a hidden island).
    static func symbol(at date: Date, still: Bool) -> String {
        frames[still ? 4 : Int(date.timeIntervalSinceReferenceDate / interval) % frames.count]
    }

    var body: some View {
        switch state {
        case .running:
            // Turned by an AppKit view of its own (`SpinnerGlyphView`), which repaints only itself; still with Reduce Motion or the
            // animations off, and paused while nobody can see the island (`\.islandSeen`).
            SpinnerGlyph(size: 13, color: AgentPalette.running, still: !animated || reduceMotion, seen: seen)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(AgentPalette.done.opacity(0.85))
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(AgentPalette.failedFill)
        }
    }
}

// MARK: - Spinners and pulses that paint themselves
//
// Claude's spinner symbol (a tab's badge, an agent's row, a shell's row) and the capsule's pulsing marks move by themselves while agents work,
// six and ten times a second. As `TimelineView`s each of those frames rendered the island's whole hosting view: measured, two agents at work
// kept a core busy (at the priority the tests run at), against next to nothing for the same island with them still. Here they are AppKit views
// that repaint only themselves, and what they paint is SwiftUI's own picture: each symbol, and each mark, is rendered once by `ImageRenderer`
// from the very view it replaces, at the screen's scale, and a frame only chooses which picture to show and how opaque. So they look exactly as
// they did. Each frame is the clock's (`IslandClock`), so one that was paused shows the right moment when it is seen again.

/// Claude's spinner symbol in SwiftUI: the AppKit view that turns it. It takes the size the `Text` of its symbols takes: their line's height,
/// and the width it is given (every place it is used sets one, and the symbol is centred in it as a `Text` is in such a frame).
struct SpinnerGlyph: NSViewRepresentable {
    var size: CGFloat
    var color: Color
    var still: Bool
    var seen: Bool

    func makeNSView(context: Context) -> SpinnerGlyphView { SpinnerGlyphView(frame: .zero) }
    func updateNSView(_ view: SpinnerGlyphView, context: Context) {
        view.show(size: size, color: color, scheme: context.environment.colorScheme, still: still, running: seen)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinnerGlyphView, context: Context) -> CGSize? {
        nsView.fit(width: proposal.width, size: size)
    }
}

/// The spinner itself: the symbols as SwiftUI draws them (rendered once each), the one of the moment shown, a new one every 0.16 s while it
/// turns and can be seen, on one clock for all the spinners on show. It takes no clicks and is no element of its own for VoiceOver (the row
/// or the badge speaks for it).
final class SpinnerGlyphView: NSView, IslandTicking {
    /// The clock of every spinner that turns.
    static let clock = IslandTicker(every: SubagentStateGlyph.interval)
    private(set) var size: CGFloat = 13
    private(set) var color = AgentPalette.running
    private(set) var scheme = ColorScheme.dark
    private(set) var still = false
    private(set) var running = false
    /// The width the place it sits in gives it.
    private(set) var boxWidth: CGFloat = 0
    private var pictures: [String: CGImage] = [:]
    private var picturedScale: CGFloat = 0
    private var shown: String?
    /// It is on the clock: it turns, it is in a window and the island can be seen.
    private(set) var onClock = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }

    /// The height of the line a `Text` of these symbols takes, and the widest of them.
    static func natural(_ size: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let sizes = SubagentStateGlyph.frames.map { NSAttributedString(string: $0, attributes: [.font: font]).size() }
        return CGSize(width: sizes.map(\.width).max() ?? size, height: sizes.map(\.height).max() ?? size)
    }

    func fit(width proposed: CGFloat?, size: CGFloat) -> CGSize {
        let natural = Self.natural(size)
        // A width it is not meant to fill (SwiftUI asking how far it could stretch) gets the widest symbol's, as a `Text` would answer.
        let width = proposed.flatMap { $0.isFinite && $0 > 0 && $0 <= natural.width * 3 ? $0 : nil } ?? natural.width
        if width != boxWidth { boxWidth = width; pictures = [:]; needsDisplay = true }
        return CGSize(width: width, height: natural.height)
    }

    func show(size: CGFloat, color: Color, scheme: ColorScheme, still: Bool, running: Bool) {
        if size != self.size || color != self.color || scheme != self.scheme { pictures = [:]; needsDisplay = true }
        // Back in sight, or turning again: the symbol of this moment at once.
        if (running && !self.running) || still != self.still { needsDisplay = true }
        self.size = size; self.color = color; self.scheme = scheme; self.still = still; self.running = running
        schedule()
    }

    private func schedule() {
        onClock = window != nil && running && !still
        if onClock { Self.clock.add(self) } else { Self.clock.remove(self) }
    }

    func islandTick() {
        if SubagentStateGlyph.symbol(at: IslandClock.now(), still: still) != shown { needsDisplay = true }
    }

    /// The picture SwiftUI makes of `symbol` in this view's box: the `Text` it replaces, centred in the width it is given.
    private func picture(_ symbol: String, scale: CGFloat) -> CGImage? {
        if scale != picturedScale { pictures = [:]; picturedScale = scale }
        if let picture = pictures[symbol] { return picture }
        let width = boxWidth > 0 ? boxWidth : Self.natural(size).width
        let renderer = ImageRenderer(content: Text(symbol).font(.system(size: size, weight: .bold)).foregroundStyle(color)
            .frame(width: width, height: Self.natural(size).height).environment(\.colorScheme, scheme))
        renderer.scale = scale
        let picture = renderer.cgImage
        pictures[symbol] = picture
        return picture
    }

    override func draw(_ dirtyRect: NSRect) {
        let symbol = SubagentStateGlyph.symbol(at: IslandClock.now(), still: still)
        shown = symbol
        guard let cg = NSGraphicsContext.current?.cgContext, let picture = picture(symbol, scale: window?.backingScaleFactor ?? 2) else { return }
        let scale = window?.backingScaleFactor ?? 2
        cg.drawOnPixels(picture, topLeft: CGPoint(x: 0, y: bounds.height), size: CGSize(width: CGFloat(picture.width) / scale, height: CGFloat(picture.height) / scale))
    }
}

/// One of the capsule's marks in SwiftUI: the AppKit view that paints it, in the place in the row the shape it replaces had.
struct AgentMark: NSViewRepresentable {
    var mark: SubagentDots.Mark
    /// Its place in the row: each mark pulses a little after the one before.
    var index: Int
    /// Whether a running mark pulses at all (the animations on, Reduce Motion off).
    var pulsing: Bool
    var seen: Bool

    func makeNSView(context: Context) -> AgentMarkView { AgentMarkView(frame: .zero) }
    func updateNSView(_ view: AgentMarkView, context: Context) {
        view.show(mark, index: index, scheme: context.environment.colorScheme, pulsing: pulsing, running: seen)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentMarkView, context: Context) -> CGSize? {
        let side = SubagentDots.side(mark.kind)
        return CGSize(width: side, height: side)
    }
}

/// A mark itself: the shape as SwiftUI paints it (rendered once), at the opacity of the moment; ten frames a second while it works and the island
/// can be seen, on one clock for all of them (`IslandTicker`). It takes no clicks (the capsule's button does) and is no element for VoiceOver.
final class AgentMarkView: NSView, IslandTicking {
    /// The clock of every mark that pulses.
    static let clock = IslandTicker(every: AgentMarkView.interval)
    private(set) var mark = SubagentDots.Mark(id: "", kind: .agent, color: AgentPalette.running, running: false)
    private(set) var index = 0
    private(set) var scheme = ColorScheme.dark
    private(set) var pulsing = true
    private(set) var running = false
    private var picture: CGImage?
    private var picturedScale: CGFloat = 0
    /// It is on the clock: it works, it pulses, it is in a window and the island can be seen.
    private(set) var onClock = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }

    func show(_ mark: SubagentDots.Mark, index: Int, scheme: ColorScheme, pulsing: Bool, running: Bool) {
        if mark != self.mark || scheme != self.scheme { picture = nil; needsDisplay = true }
        if index != self.index || pulsing != self.pulsing || (running && !self.running) { needsDisplay = true }
        self.mark = mark; self.index = index; self.scheme = scheme; self.pulsing = pulsing; self.running = running
        schedule()
    }

    private func schedule() {
        onClock = window != nil && running && pulsing && mark.running
        if onClock { Self.clock.add(self) } else { Self.clock.remove(self) }
    }

    func islandTick() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        if picture == nil || scale != picturedScale {
            let renderer = ImageRenderer(content: SubagentDots.shape(mark).environment(\.colorScheme, scheme))
            renderer.scale = scale
            picture = renderer.cgImage; picturedScale = scale
        }
        guard let picture else { return }
        cg.setAlpha(SubagentDots.opacity(of: mark, at: index, time: IslandClock.now().timeIntervalSinceReferenceDate, pulsing: pulsing))
        cg.drawOnPixels(picture, topLeft: CGPoint(x: 0, y: bounds.height), size: CGSize(width: CGFloat(picture.width) / scale, height: CGFloat(picture.height) / scale))
    }
}

extension AgentMarkView {
    /// The frame rate the marks' `TimelineView` had.
    static let interval = 0.1
}

extension CGContext {
    /// Draws `picture` (`size` points) with its top left corner at `topLeft` (user space, y up) moved onto the nearest whole pixel. SwiftUI puts
    /// what it paints on whole pixels; a view of ours can sit between two (SwiftUI lays it out at fractional points), and a picture drawn there
    /// would be resampled, a shade off along its edges from the one SwiftUI painted.
    func drawOnPixels(_ picture: CGImage, topLeft: CGPoint, size: CGSize) {
        let device = convertToDeviceSpace(topLeft)
        let corner = convertToUserSpace(CGPoint(x: device.x.rounded(), y: device.y.rounded()))
        draw(picture, in: CGRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height))
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
        NookPalette.mintOnBlack.setFill()
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
                .background(Color(nsColor: NookPalette.mintOnBlack), in: Capsule())
                .overlay(Capsule().stroke(Color.black, lineWidth: 1.2).padding(-1.2))
                .accessibilityLabel(running == 1 ? "1 agente trabajando" : "\(running) agentes trabajando")
        }
    }
}
