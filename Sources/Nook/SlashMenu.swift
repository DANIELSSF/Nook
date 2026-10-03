import SwiftUI
import AppKit

// The "/" menu above Nook's composer. `AppModel.completions` decides which commands match and in what order; this file
// only decides what the keys do (`SlashMenuState`, plain values with no view in them) and how the rows look
// (`SlashMenuView`).

// MARK: - State

/// What the menu shows: the commands that match the draft, the highlighted row, and whether Esc closed it. The draft
/// changing (`update`) always brings it back, with the first row highlighted.
struct SlashMenuState: Equatable {
    enum Key: Equatable { case up, down, tab, enter, escape }

    enum Outcome: Equatable {
        /// The menu is not showing: the key keeps its usual meaning in the field.
        case ignored
        /// The key was the menu's (the highlight moved, or the menu closed).
        case handled
        /// Put this text in the field and let the user keep typing.
        case fill(String)
        /// Send this text now.
        case send(String)
    }

    /// How many rows the menu shows before it scrolls in the Normal island: the menu floats over the conversation above the
    /// composer, and this many rows are as much as fits there without reaching the tab row. The island's size
    /// decides how many it shows in another one (`PaneLayout.slashRows`, which gives this for the Normal island).
    static let visibleRows = 5

    private(set) var items: [SlashCommand] = []
    private(set) var highlighted = 0
    /// The first row of the window the list is scrolled to; keys keep the highlighted row inside it.
    private(set) var top = 0
    private(set) var closed = false
    /// The rows the menu shows now (see `visibleRows`); `setVisibleRows` follows the island's size.
    private(set) var visible = SlashMenuState.visibleRows

    var isVisible: Bool { !closed && !items.isEmpty }
    var current: SlashCommand? { isVisible && items.indices.contains(highlighted) ? items[highlighted] : nil }

    /// A new draft: its matches (empty when it is not a command being typed), the first row highlighted, the menu open.
    mutating func update(_ matches: [SlashCommand]) {
        items = matches
        highlighted = 0
        top = 0
        closed = false
    }

    /// What a key does while the menu shows. Arrows wrap around, as in Claude's own menu.
    mutating func press(_ key: Key) -> Outcome {
        guard let current else { return .ignored }
        switch key {
        case .up: highlight((highlighted + items.count - 1) % items.count); return .handled
        case .down: highlight((highlighted + 1) % items.count); return .handled
        case .tab: return .fill(Self.completion(of: current))
        case .enter: return .send(current.text)
        case .escape: closed = true; return .handled
        }
    }

    private mutating func highlight(_ index: Int) {
        highlighted = index
        top = Self.scrollTop(keeping: index, from: top, count: items.count, visible: visible)
    }

    /// The island changed size: the window of rows is as tall as the menu now is, with the highlighted row still in it.
    mutating func setVisibleRows(_ rows: Int) {
        guard rows != visible else { return }
        visible = max(1, rows)
        top = Self.scrollTop(keeping: highlighted, from: top, count: items.count, visible: visible)
    }

    /// Where the window of `visible` rows starts so that `index` is in it, moving it as little as possible. The highlighted
    /// row keeps a row of context on each side (the next row also keeps it clear of the fade at the bottom), except at the
    /// ends of the list, where the window stops.
    static func scrollTop(keeping index: Int, from top: Int, count: Int, visible: Int = visibleRows, margin: Int = 1) -> Int {
        guard count > visible else { return 0 }
        let last = count - visible
        var top = min(max(top, 0), last)
        let above = index > 0 ? margin : 0, below = index < count - 1 ? margin : 0
        if index - above < top { top = index - above }
        else if index + below > top + visible - 1 { top = index + below - (visible - 1) }
        return min(max(top, 0), last)
    }

    /// What the field holds after Tab or a click: the name and a space, so the menu closes and arguments can follow.
    static func completion(of command: SlashCommand) -> String { command.text + " " }

    private static let separators: Set<Character> = [":", "-", "_", "."]

    /// The part of a name the typed text stands for, to emphasise it: from the start of the name (or of a word in it),
    /// ignoring case and separators on both sides, like the matching itself ("adddir" covers "add-dir", "res" covers
    /// the "res" of "codex:rescue"). Nil when the name's own letters do not match (an alias did).
    static func matchedRange(in name: String, query: String) -> Range<String.Index>? {
        let wanted = query.lowercased().filter { !separators.contains($0) }
        guard !wanted.isEmpty else { return nil }
        var starts = [name.startIndex]
        var previous: Character?
        for index in name.indices {
            if let previous, separators.contains(previous), !separators.contains(name[index]) { starts.append(index) }
            previous = name[index]
        }
        for start in starts {
            var cursor = start, end = start, matched = true
            for letter in wanted {
                while cursor < name.endIndex, separators.contains(name[cursor]) { cursor = name.index(after: cursor) }
                guard cursor < name.endIndex, name[cursor].lowercased() == String(letter) else { matched = false; break }
                cursor = name.index(after: cursor); end = cursor
            }
            if matched { return start..<end }
        }
        return nil
    }
}

