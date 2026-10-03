import SwiftUI

/// What an agent's question looks like in Nook: one button per option, in the place where the composer sits. The
/// terminal still owns the question; clicking only presses the keys that reach the option (see `AppModel.answer`), and
/// nothing is ever chosen without a click. While the question is open the composer has nothing to do: a message sent
/// into a dialog would be lost or, worse, answer it. The card takes its whole place, so the conversation above keeps
/// the height it needs to show what is being asked about.
///
/// The card shares the composer's surface so it reads as the same object changing purpose. Claude's terracotta marks
/// who is asking; mint, the user's color, marks the option Enter would press right now.
struct AgentPromptCard: View {
    var prompt: AgentPrompt
    var agent: TerminalAgent? = .claude
    /// The answer's keys are being sent: the options wait for the screen to show the result.
    var busy = false
    /// Moving the highlight needs the Accessibility permission and it is not granted yet.
    var needsAccessibility = false
    var onChoose: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onHide: () -> Void = {}
    /// Something that lives in the composer and must not vanish while the card has its place (the agents' capsule).
    var accessory: AnyView?
    /// Options shown before the list scrolls; the island's size decides (`PaneLayout.cardRows`), six in the Normal one.
    var visibleRows = AgentPromptCard.visibleRows
    @State private var hovered: Int?
    /// The option clicked last: while its keys are on their way it shows as the current one, before the screen says so.
    @State private var chosen: Int?
    @State private var list: ListMetrics
    @FocusState private var focused: Bool

    init(prompt: AgentPrompt, agent: TerminalAgent? = .claude, busy: Bool = false, needsAccessibility: Bool = false,
         accessory: AnyView? = nil, visibleRows: Int = AgentPromptCard.visibleRows,
         onChoose: @escaping (Int) -> Void = { _ in }, onCancel: @escaping () -> Void = {}, onHide: @escaping () -> Void = {}) {
        self.prompt = prompt
        self.visibleRows = visibleRows
        self.agent = agent
        self.busy = busy
        self.needsAccessibility = needsAccessibility
        self.onChoose = onChoose
        self.onCancel = onCancel
        self.onHide = onHide
        self.accessory = accessory
        // The list's height is known before SwiftUI measures it, so the first frame already fades a list that overflows.
        _list = State(initialValue: ListMetrics(offset: 0, height: CGFloat(prompt.options.count) * (Self.rowHeight + Self.rowGap) - Self.rowGap))
    }

    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 24
    static let rowGap: CGFloat = 1
    static let bottomInset: CGFloat = 7
    /// More options than this scroll; the highlighted one is kept in view. Six rows and the header fill the island's
    /// pane, which is as tall as the card may get.
    static let visibleRows = 6
    /// With this many options or fewer the conversation keeps a few lines above the card; with more, the card takes the
    /// pane and the conversation (only a sliver of it would fit) steps aside.
    static let optionsBesideMirror = 4
    private static let mint = Color(red: 0.32, green: 0.73, blue: 0.61)
    private static let viewport = "promptOptions"

    private var agentName: String { agent?.title ?? "El agente" }

