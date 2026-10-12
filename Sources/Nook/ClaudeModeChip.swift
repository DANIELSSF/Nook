import SwiftUI

// Two small things Claude says under its box, now in Nook's own words:
//
//   ClaudeModeChip    the permission mode (default, "auto mode on", "plan mode on"…) as a glyph in a round chip of its colour in the composer's
//                     bottom row, beside Claude's model and effort; a click passes to the next mode, as ⇧⇥ does in the terminal
//                     (`AppModel.cycleMode`). Its name is in the tooltip and in what VoiceOver says.
//   ClaudeStatusLine  Claude's status line; the one it prints while it waits for background agents is told in Spanish, in the room there is
//
// Both only show what the screen said: after a click the chip goes on showing the mode it had until the next reading says the new one.

// MARK: - Mode

/// How a mode looks and what it is called. A mode Nook does not know by name keeps Claude's own words.
struct ClaudeModeStyle: Equatable {
    var title: String
    var symbol: String
    var color: TabRGB
    /// The same colour on the light island: the tone is deeper there, so the glyph reads on the paper (3 : 1 or more on the card).
    var lightColor: TabRGB
    /// What the mode means, for the tooltip.
    var summary: String
    /// The same in a line, for the tip over the chip.
    var blurb: String
    /// How much of its colour the chip's wash and edge take. The default mode, the one a session is in most of the time, is the quietest.
    var wash = 0.13
    var edge = 0.32

    static let cycleHint = "Pasa al siguiente modo, como ⇧⇥ en la terminal."

    // The colours say how much Claude may do on its own: calm blue-greens and violets for the guarded modes, the island's soft red for the one
    // with no guard. None is mint (the tab's colour, the user's voice) or terracotta (Claude's), and none is the amber of the notices: the chip
    // is a status, not a call to attention. Each is a light tone that reads on the island's black (see `SessionInfoTests`).
    static let planColor = TabRGB(0.36, 0.78, 0.88)
    static let acceptEditsColor = TabRGB(0.79, 0.61, 0.96)
    static let autoColor = TabRGB(0.53, 0.73, 1.00)
    static let bypassColor = TabRGB(0.97, 0.52, 0.50)
    static let otherColor = TabRGB(0.72, 0.75, 0.80)
    /// The default mode wears the island's neutral grey, with a fainter wash than the others.
    static let normalColor = TabRGB(0.70, 0.73, 0.78)
    // The same hues on the light island, each a deeper tone.
    static let planLight = TabRGB(0.02, 0.45, 0.58)
    static let acceptEditsLight = TabRGB(0.50, 0.28, 0.75)
    static let autoLight = TabRGB(0.12, 0.40, 0.78)
    static let bypassLight = TabRGB(0.78, 0.21, 0.21)
    static let otherLight = TabRGB(0.38, 0.41, 0.48)
    static let normalLight = TabRGB(0.36, 0.39, 0.46)

    /// The colour in `scheme`.
    func color(_ scheme: ColorScheme) -> TabRGB { scheme == .dark ? color : lightColor }

    init(_ mode: ClaudeMode) {
        if mode.isDefault {
            self.init(title: "Normal", symbol: "hand.raised", color: Self.normalColor, lightColor: Self.normalLight,
                      summary: "Modo normal: Claude te pide permiso antes de editar archivos o de ejecutar comandos.",
                      blurb: "Claude pide permiso antes de editar o ejecutar", wash: 0.07, edge: 0.2)
            return
        }
        switch mode.kind {
        case .auto:
            self.init(title: "Auto", symbol: "bolt.fill", color: Self.autoColor, lightColor: Self.autoLight,
                      summary: "Modo automático: Claude aprueba por sí mismo lo que considera seguro y solo te consulta lo arriesgado.",
                      blurb: "Claude aprueba solo lo que ve seguro")
        case .acceptEdits:
            self.init(title: "Aceptar ediciones", symbol: "pencil", color: Self.acceptEditsColor, lightColor: Self.acceptEditsLight,
                      summary: "Modo aceptar ediciones: Claude edita los archivos sin pedirte permiso; para lo demás sigue preguntando.",
                      blurb: "Edita archivos sin pedirte permiso")
        case .plan:
            self.init(title: "Plan", symbol: "list.bullet.clipboard", color: Self.planColor, lightColor: Self.planLight,
                      summary: "Modo plan: Claude investiga y propone un plan, y no cambia nada hasta que lo apruebes.",
                      blurb: "Propone un plan y no cambia nada")
        case .bypassPermissions:
            self.init(title: "Sin permisos", symbol: "lock.open.fill", color: Self.bypassColor, lightColor: Self.bypassLight,
                      summary: "Modo sin permisos: Claude ejecuta todo sin pedir confirmación. Úsalo solo donde confíes en lo que hace.",
                      blurb: "Ejecuta todo sin pedir confirmación")
        case nil:
            let name = Self.plainName(of: mode.label)
            self.init(title: name, symbol: "circle.fill", color: Self.otherColor, lightColor: Self.otherLight, summary: "Modo de Claude: «\(mode.label)».", blurb: "Modo de Claude: «\(mode.label)»")
        }
    }