// MARK: - View

/// The menu itself: one row per command, the highlighted one tinted mint (the user's color, as the prompt card's current
/// option), and a list that scrolls when there are more than `visibleRows`. It never takes the keyboard: the field keeps
/// it, and the keys arrive through `SlashMenuState`.
struct SlashMenuView: View {
    var commands: [SlashCommand]
    var highlighted: Int
    /// The row the list is scrolled to (see `SlashMenuState.top`).
    var top = 0
    /// What the user typed after the slash, emphasised in each name.
    var query = ""
    /// Rows shown before the list scrolls (`SlashMenuState.visible`).
    var visibleRows = SlashMenuView.visibleRows
    var onPick: (SlashCommand) -> Void = { _ in }
    @State private var hovered: String?
    @State private var list: ListMetrics

    init(commands: [SlashCommand], highlighted: Int, top: Int = 0, query: String = "", visibleRows: Int = SlashMenuView.visibleRows, onPick: @escaping (SlashCommand) -> Void = { _ in }) {
        self.commands = commands
        self.highlighted = highlighted
        self.top = top
        self.query = query
        self.visibleRows = visibleRows
        self.onPick = onPick
        // The list's height is known before SwiftUI measures it, so the first frame already fades a list that overflows.
        _list = State(initialValue: ListMetrics(offset: 0, height: CGFloat(commands.count) * (Self.rowHeight + Self.rowGap) - Self.rowGap))
    }

    static let rowHeight: CGFloat = 21
    static let rowGap: CGFloat = 1
    static let inset: CGFloat = 4
    static let radius: CGFloat = 14
    /// Between the menu's bottom edge and the composer.
    static let gap: CGFloat = 5
    static let visibleRows = SlashMenuState.visibleRows
    private static let mint = Color(red: 0.32, green: 0.73, blue: 0.61)
    private static let viewport = "slashMenuList"
    /// The widest the name-and-arguments column gets; descriptions start after it.
    private static let leadCap: CGFloat = 200
    private static let nameCap: CGFloat = 300
    private static let noteCap: CGFloat = 96
    private static let noteGap: CGFloat = 7

    // The monospaced faces' character widths, to size the name column without measuring every row.
    private static func advance(of font: NSFont) -> CGFloat { NSAttributedString(string: "0", attributes: [.font: font]).size().width }
    private static let nameAdvance = advance(of: .monospacedSystemFont(ofSize: 12, weight: .medium))
    private static let noteAdvance = advance(of: .monospacedSystemFont(ofSize: 10.5, weight: .regular))

    /// The height the list takes: whole rows up to `visible`.
    static func listHeight(rows: Int, visible: Int = visibleRows) -> CGFloat {
        let shown = CGFloat(min(max(rows, 0), max(visible, 1)))
        return shown * (rowHeight + rowGap) - (shown > 0 ? rowGap : 0)
    }

    /// The whole menu's height for this many commands.
    static func height(rows: Int, visible: Int = visibleRows) -> CGFloat { listHeight(rows: rows, visible: visible) + 2 * inset }

    var body: some View {
        rows
            .padding(Self.inset).frame(maxWidth: .infinity)
            .nookGlassCard(radius: Self.radius, dim: 1, dimColor: Color(white: 0.08), clipsContent: true, fill: Color(white: 0.08), stroke: Color.white.opacity(0.1))
            .shadow(color: .black.opacity(0.55), radius: 14, y: 5)
            .accessibilityElement(children: .contain).accessibilityLabel("Comandos")
    }

    @ViewBuilder private var rows: some View {
        let lead = leadWidth
        let currentID = commands.indices.contains(highlighted) ? commands[highlighted].id : nil
        let stack = LazyVStack(spacing: Self.rowGap) {
            ForEach(commands) { command in row(command, current: command.id == currentID, lead: lead) }
        }
        let height = Self.listHeight(rows: commands.count, visible: visibleRows)
        if commands.count > visibleRows {
            ScrollViewReader { proxy in
                ScrollView {
                    // An overlay, not a background: a background's preference never reaches `onPreferenceChange` here.
                    stack.overlay(GeometryReader { geometry in
                        Color.clear.preference(key: ListMetricsKey.self, value: ListMetrics(offset: -geometry.frame(in: .named(Self.viewport)).minY, height: geometry.size.height))
                    }.allowsHitTesting(false))
                }
                .coordinateSpace(name: Self.viewport).scrollIndicators(.hidden)
                .onPreferenceChange(ListMetricsKey.self) { if $0.height > 0 { list = $0 } }
                .frame(height: height)
                // More below: the last row fades out instead of ending in a cut.
                .nookScrollFade(active: list.height - list.offset - height > 2, height: 20, surface: Color(white: 0.08))
                // Keys, and a new list, bring the window the state chose back (also after the wheel moved it). Not animated:
                // like a native menu, and the highlight never trails behind a scroll.
                .onChange(of: ScrollTarget(top: top, highlighted: highlighted, first: commands.first?.id, count: commands.count)) { _, _ in
                    if commands.indices.contains(top) { proxy.scrollTo(commands[top].id, anchor: .top) }
                }
            }
        } else {
            stack.frame(height: height, alignment: .top)
        }
    }

