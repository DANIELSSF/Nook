import SwiftUI

// The settings card's "Pantalla" tab: the switch that lets Claude see the screen, what that means in four plain lines, and, once it is on, the
// two things that have to be true for it to work (macOS lets Nook record the screen; Claude Code has the `capture_screen` tool), each as a row with
// its state and the one button that fixes it.
//
//   ScreenVisionPanePresentation  what each row says for each state (plain values, so the tests hold them to the words and tones)
//   ScreenVisionPane              the tab

// MARK: - What the rows say

enum ScreenVisionPanePresentation {
    /// Screen Recording's row. It is only shown while screen vision is on, and then a permission that is missing speaks louder than in the Permisos
    /// tab: without it nothing can be captured. Refused is amber already; not asked yet is no longer neutral.
    struct Permission: Equatable {
        var chip: String
        var tone: PermissionTone
        var symbol: String
        var action: PermissionAction?
        /// What the row tells under its title: what the permission is for, and (while it is missing) what macOS asks of the user once it is on.
        var detail: String?
    }

    /// What macOS asks for after the switch is on: it counts the permission from the next time Nook opens.
    static let restartAdvice = "Si te ofrece «Salir y volver a abrir», acéptalo: cuenta desde que Nook vuelve a abrirse."

    static func permission(_ state: NookPermission.State?) -> Permission {
        let base = NookPermission.screenRecording.presentation(for: state)
        let missing = state == .notAsked || state == .denied
        // A permission that is on has nothing to say; one that is not says what it is for and, when it is missing, what comes after switching it on.
        let detail = base.action == nil ? nil : missing ? permissionPurpose + " " + restartAdvice : permissionPurpose
        return Permission(chip: base.chip, tone: state == .notAsked ? .attention : base.tone, symbol: base.symbol, action: base.action, detail: detail)
    }

    /// The tool's row: where Claude Code stands with `capture_screen`.
    struct Tool: Equatable {
        var chip: String
        var tone: PermissionTone
        var symbol: String
        /// `ScreenVision.describe`: one sentence, in the model's words.
        var sentence: String
        var working: Bool
        /// A failure can be tried again; anything else has nothing to press.
        var canRetry: Bool
    }

    static func tool(_ registration: ScreenVision.Registration) -> Tool {
        let sentence = ScreenVision.describe(registration)
        switch registration {
        case .idle: return Tool(chip: "Sin añadir", tone: .neutral, symbol: "circle.dashed", sentence: sentence, working: false, canRetry: false)
        case .working: return Tool(chip: "En curso", tone: .neutral, symbol: "ellipsis.circle", sentence: sentence, working: true, canRetry: false)
        case .ready: return Tool(chip: "Lista", tone: .good, symbol: "checkmark.circle.fill", sentence: sentence, working: false, canRetry: false)
        case .failed: return Tool(chip: "No se pudo", tone: .bad, symbol: "xmark.circle.fill", sentence: sentence, working: false, canRetry: true)
        }
    }

    // The words of the tab outside its rows.
    static let switchTitle = "Dejar que Claude vea mi pantalla"
    static let attachTitle = "Adjuntar mi pantalla a cada mensaje"
    static let attachNote = "Igual que el botón del ojo junto al campo de mensaje."
    static let facts: [(symbol: String, lead: String, text: String)] = [
        ("display", "Qué ve.", "La pantalla donde está el puntero, sin las ventanas de Nook. Claude también puede pedir la principal o todas."),
        ("clock", "Cuándo.", "Con cada mensaje, si activas el botón del ojo junto al campo de mensaje; y cuando Claude usa su herramienta capture_screen."),
        ("puzzlepiece.extension", "En Claude Code.", "Al activarla, Nook añade la herramienta capture_screen; al desactivarla, la quita."),
        ("folder", "Dónde queda.", "En /tmp, legible solo por tu usuario. Nook borra las de más de 24 horas al guardar otra."),
    ]
    static let privacyNote = "Mientras esté activada, cualquier programa que se ejecute con tu usuario puede pedirle una captura a Nook."
    static let toolTitle = "Herramienta para Claude"
    static let permissionPurpose = "macOS pide este permiso para que Nook pueda capturar la pantalla."
}

// MARK: - The tab

struct ScreenVisionPane: View {
    @ObservedObject var vision: ScreenVision
    @ObservedObject var permissions: PermissionsModel
    /// The tallest the tab may be: past it the tab scrolls instead of the card running off the screen.
    var maxHeight: CGFloat
    /// Called when something that changes the tab's height has changed, so the card's window can follow.
    var onContentChange: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Copy = ScreenVisionPanePresentation

