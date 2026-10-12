import SwiftUI

// The model button in the composer's bottom row, and the list of models it opens: the ones Claude's own /model picker offers, laid out as Nook's.
//
//   ClaudeModelName     the words a model is called by: its short name, for the chip's tooltip
//   ClaudeModelChip     the model the tab uses now, as the symbol of its family (`ClaudeModelFamily`, in `ChipGlyphs.swift`); a click opens the list
//   ModelMenuPlan       what the list says: the models of Claude's picker in its order, and, when the list is old or lacks some, what to tell of it
//   ClaudeModelMenu     the list, over the conversation, above the row: a row for each model (symbol, name, description, a mark on the one in use), the
//                       effort's ‹ ›, and the two buttons that apply the model chosen as Claude's picker does (the default, or this session only)
//   ModelMenuKey        what ↑ ↓ ↵ and S do on it (the message field keeps the keyboard; see `SessionPane.composerKey`)
//   ModelMenuLayer      the list and the click-away that closes it, as one modifier of the row
//
// The rows, the buttons and the effort stepper are shared with Claude's picker when it is on the tab (`ModelPickerParts.swift`, `AgentPromptCard`).
//
// Nothing here knows what models exist: `AppModel.availableModels(for:)` has them (Claude Code's own list on disk, else the rows Claude's picker showed
// when Nook last saw it, else Claude's aliases), and `AppModel.setModel(_:on:scope:)` and `openModelPicker` do the choosing. This is what they look like.

// MARK: - Names

enum ClaudeModelName {
    /// The model by name, as the chip's tooltip says it: Claude's name for it without what it adds in brackets ("Opus 4.6 (1M context)" is "Opus 4.6"),
    /// and a model id the way the agents' lists say it ("claude-sonnet-4-5-20250929" is "Sonnet 4.5"). nil when Claude has not named one.
    static func short(_ name: String?) -> String? {
        guard var text = name?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("claude-") { text = AgentModelName.short(text) ?? text }
        // A name that is only what it adds in brackets ("(1M context)") says nothing.
        if let open = text.firstIndex(where: { $0 == "(" || $0 == "[" }) { text = String(text[..<open]).trimmingCharacters(in: .whitespaces) }
        return text.isEmpty ? nil : text
    }
}

// MARK: - The list's plan

/// What the list says: the models Claude's own picker offers, in its order (from Claude Code's list on disk, or the rows Nook saw in the picker), and, only
/// when Nook knows no list, Claude's aliases (Claude Code resolves each alias to the newest model of its family, so they never go out of date); nothing is
/// invented here.
struct ModelMenuPlan: Equatable {
    enum Note: Equatable {
        /// The list was made by another Claude Code version than this tab's, or is past the time Claude would fetch it again: it may lack a newer model.
        case stale
        /// Nook has not seen Claude's picker yet: only the aliases are known.
        case onlyAliases
        /// Rows of Claude's picker the list lacks (it said "… +3 models" and Nook has not seen them).
        case missing(Int)
    }

    var learned: [ClaudeModelChoice]
    var aliases: [ClaudeModelChoice]
    var note: Note?

    /// `missing` is how many rows of Claude's picker are not in `choices`: 0 when the list is whole, nil when nothing says (nothing is said of it then).
    init(choices: [ClaudeModelChoice], stale: Bool, missing: Int? = 0) {
        learned = choices.filter { !$0.isAlias }
        aliases = choices.filter(\.isAlias)
        if stale { note = .stale }
        else if learned.isEmpty { note = .onlyAliases }
        else if let missing, missing > 0 { note = .missing(missing) }
        else { note = nil }
    }

    /// Every row that chooses a model, in the order the arrows walk them.
    var rows: [ClaudeModelChoice] { learned + aliases }

    /// The last row, which opens Claude's own picker, stands out when what the list needs is for the picker to be seen.
    var openerStandsOut: Bool { note != nil }

    var noteText: String? {
        switch note {
        case .stale: "Lista de otra versión de Claude Code. Ábrelo para actualizarla."
        case .onlyAliases: "Solo conozco los alias. Ábrelo para ver todos los modelos."
        case .missing(let count): count == 1 ? "Falta 1 modelo de la lista de Claude. Ábrelo para verlo." : "Faltan \(count) modelos de la lista de Claude. Ábrelo para verlos."
        case nil: nil
        }
    }

