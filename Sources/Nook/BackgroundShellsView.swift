import SwiftUI

// Background shells in the island, keeping the subagents company: the commands Claude Code starts with `run_in_background` (or moves there once they
// pass their timeout), which its status line counts ("· 1 shell") and its conversation only mentions in passing. They stand where the agents do:
// a mark and a count in the composer's capsule, a section in its list (and in the list under a tab's badge, which counts them too), and a click on
// a row shows the shell's output in the mirror's place (`ShellOutputView.swift`).
//
//   ShellPalette         the colour of each state, taken from the agents' palette
//   ShellStateGlyph      its mark: Claude's own spinner while the shell runs, a check, an exclamation, a square when it was stopped
//   ShellSummary         how many shells are in each state, and BackgroundSummary what the capsule says of them and the agents together
//   ShellHint            the shells Claude's mode line counts that its record does not name, and how long such a count waits before it is believed
//   ShellWords           the words of the rows, their tooltips and the capsule's, in Spanish
//   ShellClock           a running shell's time ticks on its own: the list holds no seconds
//   ShellListLayout      the rows' heights and order (rows have fixed heights, as the agents' have, so the card's height is known before it draws)
//   ShellRow, ShellUnseenRow, ShellSectionHeader   what the list shows

// MARK: - Colours and marks

enum ShellPalette {
    /// A shell that was stopped (by Claude, the user, the system) neither finished nor failed: the island's neutral.
    static let stopped = Color.nookSecondary

    /// Running is Claude's terracotta, finished its mint, and failed its amber, as for the agents (a soft red would sit too close to the terracotta
    /// to tell a failure from a shell that works).
    static func color(_ state: ShellActivity.State) -> Color {
        switch state {
        case .running: AgentPalette.running
        case .completed: AgentPalette.done
        case .failed: AgentPalette.failedFill
        case .stopped: stopped
        }
    }
}

/// A shell's state as a mark in the row's first column: the agents' own for the three they share.
struct ShellStateGlyph: View {
    var state: ShellActivity.State
    var animated = true

    var body: some View {
        switch state {
        case .running: SubagentStateGlyph(state: .running, animated: animated)
        case .completed: SubagentStateGlyph(state: .done, animated: animated)
        case .failed: SubagentStateGlyph(state: .failed, animated: animated)
        case .stopped: Image(systemName: "stop.fill").font(.system(size: 7.5)).foregroundStyle(ShellPalette.stopped.opacity(0.9))
        }
    }
}

// MARK: - Counting

/// How many shells are in each state. The capsule and a tab's badge count these beside the agents; neither holds a duration, so they only change when a
/// shell starts or ends.
struct ShellSummary: Equatable {
    var running = 0
    /// Over without failing: finished, or stopped (`stopped` is the part of them that was stopped).
    var done = 0
    var stopped = 0
    var failed = 0
    /// Claude's mode line counts them, its record does not name them: they are not on the list, and as far as anyone knows they run.
    var unseen = 0

    /// Running, as far as is known.
    var active: Int { running + unseen }
    var total: Int { active + done + failed }

    init() {}

    init(_ shells: [ShellActivity], unseen: Int = 0) {
        for shell in shells {
            switch shell.state {
            case .running: running += 1
            case .completed: done += 1
            case .stopped: done += 1; stopped += 1
            case .failed: failed += 1
            }
        }
        self.unseen = max(0, unseen)
    }
}

/// What the composer's capsule counts: the subagents and the shells together.
struct BackgroundSummary: Equatable {
    var agents: SubagentSummary
    var shells: ShellSummary

    init(_ agents: [SubagentActivity], shells: [ShellActivity] = [], unseen: Int = 0) {
        self.agents = SubagentSummary(agents)
        self.shells = ShellSummary(shells, unseen: unseen)
    }

    /// Working now: agents at work, shells running, and the ones Claude counts and Nook cannot name.
    var running: Int { agents.running + shells.active }
    var failed: Int { agents.failed + shells.failed }
    var total: Int { agents.total + shells.total }