    /// Everything the tab's height depends on.
    private struct Layout: Equatable {
        var enabled: Bool
        var registration: ScreenVision.Registration
        var restart: Bool
        var permission: NookPermission.State?
    }
    private var layout: Layout {
        Layout(enabled: vision.enabled, registration: vision.registration, restart: vision.needsClaudeRestart, permission: permissions.states[.screenRecording])
    }

    var body: some View {
        // The tab at its own height when it fits, in a scroll view when it does not.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }.scrollIndicators(.automatic)
        }
        .frame(maxHeight: maxHeight)
        // The permission is read when the tab comes up (and by the model whenever the user may have changed it in System Settings).
        .onAppear { permissions.refresh() }
        .onChange(of: layout) { _, _ in onContentChange() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel("Visión de pantalla")
                Toggle(Copy.switchTitle, isOn: $vision.enabled)
                    .toggleStyle(.switch).controlSize(.small).tint(PermissionPalette.mint)
                    .font(.system(size: 12, weight: .medium)).accessibilityLabel(Copy.switchTitle)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(Copy.facts.enumerated()), id: \.offset) { _, fact in Fact(symbol: fact.symbol, lead: fact.lead, text: fact.text) }
            }
            if vision.enabled {
                enabledSection.transition(.opacity)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
                Text(Copy.privacyNote).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: vision.enabled)
    }

    /// What shows while the feature is on: the composer's own switch, and the two things it needs.
    private var enabledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle(Copy.attachTitle, isOn: $vision.attachToMessages)
                    .toggleStyle(.switch).controlSize(.small).tint(PermissionPalette.mint)
                    .font(.system(size: 12, weight: .medium)).accessibilityLabel(Copy.attachTitle)
                Text(Copy.attachNote).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                permissionRow
                toolRow
                if vision.needsClaudeRestart { restartNote }
            }
        }
    }

    private var permissionRow: some View {
        let shown = Copy.permission(permissions.states[.screenRecording])
        let permission = NookPermission.screenRecording
        return StatusRow(symbol: permission.symbol, title: permission.title, chip: shown.chip, chipSymbol: shown.symbol, tone: shown.tone) {
            if let detail = shown.detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
            if let action = shown.action {
                HStack(spacing: 8) {
                    RowButton(title: action.title, symbol: action.symbol, prominent: true) { permissions.perform(action, for: .screenRecording) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var toolRow: some View {
        let shown = Copy.tool(vision.registration)
        return StatusRow(symbol: "puzzlepiece.extension", title: Copy.toolTitle, chip: shown.chip, chipSymbol: shown.symbol, tone: shown.tone) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if shown.working { ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10) }
                // A failure can be a command to run by hand: it can be selected and copied.
                Text(shown.sentence).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if shown.canRetry {
                HStack(spacing: 8) {
                    RowButton(title: "Reintentar", symbol: "arrow.clockwise", prominent: true) { vision.retryRegistration() }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// Claude Code reads its tools when a session starts: sessions that were open when the tool was added do not have it yet.
    private var restartNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(PermissionPalette.amber).padding(.top, 1)
            Text(ScreenVision.restartNote).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { vision.dismissRestartNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.primary.opacity(0.62)).frame(width: 20, height: 20).contentShape(Rectangle())
            }.nookPress(.spin).help("Entendido: ocultar este aviso").accessibilityLabel("Entendido")
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
        .background(PermissionPalette.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Pieces

/// One of the plain lines about what is captured and where it goes: a symbol, a lead word and the rest.
private struct Fact: View {
    var symbol: String
    var lead: String
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).frame(width: 14).accessibilityHidden(true)
            (Text(lead + " ").fontWeight(.semibold).foregroundStyle(Color.primary.opacity(0.85)) + Text(text))
                .font(.system(size: 10.5)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One thing the feature needs, in the card the Permisos tab's rows are: its icon, its name, its state, and under them what to do. A state too long
/// for the line drops under the name.
private struct StatusRow<Detail: View>: View {
    var symbol: String
    var title: String
    var chip: String
    var chipSymbol: String
    var tone: PermissionTone
    private let detail: Detail

    init(symbol: String, title: String, chip: String, chipSymbol: String, tone: PermissionTone, @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol; self.title = title; self.chip = chip; self.chipSymbol = chipSymbol; self.tone = tone
        self.detail = detail()
    }

    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tone.color)
            .frame(width: 24, height: 24).background(tone.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private var heading: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(1).fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { icon; heading; Spacer(minLength: 6); StateChip(text: chip, symbol: chipSymbol, tone: tone) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { icon; heading; Spacer(minLength: 0) }
                    StateChip(text: chip, symbol: chipSymbol, tone: tone)
                }
            }
            detail
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookWash(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(tone == .attention || tone == .bad ? tone.color.opacity(0.42) : Color.nookWash(0.07),
                                                                                 lineWidth: tone == .attention || tone == .bad ? 0.9 : 0.6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(chip)")
    }
}