    private init(title: String, symbol: String, color: TabRGB, lightColor: TabRGB, summary: String, blurb: String, wash: Double = 0.13, edge: Double = 0.32) {
        self.title = title; self.symbol = symbol; self.color = color; self.lightColor = lightColor; self.summary = summary; self.blurb = blurb; self.wash = wash; self.edge = edge
    }

    /// "yolo mode on" → "Yolo mode": Claude's words without the "on" that says it is active.
    static func plainName(of label: String) -> String {
        var name = label.trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasSuffix(" on") { name = String(name.dropLast(3)) } else if name.lowercased() == "on" { name = "" }
        return name.isEmpty ? "Modo" : name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Why a click on the chip must do nothing now, in words for its tooltip; nil when it may pass to the next mode. ⇧⇥ goes to whatever has the
    /// keys, and an option of an open question is named after it ("Yes, allow all edits during this session (shift+tab)"): pressed then, it would
    /// answer the question. So the chip waits for the question to be answered (or cancelled) and for Claude's panel to close.
    static func block(running: Bool, questionOpen: Bool, panelOpen: Bool) -> String? {
        if !running { return "La terminal está cerrada." }
        if questionOpen { return "Hay una pregunta abierta: respóndela antes, porque ⇧⇥ podría contestarla." }
        if panelOpen { return "Cierra antes el panel de Claude." }
        return nil
    }

    /// The tooltip: what the mode does, then that a click passes to the next one (and what that takes), or what stands in the way of it.
    func tooltip(blocked: String? = nil, needsAccessibility: Bool = false) -> String {
        var lines = [summary]
        if let blocked {
            lines.append(blocked)
        } else {
            lines.append("Pulsa para pasar al siguiente modo (⇧⇥ en la terminal).")
            if needsAccessibility { lines.append("Cambiar de modo requiere el permiso de Accesibilidad; Nook lo explicará al pulsar.") }
        }
        return lines.joined(separator: "\n")
    }

    /// The tip over the chip: the mode, what it lets Claude do, and how to pass to the next one (or what stands in the way of it).
    func tip(blocked: String? = nil, needsAccessibility: Bool = false) -> NookTip {
        if let blocked { return NookTip("Modo", value: title, detail: blocked) }
        return NookTip("Modo", value: title, detail: blurb + " · ⇧⇥ para cambiar" + (needsAccessibility ? "\nPara cambiarlo Nook pide el permiso de Accesibilidad." : ""))
    }
}

/// How the chip looks at the start; render tests and previews use it to show a state that is gone in a moment.
enum ModeChipLook { case resting, hovered, pressed, asked }

/// The chip: the mode's glyph in its colour, on a wash of it, in a round chip like the model's and the effort's. It is a button: a click passes to
/// the next mode, as ⇧⇥ does in the terminal. Claude answers on the screen, and the chip follows at the next reading (the bridge reads again right
/// after the key, the open island every half second), so the click shows at once what it did: the chip lights while the mouse is down and stays lit
/// until the new mode arrives (or a moment passes).
struct ClaudeModeChip: View {
    var mode: ClaudeMode
    /// Why a click does nothing now (a question is open and ⇧⇥ could answer it, the terminal is closed…); nil when it passes to the next mode.
    var blocked: String?
    /// The key needs the Accessibility permission and it is not granted yet (a Terminal tab).
    var needsAccessibility = false
    var action: () -> Void
    @State private var hovered: Bool
    @State private var pressed: Bool
    @State private var asked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = ChipMetrics.side
    /// How long the chip stays lit after a click if the screen has not changed it by then.
    static let askedSeconds = 0.9

    init(mode: ClaudeMode, blocked: String? = nil, needsAccessibility: Bool = false, look: ModeChipLook = .resting, action: @escaping () -> Void) {
        self.mode = mode
        self.blocked = blocked
        self.needsAccessibility = needsAccessibility
        self.action = action
        _hovered = State(initialValue: look == .hovered)
        _pressed = State(initialValue: look == .pressed)
        _asked = State(initialValue: look == .asked)
    }

    var body: some View {
        let style = ClaudeModeStyle(mode)
        Button {
            guard blocked == nil else { return }
            asked = true
            action()
        } label: {
            chip(style)
        }
        .buttonStyle(PressReporter(pressed: $pressed))
        .disabled(blocked != nil)
        .opacity(blocked == nil ? 1 : 0.5)
        .onHover { hovered = $0 }
        .nookTip(style.tip(blocked: blocked, needsAccessibility: needsAccessibility), id: "mode")
        .accessibilityLabel("Modo de permisos de Claude")
        .accessibilityValue(style.title)
        .accessibilityHint(blocked ?? ClaudeModeStyle.cycleHint)
        // Lit for a moment after the click; the new mode, when it arrives, ends it.
        .task(id: asked) {
            guard asked else { return }
            try? await Task.sleep(for: .seconds(Self.askedSeconds))
            if !Task.isCancelled { asked = false }
        }
        .onChange(of: mode) { _, _ in asked = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: style)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
    }