    /// Short on purpose, like the agents' own words: the composer's control row also holds Claude's status and the keys. "2 agentes" and "1 shell"
    /// while anything runs, joined by a dot when both do; then "3 agentes listos", "1 shell listo" or "1 con error" for the moment the capsule lingers.
    var label: String {
        guard total > 0 else { return "" }
        if running > 0 {
            return [agents.running > 0 ? Self.agents(agents.running) : nil, shells.active > 0 ? ShellWords.count(shells.active) : nil]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if failed > 0 {
            // The agents keep their words ("1 con error"); a failed shell says what it is.
            if shells.failed == 0 { return "\(agents.failed) con error" }
            if agents.failed == 0 { return "\(ShellWords.count(shells.failed)) con error" }
            return "\(failed) con error"
        }
        // Shells that were stopped, and nothing else over, are told as that ("1 shell detenido"): "listo" would say they finished.
        if agents.done == 0, shells.done == shells.stopped { return ShellWords.count(shells.stopped) + (shells.stopped == 1 ? " detenido" : " detenidos") }
        let parts = [agents.done > 0 ? Self.agents(agents.done) : nil, shells.done > 0 ? ShellWords.count(shells.done) : nil].compactMap { $0 }
        return parts.joined(separator: " · ") + (agents.done + shells.done == 1 ? " listo" : " listos")
    }

    /// What VoiceOver calls the capsule: whichever of the two it holds.
    var title: String {
        switch (agents.total > 0, shells.total > 0) {
        case (_, false): return "Agentes de Claude"
        case (false, true): return "Shells de Claude"
        case (true, true): return "Agentes y shells de Claude"
        }
    }

    private static func agents(_ count: Int) -> String { count == 1 ? "1 agente" : "\(count) agentes" }
}

/// Shells Claude's mode line counts beyond the ones its record names. The record starts from its last megabytes, so a shell started before that is
/// invisible to Nook, but not to Claude's line ("· 1 shell"): the count is a hint, and it is told as one.
enum ShellHint {
    /// A count that appears is believed after this long. The record and the screen are read on their own clocks: when a shell ends, one of them says
    /// so a moment before the other, and for that moment the line would still count a shell the record has already finished.
    static let settle = 1.5

    /// How many shells the line counts that the record does not name as running; 0 when it counts none or the record names them all.
    static func unseen(rows: [ShellActivity], screen: Int?) -> Int {
        max(0, (screen ?? 0) - rows.filter(\.isRunning).count)
    }
}

// MARK: - Words

enum ShellWords {
    /// "1 shell", "3 shells".
    static func count(_ count: Int) -> String { count == 1 ? "1 shell" : "\(count) shells" }

    /// The section's headline: "1 en curso", "3 en curso".
    static func running(_ count: Int) -> String { "\(count) en curso" }

    /// The row that stands for shells Claude counts and Nook cannot name: "1 más, lanzado antes de lo que Nook leyó" (with the named ones above it),
    /// or "2 shells, lanzados antes de lo que Nook leyó" (alone in the list).
    static func unseenRow(_ count: Int, alongside: Bool) -> String {
        (alongside ? "\(count) más" : Self.count(count)) + ", \(count == 1 ? "lanzado" : "lanzados") antes de lo que Nook leyó"
    }

    /// What the row's tooltip (and the capsule's) says about them: Nook knows how many, and not which, so it cannot open them.
    static func unseenHelp(_ count: Int) -> String {
        let one = count == 1, pronoun = one ? "lo" : "los"
        return "Claude cuenta \(Self.count(count)) que su registro no nombra: \(one ? "se lanzó" : "se lanzaron") antes de lo que Nook leyó, "
            + "así que Nook no puede abrir\(pronoun). Ábre\(pronoun) en Claude con Gestionar (↓)."
    }

    /// The row's tooltip: its name, the command (as long as it is, within reason), where it stands, and what a click does.
    static func rowHelp(_ shell: ShellActivity, opens: Bool) -> String {
        var lines = [shell.name]
        if let command = tooltipCommand(shell.command) { lines.append("$ " + command) }
        lines.append(shell.standing)
        if shell.movedToBackground { lines.append("Empezó en primer plano; Claude lo pasó a segundo plano al pasar su tiempo límite.") }
        if opens { lines.append("Clic para ver su salida") }
        return lines.joined(separator: "\n")
    }