    /// The model that is the current one, if the list marks one.
    var current: ClaudeModelChoice? { rows.first(where: \.isCurrent) }
    var currentIndex: Int? { rows.firstIndex(where: \.isCurrent) }

    static let aliasesTitle = "Alias"
    static let aliasesCaption = "siempre el más nuevo de su familia"
    static let openerTitle = "Ver selector de Claude…"

    /// What to tell of a model that only Claude's picker can choose.
    static func pickerHint(needsAccessibility: Bool) -> String {
        "Nook lo elige en el selector de Claude." + (needsAccessibility ? " En una pestaña de Terminal necesita el permiso de Accesibilidad." : "")
    }
}

// MARK: - The chip

/// The chip in the composer's row: a symbol for the family of the model Claude names (see `ClaudeModelFamily`), in a round chip like the effort's and
/// the mode's. The model's own name and version are in its tooltip and in what VoiceOver says. Like the effort chip beside it, it is a control, so it
/// wears the island's neutral grey, not a colour of its own.
struct ClaudeModelChip: View {
    /// Claude's name for the tab's model ("Sonnet 5.5"); nil until its banner or its answer to /model has named one.
    var model: String?
    var open = false
    /// Why the list cannot be opened now (Claude is working, asks something, is not running…); nil when it can.
    var blocked: String?
    /// A model was just chosen and Claude has not answered yet: the chip stays lit until it does.
    var waiting = false
    var action: () -> Void
    @State private var hovered: Bool
    @State private var pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = ChipMetrics.side

    init(model: String?, open: Bool = false, blocked: String? = nil, waiting: Bool = false, look: ModeChipLook = .resting, action: @escaping () -> Void) {
        self.model = model
        self.open = open
        self.blocked = blocked
        self.waiting = waiting
        self.action = action
        _hovered = State(initialValue: look == .hovered)
        _pressed = State(initialValue: look == .pressed)
    }

    /// The tooltip: the model by name, and that a click lists them all (or what stands in the way of it).
    static func help(model: String?, blocked: String? = nil) -> String {
        let named = ClaudeModelName.short(model).map { "Modelo de Claude: \($0)." } ?? "Modelo de Claude: aún sin leer."
        return named + "\n" + (blocked ?? "Pulsa para ver todos los modelos disponibles y cambiar de modelo.")
    }

    /// The tip over the chip: the model by name and what a click does (or what stands in the way of it). None while the list is open from the chip.
    static func tip(model: String?, open: Bool = false, blocked: String? = nil) -> NookTip? {
        guard !open else { return nil }
        return NookTip("Modelo", value: ClaudeModelName.short(model) ?? "sin leer", detail: blocked ?? "Pulsa para ver todos los modelos y cambiar")
    }

    var body: some View {
        let named = ClaudeModelName.short(model) != nil
        Button(action: action) {
            ModelGlyph(family: ClaudeModelFamily(model: model), color: Color.primary.opacity(named ? 0.9 : 0.62))
                .chipSurface(fill: ChipWash.fill(hovered: hovered, pressed: pressed, lit: open || waiting, blocked: blocked != nil), ring: open)
        }
        .buttonStyle(PressReporter(pressed: $pressed))
        .disabled(blocked != nil)
        .opacity(blocked == nil ? 1 : 0.5)
        .onHover { hovered = $0 }
        .nookTip(Self.tip(model: model, open: open, blocked: blocked), id: "model")
        .accessibilityLabel("Modelo de Claude")
        .accessibilityValue(ClaudeModelName.short(model) ?? "sin leer")
        .accessibilityHint(blocked ?? "Abre la lista de modelos disponibles")
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
    }
}

// MARK: - The list