    /// How much of the colour the wash and the edge take now: the pointer over the chip raises them a little, the mouse down and the wait for the
    /// answer more (the edge most: a wash lighter than 25 % would take the text under the contrast it needs, see `SessionInfoTests`). A chip that
    /// cannot be pressed stays as it is.
    private func lift(_ style: ClaudeModeStyle) -> (wash: Double, edge: Double) {
        guard blocked == nil else { return (style.wash, style.edge) }
        if pressed { return (style.wash + 0.12, style.edge + 0.32) }
        if asked { return (style.wash + 0.09, style.edge + 0.28) }
        if hovered { return (style.wash + 0.05, style.edge + 0.14) }
        return (style.wash, style.edge)
    }

    private func chip(_ style: ClaudeModeStyle) -> some View {
        let color = style.color(scheme).color
        let strength = lift(style)
        // A circle: a stroked capsule would leave a short tick at each end, where its arcs meet no straight side.
        let shape = Circle()
        return Image(systemName: style.symbol).font(.system(size: style.symbol == "circle.fill" ? 6 : 10, weight: .semibold))
            // The default mode's grey is the island's own secondary text; the others are their colour.
            .foregroundStyle(style.wash < 0.1 ? color.opacity(0.95) : color)
            .frame(width: Self.height, height: Self.height)
            .background(color.opacity(strength.wash), in: shape).overlay(shape.strokeBorder(color.opacity(strength.edge), lineWidth: 0.7))
            .scaleEffect(pressed && blocked == nil && !reduceMotion ? 0.96 : 1)
            .contentShape(shape).fixedSize()
    }
}

/// Tells a chip when the mouse is down on it; the chip draws the press itself (its colours are its own).
struct PressReporter: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

// MARK: - Status

/// Claude's status in the words Nook shows: its own spinner line as it prints it, except the wait for background agents, which is told in Spanish.
enum ClaudeStatusCopy {
    /// What Claude is waiting for, in Spanish: "agente" unless its line says tasks or jobs.
    private static func noun(_ status: ClaudeStatus) -> (one: String, many: String, article: String) {
        let lower = status.text.lowercased()
        if lower.contains(" task") { return ("tarea", "tareas", "") }
        if lower.contains(" job") { return ("trabajo", "trabajos", "") }
        return ("agente", "agentes", "a ")
    }

    /// "Esperando a 3 agentes en segundo plano" and the shorter ways to say it, the longest first (the personal "a" goes before the rest does).
    /// Empty for a status that is not that wait.
    static func waiting(_ status: ClaudeStatus) -> [String] {
        guard let count = status.background else { return [] }
        let words = noun(status)
        let counted = "\(count) \(count == 1 ? words.one : words.many)"
        // What Claude printed after the sentence (a time, a token count) goes on after it.
        let tail = Self.tail(of: status.text)
        return ["Esperando \(words.article)\(counted) en segundo plano" + tail, "Esperando \(counted) en segundo plano" + tail,
                "Esperando \(words.article)\(counted)" + tail, "Esperando \(counted)" + tail, "Esperando…"]
    }

    /// What follows "…to finish…" in Claude's line: "(1m 2s · ↓ 3k tokens)", or nothing.
    static func tail(of text: String) -> String {
        guard let end = text.range(of: "to finish")?.upperBound else { return "" }
        let rest = text[end...].drop { $0 == "…" || $0 == "." || $0.isWhitespace }
        let cleaned = SessionPane.statusText(String(rest))
        return cleaned.isEmpty ? "" : " " + cleaned
    }

    /// The sentence for the tooltip.
    static func explanation(_ status: ClaudeStatus) -> String? {
        guard let count = status.background else { return nil }
        let words = noun(status)
        return "Claude terminó su parte y espera a que acaben \(count) \(count == 1 ? words.one : words.many) en segundo plano antes de seguir."
    }
}

/// Claude's status in the composer's bottom row: its spinner symbol (in the terminal's own colour) and its words.
struct ClaudeStatusLine: View {
    var status: ClaudeStatus
    var size: CGFloat = 10.5

    var body: some View {
        let waiting = ClaudeStatusCopy.waiting(status)
        Group {
            if waiting.count == 5 {
                // The wait is a sentence that can be said shorter: the whole of it when it fits, then without "a", then without "en segundo plano".
                ViewThatFits(in: .horizontal) {
                    line(waiting[0], fixed: true)
                    line(waiting[1], fixed: true)
                    line(waiting[2], fixed: true)
                    line(waiting[3], fixed: true)
                    line(waiting[4], fixed: false)
                }
            } else {
                line(SessionPane.statusText(status.text), fixed: false)
            }
        }.help(ClaudeStatusCopy.explanation(status) ?? status.text)
    }

    private func line(_ text: String, fixed: Bool) -> some View {
        let glyph = Text(status.glyph.map { $0 + " " } ?? "").foregroundStyle(status.working ? claudeSpinner : Color.nookSecondary)
        return (glyph + Text(text)).font(.system(size: size)).foregroundStyle(status.working ? Color.primary.opacity(0.85) : Color.nookSecondary)
            .lineLimit(1).truncationMode(.tail).fixedSize(horizontal: fixed, vertical: false)
    }
}