    // MARK: Rows

    /// What follows a name, dimmed: the aliases that made the row match ("/new" finds "clear", so it shows "(new)"), then the
    /// arguments ("[model]"). Aliases of a row that matched by its name would only crowd it.
    private func note(for command: SlashCommand) -> String? {
        var parts: [String] = []
        if !query.isEmpty, !command.aliases.isEmpty, SlashMenuState.matchedRange(in: command.name, query: query) == nil {
            let matching = command.aliases.filter { SlashMenuState.matchedRange(in: $0, query: query) != nil }
            parts.append("(" + (matching.isEmpty ? command.aliases : matching).joined(separator: ", ") + ")")
        }
        if let hint = command.hint, !hint.isEmpty { parts.append(hint) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// One width for every row's name-and-arguments column, so the descriptions line up. A name is never cut by it (the
    /// longest ones aside); the arguments give way first.
    private var leadWidth: CGFloat {
        var widest: CGFloat = 0, longestName: CGFloat = 0
        for command in commands {
            let name = CGFloat(command.name.count + 1) * Self.nameAdvance
            var width = name
            if let note = note(for: command) { width += Self.noteGap + min(CGFloat(note.count) * Self.noteAdvance, Self.noteCap) }
            widest = max(widest, width); longestName = max(longestName, name)
        }
        // A little slack: a name that fills its column to the pixel would be cut.
        return (max(min(longestName, Self.nameCap), min(widest, Self.leadCap)) + 3).rounded(.up)
    }

    private func name(of command: SlashCommand) -> Text {
        let name = command.name
        let slash = Text("/").foregroundStyle(Color.secondary)
        guard let range = SlashMenuState.matchedRange(in: name, query: query) else {
            return slash + Text(name).fontWeight(.medium).foregroundStyle(Color.primary.opacity(0.92))
        }
        // What was typed stands out; the rest of the name is a step quieter.
        let quiet = Color.primary.opacity(0.72)
        return slash + Text(name[..<range.lowerBound]).foregroundStyle(quiet) + Text(name[range]).fontWeight(.semibold).foregroundStyle(Color.primary)
            + Text(name[range.upperBound...]).foregroundStyle(quiet)
    }

    private func row(_ command: SlashCommand, current: Bool, lead: CGFloat) -> some View {
        let hovering = hovered == command.id
        return HStack(spacing: 10) {
            HStack(spacing: 0) {
                name(of: command).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).layoutPriority(2)
                if let note = note(for: command) {
                    Text(note).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .padding(.leading, Self.noteGap)
                }
                Spacer(minLength: 0)
            }.frame(width: lead, alignment: .leading)
            if let detail = command.detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // The room is kept on every row, so a description is cut at the same place whichever row is highlighted.
            Keycap(text: "⇥").opacity(current ? 1 : 0)
        }
        .padding(.horizontal, 8).frame(height: Self.rowHeight)
        .background(fill(current: current, hovering: hovering), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Self.mint.opacity(current ? 0.3 : 0), lineWidth: 0.7))
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? command.id : (hovered == command.id ? nil : hovered) }
        // A tap, not a Button: nothing here may take the keyboard from the field.
        .onTapGesture { onPick(command) }
        .help(help(for: command))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.text + (command.hint.map { " " + $0 } ?? ""))
        .accessibilityHint(command.detail ?? "")
        .accessibilityValue(current ? "marcado" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPick(command) }
    }

    private func fill(current: Bool, hovering: Bool) -> Color {
        if current { return Self.mint.opacity(hovering ? 0.22 : 0.15) }
        return Color.white.opacity(hovering ? 0.09 : 0)
    }

    /// The row truncates; the tooltip has all of it.
    private func help(for command: SlashCommand) -> String {
        var lines = [command.text + (command.hint.map { " " + $0 } ?? "")]
        if !command.aliases.isEmpty { lines.append("También: " + command.aliases.map { "/" + $0 }.joined(separator: ", ")) }
        if let detail = command.detail { lines.append(detail) }
        return lines.joined(separator: "\n")
    }
}

/// What decides where the list is scrolled to; a change of any of it scrolls.
private struct ScrollTarget: Equatable {
    var top: Int
    var highlighted: Int
    var first: String?
    var count: Int
}

/// Where a scrolling list is: how far it moved and how tall it is, measured from inside it.
private struct ListMetrics: Equatable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
}

private struct ListMetricsKey: PreferenceKey {
    static let defaultValue = ListMetrics()
    static func reduce(value: inout ListMetrics, nextValue: () -> ListMetrics) { value = nextValue() }
}

/// A key's name on a small cap, like the ones on the prompt card.
private struct Keycap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            .padding(.horizontal, 4.5).frame(height: 15)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
