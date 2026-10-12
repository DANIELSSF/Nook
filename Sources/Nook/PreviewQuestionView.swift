import SwiftUI
import AppKit

// Claude's question whose options carry a preview (`AgentPrompt.takesNotes`), as the card draws it: the options, the highlighted option's mock in a box of its own,
// and a field for notes that travel with whichever option is chosen. The terminal draws the options in a column and the mock in a box beside it; the card keeps that
// shape while it has the room for it, and stacks them when it does not.
//
//   PreviewCopy      the words, in Spanish (pure; the tests hold them)
//   PreviewMetrics   how the options, the box and the notes are laid out for a card's width (pure): beside or stacked, the mock's text size, every height
//   PreviewBox       the box: which option it belongs to, the mock in a monospaced font with its whitespace, the fold Claude makes of what it keeps out
//   PreviewNotes     the notes: a field Nook writes into, notes the terminal already holds (read only), or its notes field open (the card says so and waits)
//   NotesMark        what a row carries while notes are written: a click on it sends them
//   WrittenNotes     the notes written for one question, kept by the pane so they outlive the card (folding it away, a redraw that blinks the dialog off)
//   WrittenNotesStore  the same, by tab, so they outlive the pane too (the user goes to another tab and comes back)

// MARK: - Words

/// The words of the preview and its notes. The mock is Claude's; everything else is Nook's.
enum PreviewCopy {
    static let label = "Vista previa"
    /// An option Claude gave no preview ("No preview available" in its box).
    static let none = "Esta opción no tiene vista previa."

    /// What the fold says: Claude keeps lines of the mock out of its box when the terminal is short (the box is at most the terminal's height less 26 rows), and the
    /// terminal has no key to see them. The box says so where the mock ends, in the amber the terminal draws it in.
    static func hidden(_ count: Int, agentName: String) -> String { "\(agentName) oculta \(count) \(count == 1 ? "línea más" : "líneas más")" }
    static func hiddenHelp(_ count: Int, agentName: String) -> String {
        "\(agentName) no muestra \(count == 1 ? "una línea" : "\(count) líneas") de esta vista previa porque la ventana de la terminal es baja, y en la terminal tampoco se ven. Con una más alta se verían."
    }

    /// What VoiceOver hears for the box's label.
    static func spokenLabel(number: Int?, title: String) -> String {
        number.map { "Vista previa de la opción \($0): \(title)" } ?? "Vista previa de \(title)"
    }