    /// The command for a tooltip: its first lines as they are, never more than eight, and cut with an ellipsis. Nil without a command (a shell known
    /// only from its end).
    static func tooltipCommand(_ command: String) -> String? {
        let lines = command.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let kept = Array(lines.drop { $0.isEmpty })
        guard !kept.isEmpty else { return nil }
        var text = kept.prefix(8).joined(separator: "\n")
        var cut = kept.count > 8
        if text.count > 600 { text = String(text.prefix(599)); cut = true }
        return cut ? text + " …" : text
    }

    /// The capsule's tooltip lines for the shells: a mark for the state, the name, and where it stands.
    static func capsuleLines(_ shells: [ShellActivity], unseen: Int) -> [String] {
        var lines = ShellListLayout.ordered(shells).map { shell in
            let mark: String
            switch shell.state {
            case .running: mark = "●"
            case .completed: mark = "✓"
            case .failed: mark = "!"
            case .stopped: mark = "■"
            }
            return "\(mark) \(shell.name) (shell) — \(shell.standing)"
        }
        if unseen > 0 { lines.append("? " + unseenRow(unseen, alongside: !shells.isEmpty)) }
        return lines
    }
}

extension ShellActivity {
    /// Where the shell stands, for a tooltip: a running one says it runs, and a finished one how long it took. A tooltip that changed every second
    /// would be taken down by AppKit each time, so the seconds of a shell that runs are in the row and not in it.
    var standing: String { isRunning ? stateText : detail() }

    /// The command's first line as one calm line (runs of spaces collapsed, cut at 160 characters), with an ellipsis when more lines follow: what the
    /// row's second line says. Empty for a shell known only from its end.
    var commandPreview: String {
        let lines = command.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        let line = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        let capped = line.count > 160 ? String(line.prefix(159)) + "…" : line
        return lines.count > 1 ? capped + " …" : capped
    }

    /// The face its name is set in: a description in the island's own, a command (the call had no description) in the monospaced one, as a command is
    /// everywhere else in it.
    func nameFont(weight: Font.Weight) -> Font {
        isNamedByItsCommand ? .system(size: 10, weight: weight, design: .monospaced) : .system(size: 10.5, weight: weight)
    }

    /// Its name is only its command's first line (the call had no description): a second line would say the same twice.
    var isNamedByItsCommand: Bool {
        guard let first = command.components(separatedBy: "\n").lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return false }
        return name == first || (name.hasSuffix("…") && first.hasPrefix(String(name.dropLast())))
    }

    /// Whether the list gives the shell a second line, with its command. Only a running shell has one, and only when the name does not already say it:
    /// a finished shell's command is in its tooltip.
    var showsCommandLine: Bool { isRunning && !commandPreview.isEmpty && !isNamedByItsCommand }
}

// MARK: - The clock

/// A running shell's time ticks by itself: the list holds no seconds, so a row that shows them reads the clock once a second while the shell runs, and
/// never otherwise. `ticking` false (the island is out of sight) holds it still.
struct ShellClock<Content: View>: View {
    var running: Bool
    var ticking = true
    @ViewBuilder var content: (Date) -> Content

    /// Nobody can see the island (`\.islandSeen`): the clock holds too.
    @Environment(\.islandSeen) private var seen

    var body: some View {
        if running && ticking && seen {
            TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
        } else {
            content(Date())
        }
    }
}

// MARK: - Layout

/// The shells' part of the list: the rows have fixed heights (a running shell with a command has a second line, as a working agent has), so the card's
/// height is known before it draws.
enum ShellListLayout {
    /// The section's title, under the agents.
    static let sectionHeight: CGFloat = 22
    static let rowHeight = SubagentListLayout.rowHeight
    /// A running shell: its name and, under it, its command.
    static let commandRowHeight = SubagentListLayout.workingRowHeight

    static func rowHeight(of shell: ShellActivity) -> CGFloat { shell.showsCommandLine ? commandRowHeight : rowHeight }

