import SwiftUI
import AppKit

// The "Sonido" tab of the settings card: whether an alert makes a sound, which one says what, how loud, and which tabs may make it.
//
// What it edits is `AppModel.alertSound` (the switch for every tab, a sound for each kind of alert, the volume) and each tab's own switch (`AppModel.setAlertSound`, kept by the
// tab's id); the decision to play is the model's (`AppModel.raiseAlert`). Pointing at a sound plays it (`AppModel.previewAlertSound`, which plays whatever the switches say), so the
// ear can choose. A tab whose own switch is off carries a slashed speaker in the tab row, and the tab's context menu, its «…» menu and its editor have the switch too.

// MARK: - Words

enum SoundCopy {
    static let title = "Sonido de avisos"
    static let mainDetail = "Suena cuando una terminal termina, hace una pregunta o falla."
    static let mainOff = "Los avisos son silenciosos. Terminal sigue sonando por su cuenta."
    static let mutedTab = "Sin sonido de avisos en esta pestaña"
    static let volume = "Volumen"
    static let enableAll = "Activar en todas"
    static let muteAll = "Silenciar todas"
    static let noTabs = "Aún no hay pestañas."
    static let tabsHint = "También con clic derecho en una pestaña, o en su menú «…»."
    static let editorDetail = "Suena cuando esta pestaña termina, pregunta o falla."
    static let editorOff = "Apagado para todas las pestañas, en Ajustes → Sonido."
    static let preview = "Escuchar"

    /// What a tab's menus offer: to turn its own sound off while it is on, and on while it is off.
    static func tabToggle(on: Bool) -> String { on ? "Silenciar sonido de esta pestaña" : "Activar sonido de esta pestaña" }

    /// The kind of alert, as the picker names it.
    static func kind(_ kind: NookAlert.Kind) -> String {
        switch kind { case .finished: "Terminó"; case .question: "Pregunta"; case .failed: "Error" }
    }
    static func kindDetail(_ kind: NookAlert.Kind) -> String {
        switch kind { case .finished: "Una IA terminó su turno"; case .question: "Una IA espera tu respuesta"; case .failed: "Una IA se detuvo con un error" }
    }
    static func symbol(_ kind: NookAlert.Kind) -> String {
        switch kind { case .finished: "checkmark.circle.fill"; case .question: "questionmark.bubble.fill"; case .failed: "exclamationmark.triangle.fill" }
    }

    /// How many of the tabs have their sound on, in words: "Todas con sonido", "Ninguna con sonido", "2 de 3 con sonido".
    static func tabsSummary(on: Int, of total: Int) -> String {
        guard total > 0 else { return noTabs }
        if on == total { return total == 1 ? "Con sonido" : "Todas con sonido" }
        if on == 0 { return total == 1 ? "Sin sonido" : "Ninguna con sonido" }
        return "\(on) de \(total) con sonido"
    }

    /// The volume as a percentage.
    static func percent(_ volume: Double) -> String { "\(Int((volume * 100).rounded())) %" }
}

extension NookAlert.Kind: CaseIterable {
    static var allCases: [NookAlert.Kind] { [.finished, .question, .failed] }
}

// MARK: - The pane

struct SoundSettingsPane: View {
    @ObservedObject var model: AppModel
    /// The tallest the tab may be: past it the list scrolls instead of the card running off the screen.
    var maxHeight: CGFloat

    private var sound: AlertSoundSettings { model.alertSound }
    private var on: Bool { sound.enabled }