    /// The mock for VoiceOver: its words without the frames and rules it is drawn with, which would be read as "box drawings light horizontal".
    static func spoken(_ mock: String) -> String {
        let frame = Set("─━═╌┄╍┈┉┅│┃║╎╏┆┇┊┋╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝▏▕")
        return mock.split(separator: "\n", omittingEmptySubsequences: true).map { row -> String in
            row.filter { !frame.contains($0) }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Notes

    static let placeholder = "Añadir notas"
    static func fieldHelp(agentName: String) -> String {
        "Notas para \(agentName) sobre la opción que elijas: se envían con ella. Atajo: n."
    }
    static let fieldLabel = "Notas"
    static func fieldHint(agentName: String) -> String {
        "Opcional. Se envían a \(agentName) con la opción que elijas. Intro las envía con la opción de la vista previa; Escape vuelve a las opciones."
    }

    /// What stands under the field once something is written: that the choice carries it, and what ↵ does.
    static func caption(sendsWith number: Int?) -> String {
        guard let number else { return "Se envían con la opción que elijas." }
        return "Se envían con la opción que elijas, o con ↵ en la opción \(number)."
    }

    static let rowHelp = "Se envía con tus notas."
    static let chatHelp = "Esta opción no lleva las notas."
    static let spokenWithNotes = "se envía con tus notas"

    /// Notes the terminal already holds, its field closed: they travel with the answer all the same, and are changed there.
    static let heldLabel = "Notas escritas en la terminal"
    static let heldCaption = "Se envían con la opción que elijas. Para cambiarlas, edítalas en la terminal."
    /// Claude's notes field has the terminal's keyboard, empty or with what is being typed in it: what Nook presses would land in it (an arrow moves its cursor, Enter answers
    /// the option Claude has highlighted), so the card says so and leaves the choice to the terminal until the field is closed. The same remedy as the model's notice.
    static let focusedLabel = "El campo de notas está abierto en la terminal."
    /// What is typed in it so far, when something is: not held yet, and not Nook's to send.
    static func focusedTyped(_ notes: String) -> String { "Escrito allí: «\(notes)»" }
    static let focusedCaption = "Ciérralo allí con Esc, o termina allí tu respuesta."
    /// A row's tooltip while the field has the keyboard.
    static let blockedHelp = "El campo de notas está abierto en la terminal: ciérralo allí con Esc, o termina allí tu respuesta."
}

// MARK: - What the notes are

/// What a question's notes are right now, by what the screen says (`AgentPrompt.notes`, `notesOpen`, `notesFocused`): one reading for the card's rows and keys, the notes'
/// block and the estimate of its height.
enum PreviewNotesState: Equatable {
    /// Nook may write them: the terminal holds none and has no field open.
    case editable
    /// The terminal holds notes with its field closed: read only here, and they go with whichever option is answered.
    case held(String)
    /// Claude's notes field has the terminal's keyboard, empty or with the text typed so far: the arrows and Enter of a choice would land in it (the model refuses), so the
    /// options wait. An open field with nothing in it is focused by definition (`notesOpen`, the placeholder); with text in it, it is what the key hint says
    /// (`notesFocused`), which is what tells text being typed from notes held.
    case focused(typed: String?)

    init(_ prompt: AgentPrompt) {
        if prompt.notesFocused || prompt.notesOpen { self = .focused(typed: prompt.notes) }
        else if let notes = prompt.notes { self = .held(notes) }
        else { self = .editable }
    }
}

// MARK: - Measures

/// How the preview question's body is laid out at a card's width. Pure: the card draws what this says and the pane's estimate of the card's height asks it too, so the
/// two cannot drift.
///
/// The options and the box stand side by side, as in the terminal, when the mock fits the box at a size that still reads; otherwise (a narrow island, or a mock wider
/// than the room beside the options) they stack and the box takes the card's whole width. The mock keeps the size it is drawn at as long as it fits and shrinks to fit
/// down to a floor; past it the box scrolls across.
enum PreviewMetrics {
    /// The mock's size at the design's text size, and the least it is made to shrink to fit.
    static let nominalSize: CGFloat = 10.5
    static let floorSize: CGFloat = 9
    /// The options' share of the card's width beside the box, within these bounds (at the design's text size).
    static let optionsShare: CGFloat = 0.36
    static let optionsRange: ClosedRange<CGFloat> = 170...236
    /// The narrowest box worth putting beside the options (at the design's text size).
    static let besideMinimum: CGFloat = 220
    static let besideGap: CGFloat = 8
    /// Where the options stand from the card's edge: as the rows of any other question.
    static let edge: CGFloat = 6
    /// Between the options, the box and the notes when they stack, and between the options and the notes beside the box.
    static let stackGap: CGFloat = 8
    static let insetX: CGFloat = 9
    static let insetY: CGFloat = 8
    static let headerHeight: CGFloat = 26
    static let foldHeight: CGFloat = 22
    /// What the box shows for an option without a preview, under its header.
    static let emptyHeight: CGFloat = 40
    /// Lines of the mock the box never gives up for the room, when it has that many.
    static let minLines = 4
    /// The rule over «Chat about this», with the air around it.
    static let ruleHeight: CGFloat = 10.5
    /// The field's own padding; with one line of the input text it is the height a row has.
    static let fieldPadding: CGFloat = 3
    static let fieldMinHeight: CGFloat = 28
    /// The mark a row grows at its end while notes are written: a circle as wide as the number's box.
    static let markWidth: CGFloat = 17
    /// How many lines of what is being typed in the terminal's field the notice quotes.
    static let focusedTypedLines = 3

    static func scale(_ chatSize: Double) -> CGFloat { CGFloat(chatSize / DisplaySettings.defaultChatSize) }
    private static func halves(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    struct Arrangement: Equatable {
        /// The box stands beside the options.
        var beside: Bool
        /// Beside the box, the options' column; stacked, the whole row.
        var optionsWidth: CGFloat
        /// The box's own width.
        var boxWidth: CGFloat
        /// The mock's monospaced size, and the height of one of its lines as SwiftUI sets it.
        var fontSize: CGFloat
        var lineHeight: CGFloat
        var lines: Int
        /// The widest line does not fit even at the floor: the box scrolls across.
        var scrollsAcross: Bool
        var hiddenLines: Int
        var hasPreview: Bool

        /// The mock with its padding.
        var contentHeight: CGFloat { CGFloat(lines) * lineHeight + 2 * PreviewMetrics.insetY }
        var footerHeight: CGFloat { hiddenLines > 0 ? PreviewMetrics.foldHeight : 0 }
        /// The box as tall as its whole mock: its header, the mock, the fold.
        var naturalHeight: CGFloat { PreviewMetrics.headerHeight + (hasPreview ? contentHeight : PreviewMetrics.emptyHeight) + footerHeight }
        /// The least it is made to take, however little room there is: a few lines of the mock.
        var minimumHeight: CGFloat {
            hasPreview ? PreviewMetrics.headerHeight + 2 * PreviewMetrics.insetY + CGFloat(min(lines, PreviewMetrics.minLines)) * lineHeight + footerHeight : naturalHeight
        }

        /// The box's height when it may take `cap` at the most (nil: as much as it needs). A mock taller than that scrolls inside the box, under its header and over the fold.
        func height(cap: CGFloat?) -> CGFloat {
            guard let cap else { return naturalHeight }
            return min(naturalHeight, max(cap, minimumHeight))
        }

        func scrollsDown(cap: CGFloat?) -> Bool { naturalHeight > height(cap: cap) + 0.5 }
    }

    /// How wide `text` is at one point of size, in its widest line, and how many lines it has. Measured big and scaled down: a small size rounds its advances.
    struct Ink: Equatable {
        var widest: CGFloat
        var lines: Int
    }
    private static var inked: (text: String, ink: Ink)?

    /// The mock as it is drawn: its tabs are spaces (a screen has none, and a text view would draw them wide).
    static func displayed(_ mock: String) -> String { mock.replacingOccurrences(of: "\t", with: "    ") }

    /// The mock's font. Menlo, not the system's monospaced font: that one draws the horizontal rules of a frame as dashes at the fractional sizes a mock is fitted to (its
    /// glyphs overlap a little at each joint), where Menlo's join seamlessly at any size, as a terminal's do. Any Mac has it; without it the system's stands in.
    static func mockFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func ink(of mock: String) -> Ink {
        if let inked, inked.text == mock { return inked.ink }
        let font = mockFont(100)
        let rows = mock.components(separatedBy: "\n")
        let widest = rows.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let ink = Ink(widest: widest / 100, lines: rows.count)
        inked = (mock, ink)
        return ink
    }

    /// A line of the mock at `size`, as SwiftUI sets it in a `Text` of this font: its ascent and its descent each rounded to a whole point (10.5 pt takes 12, 11 pt takes 13).
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let font = mockFont(size)
        return font.ascender.rounded() + (-font.descender).rounded() + font.leading.rounded()
    }

    /// The size the widest line fits `textWidth` at: the design's size when it fits, else the largest half point that does, never under `floor` (then it scrolls across).
    static func fit(_ ink: Ink?, textWidth: CGFloat, nominal: CGFloat, floor: CGFloat) -> (size: CGFloat, across: Bool) {
        guard let ink, ink.widest > 0 else { return (nominal, false) }
        let ideal = textWidth / ink.widest
        if ideal >= nominal { return (nominal, false) }
        let size = (ideal * 2).rounded(.down) / 2
        return size >= floor ? (size, false) : (floor, true)
    }

    /// The layout for `mock` (nil: the option has none) in a card `width` wide, at the user's chat text size.
    static func arrange(_ mock: String?, hiddenLines: Int = 0, width: CGFloat, chatSize: Double = DisplaySettings.defaultChatSize) -> Arrangement {
        let k = scale(chatSize)
        let nominal = halves(nominalSize * k), floor = halves(floorSize * k)
        let inner = width - 2 * edge
        let shown = mock.map(displayed)
        let ink = shown.map(ink(of:))
        let options = min(max(inner * optionsShare, optionsRange.lowerBound * k), optionsRange.upperBound * k)
        let besideBox = inner - options - besideGap
        let besideFit = fit(ink, textWidth: besideBox - 2 * insetX, nominal: nominal, floor: floor)
        let beside = besideBox >= besideMinimum * k && !besideFit.across
        let boxWidth = beside ? besideBox : inner
        let chosen = beside ? besideFit : fit(ink, textWidth: inner - 2 * insetX, nominal: nominal, floor: floor)
        return Arrangement(beside: beside, optionsWidth: beside ? options : inner, boxWidth: boxWidth, fontSize: chosen.size, lineHeight: lineHeight(chosen.size), lines: ink?.lines ?? 0,
                           scrollsAcross: chosen.across, hiddenLines: hiddenLines, hasPreview: shown != nil)
    }

    // MARK: Notes

    /// The notes' height while they are empty and editable: one line of the input text in its padding.
    static func fieldHeight(inputSize: Double) -> CGFloat {
        max(fieldMinHeight, ComposerMetrics.fieldHeight(lines: 1, size: inputSize) + 2 * fieldPadding)
    }

    /// The notes block as the card lays it out, for the estimate: the empty field (nothing written yet is what an estimate can know), or the held notes / the focused field's
    /// notice, which are text.
    static func notesHeight(_ prompt: AgentPrompt, width: CGFloat, chatSize: Double, inputSize: Double) -> CGFloat {
        // The height of the lines of `text` as SwiftUI sets them (each line's ascent and descent rounded up to a whole point), at most `limit` of them.
        func block(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, width: CGFloat, limit: Int = .max) -> CGFloat {
            let font = NSFont.systemFont(ofSize: halves(size * scale(chatSize)), weight: weight)
            return CGFloat(min(limit, PromptCardText.lines(text, font: font, width: width))) * (ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading))
        }
        // The notes' box has 10 pt at each side and 8 above and below; its label has a glyph and the gap after it before the words.
        switch PreviewNotesState(prompt) {
        case .focused(let typed):
            var height = 2 * 8 + block(PreviewCopy.focusedLabel, size: 10.5, weight: .semibold, width: width - 20 - 12 - 6)
            if let typed { height += 3 + block(PreviewCopy.focusedTyped(typed), size: 10.5, width: width - 20, limit: focusedTypedLines) }
            return height + 3 + block(PreviewCopy.focusedCaption, size: 10, width: width - 20)
        case .held(let held):
            return 2 * 8 + block(PreviewCopy.heldLabel, size: 10, weight: .semibold, width: width - 20 - 9 - 5) + 3 + block(held, size: 11, width: width - 20)
                + 5 + block(PreviewCopy.heldCaption, size: 10, width: width - 8)
        case .editable:
            return fieldHeight(inputSize: inputSize)
        }
    }
}

// MARK: - The box

/// The highlighted option's preview in a box of its own, as the terminal draws it beside the options: a header that says which option it belongs to (the highlight is
/// where the terminal has it, and Nook never moves it just to look at another option's mock), the mock in a monospaced font with its whitespace exactly, and, when
/// Claude keeps lines out of its box, the fold that says how many. The mock fits the box down to a floor; a taller one scrolls inside it, under the header and over the
/// fold, so a long mock never pushes the options out of reach.
struct PreviewBox: View {
    var mock: String?
    var hiddenLines: Int
    /// The option the preview belongs to: the number the terminal prints, its words, and whether the terminal has the highlight on it.
    var number: Int?
    var title: String
    var highlighted: Bool
    var arrangement: PreviewMetrics.Arrangement
    /// The tallest the box may be (the card's room), nil for as tall as the mock.
    var cap: CGFloat?
    var agentName: String
    var chatSize: Double
    @Environment(\.tabTint) private var tint
    /// How far the mock has scrolled in its box and how big it and the box are, measured from inside it: the edge that has more fades out instead of ending in a cut.
    @State private var scroll = BoxScroll()
    private static let space = "previewMock"

