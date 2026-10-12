import SwiftUI
import AppKit

// Entering a background shell, as one enters a subagent (`AgentView.swift`): a click on its row in a list (`ShellRow`) puts its output in the mirror's place
// (`TerminalSession.viewedShell`), under a slim bar that says which shell it is and how it is doing, with the way back to Claude's conversation (Esc does
// the same) and its command to copy. The composer keeps writing to Claude.
//
//   ShellViewBar            the bar: the way back, the shell's state and name, its state in words with the time (it ticks), and a button for its command
//   ShellOutputState        what the output is like right now (being read, silent, not there to read) and the words it has for each
//   ShellOutputPlaceholder  those words, over an empty mirror, once they have been true for a moment
//   ShellOutputPane         the bar over the output, which is the mirror's plain text (no transcript styling): it follows its end while it grows, and
//                           stops following when the reader scrolls up, as the mirror always does
//   ShellOutputWords        the bar's tooltip, the notice and the text the mirror is given
//
// Claude's own conversation stays where it is under this (see `SessionPane.conversation`): it is not taken out, so its text, its scroll and its selection
// are as they were when it comes back.

// MARK: - Words

enum ShellOutputWords {
    /// How much of the output Nook keeps and shows: the last part, `ShellOutputTail`'s 200,000 bytes.
    static let keptKB = 200

    /// What the line under the bar says when earlier output was left out (the reader would look for the start of it, and it is not there).
    static let clippedNotice = "Se muestran solo los últimos ~\(keptKB) KB de la salida; lo anterior se omitió."

    /// The bar's tooltip: the name, the whole command (within reason) and where the shell stands.
    static func barHelp(_ shell: ShellActivity) -> String {
        var lines = [shell.name]
        if let command = ShellWords.tooltipCommand(shell.command) { lines.append("$ " + command) }
        lines.append(shell.standing)
        if shell.movedToBackground { lines.append("Empezó en primer plano; Claude lo pasó a segundo plano al pasar su tiempo límite.") }
        return lines.joined(separator: "\n")
    }

    /// Whether the output has anything to read: a file with only blank lines is as silent as one with nothing.
    static func hasOutput(_ output: ShellOutput) -> Bool { output.text.contains { !$0.isWhitespace } }

    /// The text the mirror shows for the output as read. Nothing for an output not read yet or not there to read (the placeholder says which). The tail
    /// ends every finished line with its newline: the mirror's last line is the output's last, not a blank one under it.
    static func mirrorText(_ output: ShellOutput?) -> String {
        guard let output, output.available, hasOutput(output) else { return "" }
        var text = output.text
        while text.last == "\n" { text.removeLast() }
        return text
    }
}

// MARK: - The output's state

/// What the output is like, for the words over an empty mirror.
enum ShellOutputState: Equatable {
    /// The first reading has not come.
    case reading
    /// The file is there and has nothing in it; `running` tells whether the shell may still write.
    case silent(running: Bool)
    /// There is no output to read: the file is gone or is not one Nook may open; `named` is whether Claude said where it is.
    case unavailable(named: Bool)
    /// There is output on show.
    case showing

    init(output: ShellOutput?, shell: ShellActivity?) {
        guard let output else { self = .reading; return }
        if !output.available { self = .unavailable(named: shell?.outputPath != nil); return }
        self = ShellOutputWords.hasOutput(output) ? .showing : .silent(running: shell?.isRunning ?? false)
    }

    var title: String? {
        switch self {
        case .reading: "Leyendo la salida…"
        case .silent(let running): running ? "Sin salida todavía" : "Sin salida"
        case .unavailable: "La salida de este shell no está disponible"
        case .showing: nil
        }
    }

    var detail: String? {
        switch self {
        case .reading, .showing: nil
        case .silent: "Si el comando manda su salida a otro archivo, aquí no aparecerá."
        case .unavailable(let named): named ? "Su archivo ya no existe o Nook no puede abrirlo." : "Claude no indicó dónde guarda su salida."
        }
    }

    var symbol: String? {
        switch self {
        case .reading, .silent: "terminal"
        case .unavailable: "doc.questionmark"
        case .showing: nil
        }
    }

    /// How long the words wait before they show. Right after entering, the file is being read and the mirror is empty for a blink; an empty file is
    /// often the moment before the command's first line.
    var delay: Double {
        switch self {
        case .reading: 0.6
        case .silent, .unavailable: 0.3
        case .showing: 0
        }
    }

    /// Identifies the words, so each state fades in on its own.
    var key: String {
        switch self {
        case .reading: "reading"
        case .silent(let running): running ? "silent-running" : "silent"
        case .unavailable(let named): named ? "unavailable-named" : "unavailable"
        case .showing: "showing"
        }
    }
}

/// Shown over the empty mirror: the output is being read, the shell has written nothing yet, or there is nothing to read. It waits a moment first (see
/// `ShellOutputState.delay`), as the agents' placeholder does.
struct ShellOutputPlaceholder: View {
    var state: ShellOutputState
    @State private var shown = false