/// The list of models, the ones Claude's own /model picker offers and in its order: a row for each (the family's symbol, the name, Claude's description
/// under it, a mark on the one in use) and, last, Claude's picker itself. A row chosen with the pointer or the arrows is applied with the buttons under
/// the list, as the picker applies it: «Usar por defecto» (↵) or «Solo esta sesión» (S). The effort has its ring and ‹ › beside them. When the models do
/// not all fit, the part that shows ends under a whole row (never through one), with the edges fading and a chevron where there is more; the buttons
/// and, when the list is old or incomplete, the row that says so stay in view. It floats over the conversation's text, so its surface is as opaque as
/// the "/" menu's.
struct ClaudeModelMenu: View {
    var plan: ModelMenuPlan
    /// The row chosen: an index into `plan.rows`, or `plan.rows.count` for Claude's picker. nil until the pointer or the arrows choose one.
    var highlighted: Int?
    var width: CGFloat = ClaudeModelMenu.width
    /// The tallest the card may be; past it the models scroll.
    var maxHeight: CGFloat = 150
    /// A Terminal tab without the Accessibility permission: choosing a model Nook can only pick in Claude's picker moves its highlight with keys.
    var needsAccessibility = false
    /// The level of effort Claude has (or was just asked for).
    var effort: ClaudeEffort?
    var onSelect: (Int) -> Void = { _ in }
    var onChoose: (ClaudeModelChoice, ClaudeModelScope) -> Void = { _, _ in }
    /// ‹ is -1 and › is 1.
    var onEffortStep: (Int) -> Void = { _ in }
    var onOpenPicker: () -> Void = {}
    @State private var hovered: String?
    @State private var listHeight: CGFloat
    /// The part under the list as laid out (its buttons and, when it has one, the row that says the list is old): the models get what the card's room leaves.
    @State private var footerHeight: CGFloat
    /// Where each model's row stands in the list, as laid out: where the part that shows may end.
    @State private var rowFrames: [String: CGRect] = [:]
    /// How far the list has scrolled.
    @State private var offset: CGFloat = 0
    @Environment(\.tabTint) private var tint

    static let width: CGFloat = 380
    private static let openerHeight: CGFloat = 28
    /// The room under a row where the part of the list that shows may end: the row's own margin and the fade that takes the same.
    static let rowBreath: CGFloat = 3
    private static let fadeTop: CGFloat = 6
    private static let fadeBottom: CGFloat = 6
    private static let content = "modelListContent"
    private static let viewport = "modelListViewport"
    private static let surface = Color.nookCard

    init(plan: ModelMenuPlan, highlighted: Int? = nil, width: CGFloat = ClaudeModelMenu.width, maxHeight: CGFloat = 150, needsAccessibility: Bool = false, effort: ClaudeEffort? = nil,
         onSelect: @escaping (Int) -> Void = { _ in }, onChoose: @escaping (ClaudeModelChoice, ClaudeModelScope) -> Void = { _, _ in }, onEffortStep: @escaping (Int) -> Void = { _ in },
         onOpenPicker: @escaping () -> Void = {}) {
        self.plan = plan
        self.highlighted = highlighted
        self.width = width
        self.maxHeight = maxHeight
        self.needsAccessibility = needsAccessibility
        self.effort = effort
        self.onSelect = onSelect
        self.onChoose = onChoose
        self.onEffortStep = onEffortStep
        self.onOpenPicker = onOpenPicker
        // Close enough before SwiftUI has measured the rows that the card does not jump when it opens.
        _listHeight = State(initialValue: Self.estimatedListHeight(plan, width: width))
        _footerHeight = State(initialValue: Self.estimatedFooterHeight(plan))
    }

    /// The room the models have: the card's, less what stands under them. At least two rows.
    private var listRoom: CGFloat { max(60, maxHeight - footerHeight) }

    /// The models are taller than the room the card leaves them.
    private var scrolls: Bool { listHeight > listRoom + 1 }

    /// The height of the part of the list that shows: all of it when it fits, else what ends under a whole row.
    private var visibleHeight: CGFloat {
        guard scrolls else { return listHeight }
        return Self.snappedHeight(room: listRoom, rowEnds: plan.rows.compactMap { rowFrames[$0.id]?.maxY })
    }

    private var moreAbove: Bool { offset > 2 }
    private var moreBelow: Bool { scrolls && listHeight - offset - visibleHeight > 2 }

    /// The tallest part of a scrolling list that fits `room` and ends under a row, not through one: where the last row that shows ends (`rowEnds`, from
    /// the list's top) and a little more. The room itself when not even the first row fits in it.
    static func snappedHeight(room: CGFloat, rowEnds: [CGFloat], breath: CGFloat = rowBreath) -> CGFloat {
        rowEnds.map { $0 + breath }.filter { $0 <= room + 0.5 }.max() ?? room
    }