    private struct BoxScroll: Equatable {
        var offset = CGPoint.zero
        var content = CGSize.zero
        var viewport = CGSize.zero
    }

    private var k: CGFloat { PreviewMetrics.scale(chatSize) }
    private func scaled(_ size: CGFloat) -> CGFloat { (size * k * 2).rounded() / 2 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.nookWash(0.07)).frame(height: 0.5)
            content
            if hiddenLines > 0 { fold }
        }
        .frame(height: arrangement.height(cap: cap))
        .background(Color.nookInset, in: shape)
        .overlay(shape.strokeBorder(Color.nookWash(0.09), lineWidth: 0.7))
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PreviewCopy.spokenLabel(number: number, title: title))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(PreviewCopy.label).font(.system(size: scaled(10), weight: .semibold)).foregroundStyle(Color.nookSecondary).lineLimit(1).fixedSize()
            if let number {
                Text("\(number)").font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(highlighted ? Color.black.opacity(0.8) : Color.nookSecondary)
                    .frame(width: 16, height: 16).background(highlighted ? tint.accent : Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            }
            Text(title).font(.system(size: scaled(10.5), weight: .medium)).foregroundStyle(Color.primary.opacity(0.88)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PreviewMetrics.insetX).frame(height: PreviewMetrics.headerHeight)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if let mock {
            let text = Text(verbatim: PreviewMetrics.displayed(mock)).font(Font(PreviewMetrics.mockFont(arrangement.fontSize) as CTFont)).foregroundStyle(Color.primary.opacity(0.9))
                .fixedSize().padding(.horizontal, PreviewMetrics.insetX).padding(.vertical, PreviewMetrics.insetY).textSelection(.enabled)
                .accessibilityLabel(PreviewCopy.spoken(mock))
            if arrangement.scrollsAcross || arrangement.scrollsDown(cap: cap) {
                ScrollView(scrollAxes) {
                    text.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                        scroll.offset = CGPoint(x: -frame.minX, y: -frame.minY)
                        scroll.content = frame.size
                    }
                }
                .coordinateSpace(name: Self.space).scrollIndicators(.hidden)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { scroll.viewport = $0 }
                .mask(edgeFade(.vertical)).mask(edgeFade(.horizontal))
            } else {
                text.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            }
        } else {
            Text(PreviewCopy.none).font(.system(size: scaled(10.5))).foregroundStyle(Color.nookSecondary).padding(.horizontal, PreviewMetrics.insetX)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// The mock fades where it goes on past the box's edge: at the start once it has scrolled, at the end while there is more.
    private func edgeFade(_ axis: Axis) -> some View {
        let vertical = axis == .vertical
        let offset = vertical ? scroll.offset.y : scroll.offset.x
        let content = vertical ? scroll.content.height : scroll.content.width
        let viewport = vertical ? scroll.viewport.height : scroll.viewport.width
        let start = offset > 2, end = content - offset - viewport > 2
        let leading = LinearGradient(colors: [start ? .clear : .black, .black], startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
        let trailing = LinearGradient(colors: [.black, end ? .clear : .black], startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
        return Group {
            if vertical {
                VStack(spacing: 0) { leading.frame(height: 12); Rectangle(); trailing.frame(height: 14) }
            } else {
                HStack(spacing: 0) { leading.frame(width: 12); Rectangle(); trailing.frame(width: 14) }
            }
        }
    }

    private var scrollAxes: Axis.Set {
        var axes: Axis.Set = []
        if arrangement.scrollsAcross { axes.insert(.horizontal) }
        if arrangement.scrollsDown(cap: cap) { axes.insert(.vertical) }
        return axes
    }

    /// Where Claude's own box ends its mock: a dashed rule in the amber the terminal draws it in, and how many lines it keeps out.
    private var fold: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors").font(.system(size: 9, weight: .semibold))
            Text(PreviewCopy.hidden(hiddenLines, agentName: agentName)).font(.system(size: scaled(10), weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(AgentPalette.failed)
        .frame(maxWidth: .infinity).frame(height: PreviewMetrics.foldHeight)
        .background(AgentPalette.failed.opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle().stroke(AgentPalette.failed.opacity(0.55), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3])).frame(height: 0.7)
        }
        .help(PreviewCopy.hiddenHelp(hiddenLines, agentName: agentName))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PreviewCopy.hidden(hiddenLines, agentName: agentName))
    }
}