    var body: some View {
        if let title = state.title {
            VStack(spacing: 5) {
                if let symbol = state.symbol { Image(systemName: symbol).font(.system(size: 15, weight: .light)).foregroundStyle(Color.nookTertiary) }
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.nookSecondary)
                if let detail = state.detail { Text(detail).font(.system(size: 10)).foregroundStyle(Color.nookSecondary.opacity(0.85)) }
            }
            .multilineTextAlignment(.center).padding(.horizontal, 24)
            .opacity(shown ? 1 : 0)
            .task {
                if state.delay > 0 { try? await Task.sleep(for: .seconds(state.delay)) }
                if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - The bar

/// The bar over a shell's output: the way back to Claude, the shell's state and name, its state in words with the time, and a button that copies its
/// command; its tooltip has the command whole. A long name is cut before anything else gives way, so the state and the time are always in view.
struct ShellViewBar: View {
    /// The shell as the list knows it; nil once it left the list (finished a while ago) but its output is still shown.
    var shell: ShellActivity?
    var animated = true
    /// The clock runs while this is true (the island is on screen).
    var ticking = true
    var pasteboard: NSPasteboard = .general
    var onBack: () -> Void
    /// Something was copied: the composer's status line says so for a moment.
    var onCopy: () -> Void = {}
    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            ViewBackButton(action: onBack)
            Rectangle().fill(Color.nookWash(0.12)).frame(width: 1, height: 12)
            if let shell {
                ShellClock(running: shell.isRunning, ticking: ticking) { now in
                    HStack(spacing: 8) {
                        ShellStateGlyph(state: shell.state, animated: animated).frame(width: 13).accessibilityHidden(true)
                        Text(shell.name).font(shell.nameFont(weight: .semibold)).lineLimit(1).truncationMode(.tail).frame(minWidth: 60, alignment: .leading)
                        Spacer(minLength: 6)
                        // Short and worth more than the tail of a long name.
                        Text(shell.detail(at: now)).font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(shell.state == .failed ? AgentPalette.failed : Color.nookSecondary).lineLimit(1).fixedSize().layoutPriority(1)
                    }
                    .help(ShellOutputWords.barHelp(shell))
                    .contextMenu { if !shell.command.isEmpty { Button("Copiar el comando") { copy(shell.command) } } }
                }
                if !shell.command.isEmpty { CopyCommandButton { copy(shell.command) }.layoutPriority(1) }
            } else {
                Text("Shell").font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 6)
                Text("Salida de un shell anterior").font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1)
            }
        }
        .padding(.leading, 5).padding(.trailing, shell?.command.isEmpty == false ? 4 : 11).frame(height: AgentViewBar.height)
        .background(Color.nookWash(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.nookWash(0.07), lineWidth: 0.5))
        // Like the agent's bar, it comes in with a fade of its own opacity, so the mirror below it changes size at once and only once.
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shell.map { "Salida del shell \($0.name)" } ?? "Salida de un shell")
    }

    private func copy(_ command: String) {
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        onCopy()
    }
}

/// The round button at the bar's end: copies the shell's command, and shows a check for a moment.
struct CopyCommandButton: View {
    var action: () -> Void
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        Button { action(); copied = true } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(copied ? AgentPalette.done : Color.primary.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(Color.nookWash(hovered ? 0.17 : 0.1), in: Circle())
                .contentShape(Circle())
        }
        .nookPress(.pop)
        .onHover { hovered = $0 }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
        .help("Copiar el comando")
        .accessibilityLabel("Copiar el comando")
    }
}

// MARK: - The pane

/// What stands in the conversation's place while a shell's output is shown: the bar, and under it the output as the mirror shows plain text. A shell
/// that left the list (`shell` nil) is still shown while its output can be read, with the way back.
struct ShellOutputPane: View {
    /// The shell's task id, which names what the mirror shows (so it keeps where the reader was in each text).
    var id: String
    var shell: ShellActivity?
    /// What was read of its output; nil until the first reading arrives.
    var output: ShellOutput?
    var fontSize = DisplaySettings.defaultChatSize
    /// The mirror's own inset, which brings its text to the composer's text column.
    var inset: CGFloat = 6
    var animated = true
    var ticking = true
    var pasteboard: NSPasteboard = .general
    var onBack: () -> Void
    var onCopy: () -> Void = {}

    var body: some View {
        let state = ShellOutputState(output: output, shell: shell)
        VStack(spacing: 6) {
            ShellViewBar(shell: shell, animated: animated, ticking: ticking, pasteboard: pasteboard, onBack: onBack, onCopy: onCopy).padding(.top, 2)
            // Earlier output was left out: said where the reader would look for its start, and not in the text, which follows its end.
            if output?.clipped == true, state == .showing {
                Text(ShellOutputWords.clippedNotice).font(.system(size: 9.5)).foregroundStyle(Color.nookSecondary).lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, inset + 7).frame(maxWidth: .infinity, alignment: .leading).padding(.top, -2)
            }
            LiveTerminalSurface(text: ShellOutputWords.mirrorText(output), transcript: false, fontSize: fontSize, contentID: "shell:" + id) { onCopy() }
                .padding(.horizontal, inset)
                .overlay { ShellOutputPlaceholder(state: state).id(id + "/" + state.key) }
        }
    }
}
