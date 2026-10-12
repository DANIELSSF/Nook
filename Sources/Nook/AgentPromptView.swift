import SwiftUI

/// What an agent's question looks like in Nook: one button per option, in the place where the composer sits. The
/// terminal still owns the question; clicking only presses the keys that reach the option (see `AppModel.answer`), and
/// nothing is ever chosen without a click. While the question is open the composer has nothing to do: a message sent
/// into a dialog would be lost or, worse, answer it. The card takes its whole place, so the conversation above keeps
/// the height it needs to show what is being asked about. The one option that presses no key is a text field ("Type something."): choosing it gives the
/// card's place to the composer, which then answers that question (the bar over its field says which, and Esc comes back here: `FieldAnswerBar`).
///
/// The card says everything the dialog says, and cuts nothing: the whole question (with the note under a short title, and the label chip of
/// a single question), every option with its full label and description wrapped, the boxes of a question that takes several answers, the
/// "current" mark of a picker, the tabs of a dialog with several questions and the ‹ › of a setting changed in place. When all that is
/// taller than the pane, the card is as tall as the pane and its body scrolls under a bar of its own (the mark, Cancelar and the way to hide it
/// stay in view), fading at the edge that has more. The last step of a dialog with several questions is a summary instead of prose: each question with
/// its answer, and the two ways out as buttons (see `reviewContent`).
///
/// Claude's own /model picker is the same list as the model button's (`ModelPickerParts.swift`): a row for each model with its family's symbol, name
/// and description, the effort with its ‹ ›, and the two ways to apply a model (see `modelPickerContent`).
///
/// The card shares the composer's surface so it reads as the same object changing purpose. Claude's terracotta marks
/// who is asking; the tab's color (mint unless the user chose another), the user's, marks the option Enter would press right now.
struct AgentPromptCard: View {
    var prompt: AgentPrompt
    var agent: TerminalAgent? = .claude
    /// The answer's keys are being sent: the options wait for the screen to show the result.
    var busy = false
    /// A Terminal tab without the Accessibility permission: the keys that are key events (← → and a text field reached by arrows
    /// alone) need it. Choosing any other option goes as one write and doesn't (`AgentPrompt.needsDirectKeys(choosing:)`).
    var needsAccessibility = false
    var onChoose: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onHide: () -> Void = {}
    /// ← or → on the dialog: a setting changed in place (the model picker's effort) or the next question of a dialog with several.
    var onKey: (TerminalKey) -> Void = { _ in }
    /// Something that lives in the composer and must not vanish while the card has its place (the agents' capsule).
    var accessory: AnyView?
    /// The tallest the card may be: the pane's room. Past it the body scrolls. Nil leaves it as tall as it needs (previews).
    var maxHeight: CGFloat?
    /// The user's chat text size: the card's texts (the question, the options, their descriptions) follow it, since they are what the user reads.
    var chatSize = DisplaySettings.defaultChatSize
    /// The conversation is hidden under the card, so the card says what the question is about (the command a permission is for).
    var showsContext = false
    /// Claude's model picker, when this question is it: the list it offers (whole, from Claude Code's own list) and how to apply a model. nil leaves the
    /// picker as any other list of options.
    var modelPicker: ModelPickerContext?
    /// The text fields of the dialog that already hold an answer Nook wrote (`TerminalSession.isFilledField`): a question with several answers keeps its dialog,
    /// the field showing the text with its box ticked, and a click on it toggles the box like on any option and takes no more text. Its row says whose text it
    /// holds, not that it takes some (`AnswerMark`, `PromptCardText.inputHelp`).
    var filledFields: Set<Int> = []
    /// Kept for callers that still pass it; the body scrolls by height now, not by a count of rows (see `maxHeight`).
    var visibleRows = AgentPromptCard.visibleRows
    /// How wide the card is, when the caller knows before it is laid out: the question with a preview arranges its options, box and notes by it (`PreviewMetrics`), and
    /// the first frame has it right instead of settling a turn later. Once the card has a width of its own it goes by that.
    var width: CGFloat?
    /// The user's text size for what they type: the notes' field.
    var inputSize = DisplaySettings.defaultInputSize
    /// The notes written for a question with a preview, kept by the caller so they outlive the card (`WrittenNotes`); without it the card keeps them itself.
    var notes: Binding<String>?
    /// A click on an option with notes written: the option and its notes, as one answer (`AppModel.answer(_:option:notes:on:)`). Without notes it is `onChoose`.
    var onChooseWithNotes: (Int, String) -> Void = { _, _ in }
    @State private var hovered: Int?
    /// The notes written here when the caller keeps none, and what puts the keyboard in the field and brings it into view (the `n` key, as in the terminal).
    @State private var ownNotes = ""
    @State private var notesFocus = 0
    @State private var notesReveal = 0
    @State private var measuredWidth: CGFloat?
    /// Whether a text view (the notes' field) has the keyboard: the card's digits and «n» are then characters (`KeyboardBox`).
    @State private var keyboard = KeyboardBox()
    /// What stands above the box of a question with a preview, as laid out: the intro, and the options when they stack over it. The box is as tall as the body's room
    /// leaves it (`previewCap`).
    @State private var introHeight: CGFloat
    @State private var optionsHeight: CGFloat
    /// The model chosen in Claude's picker with the pointer or the arrows, before it is applied; until then it is the row Claude's picker has highlighted.
    @State private var modelSelection: Int?
    /// Where each row of Claude's model picker stands in the card's body, as laid out (for scrolling to the one chosen only when it is out of view).
    @State private var modelRowFrames: [Int: CGRect] = [:]
    /// The option clicked last: while its keys are on their way it shows as the current one, before the screen says so.
    @State private var chosen: Int?
    /// The body's own height and how far it has scrolled, measured from inside it.
    @State private var list: ListMetrics
    /// The bar's and the footer's heights as laid out: the body gets what the card's room leaves.
    @State private var barHeight = AgentPromptCard.headerHeight
    @State private var footerHeight: CGFloat
    @FocusState private var focused: Bool
    @Environment(\.tabTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(prompt: AgentPrompt, agent: TerminalAgent? = .claude, busy: Bool = false, needsAccessibility: Bool = false,
         accessory: AnyView? = nil, visibleRows: Int = AgentPromptCard.visibleRows, maxHeight: CGFloat? = nil, chatSize: Double = DisplaySettings.defaultChatSize, showsContext: Bool = false,
         modelPicker: ModelPickerContext? = nil, filledFields: Set<Int> = [], width: CGFloat? = nil, inputSize: Double = DisplaySettings.defaultInputSize, notes: Binding<String>? = nil,
         onChoose: @escaping (Int) -> Void = { _ in }, onChooseWithNotes: @escaping (Int, String) -> Void = { _, _ in }, onCancel: @escaping () -> Void = {},
         onHide: @escaping () -> Void = {}, onKey: @escaping (TerminalKey) -> Void = { _ in }) {
        self.prompt = prompt
        self.modelPicker = modelPicker
        self.filledFields = filledFields
        self.width = width
        self.inputSize = inputSize
        self.notes = notes
        self.onChooseWithNotes = onChooseWithNotes
        self.visibleRows = visibleRows
        self.agent = agent
        self.busy = busy
        self.needsAccessibility = needsAccessibility
        self.maxHeight = maxHeight
        self.chatSize = chatSize
        self.showsContext = showsContext
        self.onChoose = onChoose
        self.onCancel = onCancel
        self.onHide = onHide
        self.onKey = onKey
        self.accessory = accessory
        // The body's height is known roughly before SwiftUI measures it, so the first frame is close to the last.
        let isModelPicker = modelPicker != nil && ClaudeModelStore.isModelPicker(prompt)
        // The question with a preview arranges itself by the card's width, so its first frame has the width the caller knows; the others have always had the default.
        _list = State(initialValue: ListMetrics(offset: 0, height: PromptCardText.estimatedBodyHeight(prompt, inline: PromptCardText.isInline(prompt, hasAccessory: accessory != nil),
                                                                                                    width: prompt.takesNotes ? width ?? 500 : 500, chatSize: chatSize,
                                                                                                    modelPicker: isModelPicker, filled: filledFields, inputSize: inputSize)))
        _footerHeight = State(initialValue: PromptCardText.estimatedFooter(prompt, modelPicker: isModelPicker, chatSize: chatSize))
        // What stands above its box, for the box's first frame (`previewCap`); the card measures both once it is laid out.
        var intro: CGFloat = 0, options: CGFloat = 0
        if prompt.takesNotes {
            let previewWidth = width ?? 500
            let arrangement = PreviewMetrics.arrange(prompt.preview, hiddenLines: prompt.previewHiddenLines, width: previewWidth, chatSize: chatSize)
            intro = PromptCardText.estimatedIntro(prompt, inline: PromptCardText.isInline(prompt, hasAccessory: accessory != nil), width: previewWidth, chatSize: chatSize)
            options = PromptCardText.estimatedPreviewOptions(prompt, column: arrangement.optionsWidth, chatSize: chatSize, filled: filledFields)
        }
        _introHeight = State(initialValue: intro)
        _optionsHeight = State(initialValue: options)
    }

    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 24
    static let rowGap: CGFloat = 1
    static let bottomInset: CGFloat = 7
    /// The adjustment's row and the air above it.
    static let footerRowHeight: CGFloat = 28
    static let footerGap: CGFloat = 5
    /// What an option's row has that a line of text does not: the number's box is 17 pt and the row 3.5 pt above and below it.
    private static let markerSide: CGFloat = 17
    /// With compact rows (one line each), this many options show before the list scrolls: six rows and the header fill the Normal island's pane.
    static let visibleRows = 6
    /// With this many options or fewer the conversation keeps a few lines above the card; with more, the card takes the
    /// pane and the conversation (only a sliver of it would fit) steps aside.
    static let optionsBesideMirror = 4
    private static let viewport = "promptBody"

    private var agentName: String { agent?.title ?? "El agente" }
    /// A text size of the design, in points, at the user's chat text size (the design is for 11 pt).
    private func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: scaledSize(size), weight: weight) }
    private func scaledSize(_ size: CGFloat) -> CGFloat { (size * CGFloat(chatSize / DisplaySettings.defaultChatSize) * 2).rounded() / 2 }
    private var inline: Bool { PromptCardText.isInline(prompt, hasAccessory: accessory != nil) }
    /// This card is Claude's model picker, drawn as the model button's list.
    private var isModelPicker: Bool { modelPicker != nil && ClaudeModelStore.isModelPicker(prompt) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            bodyList.allowsHitTesting(!busy)
            if isModelPicker {
                modelPickerFooter.allowsHitTesting(!busy).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            } else if let adjustment = prompt.adjustment {
                adjustmentRow(adjustment).padding(.top, Self.footerGap).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .padding(.bottom, Self.bottomInset)
        .composerSurface()
        .background(KeyboardProbe(box: keyboard))
        // 1…9 choose, as long as the card has the keyboard (the island is key and nothing else is being typed into).
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            // (Where notes are written, a digit typed into their field is a character: the card leaves it alone.)
            guard !busy, !(prompt.takesNotes && keyboard.isTyping), press.modifiers.subtracting(.numericPad).isEmpty, let digit = Int(press.characters) else { return .ignored }
            // In Claude's model picker a number chooses the row it names; applying it is the buttons' (↵, S).
            if isModelPicker { return selectModel(number: digit) }
            // With the terminal's own notes field open or being typed into the options wait (their rows are dimmed), and the keys with them.
            guard !notesBlocked, let index = optionIndex(forDigit: digit) else { return .ignored }
            choose(index)
            return .handled
        }
        // «n» opens the notes of a question with a preview, as it does in the terminal: the field takes the keyboard.
        .onKeyPress(characters: CharacterSet(charactersIn: "nN"), phases: .down) { press in
            guard press.modifiers.isEmpty, !keyboard.isTyping else { return .ignored }
            return openNotes()
        }
        // Claude's model picker: the arrows walk its rows, ↵ applies the one chosen as the default and S for this session only, as the picker does.
        .onKeyPress(.upArrow) { moveModelSelection(-1) }
        .onKeyPress(.downArrow) { moveModelSelection(1) }
        .onKeyPress(.return) { applyModel(.default) }
        .onKeyPress(KeyEquivalent("s")) { applyModel(.sessionOnly) }
        // One turn later: the view has to be in the window before it can take the keyboard.
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: busy) { _, working in if !working { chosen = nil } }
        // The question with a preview arranges itself by the width it has (`PreviewMetrics`), which only the layout knows for sure.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { measuredWidth = $0 } }
        .accessibilityElement(children: .contain)
    }

    // MARK: Bar

    private var title: String {
        if !prompt.question.isEmpty { return prompt.question }
        return kindLabel
    }

    /// Who is asking, for when the question itself is in the body (or there is none).
    private var kindLabel: String { PromptCardText.kindLabel(prompt, agentName: agentName) }

    /// The mark, the label of the question, the question when it is short, and the buttons. It never scrolls, so Cancelar is always at hand.
    private var bar: some View {
        HStack(alignment: .top, spacing: 8) {
            AskingMark(agent: agent)
            if let header = prompt.header { LabelChip(text: header).frame(height: 22) }
            if isModelPicker {
                // Nook's own words for Claude's "Select model": the mark says who is asking.
                Text(PromptCardText.modelPickerTitle).font(scaled(12, .semibold)).lineLimit(1).frame(minHeight: 22, alignment: .leading).accessibilityAddTraits(.isHeader)
            } else if inline {
                // A short question sits beside the mark; if it wraps, the bar grows with it.
                Text(prompt.question).font(scaled(12, .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 22, alignment: .leading).help(helpText)
            } else if PromptCardText.isReview(prompt) {
                // The summary's own title, in the place of who is asking: the mark says that already.
                Text(PromptCardText.reviewTitle).font(scaled(12, .semibold)).lineLimit(1).frame(minHeight: 22, alignment: .leading).accessibilityAddTraits(.isHeader)
            } else if prompt.header == nil || prompt.question.isEmpty {
                Text(kindLabel).font(scaled(12, .semibold)).foregroundStyle(prompt.question.isEmpty ? Color.primary : Color.nookSecondary)
                    .lineLimit(1).frame(minHeight: 22, alignment: .leading)
            }
            Spacer(minLength: 8)
            if let accessory { accessory.frame(height: 22) }
            if busy {
                Text("Enviando…").font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).frame(height: 22)
            } else {
                Button(action: onCancel) {
                    HStack(spacing: 5) {
                        Text("Cancelar").font(.system(size: 10.5, weight: .medium))
                        Keycap(text: "esc")
                    }.foregroundStyle(Color.primary.opacity(0.8))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).help("Cancelar la pregunta: envía Escape a \(agentName)").accessibilityLabel("Cancelar la pregunta")
            }
            Button(action: onHide) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.nookSecondary)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }.nookPress(.nudgeDown).help("Ocultar las opciones para escribir un mensaje o usar las teclas").accessibilityLabel("Ocultar las opciones")
        }
        .padding(.leading, 13).padding(.trailing, 6).padding(.vertical, 5)
        .frame(minHeight: Self.headerHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }

    /// The whole text of the question and what it is about, for the tooltip.
    private var helpText: String { [prompt.question, prompt.note, prompt.context].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") }

    // MARK: Body

    /// A click (or a digit) on option `index`: the option, and with it the notes written for a question with a preview (`notesToSend`) as one answer.
    private func choose(_ index: Int) {
        chosen = index
        if let written = notesToSend(for: index) { onChooseWithNotes(index, written) } else { onChoose(index) }
    }

    /// Whether the card takes the whole pane for these options (see `optionsBesideMirror`). A taller island leaves room for
    /// more of them beside the conversation (`PaneLayout.cardOptionsBesideMirror`). This is the estimate for compact rows, which is what
    /// there is before the card is laid out; once it is, the pane goes by the card's own height (`coversMirror(cardHeight:room:)`).
    static func coversMirror(optionCount: Int, besideMirror: Int = optionsBesideMirror) -> Bool { optionCount > besideMirror }

    /// Whether a card of this height leaves the conversation less than it can show a line of.
    static func coversMirror(cardHeight: CGFloat, room: CGFloat) -> Bool {
        room - cardHeight - ComposerMetrics.spacing < PaneLayout.minConversationBesideCard
    }

    /// The card's height with this many compact options, of which `visibleRows` show before the list scrolls.
    static func cardHeight(options: Int, visibleRows: Int) -> CGFloat {
        let rows = CGFloat(min(max(options, 0), max(visibleRows, 1)))
        return headerHeight + rows * (rowHeight + rowGap) - (rows > 0 ? rowGap : 0) + bottomInset
    }

    /// What the body may take: the card's room less its bar, its footer and its bottom edge. At least a few rows' worth.
    private var maxBodyHeight: CGFloat {
        guard let maxHeight else { return .infinity }
        return max(3 * (Self.rowHeight + Self.rowGap), maxHeight - barHeight - footerHeight - Self.bottomInset)
    }

    private var bodyHeight: CGFloat {
        let height = min(list.height, maxBodyHeight)
        // Claude's model picker, when its rows do not all fit, shows whole rows (as the model button's list does), never one cut through.
        guard isModelPicker, list.height > height + 1 else { return height }
        return ClaudeModelMenu.snappedHeight(room: height, rowEnds: modelRowFrames.values.map(\.maxY), breath: 4)
    }
    private var scrolls: Bool { list.height > bodyHeight + 1 }

    private var bodyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    // The body's height and how far it has scrolled, measured from inside it (a preference does not make it out of the
                    // scroll view in an offscreen window, which is where the render tests look at the card).
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { list.height = $0 } }
                    .onGeometryChange(for: CGFloat.self) { -$0.frame(in: .named(Self.viewport)).minY } action: { list.offset = $0 }
            }
            .coordinateSpace(name: Self.viewport).scrollIndicators(.hidden)
            .frame(height: bodyHeight)
            // More above or below: that edge fades out instead of ending in a cut.
            .mask(edgeFade)
            // The highlighted option stays in view as the arrows (or a click's keys) move it.
            .onChange(of: prompt.highlighted) { _, index in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(index) } }
            .onAppear { if prompt.highlighted > 0 { DispatchQueue.main.async { proxy.scrollTo(prompt.highlighted) } } }
            // «n» opens the notes of a question with a preview: the field comes into view as it takes the keyboard, and stays in view as what is written grows it (the field is a text
            // view of its own, which does not scroll the card's body to its caret). One turn later, once the layout has the field's new size, and again when the field is done
            // growing (it grows with a short animation, and the body's content is as tall as it was until that has run).
            .onChange(of: notesReveal) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo(Self.notesID) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(Self.notesID) }
            }
            // The model picker's rows are the list's own (not `prompt.options`): the one chosen stays in view, and the list opens at it.
            .onChange(of: modelSelection) { _, index in if let index { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(Self.modelRowID(index)) } } }
            .onAppear {
                guard isModelPicker, let at = pickerSelection else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let frame = modelRowFrames[at], frame.maxY > bodyHeight { proxy.scrollTo(Self.modelRowID(at), anchor: .top) }
                }
            }
        }
    }

    private var edgeFade: some View {
        let top = list.offset > 2
        let bottom = list.height - list.offset - bodyHeight > 2
        return VStack(spacing: 0) {
            LinearGradient(colors: [top ? .clear : .black, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
            Rectangle()
            LinearGradient(colors: [.black, bottom ? .clear : .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isModelPicker {
                modelPickerContent
            } else if PromptCardText.isReview(prompt) {
                reviewContent
            } else if prompt.takesNotes {
                intro.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { introHeight = $0 }
                previewContent
            } else {
                intro
                VStack(spacing: Self.rowGap) {
                    ForEach(prompt.options) { option in row(option).id(option.index) }
                }.padding(.horizontal, 6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What comes before the options: the tabs of a dialog with several questions, the question when it did not fit the bar, its note, a word
    /// for a question that takes several answers, and what the question is about.
    @ViewBuilder private var intro: some View {
        let context = showsContext ? prompt.context.flatMap { $0.isEmpty ? nil : $0 } : nil
        let titled = !inline && !prompt.question.isEmpty
        if !prompt.tabs.isEmpty || titled || prompt.note != nil || prompt.multiSelect || context != nil {
            VStack(alignment: .leading, spacing: 6) {
                if prompt.tabs.count > 0 { tabsRow }
                if titled {
                    Text(prompt.question).font(scaled(12.5, .semibold)).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let note = prompt.note {
                    Text(note).font(scaled(10.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if prompt.multiSelect {
                    Text("Puedes marcar varias. Pulsa una opción para marcarla o quitarla.").font(scaled(10.5)).foregroundStyle(Color.nookSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let context {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(Color.nookSecondary).padding(.top, 2)
                        Text(context).font(.system(size: (10.5 * CGFloat(chatSize / DisplaySettings.defaultChatSize) * 2).rounded() / 2, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.top, 2).padding(.bottom, 8)
        }
    }

    // MARK: Tabs

    /// A dialog with several questions draws a row of tabs, each ticked once it has an answer. The terminal shows which one is open only in
    /// colour, which plain text does not carry, so the row says what is answered and ← → move between them as they do there.
    private var tabsRow: some View {
        HStack(spacing: 5) {
            keyButton(.left, symbol: "chevron.left", help: "Pregunta anterior")
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(Array(prompt.tabs.enumerated()), id: \.offset) { _, tab in TabPill(tab: tab, accent: tint.ink, size: CGFloat(10.5 * chatSize / DisplaySettings.defaultChatSize)) }
                }
            }.scrollIndicators(.hidden).frame(height: 22)
            keyButton(.right, symbol: "chevron.right", help: "Pregunta siguiente")
        }
    }

    private func keyButton(_ key: TerminalKey, symbol: String, help: String) -> some View {
        Button { onKey(key) } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.primary.opacity(0.8))
                .frame(width: 22, height: 22).background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous)).contentShape(Rectangle())
        }.nookPress(symbol: symbol).disabled(busy)
            .help(help + " · " + key.label + (needsAccessibility ? " (requiere Accesibilidad)" : "")).accessibilityLabel(help)
    }

    // MARK: Options

    /// Whether `option` is a text field holding an answer Nook wrote (see `filledFields`).
    private func isFilled(_ option: AgentPrompt.Option) -> Bool { option.input == .inline && filledFields.contains(option.index) }

    private func row(_ option: AgentPrompt.Option) -> some View {
        let current = busy ? (chosen ?? prompt.highlighted) == option.index : option.index == prompt.highlighted
        let filled = isFilled(option)
        let carries = carriesNotes(option)
        return Button { choose(option.index) } label: {
            HStack(alignment: .top, spacing: 9) {
                marker(option, current: current)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(scaled(12, current || option.current ? .medium : .regular)).fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: Self.markerSide, alignment: .leading)
                    if let detail = option.detail {
                        Text(detail).font(scaled(10.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if option.current { CurrentMark() }
                    // A field that holds the user's answer is no place to write any more: the pencil gives way to whose text the row shows.
                    if filled { AnswerMark() }
                    else if option.input != .none { Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.nookSecondary) }
                    // Notes are written and this option takes them: a click sends them with it.
                    if carries { NotesMark() }
                    if let shortcut = option.shortcut { Keycap(text: shortcut) }
                }.frame(minHeight: Self.markerSide)
            }
            .padding(.horizontal, 7).padding(.vertical, 3.5)
            .frame(minHeight: Self.rowHeight)
            .background(fill(current: current, hovering: hovered == option.index), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.accent.opacity(current ? 0.3 : 0), lineWidth: 0.7))
            .contentShape(Rectangle())
            .opacity((busy && !current) || notesBlocked ? 0.45 : 1)
        }
        .nookPress(.none, depth: PressDepth.row)
        .disabled(notesBlocked)
        .onHover { inside in hovered = inside ? option.index : (hovered == option.index ? nil : hovered) }
        .help(help(for: option, current: current))
        .accessibilityLabel(unnumbered(option) ? option.title : "Opción \(option.index + 1): \(option.title)")
        .accessibilityValue([PromptCardText.spoken(option, highlighted: current, filled: filled), carries ? PreviewCopy.spokenWithNotes : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(option.detail ?? "")
    }

    /// The number the terminal prints, in a box the tab's colour fills while it is the option Enter would press; or, in a question that takes
    /// several answers, the box that says whether it is ticked.
    @ViewBuilder private func marker(_ option: AgentPrompt.Option, current: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if let checked = option.checked {
            ZStack {
                shape.fill(checked ? tint.accent : Color.nookWash(0.09))
                if checked { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.black.opacity(0.8)) }
                else { shape.strokeBorder(Color.nookWash(current ? 0.5 : 0.3), lineWidth: 1) }
            }.frame(width: Self.markerSide, height: Self.markerSide)
        } else if unnumbered(option) {
            // «Chat about this» is no numbered answer where the terminal draws the preview: it leaves the dialog, carries no notes and no digit chooses it.
            Image(systemName: "bubble.left").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(current ? Color.black.opacity(0.8) : Color.nookSecondary)
                .frame(width: Self.markerSide, height: Self.markerSide)
                .background(current ? tint.accent : Color.nookWash(0.09), in: shape)
        } else {
            Text("\(option.index + 1)").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(current ? Color.black.opacity(0.8) : Color.nookSecondary)
                .frame(width: Self.markerSide, height: Self.markerSide)
                .background(current ? tint.accent : Color.nookWash(0.09), in: shape)
        }
    }

    private func fill(current: Bool, hovering: Bool) -> Color {
        if current { return tint.accent.opacity(hovering ? 0.22 : 0.15) }
        return Color.nookWash(hovering ? 0.09 : 0)
    }

    /// What the click does, and what it needs. The row shows everything now; this adds the part that is not on it.
    private func help(for option: AgentPrompt.Option, current: Bool) -> String {
        var lines: [String] = []
        let filled = isFilled(option)
        if let words = PromptCardText.inputHelp(option, agentName: agentName, filled: filled) { lines.append(words) }
        // A field's box is ticked by the answer that goes into it, not by the click (`inputHelp` says so); once it holds the answer, the click toggles it as on any option.
        if let checked = option.checked, option.input != .inline || filled { lines.append(checked ? "Marcada: pulsa para quitarla." : "Sin marcar: pulsa para marcarla.") }
        if option.current { lines.append("Es la opción que está en uso ahora.") }
        // Notes written for a question with a preview go with the option chosen, except to «Chat about this», which has no place for them.
        if prompt.takesNotes, notesEditable, hasNotesWritten { lines.append(carriesNotes(option) ? PreviewCopy.rowHelp : PreviewCopy.chatHelp) }
        if notesBlocked { lines.append(PreviewCopy.blockedHelp) }
        // A text field that still waits for its answer takes no Enter from the click, which Nook's composer writes; one that holds it does take it (it toggles the box).
        if current, option.input == .inline, !filled { lines.append("Es la opción marcada en la terminal.") }
        else if current { lines.append("Es la opción marcada en la terminal: solo envía Enter.") }
        // Any other choice reaches a Terminal tab in one write; only arrows alone, to a text field, are key events.
        else if needsAccessibility, prompt.needsDirectKeys(choosing: option.index) {
            lines.append("Llevar la selección a este campo requiere el permiso de Accesibilidad; Nook lo explicará al pulsar.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Adjustment

    /// A setting the dialog changes in place with ← and → (the model picker's effort): what it says now, and the two keys as buttons.
    private func adjustmentRow(_ text: String) -> some View {
        let adjustment = PromptCardText.adjustment(text)
        return HStack(spacing: 8) {
            if let effort = adjustment.effort { EffortGlyph(effort: effort, color: Color.primary.opacity(0.85), size: 12) }
            else { Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(Color.nookSecondary) }
            Text(adjustment.label).font(scaled(11, .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                stepButton(.left, symbol: "chevron.left", help: adjustment.effort == nil ? "Ajustar" : "Menos esfuerzo")
                stepButton(.right, symbol: "chevron.right", help: adjustment.effort == nil ? "Ajustar" : "Más esfuerzo")
            }
        }
        .padding(.horizontal, 10).frame(minHeight: Self.footerRowHeight)
        .background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(adjustment.label)
    }

    private func stepButton(_ key: TerminalKey, symbol: String, help: String) -> some View {
        Button { onKey(key) } label: {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.primary.opacity(0.85))
                .frame(width: 26, height: 22).background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous)).contentShape(Rectangle())
        }.nookPress(symbol: symbol).disabled(busy)
            .help(help + " · " + key.label + (needsAccessibility ? " (requiere Accesibilidad)" : "")).accessibilityLabel(help)
    }
}

// MARK: - Claude's model picker

/// What the card needs of Claude's model picker besides the prompt: the list it offers and how a model is applied.
struct ModelPickerContext {
    /// The models of Claude's picker (Claude Code's own list when it is on disk, whole), with the one in use marked.
    var plan: ModelMenuPlan
    /// A Terminal tab without the Accessibility permission: applying a model for this session only is done with keys.
    var needsAccessibility = false
    /// ↵ is `.default` and S is `.sessionOnly`, as in the picker.
    var onPick: (ClaudeModelChoice, ClaudeModelScope) -> Void
}

/// Claude's own /model picker as a card: the rows of the model button's list (a symbol, the name and Claude's description for each, the number the picker
/// prints, a mark on the one in use), the effort with its ‹ ›, and under them the two ways to apply a model, «Usar por defecto» (↵) and «Solo esta sesión»
/// (S), which are the keys the picker names. A row is chosen first (a click or the arrows) and then applied, as in the picker; nothing is changed by a click
/// on a row. Cancel is the bar's button, as for any question.
extension AgentPromptCard {
    fileprivate static func modelRowID(_ index: Int) -> String { "model-row-\(index)" }
    fileprivate static let pickerContent = "pickerContent"

    /// The row chosen: the one clicked or reached with the arrows, else the one Claude's picker has highlighted, else the model in use.
    fileprivate var pickerSelection: Int? {
        guard let picker = modelPicker else { return nil }
        let rows = picker.plan.rows
        if let modelSelection, rows.indices.contains(modelSelection) { return modelSelection }
        if prompt.options.indices.contains(prompt.highlighted), let at = rows.firstIndex(where: { $0.label == prompt.options[prompt.highlighted].title }) { return at }
        return picker.plan.currentIndex
    }

    /// How many models the picker has that the card's list does not: what the list says it lacks, else what the picker says is below its view (when the
    /// list is no more than the picker's rows).
    private var hiddenModels: Int {
        guard let plan = modelPicker?.plan else { return 0 }
        if case .missing(let count)? = plan.note { return count }
        return plan.rows.count <= prompt.options.count ? prompt.moreBelow : 0
    }

    fileprivate var pickerChoice: ClaudeModelChoice? {
        guard let picker = modelPicker, let at = pickerSelection else { return nil }
        return picker.plan.rows[at]
    }

    private var chatScale: CGFloat { CGFloat(chatSize / DisplaySettings.defaultChatSize) }

    fileprivate var modelPickerContent: some View {
        let rows = modelPicker?.plan.rows ?? []
        return VStack(spacing: Self.rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, choice in modelRow(choice, index: index).id(Self.modelRowID(index)) }
            // Rows the picker keeps out of sight that the list does not have (it came from the rows Nook saw, not from Claude Code's own list).
            if hiddenModels > 0 {
                Text("… +\(hiddenModels) \(hiddenModels == 1 ? "modelo más" : "modelos más") en el selector de Claude").font(scaled(10.5)).foregroundStyle(Color.nookSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.top, 4)
            }
        }.padding(.horizontal, 6).padding(.top, 2).coordinateSpace(name: Self.pickerContent)
    }

    private func modelRow(_ choice: ClaudeModelChoice, index: Int) -> some View {
        let marked = index == pickerSelection
        let key = 1000 + index
        return Button { modelSelection = index } label: {
            ModelRowLabel(choice: choice, number: choice.row, selected: marked, scale: chatScale)
                .padding(.horizontal, 7).padding(.vertical, 3.5)
                .background(fill(current: marked, hovering: hovered == key), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.accent.opacity(marked ? 0.3 : 0), lineWidth: 0.7))
                .contentShape(Rectangle())
        }
        .nookPress(.none, depth: PressDepth.row)
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
        .help(ModelRowLabel.help(for: choice))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pickerContent)) } action: { modelRowFrames[index] = $0 }
        .accessibilityLabel("Modelo \(choice.row.map { "\($0): " } ?? "")\(choice.label)")
        .accessibilityValue([choice.isCurrent ? "actual" : nil, marked ? "elegido" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(choice.detail ?? "")
        .accessibilityAddTraits(marked ? .isSelected : [])
    }

    /// The effort Claude's picker has under its rows (its own keys ← →) and the buttons that apply the model chosen: beside each other when the card is wide
    /// enough (the effort with its name, else with only its ring), else the buttons under the effort.
    fileprivate var modelPickerFooter: some View {
        let buttons = ModelScopeButtons(selection: pickerChoice, needsAccessibility: modelPicker?.needsAccessibility ?? false, scale: min(chatScale, 1.3)) { choice, scope in
            modelPicker?.onPick(choice, scope)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { effortRow(named: true); Spacer(minLength: 6); buttons }
            HStack(spacing: 8) { effortRow(named: false); Spacer(minLength: 6); buttons }
            VStack(alignment: .leading, spacing: 6) { effortRow(named: true); buttons }
        }.padding(.horizontal, 6).padding(.top, Self.footerGap)
    }

    /// The picker's effort, as a pill with its ring and ‹ ›, which press ← and → in the picker; or, when what the picker adjusts is not the effort, the
    /// adjustment as the card has always drawn it.
    @ViewBuilder private func effortRow(named: Bool) -> some View {
        if let adjustment = prompt.adjustment {
            if let effort = PromptCardText.adjustment(adjustment).effort {
                EffortStepper(effort: effort, named: named, scale: min(chatScale, 1.3)) { delta in onKey(delta < 0 ? .left : .right) }
                    .padding(.horizontal, 10).frame(height: 28 * min(chatScale, 1.3))
                    .background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize()
            } else {
                adjustmentRow(adjustment).padding(.horizontal, -6)
            }
        }
    }

    fileprivate func selectModel(number: Int) -> KeyPress.Result {
        guard let rows = modelPicker?.plan.rows, let at = rows.firstIndex(where: { $0.row == number }) else { return .ignored }
        modelSelection = at
        return .handled
    }

    fileprivate func moveModelSelection(_ delta: Int) -> KeyPress.Result {
        guard isModelPicker, !busy, let rows = modelPicker?.plan.rows, !rows.isEmpty else { return .ignored }
        let from = pickerSelection ?? (delta > 0 ? -1 : rows.count)
        modelSelection = min(max(from + delta, 0), rows.count - 1)
        return .handled
    }

    fileprivate func applyModel(_ scope: ClaudeModelScope) -> KeyPress.Result {
        guard isModelPicker, !busy, let choice = pickerChoice else { return .ignored }
        modelPicker?.onPick(choice, scope)
        return .handled
    }
}

// MARK: - The review step

/// The step that sends the answers of several questions: a title, each question as Claude asked it with the answer given (or the lack of one), what
/// Claude warns about, and its closing question over the two ways out. Where the dialog shows this as a paragraph, the card makes a summary one can read
/// at a glance: the answers stand out and the questions step back. The buttons answer as the options do (1 and 2 choose them too).
extension AgentPromptCard {
    fileprivate typealias Review = PromptReviewMetrics

    fileprivate var reviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !prompt.tabs.isEmpty { tabsRow.padding(.horizontal, Review.textInset).padding(.top, 2).padding(.bottom, 8) }
            VStack(spacing: Review.entryGap) {
                if let warning = prompt.warning { reviewNotice(PromptCardText.reviewWarning(warning)) }
                ForEach(Array(prompt.review.enumerated()), id: \.offset) { index, item in reviewEntry(item, index: index) }
            }.padding(.horizontal, Review.edgeInset)
            if !prompt.question.isEmpty {
                Text(PromptCardText.reviewClosing(prompt.question)).font(scaled(11.5, .medium)).foregroundStyle(Color.primary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Review.textInset).padding(.top, Review.closingTop).padding(.bottom, Review.closingBottom)
            }
            reviewActions.padding(.horizontal, Review.edgeInset).padding(.top, prompt.question.isEmpty ? Review.closingTop : 0)
        }
    }

    /// What Claude warns about ("You have not answered all questions"), in the amber of the island's notices.
    fileprivate func reviewNotice(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Review.noticeGap) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: scaledSize(10))).foregroundStyle(AgentPalette.failed)
                .frame(width: scaledSize(Review.noticeMark), alignment: .center).accessibilityHidden(true)
            Text(text).font(scaled(11, .medium)).foregroundStyle(Color.primary.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Review.noticeInset).padding(.vertical, Review.noticeVertical).frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPalette.failed.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AgentPalette.failed.opacity(0.3), lineWidth: 0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aviso: \(text)")
    }

    /// One question: the tab it belongs to as a small label, the answer under it, and the question's own text last and quiet. The label and the
    /// answer are what a review is read for; the question (which can run to a paragraph) is there for whoever wants to recall what was asked, so it
    /// never pushes the answer out of sight.
    fileprivate func reviewEntry(_ item: AgentPrompt.ReviewItem, index: Int) -> some View {
        let label = PromptCardText.reviewLabel(item, index: index, of: prompt.review.count)
        return VStack(alignment: .leading, spacing: Review.partGap) {
            if let label { Text(label).font(scaled(10, .semibold)).foregroundStyle(Color.nookSecondary).lineLimit(1) }
            reviewAnswer(item.answer)
            Text(item.question).font(scaled(11)).foregroundStyle(Color.primary.opacity(0.6)).lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.horizontal, Review.questionInset)
        }
        .padding(.horizontal, Review.entryInset).padding(.vertical, Review.entryVertical).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookWash(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label ?? "Pregunta"): \(item.question)")
        .accessibilityValue(item.answer ?? PromptCardText.unanswered.lowercased())
    }

    /// The answer in the tab's colour with a check, or the amber word for a question that has none.
    @ViewBuilder fileprivate func reviewAnswer(_ answer: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        if let answer {
            HStack(alignment: .firstTextBaseline, spacing: Review.answerMarkGap) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: scaledSize(11.5))).foregroundStyle(tint.ink)
                    .frame(width: scaledSize(Review.answerMark), alignment: .center).accessibilityHidden(true)
                Text(answer).font(scaled(12, .medium)).foregroundStyle(Color.primary.opacity(0.95)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.horizontal, Review.answerInset).padding(.vertical, Review.answerVertical).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.accent.opacity(0.14), in: shape)
            .overlay(shape.strokeBorder(tint.accent.opacity(0.3), lineWidth: 0.7))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Review.answerMarkGap) {
                Image(systemName: "exclamationmark.circle").font(.system(size: scaledSize(11))).foregroundStyle(AgentPalette.failed)
                    .frame(width: scaledSize(Review.answerMark), alignment: .center).accessibilityHidden(true)
                Text(PromptCardText.unanswered).font(scaled(11.5, .medium)).foregroundStyle(AgentPalette.failed)
            }
            .padding(.horizontal, Review.answerInset).padding(.vertical, Review.answerVertical).frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentPalette.failed.opacity(0.1), in: shape)
            .overlay(shape.strokeBorder(AgentPalette.failed.opacity(0.3), lineWidth: 0.7))
        }
    }

    /// The options as buttons: the one that sends is solid in the tab's colour, the others are quiet. Each carries its number, which is also its key.
    fileprivate var reviewActions: some View {
        let primary = PromptCardText.primaryOption(in: prompt)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(prompt.options) { option in reviewAction(option, primary: option.index == primary).id(option.index) } }
            VStack(spacing: 6) { ForEach(prompt.options) { option in reviewAction(option, primary: option.index == primary).id(option.index) } }
        }
    }

    fileprivate func reviewAction(_ option: AgentPrompt.Option, primary: Bool) -> some View {
        let current = busy ? (chosen ?? prompt.highlighted) == option.index : option.index == prompt.highlighted
        let hovering = hovered == option.index
        let title = PromptCardText.decisionTitle(option)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Button { choose(option.index) } label: {
            HStack(spacing: 8) {
                Text("\(option.index + 1)").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(primary ? Color.black.opacity(0.75) : Color.nookSecondary)
                    .frame(width: Self.markerSide, height: Self.markerSide)
                    .background(primary ? Color.black.opacity(0.14) : Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title).font(scaled(12, .semibold)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(primary ? Color.black.opacity(0.85) : Color.primary.opacity(0.88))
                if primary { Image(systemName: "paperplane.fill").font(.system(size: scaledSize(9.5), weight: .semibold)).foregroundStyle(Color.black.opacity(0.7)) }
            }
            .padding(.horizontal, 12).frame(minHeight: Review.actionHeight)
            .frame(maxWidth: primary ? .infinity : nil)
            .background(primary ? tint.accent.opacity(hovering ? 0.92 : 0.82) : Color.nookWash(hovering ? 0.15 : 0.09), in: shape)
            .overlay(shape.strokeBorder(tint.accent.opacity(current && !primary ? 0.45 : 0), lineWidth: 0.8))
            .contentShape(shape)
            .opacity(busy && !current ? 0.45 : 1)
        }
        .nookPress(.none, depth: PressDepth.card)
        .onHover { inside in hovered = inside ? option.index : (hovered == option.index ? nil : hovered) }
        .help(([PromptCardText.decisionHelp(option, agentName: agentName)].compactMap { $0 } + [help(for: option, current: current)]).filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityLabel("Opción \(option.index + 1): \(title)")
        .accessibilityValue(PromptCardText.spoken(option, highlighted: current))
    }
}

// MARK: - The question with a preview

/// Claude's question whose options carry a preview (`AgentPrompt.takesNotes`): the options, the box with the preview of the option the terminal has highlighted, and the
/// notes. Beside each other, as the terminal draws them, when the card has the width for it; stacked when it does not (`PreviewMetrics`). The pieces are in
/// `PreviewQuestionView.swift`; this is how the card puts them together and what a click does with the notes.
///
/// The box follows the terminal's highlight and nothing else: another option's preview would take the arrows, which in a Terminal tab are key events that bring it
/// forward. So the box says which option it belongs to, and a click on any option answers that option, with the notes when there are some.
///
/// Notes are written in the card, beside what they are about, and travel with whichever option is chosen (`AppModel.answer(_:option:notes:on:)`: one write, nothing
/// brought forward). «n» opens the field as in the terminal; ↵ in it sends them with the option the preview belongs to; Esc gives the keyboard back to the card and
/// keeps them. Not while the terminal already holds notes with its field closed (shown read only: they go with the answer all the same), nor while its own field has the
/// keyboard, empty or with text being typed (the card says so, quotes the text and waits: a choice's keys would land in that field).
extension AgentPromptCard {
    fileprivate static let notesID = "promptNotes"

    // MARK: Which option, which notes

    /// The card's width: its own once laid out, else what the caller knew, else the estimate's default.
    fileprivate var cardWidth: CGFloat { measuredWidth ?? width ?? 500 }

    fileprivate var arrangement: PreviewMetrics.Arrangement {
        PreviewMetrics.arrange(prompt.preview, hiddenLines: prompt.previewHiddenLines, width: cardWidth, chatSize: chatSize)
    }

    /// The notes written here: the caller's when it keeps them (they outlive the card), else the card's own.
    fileprivate var notesText: String {
        get { notes?.wrappedValue ?? ownNotes }
        nonmutating set { if let notes { notes.wrappedValue = newValue } else { ownNotes = newValue } }
    }

    fileprivate var hasNotesWritten: Bool { !notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// What the question's notes are now, by what the screen says (`PreviewNotesState`).
    fileprivate var notesState: PreviewNotesState { PreviewNotesState(prompt) }

    /// Nook may write notes: the question takes them and the terminal holds none and has no field of its own open or typed into (`notesFocused`).
    fileprivate var notesEditable: Bool { prompt.takesNotes && notesState == .editable }

    /// The terminal's notes field has the keyboard, empty or with text being typed in it (`notesFocused`): the arrows and Enter of a click land in it (Enter answers the option
    /// Claude has highlighted, not the clicked one), so the options and their digits wait until it is closed. The model refuses too (`AppModel.notesFieldNotice`).
    fileprivate var notesBlocked: Bool {
        guard prompt.takesNotes, case .focused = notesState else { return false }
        return true
    }

    /// «Chat about this» in a question with a preview: no numbered answer. It leaves the dialog and carries no notes, and no digit chooses it (the terminal does not number it).
    fileprivate func unnumbered(_ option: AgentPrompt.Option) -> Bool { prompt.takesNotes && option.number == nil }

    /// A click on `option` would send the notes written now with it.
    fileprivate func carriesNotes(_ option: AgentPrompt.Option) -> Bool { notesEditable && hasNotesWritten && option.number != nil }

    /// The notes that go with option `index`, or nil when it goes alone (nothing written, notes not Nook's to write, or an option that takes none).
    fileprivate func notesToSend(for index: Int) -> String? {
        guard notesEditable, hasNotesWritten, prompt.options.indices.contains(index), prompt.options[index].number != nil else { return nil }
        return notesText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func optionIndex(forDigit digit: Int) -> Int? { PromptCardText.optionIndex(forDigit: digit, in: prompt) }

    // MARK: Keys

    /// «n»: the notes' field takes the keyboard and comes into view.
    fileprivate func openNotes() -> KeyPress.Result {
        guard prompt.takesNotes, notesEditable, !busy else { return .ignored }
        notesFocus += 1
        notesReveal += 1
        return .handled
    }

    /// Esc in the notes' field: the keyboard goes back to the card, so digits choose again, and what is written stays. (Toggled, so it applies whichever way the card thinks
    /// it stands: the field is a text view of its own, which SwiftUI does not always tell it took the keyboard.)
    fileprivate func leaveNotes() {
        focused = false
        DispatchQueue.main.async { focused = true }
    }

    /// ↵ in the notes' field: the option the preview belongs to, with the notes (what ↵ does in the terminal's own notes field).
    fileprivate func submitNotes() {
        guard !busy, let option = prompt.previewOption, notesToSend(for: option) != nil else { return }
        choose(option)
    }

    // MARK: The pieces

    @ViewBuilder fileprivate var previewContent: some View {
        let arrangement = self.arrangement
        if arrangement.beside {
            HStack(alignment: .top, spacing: PreviewMetrics.besideGap) {
                VStack(alignment: .leading, spacing: PreviewMetrics.stackGap) {
                    previewOptions
                    notesBlock
                }.frame(width: arrangement.optionsWidth)
                previewBox(arrangement).frame(maxWidth: .infinity)
            }.padding(.horizontal, PreviewMetrics.edge)
        } else {
            VStack(alignment: .leading, spacing: PreviewMetrics.stackGap) {
                previewOptions
                previewBox(arrangement)
                notesBlock
            }.padding(.horizontal, PreviewMetrics.edge)
        }
    }

    /// The numbered options, and under a rule what the terminal draws under one («Chat about this»), as it does.
    private var previewOptions: some View {
        let others = prompt.options.filter { $0.number == nil }
        return VStack(spacing: Self.rowGap) {
            ForEach(prompt.options.filter { $0.number != nil }) { option in row(option).id(option.index) }
            if !others.isEmpty {
                Rectangle().fill(Color.nookWash(0.08)).frame(height: 0.5).padding(.horizontal, 8).padding(.vertical, 5)
                ForEach(others) { option in row(option).id(option.index) }
            }
        }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { optionsHeight = $0 }
    }

    private func previewBox(_ arrangement: PreviewMetrics.Arrangement) -> some View {
        let at = prompt.previewOption
        let option = at.flatMap { prompt.options.indices.contains($0) ? prompt.options[$0] : nil }
        return PreviewBox(mock: prompt.preview, hiddenLines: prompt.previewHiddenLines, number: option?.number, title: option?.title ?? "", highlighted: at == prompt.highlighted,
                          arrangement: arrangement, cap: previewCap, agentName: agentName, chatSize: chatSize)
    }

    /// The tallest the box may be, so that a mock taller than the card scrolls in its box and never pushes the options out of reach. With room for it the box takes what the
    /// body has left under the intro (and under the options when they stack over it, and over the notes that stand under it), so the whole card is in view and only the mock
    /// scrolls. Without that room (a small island) it may be as tall as the body, which scrolls to it: the box is then in view whole once it is reached.
    private var previewCap: CGFloat? {
        guard maxHeight != nil else { return nil }
        let arrangement = self.arrangement
        let above = introHeight + (arrangement.beside ? 0 : optionsHeight + PreviewMetrics.stackGap)
        let below = arrangement.beside ? 0 : PreviewMetrics.stackGap + PreviewMetrics.notesHeight(prompt, width: arrangement.optionsWidth, chatSize: chatSize, inputSize: inputSize)
        let room = maxBodyHeight - above - below - 4
        return room >= arrangement.minimumHeight ? room : maxBodyHeight - 4
    }

    private var notesBlock: some View {
        let number = prompt.previewOption.flatMap { prompt.options.indices.contains($0) ? prompt.options[$0].number : nil }
        return PreviewNotes(text: Binding(get: { notesText }, set: { notesText = $0 }), state: notesState, agentName: agentName, sendsWith: number,
                            busy: busy, inputSize: inputSize, chatSize: chatSize, focusRequest: notesFocus, onSubmit: submitNotes, onLeave: leaveNotes).id(Self.notesID)
            // What is written grows the field (and puts its caption under it): while it is being typed into it stays in view.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in if keyboard.isTyping { notesReveal += 1 } }
    }
}

/// The review step's measures, shared by the card and by the estimate of its height.
enum PromptReviewMetrics {
    /// The title's and the tabs' column, like the rest of the card's text.
    static let textInset: CGFloat = 13
    /// A question's text stands a little in from the entry's edge, so it does not touch the line of the answer's box above it.
    static let questionInset: CGFloat = 2
    /// Where the entries and the buttons stand: the edge of the options' rows.
    static let edgeInset: CGFloat = 6
    static let entryInset: CGFloat = 10
    static let entryVertical: CGFloat = 8
    static let entryGap: CGFloat = 6
    /// Between the label, the question and the answer of an entry.
    static let partGap: CGFloat = 5
    static let answerInset: CGFloat = 9
    static let answerVertical: CGFloat = 6
    /// The check's column and the gap after it.
    static let answerMark: CGFloat = 12
    static let answerMarkGap: CGFloat = 7
    static let noticeInset: CGFloat = 10
    static let noticeVertical: CGFloat = 6
    static let noticeMark: CGFloat = 12
    static let noticeGap: CGFloat = 7
    static let closingTop: CGFloat = 10
    static let closingBottom: CGFloat = 6
    static let actionHeight: CGFloat = 30
}

// MARK: - Words

/// How the card puts the dialog's parts: pure, so the tests can hold them without a window.
enum PromptCardText {
    /// Whether the question goes in the bar beside the mark: it is short, has one paragraph, and there are no tabs over it. A longer one
    /// opens the body and wraps there at the card's whole width.
    static func isInline(_ prompt: AgentPrompt, hasAccessory: Bool) -> Bool {
        prompt.review.isEmpty && prompt.tabs.isEmpty && !prompt.question.isEmpty && !prompt.question.contains("\n") && prompt.question.count <= (hasAccessory ? 38 : 52)
    }

    /// Nook's title for Claude's model picker ("Select model").
    static let modelPickerTitle = "Elegir modelo"

    /// Who is asking, for a bar whose question is in the body or missing; also what the composer's bar says when the screen has no question to repeat
    /// (`FieldAnswerBar`).
    static func kindLabel(_ prompt: AgentPrompt, agentName: String) -> String {
        switch prompt.kind {
        case .approval: return "\(agentName) pide permiso"
        case .question: return "\(agentName) pregunta"
        case .selector: return "Elige una opción"
        }
    }

    /// What choosing an option that asks for text does, for the tooltip's first line (nil for one that does not). The text field is answered in Nook's
    /// composer, with nothing pressed in the terminal until the answer goes; "Chat about this" and its like leave the dialog and ask the user to tell the
    /// agent something next. A field that already holds the user's answer (`filled`: a question with several answers) takes no more text, and the text
    /// is changed in the terminal: the click only toggles its box, which the tooltip's next line says.
    static func inputHelp(_ option: AgentPrompt.Option, agentName: String, filled: Bool = false) -> String? {
        switch option.input {
        case .inline:
            if filled { return "Ya tiene tu respuesta; para cambiar el texto, edítalo en la terminal." }
            if option.checked != nil { return "Escribes tu texto en Nook y se envía a este campo de \(agentName); al enviarlo, su casilla queda marcada." }
            return "Escribes tu respuesta en Nook y se envía a este campo de \(agentName)."
        case .followUp: return "Elige esta opción y después escribes en Nook lo que \(agentName) debe hacer."
        case .none: return nil
        }
    }

    /// "Submit" is the tab that sends the answers.
    static func tabTitle(_ tab: AgentPrompt.Tab) -> String { tab.isSubmit ? "Enviar" : tab.title }

    /// The option a digit chooses: the one at that position, or, where the terminal draws a preview beside the options, the one it numbers that («Chat about this» has no
    /// number there, and no digit chooses it). Nil for a digit with no option.
    static func optionIndex(forDigit digit: Int, in prompt: AgentPrompt) -> Int? {
        if prompt.takesNotes { return prompt.options.firstIndex { $0.number == digit } }
        return (1...max(1, prompt.options.count)).contains(digit) && digit <= prompt.options.count ? digit - 1 : nil
    }

    // MARK: The review step

    /// The last step of a dialog with several questions: a summary of each one with its answer (see `AgentPrompt.review`).
    static func isReview(_ prompt: AgentPrompt) -> Bool { !prompt.review.isEmpty }

    static let reviewTitle = "Revisa tus respuestas"
    static let unanswered = "Sin responder"

    /// A phrase as Claude words it, compared without its case and its marks of punctuation.
    private static func plain(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Claude's warning on the review step in Spanish when it is the one it always gives; anything else as Claude words it.
    static func reviewWarning(_ text: String) -> String {
        plain(text) == "you have not answered all questions" ? "No has respondido todas las preguntas." : text
    }

    /// Claude's closing question in Spanish when it is the one it always asks; anything else as Claude words it.
    static func reviewClosing(_ text: String) -> String {
        plain(text) == "ready to submit your answers" ? "¿Listo para enviar tus respuestas?" : text
    }

    /// An option of the review step as a button: "Submit answers" and "Cancel" in Spanish, any other as the dialog words it.
    static func decisionTitle(_ option: AgentPrompt.Option) -> String {
        switch plain(option.title) {
        case "submit answers", "submit": return "Enviar respuestas"
        case "cancel": return "Cancelar"
        default: return option.title
        }
    }

    /// What a button of the review step does, when its words say it: the tooltip's first line.
    static func decisionHelp(_ option: AgentPrompt.Option, agentName: String) -> String? {
        switch plain(option.title) {
        case "submit answers", "submit": return "Envía las respuestas a \(agentName)."
        case "cancel": return "Cancela sin enviar las respuestas."
        default: return nil
        }
    }

    /// The option that sends the answers (the solid button), as an index into `prompt.options`: the first whose words say it sends; else the first.
    static func primaryOption(in prompt: AgentPrompt) -> Int {
        let sends = ["submit", "send", "enviar", "confirm"]
        return prompt.options.first { option in sends.contains { plain(option.title).hasPrefix($0) } }?.index ?? prompt.options.first?.index ?? 0
    }

    /// The small label over a question: its tab's name, or its number when the tabs do not name it (nothing for a single question).
    static func reviewLabel(_ item: AgentPrompt.ReviewItem, index: Int, of count: Int) -> String? {
        if let tab = item.tab, !tab.isEmpty { return tab }
        return count > 1 ? "Pregunta \(index + 1)" : nil
    }

    /// What a setting changed with ← → says, in Spanish when it is the effort ("Medium effort (default)" is "Esfuerzo: Medio (predeterminado)");
    /// anything else as the dialog words it.
    static func adjustment(_ text: String) -> (effort: ClaudeEffort?, label: String) {
        let pattern = try! NSRegularExpression(pattern: #"^(\w+) effort(?:\s*\(([^)]*)\))?\s*$"#, options: [.caseInsensitive])
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let level = ClaudeEffort(rawValue: ns.substring(with: match.range(at: 1)).lowercased()) else { return (nil, text) }
        var label = "Esfuerzo: \(level.title)"
        if match.range(at: 2).location != NSNotFound {
            let note = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            label += " (\(note.lowercased() == "default" ? "predeterminado" : note))"
        }
        return (level, label)
    }

    /// What VoiceOver says about an option beyond its label.
    static func spoken(_ option: AgentPrompt.Option, highlighted: Bool, filled: Bool = false) -> String {
        var parts: [String] = []
        if let checked = option.checked { parts.append(checked ? "con casilla marcada" : "con casilla sin marcar") }
        if filled { parts.append("con tu respuesta") }
        if option.current { parts.append("actual") }
        if highlighted { parts.append("resaltada") }
        return parts.joined(separator: ", ")
    }

    // MARK: Measuring

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, mono: Bool = false, chatSize: Double) -> NSFont {
        let scaled = (size * CGFloat(chatSize / DisplaySettings.defaultChatSize) * 2).rounded() / 2
        return mono ? NSFont.monospacedSystemFont(ofSize: scaled, weight: weight) : NSFont.systemFont(ofSize: scaled, weight: weight)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat { font.ascender - font.descender + font.leading }

    /// A line of `font` as SwiftUI sets it in a paragraph of its own: its ascent and its descent each rounded up to a whole point (11 pt text takes
    /// 14 pt a line, where the font's own metrics say 13), which adds up over a long text.
    private static func setHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading) }

    /// The height of `count` lines of `font` as SwiftUI sets them, with `spacing` between them.
    private static func set(_ count: Int, _ font: NSFont, spacing: CGFloat = 0) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * setHeight(font) + CGFloat(count - 1) * spacing
    }

    /// How many lines `text` takes at `width` in `font`.
    static func lines(_ text: String, font: NSFont, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 0 }
        let box = (text as NSString).boundingRect(with: NSSize(width: max(40, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return max(1, Int((box.height / lineHeight(font)).rounded()))
    }

    /// The height of `count` lines of `font`, with `spacing` between them.
    private static func block(_ count: Int, _ font: NSFont, spacing: CGFloat = 0) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * lineHeight(font) + CGFloat(count - 1) * spacing
    }

    /// The body's height as the card lays it out (what comes before the options, and the options with their descriptions wrapped), worked out from
    /// the texts at the card's `width`. The card measures itself once it is on screen; this is for what has to be known before, and without waiting
    /// for it: the first frame, and whether the card will take the pane (`SessionPane.covered`). `showsContext` adds the line of what the question
    /// is about, which the card shows only when it takes the pane.
    static func estimatedBodyHeight(_ prompt: AgentPrompt, inline: Bool, width: CGFloat = 500, chatSize: Double = DisplaySettings.defaultChatSize, showsContext: Bool = false,
                                    modelPicker: Bool = false, filled: Set<Int> = [], inputSize: Double = DisplaySettings.defaultInputSize) -> CGFloat {
        if modelPicker { return estimatedModelPickerHeight(prompt, width: width, chatSize: chatSize) }
        if isReview(prompt) { return estimatedReviewHeight(prompt, width: width, chatSize: chatSize) }
        var height = estimatedIntro(prompt, inline: inline, width: width, chatSize: chatSize, showsContext: showsContext)
        // A question with a preview lays its options, the box and the notes out by the card's width (`PreviewMetrics`).
        if prompt.takesNotes { return ceil(height + estimatedPreviewHeight(prompt, width: width, chatSize: chatSize, filled: filled, inputSize: inputSize)) }
        // The marker, the gap after it and the rows' own padding come out of the list's width; what stands at a row's end takes more.
        let rowText = width - 12 - 14 - 17 - 9
        for option in prompt.options { height += estimatedRowHeight(option, rowText: rowText, filled: filled, chatSize: chatSize) }
        return ceil(height + CGFloat(max(0, prompt.options.count - 1)) * AgentPromptCard.rowGap)
    }

    /// What comes before the options: the tabs of a dialog with several questions, the question when it did not fit the bar, its note, a word for a question that takes
    /// several answers, and what the question is about (`AgentPromptCard.intro`).
    static func estimatedIntro(_ prompt: AgentPrompt, inline: Bool, width: CGFloat, chatSize: Double, showsContext: Bool = false) -> CGFloat {
        func f(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { font(size, weight, chatSize: chatSize) }
        let introWidth = width - 26
        var intro: [CGFloat] = []
        if !prompt.tabs.isEmpty { intro.append(22) }
        if !inline, !prompt.question.isEmpty { intro.append(block(lines(prompt.question, font: f(12.5, .semibold), width: introWidth), f(12.5, .semibold), spacing: 1.5)) }
        if let note = prompt.note { intro.append(block(lines(note, font: f(10.5), width: introWidth), f(10.5))) }
        if prompt.multiSelect {
            let hint = "Puedes marcar varias. Pulsa una opción para marcarla o quitarla."
            intro.append(block(lines(hint, font: f(10.5), width: introWidth), f(10.5)))
        }
        if showsContext, let context = prompt.context, !context.isEmpty {
            let mono = font(10.5, mono: true, chatSize: chatSize)
            intro.append(block(lines(context, font: mono, width: introWidth - 36), mono) + 10)
        }
        return intro.isEmpty ? 0 : intro.reduce(0, +) + CGFloat(intro.count - 1) * 6 + 2 + 8
    }

    /// One option's row as the card lays it out, when its title and description have `rowText` points between the marker and the row's end (less what stands there).
    /// `emphasized` is the row that has the highlight, whose title the card sets a weight heavier.
    private static func estimatedRowHeight(_ option: AgentPrompt.Option, rowText: CGFloat, filled: Set<Int>, chatSize: Double, extraTrailing: CGFloat = 0, emphasized: Bool = false) -> CGFloat {
        func f(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { font(size, weight, chatSize: chatSize) }
        // What stands at a row's end: the mark of the option in use, the pencil of a field that takes text (or «Tu respuesta» in one that holds it), and its key.
        let field: CGFloat = option.input == .none ? 0 : (option.input == .inline && filled.contains(option.index) ? AnswerMark.width : 15)
        let trailing: CGFloat = (option.current ? 62 : 0) + field + (option.shortcut != nil ? 44 : 0) + extraTrailing
        let textWidth = rowText - (trailing > 0 ? trailing + 9 : 0)
        let titleFont = f(12, option.current || emphasized ? .medium : .regular)
        var inner = max(17, block(lines(option.title, font: titleFont, width: textWidth), titleFont))
        if let detail = option.detail { inner += 2 + block(lines(detail, font: f(10.5), width: textWidth), f(10.5)) + 1 }
        return max(AgentPromptCard.rowHeight, inner + 7)
    }

    /// What follows the intro of a question with a preview: its options with the box and the notes, beside each other or stacked as `PreviewMetrics.arrange` says. The box
    /// is counted as tall as its mock (the card caps it by the room it has once it is laid out), and the notes as their empty field.
    static func estimatedPreviewHeight(_ prompt: AgentPrompt, width: CGFloat, chatSize: Double, filled: Set<Int> = [], inputSize: Double = DisplaySettings.defaultInputSize) -> CGFloat {
        typealias M = PreviewMetrics
        let arrangement = M.arrange(prompt.preview, hiddenLines: prompt.previewHiddenLines, width: width, chatSize: chatSize)
        let column = arrangement.optionsWidth
        let options = estimatedPreviewOptions(prompt, column: column, chatSize: chatSize, filled: filled)
        let notes = M.notesHeight(prompt, width: column, chatSize: chatSize, inputSize: inputSize)
        if arrangement.beside { return max(options + M.stackGap + notes, arrangement.naturalHeight) }
        return options + M.stackGap + arrangement.naturalHeight + M.stackGap + notes
    }

    /// The options of a question with a preview in a column `column` points wide: the numbered rows, and under a rule what the terminal does not number («Chat about this»).
    /// A row has the marker, the gap after it and its own padding to spare, as in any other card, and the gap that stands before its (empty) end: a column this narrow
    /// wraps a title at the point where those nine points make the difference.
    static func estimatedPreviewOptions(_ prompt: AgentPrompt, column: CGFloat, chatSize: Double, filled: Set<Int> = []) -> CGFloat {
        let rowText = column - 14 - 17 - 9 - 9
        let numbered = prompt.options.filter { $0.number != nil }, others = prompt.options.filter { $0.number == nil }
        func row(_ option: AgentPrompt.Option) -> CGFloat {
            estimatedRowHeight(option, rowText: rowText, filled: filled, chatSize: chatSize, emphasized: option.index == prompt.highlighted)
        }
        var parts = numbered.map(row)
        if !others.isEmpty { parts.append(PreviewMetrics.ruleHeight); parts += others.map(row) }
        return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * AgentPromptCard.rowGap
    }

    /// Claude's model picker's body as the card lays it out: a row for each option (the badge, the name and the description at two lines at the most), with
    /// the number's box in front. (The card shows the model button's whole list, which can have more rows than the picker has in view; this is for the
    /// decision of whether it covers the conversation, which a picker's dozen rows settle however they are counted.)
    private static func estimatedModelPickerHeight(_ prompt: AgentPrompt, width: CGFloat, chatSize: Double) -> CGFloat {
        func f(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { font(size, weight, chatSize: chatSize) }
        let k = CGFloat(chatSize / DisplaySettings.defaultChatSize)
        var height: CGFloat = 2
        for option in prompt.options {
            // The row's words have the card's width less the body's padding, the row's, the number's box, the badge, the gaps, and the mark of the one in use.
            let textWidth = width - 12 - 14 - (17 + 8) * k - (22 + 8) * k - (option.current ? 72 * k : 0)
            let choice = ClaudeModelChoice(label: option.title, detail: option.detail, isCurrent: option.current)
            var text = max(15 * k, setHeight(f(11.5, .medium)))
            if option.detail != nil, !ModelRowLabel.fitsOneLine(choice, width: textWidth, scale: k), let detail = option.detail {
                text += 1.5 + set(min(2, lines(detail, font: f(10.5), width: textWidth)), f(10.5))
            }
            height += max(22 * k, text) + 7
        }
        return ceil(height + CGFloat(max(0, prompt.options.count - 1)) * AgentPromptCard.rowGap + (prompt.moreBelow > 0 ? 24 : 0))
    }

    /// What stands under the body: a setting changed in place (the effort, with its ← →) and, in Claude's model picker, the buttons that apply a model: one
    /// row with the effort when the card is wide enough for both (about 380 pt at the design's text size, the effort's ring and arrows with no name), else
    /// the buttons under it.
    static func estimatedFooter(_ prompt: AgentPrompt, modelPicker: Bool, width: CGFloat = 500, chatSize: Double = DisplaySettings.defaultChatSize) -> CGFloat {
        if modelPicker {
            let k = CGFloat(chatSize / DisplaySettings.defaultChatSize)
            let sideBySide = prompt.adjustment == nil || width >= 380 * min(k, 1.3)
            return AgentPromptCard.footerGap + 28 * min(k, 1.3) + (sideBySide ? 0 : 6 + 28 * min(k, 1.3))
        }
        return prompt.adjustment == nil ? 0 : AgentPromptCard.footerGap + AgentPromptCard.footerRowHeight
    }

    /// The review step's body as the card lays it out: the tabs, a notice when Claude warns, each question with its answer, the closing question and
    /// the buttons (side by side, which is how they stand unless their words are very long).
    private static func estimatedReviewHeight(_ prompt: AgentPrompt, width: CGFloat, chatSize: Double) -> CGFloat {
        typealias M = PromptReviewMetrics
        func f(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { font(size, weight, chatSize: chatSize) }
        // The icons' columns grow with the text, as the card scales them.
        func scaled(_ size: CGFloat) -> CGFloat { (size * CGFloat(chatSize / DisplaySettings.defaultChatSize) * 2).rounded() / 2 }
        var height: CGFloat = prompt.tabs.isEmpty ? 0 : 2 + 22 + 8
        let inner = width - 2 * M.edgeInset
        var parts: [CGFloat] = []
        if let warning = prompt.warning {
            let room = inner - 2 * M.noticeInset - scaled(M.noticeMark) - M.noticeGap
            parts.append(set(lines(reviewWarning(warning), font: f(11, .medium), width: room), f(11, .medium)) + 2 * M.noticeVertical)
        }
        for (index, item) in prompt.review.enumerated() {
            var stack: [CGFloat] = []
            if reviewLabel(item, index: index, of: prompt.review.count) != nil { stack.append(setHeight(f(10, .semibold))) }
            let text = inner - 2 * M.entryInset
            if let answer = item.answer {
                let room = text - 2 * M.answerInset - scaled(M.answerMark) - M.answerMarkGap
                stack.append(max(M.answerMark, set(lines(answer, font: f(12, .medium), width: room), f(12, .medium))) + 2 * M.answerVertical)
            } else {
                stack.append(max(M.answerMark, setHeight(f(11.5, .medium))) + 2 * M.answerVertical)
            }
            stack.append(set(lines(item.question, font: f(11), width: text - 2 * M.questionInset), f(11), spacing: 1.5))
            parts.append(stack.reduce(0, +) + CGFloat(stack.count - 1) * M.partGap + 2 * M.entryVertical)
        }
        height += parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * M.entryGap
        if prompt.question.isEmpty {
            height += M.closingTop
        } else {
            let closing = f(11.5, .medium)
            height += M.closingTop + set(lines(reviewClosing(prompt.question), font: closing, width: width - 2 * M.textInset), closing) + M.closingBottom
        }
        return ceil(height + M.actionHeight)
    }

    /// The whole card's height at `width`: its bar (taller when a short question wraps there), its body, the adjustment's row, its bottom edge.
    static func estimatedHeight(_ prompt: AgentPrompt, width: CGFloat, chatSize: Double = DisplaySettings.defaultChatSize, hasAccessory: Bool, showsContext: Bool = false,
                                modelPicker: Bool = false, filled: Set<Int> = [], inputSize: Double = DisplaySettings.defaultInputSize) -> CGFloat {
        let inline = !modelPicker && isInline(prompt, hasAccessory: hasAccessory)
        var bar = AgentPromptCard.headerHeight
        if inline {
            // The question shares the bar with the mark, the label chip, the capsule and the two buttons.
            let chip = prompt.header.map { (($0 as NSString).size(withAttributes: [.font: font(10.5, .semibold, chatSize: chatSize)]).width) + 16 + 8 } ?? 0
            let room = width - 19 - 22 - chip - (hasAccessory ? 126 : 0) - 96 - 32 - 8
            bar = max(bar, 10 + max(22, block(min(3, lines(prompt.question, font: font(12, .semibold, chatSize: chatSize), width: room)), font(12, .semibold, chatSize: chatSize))))
        }
        let footer = estimatedFooter(prompt, modelPicker: modelPicker, width: width, chatSize: chatSize)
        return ceil(bar + estimatedBodyHeight(prompt, inline: inline, width: width, chatSize: chatSize, showsContext: showsContext, modelPicker: modelPicker, filled: filled,
                                              inputSize: inputSize) + footer + AgentPromptCard.bottomInset)
    }
}

// MARK: - Pieces

/// Where a scrolling list is: how far it moved and how tall it is, measured from inside it.
private struct ListMetrics: Equatable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
}

/// A key's name on a small cap, like the ones on the key strip.
private struct Keycap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.nookSecondary)
            .padding(.horizontal, 4.5).frame(height: 15)
            .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The mark of who asks, at the start of the card's bar and of the composer's while it answers a text field (`FieldAnswerBar`): Claude's own spinner glyph in
/// its colour, or Codex's symbol.
struct AskingMark: View {
    var agent: TerminalAgent?
    var body: some View {
        Group {
            if agent == .codex { Image(systemName: SessionKind.codex.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.nookSecondary) }
            else { Text("✻").font(.system(size: 14, weight: .bold)).foregroundStyle(claudeSpinner) }
        }.frame(width: 14, height: 22).accessibilityHidden(true)
    }
}

/// The label Claude puts over a single question ("Database"), in the colour of who is asking.
struct LabelChip: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            .foregroundStyle(claudeSpinner)
            .padding(.horizontal, 8).frame(height: 20)
            .background(claudeSpinner.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("Pregunta: \(text)")
    }
}

/// What a text field says once Nook wrote the user's answer into it (a question with several answers keeps its dialog, the field showing the text with its
/// box ticked): the row's words are the user's own. It stands where the pencil of a field that still takes text does, and says the opposite: nothing more is
/// written here. The user's colour, as everything the user said is.
struct AnswerMark: View {
    @Environment(\.tabTint) private var tint
    /// About how wide it stands at a row's end, with the gap before it (the height estimate counts it).
    static let width: CGFloat = 74

    var body: some View {
        Text("Tu respuesta").font(.system(size: 9.5, weight: .semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(tint.ink)
            .padding(.horizontal, 6).frame(height: 17)
            .background(tint.accent.opacity(0.15), in: Capsule())
            .accessibilityHidden(true)
    }
}

/// What a picker marks as set now ("Sonnet ✔" in the model picker).
struct CurrentMark: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
            Text("Actual").font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(AgentPalette.done)
        .padding(.horizontal, 6).frame(height: 17)
        .background(AgentPalette.done.opacity(0.15), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// One tab of a dialog with several questions: ticked once answered, and the one that sends the answers called by what it does.
private struct TabPill: View {
    var tab: AgentPrompt.Tab
    var accent: Color
    var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(PromptCardText.tabTitle(tab)).font(.system(size: size, weight: .medium)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(tab.answered ? accent : (tab.isSubmit ? Color.primary.opacity(0.85) : Color.nookSecondary))
        .padding(.horizontal, 8).frame(height: 22)
        .background(tab.answered ? accent.opacity(0.16) : Color.nookWash(tab.isSubmit ? 0.1 : 0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.isSubmit ? "Enviar las respuestas" : "Pregunta: \(tab.title)")
        .accessibilityValue(tab.answered ? "respondida" : "sin responder")
    }

    private var symbol: String {
        if tab.isSubmit { return "paperplane" }
        return tab.answered ? "checkmark.square.fill" : "square"
    }
}