// MARK: - The notes

/// A key's name on a small cap, as the card's buttons carry it.
private struct NotesKeycap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.nookSecondary)
            .padding(.horizontal, 4.5).frame(height: 15)
            .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// What a numbered row carries while notes are written: a click on it sends them. The tab's colour, which is the user's.
struct NotesMark: View {
    @Environment(\.tabTint) private var tint
    var body: some View {
        Image(systemName: "note.text").font(.system(size: 9, weight: .semibold)).foregroundStyle(tint.ink)
            .frame(width: PreviewMetrics.markWidth, height: PreviewMetrics.markWidth).background(tint.accent.opacity(0.16), in: Circle())
            .help(PreviewCopy.rowHelp).accessibilityHidden(true)
    }
}

/// The notes of a question with a preview. They are optional and go with the answer: whichever option is chosen sends them, or ↵ in the field sends them with the option
/// the preview belongs to (what ↵ does in the terminal's own notes field).
///
/// - Nothing held (`PreviewNotesState.editable`): a field Nook writes into. It is the composer's own text view, so ↵, ⇧↵, Esc, pasting and input methods behave as they do
///   there; ↵ sends, Esc gives the keyboard back to the card (digits choose again) and keeps what is written. Written notes are in the tab's colour and say what a choice
///   does with them.
/// - The terminal holds notes with its field closed (`held`): they are shown as they are, read only; they go with the answer all the same.
/// - The terminal's notes field has the keyboard (`focused`), empty or with text being typed: what Nook presses would land in it, so the card says so, quotes what is typed
///   there, and leaves the choice to the terminal until the field is closed.
struct PreviewNotes: View {
    var text: Binding<String>
    var state: PreviewNotesState
    var agentName: String
    /// The number of the option ↵ answers with: the one the preview belongs to.
    var sendsWith: Int?
    var busy: Bool
    var inputSize: Double
    var chatSize: Double
    /// Bumped to put the keyboard in the field.
    var focusRequest: Int
    var onSubmit: () -> Void
    var onLeave: () -> Void
    @Environment(\.tabTint) private var tint

