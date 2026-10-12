import SwiftUI

// The composer answering a dialog's text field ("Type something." in Claude's questions).
//
// Choosing that option on the question's card presses no key: the card gives the composer back, and what is written in it is the answer to THAT
// question (`AppModel.sendToField`), not a message to the agent. Four things say so: the bar over the field (who asks, what, and the way back to the
// options), the composer's outline in the tab's colour (the user's voice, as the send button and the highlighted row wear it), the words of the field
// (its placeholder, its hint under it, its send button) and the conversation above, which keeps the shape it had under the card. The same state
// shows when the terminal already has the field highlighted (the user moved there by hand) and the card is out of the way.
//
//   FieldAnswerBar    the bar over the field
//   FieldAnswerCopy   its words, in Spanish (pure; the tests hold them)
//   FieldAnswerEnter  what ↵ does there (pure)

/// The words of the composer while it answers a text field. The question is the dialog's own; everything else is Nook's.
enum FieldAnswerCopy {
    static let placeholder = "Escribe tu respuesta…"
    static let sendingPlaceholder = "Enviando tu respuesta…"
    /// The way back to the options (the bar's button, and Esc).
    static let back = "Opciones"
    /// ↵ on an empty field: nothing goes, and the line under the field says why for a moment.
    static let missing = "Escribe tu respuesta para enviarla"
    static let sending = "Enviando…"

    /// The bar's title: the dialog's question, or who is asking when the screen has none.
    static func title(for prompt: AgentPrompt, agentName: String) -> String {
        prompt.question.isEmpty ? PromptCardText.kindLabel(prompt, agentName: agentName) : prompt.question
    }

    /// The answer on its way, in one line (a pasted paragraph is shown as the line it is sent as).
    static func sent(_ text: String) -> String {
        "Enviando «\(text.split(whereSeparator: \.isNewline).joined(separator: " "))»"
    }

    /// What stands under the field: where the answer goes. A question that takes several answers ticks the field's box with it, which adds it to the ones ticked.
    static func hint(multiSelect: Bool) -> String {
        multiSelect ? "Se suma a las opciones marcadas · ↵ enviar" : "Tu respuesta · ↵ enviar"
    }

    static func backHelp(agentName: String) -> String {
        "Volver a las opciones de la pregunta (Esc)\nNo se envía nada a \(agentName); lo que escribiste se queda en el campo."
    }

    static func fieldHint(agentName: String) -> String {
        "Intro envía tu respuesta al campo de texto de la pregunta de \(agentName). Escape vuelve a las opciones sin enviar nada."
    }

    static func sendDetail(empty: Bool) -> String {
        empty ? "Escribe tu respuesta primero" : "↵ envía tu respuesta a esta pregunta · Esc vuelve a las opciones"
    }

    /// An image has no place in a field of a dialog: the answer is a line of text.
    static let imageRefusal = "Una respuesta a una pregunta es solo texto: no pegué la imagen. Envíala en un mensaje después de responder."
}

/// What ↵ does while the composer answers a text field: send what is written, say that nothing is, or leave things as they are.
enum FieldAnswerEnter: Equatable {
    /// An answer or a message is on its way, or there is nothing to talk to: the draft stays where it is.
    case wait
    /// Nothing is written: nothing goes (Enter on an empty field cancels Claude's question), and the hint says so.
    case missing
    /// The answer, without the line breaks at its ends.
    case send(String)

    static func decide(draft: String, busy: Bool) -> FieldAnswerEnter {
        guard !busy else { return .wait }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .missing }
        return .send(draft.trimmingCharacters(in: .newlines))
    }
}

/// The bar over the composer's field while it answers a text field: the mark of who asks, the label and the question (what is being answered, which
/// the card showed a moment ago), and «‹ Opciones» (Esc) to go back to the options without answering. While the answer goes, it says what is on its way
/// instead and the way back waits. It stands where the card's own bar stood, with the same measures, so the card reads as turning into the composer.
struct FieldAnswerBar: View {
    var prompt: AgentPrompt
    var agent: TerminalAgent?
    /// The answer on its way, when one is.
    var sending: String?
    var onBack: () -> Void = {}
    @State private var overBack = false

    /// The most room the bar takes above the field: two lines of question with the bar's own padding (one line takes 29 pt). The composer leaves the conversation
    /// that much less, which is what the field's lines are worked out with.
    static let tallest: CGFloat = 44

    private var agentName: String { agent?.title ?? "El agente" }
    private var title: String { sending.map(FieldAnswerCopy.sent) ?? FieldAnswerCopy.title(for: prompt, agentName: agentName) }
    private var helpText: String { sending == nil ? [prompt.question, prompt.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") : "" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AskingMark(agent: agent)
            if sending == nil, let header = prompt.header { LabelChip(text: header).frame(height: 22) }
            Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(sending == nil ? Color.primary : Color.primary.opacity(0.75))
                .frame(minHeight: 22, alignment: .leading).help(helpText)
                .accessibilityLabel(sending == nil ? "Respondiendo a la pregunta de \(agentName): \(title)" : title)
            Spacer(minLength: 8)
            if sending == nil { backButton }
        }
        .padding(.leading, 13).padding(.trailing, 6).padding(.top, 6).padding(.bottom, 1)
        .accessibilityElement(children: .contain)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 8.5, weight: .bold))
                Text(FieldAnswerCopy.back).font(.system(size: 10.5, weight: .medium))
                AnswerKeycap(text: "esc")
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.leading, 8).padding(.trailing, 6).frame(height: 22)
            .background(Color.nookWash(overBack ? 0.15 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        // The way back keeps its words however narrow the island is: it is the question's text that gives way.
        .fixedSize()
        .nookPress(.squeeze, depth: PressDepth.card, strength: 0.5)
        .onHover { overBack = $0 }
        .help(FieldAnswerCopy.backHelp(agentName: agentName))
        .accessibilityLabel("Volver a las opciones")
        .accessibilityHint("No envía nada a \(agentName)")
    }
}

/// The pane's bookkeeping for an answer to a text field, apart from the pane's body (whose chain of modifiers is as long as the compiler takes): the answer on its
/// way is news only until the screen shows how the dialog took it (the delivery ending, or the dialog going or changing: a box ticked, the next question), and
/// the wait is bounded all the same, so the bar never keeps saying «Enviando» for an answer nobody follows. The hint of an empty ↵ goes by itself too. And the
/// composer turning into the answer's (or out of it) is told to the pane.
struct FieldAnswerLifecycle: ViewModifier {
    @Binding var sentAnswer: String?
    @Binding var nudged: Bool
    /// The session's answer is being delivered (`TerminalSession.answering`).
    var delivering: Bool
    /// The open dialog's signature: another one is another question.
    var signature: String?
    var answersField: Bool
    var onAnswersField: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: delivering) { _, working in if !working { sentAnswer = nil } }
            .onChange(of: signature) { _, _ in sentAnswer = nil; nudged = false }
            .onChange(of: answersField) { _, now in onAnswersField(now) }
            .task(id: sentAnswer) {
                guard sentAnswer != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { sentAnswer = nil }
            }
            .task(id: nudged) {
                guard nudged else { return }
                try? await Task.sleep(for: .seconds(2.2))
                if !Task.isCancelled { nudged = false }
            }
    }
}

/// A key's name on a small cap, as the card's buttons carry it.
private struct AnswerKeycap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.nookSecondary)
            .padding(.horizontal, 4.5).frame(height: 15)
            .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}