    var body: some View {
        // At its own height when it fits, in a scroll view when it does not.
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }.scrollIndicators(.automatic)
        }.frame(maxHeight: maxHeight)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 15) {
            mainSwitch
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Sonidos")
                VStack(spacing: 6) {
                    ForEach(NookAlert.Kind.allCases, id: \.self) { kind in
                        SoundKindRow(model: model, kind: kind)
                    }
                }
            }.opacity(on ? 1 : 0.45).allowsHitTesting(on).animation(.easeOut(duration: 0.16), value: on)
            volumeRow.opacity(on ? 1 : 0.45).allowsHitTesting(on).animation(.easeOut(duration: 0.16), value: on)
            SoundTabsSection(model: model).opacity(on ? 1 : 0.55).animation(.easeOut(duration: 0.16), value: on)
        }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
    }

    /// The switch for every tab: a speaker that waves while it is on, and what it does in a line.
    private var mainSwitch: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Color.nookMintFill.opacity(0.2) : Color.nookWash(0.07))
                Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(on ? Color.nookMint : Color.nookSecondary)
                    .contentTransition(.symbolEffect(.replace))
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(SoundCopy.title).font(.system(size: 12.5, weight: .semibold))
                Text(on ? SoundCopy.mainDetail : SoundCopy.mainOff).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle(SoundCopy.title, isOn: Binding(get: { sound.enabled }, set: { model.alertSound.enabled = $0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color.nookMintFill)
        }
        .animation(.easeOut(duration: 0.16), value: on)
        .accessibilityElement(children: .contain)
    }

    private var volumeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(SoundCopy.volume)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(Color.nookSecondary).frame(width: 14)
                Slider(value: Binding(get: { sound.volume }, set: { model.alertSound.volume = $0 }), in: 0...1) { editing in
                    // Let go, it plays once at the volume it was left at.
                    if !editing { model.previewAlertSound(for: .finished) }
                }.controlSize(.small).tint(Color.nookMintFill)
                    .accessibilityLabel(SoundCopy.volume).accessibilityValue(SoundCopy.percent(sound.volume))
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(Color.nookSecondary).frame(width: 16)
                Text(SoundCopy.percent(sound.volume)).font(.system(size: 10.5, design: .monospaced)).monospacedDigit().foregroundStyle(Color.nookSecondary)
                    .frame(width: 40, alignment: .trailing)
            }.frame(height: 22)
        }
    }
}

// MARK: - A kind of alert

/// One kind of alert and the sound that says it: a symbol in its colour, its name, a picker with the Mac's own sounds (choosing one plays it) and a button to hear the current one.
private struct SoundKindRow: View {
    @ObservedObject var model: AppModel
    var kind: NookAlert.Kind