    var body: some View {
        VStack(spacing: 0) {
            header
            options.allowsHitTesting(!busy)
        }
        .padding(.bottom, Self.bottomInset)
        .nookGlassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), dim: 0.55, dimColor: Color(white: 0.055),
                          fill: Color.white.opacity(0.07), stroke: Color.white.opacity(0.07))
        // 1…9 choose, as long as the card has the keyboard (the island is key and nothing else is being typed into).
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard !busy, press.modifiers.subtracting(.numericPad).isEmpty, let digit = Int(press.characters), (1...prompt.options.count).contains(digit) else { return .ignored }
            choose(digit - 1)
            return .handled
        }
        // One turn later: the view has to be in the window before it can take the keyboard.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: busy) { _, working in if !working { chosen = nil } }
        .accessibilityElement(children: .contain)
    }

    // MARK: Header

    private var title: String {
        if !prompt.question.isEmpty { return prompt.question }
        switch prompt.kind {
        case .approval: return "\(agentName) pide permiso"
        case .question: return "\(agentName) pregunta"
        case .selector: return "Elige una opción"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Group {
                if agent == .codex { Image(systemName: SessionKind.codex.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.secondary) }
                else { Text("✻").font(.system(size: 14, weight: .bold)).foregroundStyle(claudeSpinner) }
            }.frame(width: 14)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .help([prompt.question, prompt.context].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
            Spacer(minLength: 8)
            if let accessory { accessory }
            if busy {
                Text("Enviando…").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                Button(action: onCancel) {
                    HStack(spacing: 5) {
                        Text("Cancelar").font(.system(size: 10.5, weight: .medium))
                        Keycap(text: "esc")
                    }.foregroundStyle(Color.primary.opacity(0.8))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Cancelar la pregunta: envía Escape a \(agentName)").accessibilityLabel("Cancelar la pregunta")
            }
            Button(action: onHide) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Ocultar las opciones para escribir un mensaje o usar las teclas").accessibilityLabel("Ocultar las opciones")
        }.padding(.leading, 13).padding(.trailing, 6).frame(height: Self.headerHeight)
    }

    // MARK: Options

    private func choose(_ index: Int) {
        chosen = index
        onChoose(index)
    }

    /// Whether the card takes the whole pane for these options (see `optionsBesideMirror`). A taller island leaves room for
    /// more of them beside the conversation (`PaneLayout.cardOptionsBesideMirror`).
    static func coversMirror(optionCount: Int, besideMirror: Int = optionsBesideMirror) -> Bool { optionCount > besideMirror }

    /// The card's height with this many options, of which `visibleRows` show before the list scrolls.
    static func cardHeight(options: Int, visibleRows: Int) -> CGFloat {
        let rows = CGFloat(min(max(options, 0), max(visibleRows, 1)))
        return headerHeight + rows * (rowHeight + rowGap) - (rows > 0 ? rowGap : 0) + bottomInset
    }

    private var viewportHeight: CGFloat { CGFloat(visibleRows) * (Self.rowHeight + Self.rowGap) - Self.rowGap }

    @ViewBuilder private var options: some View {
        let rows = VStack(spacing: Self.rowGap) {
            ForEach(prompt.options) { option in row(option).id(option.index) }
        }.padding(.horizontal, 6)
        if prompt.options.count > visibleRows {
            ScrollViewReader { proxy in
                ScrollView {
                    rows.background(GeometryReader { geometry in
                        Color.clear.preference(key: ListMetricsKey.self, value: ListMetrics(offset: -geometry.frame(in: .named(Self.viewport)).minY, height: geometry.size.height))
                    })
                }
                .coordinateSpace(name: Self.viewport).scrollIndicators(.hidden)
                .onPreferenceChange(ListMetricsKey.self) { if $0.height > 0 { list = $0 } }
                .frame(height: viewportHeight)
                // More below: the last visible row fades out instead of ending in a cut.
                .nookScrollFade(active: list.height - list.offset - viewportHeight > 2, height: 22, surface: Color(white: 0.07))
                .onAppear { proxy.scrollTo(prompt.highlighted) }
                .onChange(of: prompt.highlighted) { _, index in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index) } }
            }
        } else { rows }
    }

    private func row(_ option: AgentPrompt.Option) -> some View {
        let current = busy ? (chosen ?? prompt.highlighted) == option.index : option.index == prompt.highlighted
        return Button { choose(option.index) } label: {
            HStack(spacing: 9) {
                Text("\(option.index + 1)").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(current ? Color.black.opacity(0.8) : Color.secondary)
                    .frame(width: 17, height: 17)
                    .background(current ? Self.mint : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                HStack(spacing: 7) {
                    Text(option.title).font(.system(size: 12, weight: current ? .medium : .regular)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                if option.input != .none {
                    Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let shortcut = option.shortcut { Keycap(text: shortcut) }
            }
            .padding(.horizontal, 7).frame(height: Self.rowHeight)
            .background(fill(current: current, hovering: hovered == option.index), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Self.mint.opacity(current ? 0.3 : 0), lineWidth: 0.7))
            .contentShape(Rectangle())
            .opacity(busy && !current ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? option.index : (hovered == option.index ? nil : hovered) }
        .help(help(for: option, current: current))
        .accessibilityLabel("Opción \(option.index + 1): \(option.title)")
        .accessibilityValue(current ? "marcada" : "")
    }

    private func fill(current: Bool, hovering: Bool) -> Color {
        if current { return Self.mint.opacity(hovering ? 0.22 : 0.15) }
        return Color.white.opacity(hovering ? 0.09 : 0)
    }

    /// The whole text of an option (the row truncates), what the click does, and what it needs.
    private func help(for option: AgentPrompt.Option, current: Bool) -> String {
        var lines = [option.title]
        if let detail = option.detail { lines.append(detail) }
        switch option.input {
        case .inline: lines.append("Te lleva al campo de texto de \(agentName); después escribes tu respuesta en Nook.")
        case .followUp: lines.append("Elige esta opción y después escribes en Nook lo que \(agentName) debe hacer.")
        case .none: break
        }
        if current { lines.append("Es la opción marcada en la terminal: solo envía Enter.") }
        else if needsAccessibility { lines.append("Mover la selección requiere el permiso de Accesibilidad; Nook lo explicará al pulsar.") }
        return lines.joined(separator: "\n")
    }
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

/// A key's name on a small cap, like the ones on the key strip.
private struct Keycap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            .padding(.horizontal, 4.5).frame(height: 15)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