    /// A row takes the badge's height, and the description goes under the name (a line more) when the two do not fit side by side; the aliases' title is a
    /// line of its own, and Claude's picker is the last row when the list does not stand it under the models.
    static func estimatedListHeight(_ plan: ModelMenuPlan, width: CGFloat = ClaudeModelMenu.width) -> CGFloat {
        // The row's words have the card's width less the lists's padding, the row's, the badge, the gap, and the mark of the one in use.
        func row(_ choice: ClaudeModelChoice) -> CGFloat { ModelRowLabel.fitsOneLine(choice, width: width - 10 - 14 - 22 - 8 - (choice.isCurrent ? 72 : 0)) ? 29 : 42 }
        let learned = plan.learned.reduce(CGFloat(0)) { $0 + row($1) + 1 }
        let aliases = plan.aliases.isEmpty ? 0 : 24 + CGFloat(plan.aliases.count) * 30
        return learned + aliases + (plan.openerStandsOut ? 0 : openerHeight + 1) + 6
    }

    /// What stands under the list: a hairline, the row that says the list is old (when it is), and the buttons with the effort beside them.
    static func estimatedFooterHeight(_ plan: ModelMenuPlan) -> CGFloat { 1 + (plan.noteText == nil ? 0 : 48) + 5 + 28 + 5 }