    private var tint: Color {
        switch kind { case .finished: Color.nookMint; case .question: Color.nookAmber; case .failed: Color.nookCoral }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: SoundCopy.symbol(kind)).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(SoundCopy.kind(kind)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                // A second line rather than an ellipsis, where the card is narrow.
                Text(SoundCopy.kindDetail(kind)).font(.system(size: 9)).foregroundStyle(Color.nookSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            SoundPicker(selected: model.alertSound.sound(for: kind)) { choice in
                model.alertSound.setSound(choice, for: kind)
                model.previewAlertSound(choice, for: kind)
            }
            PreviewButton(label: "\(SoundCopy.preview) \(SoundCopy.kind(kind).lowercased())") { model.previewAlertSound(for: kind) }
        }
        .padding(.horizontal, 9).padding(.vertical, 4).frame(minHeight: 38)
        .background(Color.nookWash(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// The list of the Mac's sounds, as a pill with the current one's name; the one chosen has a check.
struct SoundPicker: View {
    var selected: AlertSound
    var choose: (AlertSound) -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(AlertSound.allCases) { sound in
                Button { choose(sound) } label: {
                    if sound == selected { Label(sound.title, systemImage: "checkmark") } else { Text(sound.title) }
                }
            }
        } label: {
            // The pill holds still and its chevrons answer the click.
            NookMenuGlyph(motion: .none) {
                HStack(spacing: 5) {
                    Text(selected.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(Color.nookSecondary).nookIconMotion(.squeeze)
                }
                // As wide as the longest of the Mac's sounds («Submarino») needs, and no wider: the line beside it keeps its room.
                .padding(.horizontal, 9).frame(width: 86, height: 24, alignment: .leading)
                .background(Color.nookWash(hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .nookMenu(depth: PressDepth.card)
        .onHover { hovering = $0 }
        .accessibilityLabel("Sonido").accessibilityValue(selected.title)
    }
}

/// ▶︎: plays the sound. The speaker waves for a moment while it does.
private struct PreviewButton: View {
    var label: String
    var action: () -> Void
    @State private var playing = false
    @State private var hovering = false
    private let gate = NookMotionGate()

    var body: some View {
        Button {
            action()
            playing = true
        } label: {
            Image(systemName: playing ? "speaker.wave.3.fill" : "play.fill").font(.system(size: 9.5, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .nonRepeating, isActive: playing && gate.allows)
                .foregroundStyle(playing ? Color.nookMint : Color.primary.opacity(0.82))
                .frame(width: 24, height: 24)
                .background(Color.nookWash(hovering ? 0.13 : 0.08), in: Circle())
                .contentShape(Circle())
        }
        .nookPress(.pulse)
        .onHover { hovering = $0 }
        .help(label).accessibilityLabel(label)
        .task(id: playing) {
            guard playing else { return }
            try? await Task.sleep(for: .seconds(1.1))
            if !Task.isCancelled { playing = false }
        }
    }
}

// MARK: - The tabs

/// The tabs' own switches: all at once (two small buttons, the one that says how they all stand lit), and each one in a list.
private struct SoundTabsSection: View {
    @ObservedObject var model: AppModel

    private var summary: String {
        SoundCopy.tabsSummary(on: model.sessions.filter(\.alertSoundOn).count, of: model.sessions.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SectionLabel("Pestañas")
                Spacer(minLength: 4)
                Text(summary).font(.system(size: 9.5)).foregroundStyle(Color.nookSecondary)
            }
            HStack(spacing: 6) {
                SoundChip(title: SoundCopy.enableAll, symbol: "speaker.wave.2", lit: model.alertSoundOnForAllTabs == true) { model.setAlertSoundForAllTabs(true) }
                SoundChip(title: SoundCopy.muteAll, symbol: "speaker.slash", lit: model.alertSoundOnForAllTabs == false) { model.setAlertSoundForAllTabs(false) }
            }.disabled(model.sessions.isEmpty)
            if !model.sessions.isEmpty {
                // Up to six rows, then it scrolls.
                ScrollView(.vertical) {
                    VStack(spacing: 4) { ForEach(model.sessions) { session in SoundTabRow(model: model, session: session) } }
                }.scrollIndicators(.automatic).frame(maxHeight: 6 * 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(SoundCopy.tabsHint).font(.system(size: 9.5)).foregroundStyle(Color.nookTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// «Activar en todas» / «Silenciar todas»: a small chip, mint when it is how the tabs all stand.
struct SoundChip: View {
    var title: String
    var symbol: String
    var lit: Bool
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: lit ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(lit ? Color.nookText : Color.primary.opacity(0.8))
            .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 26)
            .background(lit ? Color.nookMintFill.opacity(0.22) : Color.nookWash(hovering && enabled ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.nookMintFill.opacity(lit ? 0.55 : 0), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        // The chip is half the card wide: a gentler squeeze, so it never spills onto the one beside it.
        .nookPress(.squeeze, depth: PressDepth.card, strength: 0.4)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}

/// One tab in the list: its mark in its colour, its name, and its own switch.
private struct SoundTabRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 8) {
            TabIconView(icon: session.icon, color: session.tint.color, size: 11, working: false, animated: false).frame(width: 18, height: 18).accessibilityHidden(true)
            Text(session.displayTitle).font(.system(size: 11)).lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: session.alertSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 9.5))
                .foregroundStyle(session.alertSoundOn ? session.tint.color : Color.nookTertiary).frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
            Toggle(session.displayTitle, isOn: Binding(get: { session.alertSoundOn }, set: { model.setAlertSound($0, for: session) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(session.tint.accent)
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(Color.nookWash(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.alertSoundOn ? "con sonido" : "sin sonido")
    }
}