    /// Running shells first, then the ones that failed, then the rest. Each group keeps launch order.
    static func ordered(_ shells: [ShellActivity]) -> [ShellActivity] {
        func rank(_ shell: ShellActivity) -> Int {
            switch shell.state { case .running: 0; case .failed: 1; case .completed, .stopped: 2 }
        }
        return shells.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

// MARK: - Rows

/// One shell of the list: its state, name and time, and, while it runs, its command under it. A click enters it (shows its output in the mirror).
struct ShellRow: View {
    var shell: ShellActivity
    var animated = true
    /// The clock runs while this is true; the list only exists on screen, so nothing but the bar over the output (`ShellViewBar`) ever holds it.
    var ticking = true
    /// Makes the row a button that shows the shell's output.
    var onOpen: ((ShellActivity) -> Void)?
    @State private var hovered = false

    private static let lineHeight: CGFloat = 14
    private static let commandHeight: CGFloat = 13

    var body: some View {
        if let onOpen {
            Button { onOpen(shell) } label: { content.contentShape(Rectangle()) }
                .nookPress(.none, depth: PressDepth.row)
                .background(Color.nookWash(hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous).inset(by: 3))
                .onHover { hovered = $0 }
                .accessibilityHint("Abre la salida de este shell")
        } else { content }
    }

    private var content: some View {
        ShellClock(running: shell.isRunning, ticking: ticking) { now in
            HStack(alignment: .top, spacing: 7) {
                // What it says is in the words: VoiceOver would read the spinner's symbol out as a character.
                ShellStateGlyph(state: shell.state, animated: animated).frame(width: 13, height: Self.lineHeight).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    firstLine(now).frame(height: Self.lineHeight)
                    if shell.showsCommandLine { commandLine.frame(height: Self.commandHeight) }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: ShellListLayout.rowHeight(of: shell))
            .help(ShellWords.rowHelp(shell, opens: onOpen != nil))
            // One thing for VoiceOver to land on: the name and where the shell stands.
            .accessibilityElement(children: .combine)
        }
    }

    /// The name and, at the end of the line, the state and the time, which are short and worth more than the tail of a long name.
    private func firstLine(_ now: Date) -> some View {
        HStack(spacing: 6) {
            Text(shell.name).font(shell.nameFont(weight: shell.isRunning ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(shell.isRunning ? Color.primary : Color.nookSecondary)
            Spacer(minLength: 6)
            Text(shell.detail(at: now)).font(.system(size: 10).monospacedDigit()).foregroundStyle(shell.state == .failed ? AgentPalette.failed : Color.nookSecondary)
                .lineLimit(1).fixedSize().layoutPriority(1)
        }
    }

    /// The command, dimmed, as the agents' current call is: "⎿ $ gcloud builds submit …".
    private var commandLine: some View {
        HStack(spacing: 4) {
            Text("⎿").font(.system(size: 9)).foregroundStyle(Color.nookSecondary.opacity(0.7))
            Text("$").font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(Color.nookSecondary).fixedSize()
            Text(shell.commandPreview).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Color.nookSecondary.opacity(0.8)).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// The row for shells Claude counts and its record does not name. Nobody knows which they are, so there is nothing to open: it says how many, and why
/// they cannot be entered.
struct ShellUnseenRow: View {
    var count: Int
    /// Named shells stand above it ("1 más…"), or it is all there is ("1 shell…").
    var alongside: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "questionmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.nookSecondary.opacity(0.85)).frame(width: 13, height: 14)
            Text(ShellWords.unseenRow(count, alongside: alongside)).font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12).frame(height: ShellListLayout.rowHeight)
        .help(ShellWords.unseenHelp(count))
        .accessibilityElement(children: .combine)
    }
}

/// The title of the shells' section, under the agents: a hairline and "Shells · 1 en curso".
struct ShellSectionHeader: View {
    var active: Int

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.nookWash(0.07)).frame(height: 0.5).padding(.horizontal, 12)
            HStack(spacing: 6) {
                Text("Shells").font(.system(size: 10.5, weight: .semibold))
                if active > 0 { Text(ShellWords.running(active)).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1).fixedSize() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: ShellListLayout.sectionHeight - 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