    private var selection: ClaudeModelChoice? {
        guard let highlighted, plan.rows.indices.contains(highlighted) else { return nil }
        return plan.rows[highlighted]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(plan.learned) { choice in row(choice) }
                        if !plan.aliases.isEmpty {
                            aliasesTitle
                            ForEach(plan.aliases) { choice in row(choice) }
                        }
                        if !plan.openerStandsOut { opener(stands: false) }
                    }
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    // The rows' places are measured from the top of the list, whatever it has scrolled.
                    .coordinateSpace(name: Self.content)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { listHeight = $0 } }
                    .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .named(Self.viewport)).minY } action: { offset = $0 }
                }
                .coordinateSpace(name: Self.viewport)
                .scrollIndicators(.hidden)
                .frame(height: visibleHeight)
                // More above or below: that edge fades out, and a chevron says so.
                .mask(edgeFade)
                .overlay(alignment: .top) { if moreAbove { moreMark("chevron.compact.up") } }
                .overlay(alignment: .bottom) { if moreBelow { moreMark("chevron.compact.down") } }
                .onChange(of: highlighted) { _, index in
                    if let index, plan.rows.indices.contains(index) { proxy.scrollTo(plan.rows[index].id) }
                    else if index == plan.rows.count { proxy.scrollTo(Self.openerID) }
                }
                // It opens at the model in use when that one would be out of view, so the list says where the tab is; else it opens at the top.
                .onAppear {
                    guard let current = plan.current else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let frame = rowFrames[current.id], frame.maxY + Self.rowBreath > visibleHeight { proxy.scrollTo(current.id, anchor: .top) }
                    }
                }
            }
            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { footerHeight = $0 } }
        }
        .frame(width: width)
        // As opaque as the "/" menu, which floats over the same text: with glass available it is a dark card with the glass only for its edge, and
        // where glass is not drawn (an offscreen render, an older system, Reduce Transparency) it is the flat card, so the conversation never shows through.
        .nookGlassCard(radius: 12, dim: 1, clipsContent: true, fill: Self.surface)
        .nookCardShadow(0.55, radius: 14, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modelos de Claude")
    }

    private var edgeFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [moreAbove ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeTop)
            Rectangle()
            LinearGradient(colors: [.black, moreBelow ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: Self.fadeBottom)
        }
    }

    private func moreMark(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.nookWash(0.4))
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Under the list

    /// A hairline, the row that says the list is old or incomplete (when it is), and the effort and the two buttons that apply the model chosen.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.nookWash(0.07)).frame(height: 0.5).padding(.horizontal, 8)
            if plan.openerStandsOut { opener(stands: true).padding(.horizontal, 5).padding(.top, 5) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    EffortStepper(effort: effort, named: false, onStep: onEffortStep)
                    Spacer(minLength: 4)
                    ModelScopeButtons(selection: selection, needsAccessibility: needsAccessibility, onChoose: onChoose)
                }
                // Too narrow for both beside each other (a large text size): the effort over the buttons.
                VStack(alignment: .leading, spacing: 6) {
                    EffortStepper(effort: effort, named: true, onStep: onEffortStep)
                    ModelScopeButtons(selection: selection, needsAccessibility: needsAccessibility, onChoose: onChoose)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
    }

    // MARK: Rows

    private var aliasesTitle: some View {
        HStack(spacing: 6) {
            Text(ModelMenuPlan.aliasesTitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.7))
            Text(ModelMenuPlan.aliasesCaption).font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
        }
        .padding(.horizontal, 8).padding(.top, plan.learned.isEmpty ? 3 : 9).padding(.bottom, 3)
        .overlay(alignment: .top) { if !plan.learned.isEmpty { Rectangle().fill(Color.nookWash(0.07)).frame(height: 0.5).padding(.horizontal, 3).padding(.top, 4) } }
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ choice: ClaudeModelChoice) -> some View {
        let index = plan.rows.firstIndex(of: choice)
        let marked = index != nil && index == highlighted
        return Button {
            if let index { onSelect(index) }
        } label: {
            ModelRowLabel(choice: choice, selected: marked)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(fill(marked: marked, hovering: hovered == choice.id), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.accent.opacity(marked ? 0.35 : 0), lineWidth: 0.7))
                .contentShape(Rectangle())
        }
        .nookPress(.none, depth: PressDepth.row)
        .onHover { inside in hovered = inside ? choice.id : (hovered == choice.id ? nil : hovered) }
        .help(ModelRowLabel.help(for: choice) + (choice.argument == nil ? "\n" + ModelMenuPlan.pickerHint(needsAccessibility: needsAccessibility) : ""))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.content)) } action: { rowFrames[choice.id] = $0 }
        .id(choice.id)
        .accessibilityLabel(choice.label)
        .accessibilityValue([choice.isCurrent ? "actual" : nil, marked ? "elegido" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(choice.detail ?? (choice.isAlias ? ModelMenuPlan.aliasesCaption : ""))
        .accessibilityAddTraits(marked ? .isSelected : [])
    }

    private func fill(marked: Bool, hovering: Bool) -> Color {
        if marked { return tint.accent.opacity(0.16) }
        return Color.nookWash(hovering ? 0.09 : 0)
    }

    private static let openerID = "modelListOpener"

    /// Claude's own picker, as a row. It is where models Nook has not seen show up, so when the list is old or incomplete it stands under the models, in
    /// the tab's colour, and says why under its title; otherwise it is the last row of the list, quiet.
    private func opener(stands: Bool) -> some View {
        let marked = highlighted == plan.rows.count
        let note = stands ? plan.noteText : nil
        return Button(action: onOpenPicker) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: stands ? "arrow.triangle.2.circlepath" : "list.bullet").font(.system(size: 9.5, weight: .semibold)).frame(width: 22, height: 15)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(ModelMenuPlan.openerTitle).font(.system(size: 11, weight: .medium)).frame(minHeight: 15, alignment: .leading)
                    if let note { Text(note).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.72)).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 4)
            }
            .foregroundStyle(stands ? tint.ink : Color.primary.opacity(0.8))
            .padding(.horizontal, 7).padding(.vertical, note == nil ? 0 : 6).frame(minHeight: Self.openerHeight)
            .background(stands ? tint.accent.opacity(hovered == "picker" || marked ? 0.26 : 0.16) : Color.nookWash(hovered == "picker" || marked ? 0.11 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(stands ? tint.accent.opacity(0.4) : tint.accent.opacity(marked ? 0.3 : 0), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .nookPress(.none, depth: PressDepth.row)
        .onHover { inside in hovered = inside ? "picker" : (hovered == "picker" ? nil : hovered) }
        .help("Abre el selector de modelos de Claude (/model), con todos los modelos de tu cuenta.")
        .id(stands ? "modelListNote" : Self.openerID)
        .accessibilityLabel("Ver el selector de Claude")
        .accessibilityHint(note ?? "")
    }
}

/// The list for a tab, read from the model each time it draws: it follows the tab's current model and its open picker (`session`), and what Nook learns
/// of Claude's models (`store`).
struct ClaudeModelMenuHost: View {
    var model: AppModel
    @ObservedObject var session: TerminalSession
    @ObservedObject var store: ClaudeModelStore
    var highlighted: Int?
    var width: CGFloat
    var maxHeight: CGFloat
    var needsAccessibility = false
    var effort: ClaudeEffort?
    var onSelect: (Int) -> Void
    var onChoose: (ClaudeModelChoice, ClaudeModelScope) -> Void
    var onEffortStep: (Int) -> Void
    var onOpenPicker: () -> Void

    var body: some View {
        ClaudeModelMenu(plan: ModelMenuPlan(choices: model.availableModels(for: session), stale: model.modelListIsStale(for: session), missing: model.missingModels(for: session)),
                        highlighted: highlighted, width: width, maxHeight: maxHeight, needsAccessibility: needsAccessibility, effort: effort,
                        onSelect: onSelect, onChoose: onChoose, onEffortStep: onEffortStep, onOpenPicker: onOpenPicker)
    }
}

// MARK: - The keys

/// What the keyboard does while the list is out: the highlight walks its rows and stops at either end, and the row after the last model is the one
/// that opens Claude's picker. ↵ applies the highlighted model as the default and S for this session only (the pane does both, see `chosen`), Esc closes;
/// with nothing highlighted yet ↵ is the field's own and S is a letter of the message.
enum ModelMenuKey {
    /// What ↵ does on the highlighted row.
    enum Target: Equatable {
        case model(Int)
        case picker
    }

    /// Where the highlight goes for `key`, or nil for a key that does not walk. `models` is how many rows choose a model; the row after them opens
    /// Claude's picker. From nowhere the arrows start at the model in use (`current`): ↓ goes to the row after it and ↑ to the one before; with none in
    /// use, ↓ goes to the first row and ↑ to the last.
    static func moved(from highlighted: Int?, by key: ComposerKey, models: Int, current: Int? = nil) -> Int? {
        switch key {
        case .up: return highlighted.map { min(max($0 - 1, 0), models) } ?? current.map { max($0 - 1, 0) } ?? models
        case .down: return highlighted.map { min(max($0 + 1, 0), models) } ?? current.map { min($0 + 1, models) } ?? 0
        case .submit, .newline, .right, .tab, .escape, .pasteImage, .letter: return nil
        }
    }

    /// The row ↵ (and S) act on; nil when nothing is highlighted.
    static func chosen(_ highlighted: Int?, models: Int) -> Target? {
        guard let highlighted else { return nil }
        return highlighted < models ? .model(highlighted) : .picker
    }
}

// MARK: - The list and its click-away

/// The list above the row it belongs to, and, under it, a click-away: anywhere else in the island closes the list instead of doing what is there
/// (the first click only closes it, as in any menu). The click-away is a very large clear area, with the pointer's hole in it so the text views under
/// it show the arrow. Esc, and the arrows and Enter, are the message field's (`SessionPane.composerKey`): the field keeps the keyboard.
struct ModelMenuLayer<Menu: View>: ViewModifier {
    var isOpen: Bool
    /// The app's own switch for animations; Reduce Motion turns them off as well.
    var animated = true
    var onClose: () -> Void
    @ViewBuilder var menu: () -> Menu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isOpen {
                    Color.clear.frame(width: 6000, height: 6000).contentShape(Rectangle()).pointerHole().onTapGesture(perform: onClose)
                }
            }
            .overlay(alignment: .topTrailing) {
                // The guide stands outside the condition: a guide set on a view that only exists `if isOpen` is not seen by the overlay's
                // alignment, and the list would hang below the row instead of standing above it.
                Group {
                    if isOpen {
                        menu()
                            .pointerHole()
                            .transition(.opacity.combined(with: .offset(y: 4)))
                    }
                }
                // Its bottom edge stands a little above the row, whatever its height.
                .alignmentGuide(.top) { $0[.bottom] + 6 }
            }
            .animation(reduceMotion || !animated ? nil : .easeOut(duration: 0.12), value: isOpen)
    }
}

extension View {
    /// Shows `menu` over this view (above it, at its trailing edge) while `isOpen`, with a click-away that calls `onClose`.
    func modelMenu<Menu: View>(isOpen: Bool, animated: Bool = true, onClose: @escaping () -> Void, @ViewBuilder _ menu: @escaping () -> Menu) -> some View {
        modifier(ModelMenuLayer(isOpen: isOpen, animated: animated, onClose: onClose, menu: menu))
    }
}