    private var k: CGFloat { PreviewMetrics.scale(chatSize) }
    private func scaled(_ size: CGFloat) -> CGFloat { (size * k * 2).rounded() / 2 }
    private var written: Bool { !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch state {
            case .focused(let typed): focusedNotice(typed)
            case .held(let notes): heldNotes(notes)
            case .editable:
                field
                if written {
                    Text(PreviewCopy.caption(sendsWith: sendsWith)).font(.system(size: scaled(10))).foregroundStyle(Color.nookSecondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The field

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let line = ComposerMetrics.lineHeight(size: inputSize)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "square.and.pencil").font(.system(size: 10, weight: .medium)).foregroundStyle(written ? tint.ink : Color.nookSecondary)
                .frame(width: 14, height: line).padding(.top, ComposerMetrics.verticalInset)
            ComposerField(text: text, placeholder: PreviewCopy.placeholder, fontSize: inputSize, maxLines: 3, focusRequest: focusRequest,
                          accessibilityLabel: PreviewCopy.fieldLabel, accessibilityHint: PreviewCopy.fieldHint(agentName: agentName), onKey: key)
            if !written { NotesKeycap(text: "n").frame(height: line).padding(.top, ComposerMetrics.verticalInset) }
        }
        .padding(.horizontal, 8).padding(.vertical, PreviewMetrics.fieldPadding)
        .frame(minHeight: PreviewMetrics.fieldMinHeight, alignment: .top)
        .background(Color.nookWash(0.06), in: shape)
        .overlay(shape.strokeBorder(tint.accent.opacity(written ? 0.5 : 0), lineWidth: 0.8))
        .opacity(busy ? 0.5 : 1).allowsHitTesting(!busy)
        .help(PreviewCopy.fieldHelp(agentName: agentName))
    }

    /// ↵ sends (⇧↵ is a line break, which the answer turns into a space); Esc leaves the field and keeps its text; a tab is never typed and an image has no place in a note.
    /// The rest is the text view's own: the caret walks the lines, letters type.
    private func key(_ key: ComposerKey, _ caret: ComposerCaret) -> Bool {
        switch key {
        case .submit: onSubmit(); return true
        case .escape: onLeave(); return true
        case .tab, .pasteImage: return true
        case .newline, .up, .down, .right, .letter: return false
        }
    }

    // MARK: Notes the terminal has

    private func heldNotes(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(Color.nookSecondary)
                    Text(PreviewCopy.heldLabel).font(.system(size: scaled(10), weight: .semibold)).foregroundStyle(Color.nookSecondary).lineLimit(2)
                }
                Text(notes).font(.system(size: scaled(11))).foregroundStyle(Color.primary.opacity(0.9)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(PreviewCopy.heldCaption).font(.system(size: scaled(10))).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(PreviewCopy.heldLabel): \(notes)")
    }

    private func focusedNotice(_ typed: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: scaled(9.5))).foregroundStyle(AgentPalette.failed).accessibilityHidden(true)
                Text(PreviewCopy.focusedLabel).font(.system(size: scaled(10.5), weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
            if let typed {
                Text(PreviewCopy.focusedTyped(typed)).font(.system(size: scaled(10.5))).foregroundStyle(Color.primary.opacity(0.8)).lineLimit(PreviewMetrics.focusedTypedLines)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text(PreviewCopy.focusedCaption).font(.system(size: scaled(10))).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentPalette.failed.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AgentPalette.failed.opacity(0.3), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Aviso: \([PreviewCopy.focusedLabel, typed.map(PreviewCopy.focusedTyped), PreviewCopy.focusedCaption].compactMap { $0 }.joined(separator: " "))")
    }
}

// MARK: - Where the keyboard is

/// What the card asks of the window it is in: whether something is being typed into. The card's digits and «n» are SwiftUI key presses, and SwiftUI gives them to the card
/// even while a text view of its own has the keyboard (a digit typed into the notes would choose an option instead of being written), so a key press that finds a text being
/// edited is left alone. A text that is only read (the conversation's, which can be selected) is not being typed into: the digits still choose.
@MainActor
final class KeyboardBox {
    fileprivate weak var view: NSView?

    /// An editable text view (the notes' field) is where the keys go.
    var isTyping: Bool { (view?.window?.firstResponder as? NSTextView)?.isEditable == true }
}

/// An invisible view that tells the card which window it is in. It takes no click and no key.
struct KeyboardProbe: NSViewRepresentable {
    var box: KeyboardBox

    private final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        box.view = view
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}

// MARK: - Notes kept by the pane

/// The notes written for one question, by the question's signature: the same dialog seen again (the card folded away and back, a redraw that blinked it off) finds its
/// notes, and another question never does. The pane keeps them (`SessionPane`), since the card is rebuilt each time it comes back.
struct WrittenNotes: Equatable {
    var signature: String
    var text: String

    /// The notes of the dialog with `signature`, empty when what is kept belongs to another.
    static func text(_ kept: WrittenNotes?, for signature: String) -> String { kept?.signature == signature ? kept?.text ?? "" : "" }

    /// What the pane keeps once `text` is written for `signature`: nothing for empty notes.
    static func keeping(_ text: String, for signature: String) -> WrittenNotes? { text.isEmpty ? nil : WrittenNotes(signature: signature, text: text) }
}

/// What each tab's notes are while its pane is rebuilt: the pane is made again whenever the user comes back to a tab, and notes written for a question that is still open
/// must be there when they do (as the message in the field is, `TerminalSession.draft`, and the images attached to it, `MessageAttachments`).
@MainActor
final class WrittenNotesStore {
    static let shared = WrittenNotesStore()
    private var byTab: [String: WrittenNotes] = [:]

    func notes(for tab: String) -> WrittenNotes? { byTab[tab] }

    func set(_ notes: WrittenNotes?, for tab: String) {
        if let notes { byTab[tab] = notes } else { byTab.removeValue(forKey: tab) }
    }
}
