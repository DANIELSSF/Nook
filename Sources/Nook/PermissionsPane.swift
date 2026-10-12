import SwiftUI
import AppKit

// The "Permisos" tab of the settings card: one row for each thing Nook needs from macOS, with its state, one button that does
// the right thing and a step-by-step guide that opens in place. `PermissionsModel` holds the state and the mappings.

/// The island's own colours as the settings card uses them (`NookTheme.swift`): the vivid ones on the dark island, deeper ones on the light.
enum PermissionPalette {
    static let mint = Color.nookMint
    /// The question colour of the island's alerts.
    static let amber = Color.nookAmber
    /// The same amber for a dot, which is drawn and not read.
    static let amberFill = Color.nookAmberFill
    /// The failed colour of the island's alerts.
    static let red = Color.nookCoral
}

extension PermissionTone {
    /// The chip's text and symbol, and the row's icon.
    var color: Color {
        switch self {
        case .good: PermissionPalette.mint
        case .attention: PermissionPalette.amber
        case .bad: PermissionPalette.red
        case .neutral: Color.primary.opacity(0.66)
        }
    }
    var wash: Color {
        switch self {
        case .good: PermissionPalette.mint.opacity(0.17)
        case .attention: PermissionPalette.amber.opacity(0.15)
        case .bad: PermissionPalette.red.opacity(0.17)
        case .neutral: Color.nookWash(0.08)
        }
    }
}

struct PermissionsPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsModel
    /// The tallest the tab may be: past it the list scrolls instead of the card running off the screen.
    var maxHeight: CGFloat

    var body: some View {
        // The list at its own height when it fits, in a scroll view when it does not.
        ViewThatFits(in: .vertical) {
            list
            ScrollView(.vertical) { list }.scrollIndicators(.automatic)
        }.frame(maxHeight: maxHeight)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 13) {
            group("Necesario", NookPermission.allCases.filter(\.essential))
            group("Opcionales", NookPermission.allCases.filter { !$0.essential })
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Integración con Claude").padding(.bottom, 1)
                ClaudeSignalsRow(model: model, permissions: permissions)
                ClaudeLimitsRow(model: model, permissions: permissions)
            }
            footer
        }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
    }

    private func group(_ title: String, _ items: [NookPermission]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title).padding(.bottom, 1)
            ForEach(items) { permission in
                PermissionRow(permission: permission, presentation: permissions.presentation(for: permission), open: permissions.isOpen(permission.id),
                              toggleGuide: { permissions.toggleGuide(permission.id) }, perform: { permissions.perform($0, for: permission) })
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
            Text("Los permisos los guarda macOS: Nook solo los pide y te lleva hasta el interruptor. El estado se actualiza solo al volver de Ajustes.")
                .font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Rows

/// One macOS permission. A permission that is on is a single line (icon, title, state); one that needs something from the user
/// also says what it is for and has its button. The chevron opens the guide on any of them.
struct PermissionRow: View {
    var permission: NookPermission
    var presentation: PermissionPresentation
    var open: Bool
    var toggleGuide: () -> Void
    var perform: (PermissionAction) -> Void

    var body: some View {
        RowFrame(tone: presentation.tone, emphasized: permission.essential && presentation.tone != .good, needsAction: presentation.action != nil,
                 title: permission.title, open: open, toggleGuide: toggleGuide, header: {
            RowHeader(symbol: permission.symbol, title: permission.title, chip: presentation.chip, chipSymbol: presentation.symbol, tone: presentation.tone, open: open)
        }, detail: {
            Text(permission.purpose).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
        }, actions: {
            if let action = presentation.action {
                RowButton(title: action.title, symbol: action.symbol, prominent: true) { perform(action) }
            }
        }, guide: {
            GuideSteps(steps: permission.steps, note: permission.note,
                       // The guide's own way to the pane, unless the row's button already is that.
                       settings: presentation.action == .openSettings ? nil : { perform(.openSettings) })
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(permission.title), \(presentation.chip)")
    }
}

/// "Avisos de Claude": Nook's hooks in Claude's settings. Not a macOS permission, and it says so.
struct ClaudeSignalsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsModel

    private var presentation: ClaudeSignalsPresentation { .make(enabled: model.claudeSignalsEnabled, folders: permissions.claudeFolders) }

    var body: some View {
        let shown = presentation
        RowFrame(tone: shown.tone, emphasized: false, needsAction: shown.action == .enable, title: "Avisos de Claude", open: permissions.isOpen(PermissionsModel.claudeKey),
                 toggleGuide: { permissions.toggleGuide(PermissionsModel.claudeKey) }, header: {
            RowHeader(symbol: "bell.badge", title: "Avisos de Claude", chip: shown.chip, chipSymbol: shown.symbol, tone: shown.tone, open: permissions.isOpen(PermissionsModel.claudeKey))
        }, detail: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nook sabe al instante cuándo Claude trabaja, termina o te necesita. Es un ajuste de Claude, no un permiso de macOS.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                if let folders = permissions.claudeFolders, !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(folders, id: \.name) { folder in
                            HStack(spacing: 5) {
                                Image(systemName: folder.enabled ? "checkmark" : "minus").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(folder.enabled ? PermissionPalette.mint : Color.nookSecondary).frame(width: 10)
                                Text(folder.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.primary.opacity(folder.enabled ? 0.8 : 0.55))
                            }.accessibilityElement(children: .combine).accessibilityLabel("\(folder.name), \(folder.enabled ? "con avisos" : "sin avisos")")
                        }
                    }
                }
            }
        }, actions: {
            RowButton(title: shown.action.title, symbol: shown.action.symbol, prominent: shown.action == .enable) {
                // Its own confirmation dialog runs first; the folders are read again once it closes.
                model.enableClaudeSignals()
                permissions.refresh()
            }
        }, guide: {
            GuideSteps(steps: [
                "Pulsa «Activar avisos…» y confirma. Nook añade sus hooks a settings.json de cada carpeta de Claude, con una copia de seguridad, y conserva tus otros ajustes.",
                "En una sesión de Claude que ya estaba abierta, revisa /hooks para aprobar el cambio; algunas versiones piden reabrir Claude.",
                "Para quitarlos, pulsa «Desactivar…»: solo se eliminan los hooks de Nook.",
            ], note: nil, settings: nil)
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Avisos de Claude, \(shown.chip)")
    }
}

/// "Límites en vivo": Nook's status line in Claude's settings, which is how a Terminal tab gets its limits, its cost and its context without a key or a scroll. Not a macOS
/// permission either, and what it changes in Claude is said before it is turned on, and again while it is.
struct ClaudeLimitsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var permissions: PermissionsModel

    private var presentation: ClaudeLimitsPresentation { .make(folders: permissions.statusLineFolders) }
    private static let title = "Límites en vivo"

    var body: some View {
        let shown = presentation
        let open = permissions.isOpen(PermissionsModel.limitsKey)
        RowFrame(tone: shown.tone, emphasized: false, needsAction: shown.action == .enable, showsDetail: shown.tone == .attention, actionsWhenOpen: shown.action != nil,
                 title: Self.title, open: open, toggleGuide: { permissions.toggleGuide(PermissionsModel.limitsKey) }, header: {
            RowHeader(symbol: "gauge.with.dots.needle.67percent", title: Self.title, chip: shown.chip, chipSymbol: shown.symbol, tone: shown.tone, open: open)
        }, detail: {
            VStack(alignment: .leading, spacing: 8) {
                Text(ClaudeLimitsPresentation.subtitle).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                if let note = shown.note {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: shown.tone == .attention ? "exclamationmark.triangle.fill" : "info.circle").font(.system(size: 10))
                            .foregroundStyle(shown.tone == .attention ? PermissionPalette.amber : shown.tone.color)
                        Text(note).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("QUÉ SE GUARDA").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(Color.nookSecondary)
                    Text(ClaudeLimitsPresentation.keeps).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 3) {
                    Text("QUÉ CAMBIA EN CLAUDE").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(Color.nookSecondary)
                    Text(ClaudeLimitsPresentation.effects).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
                if let folders = permissions.statusLineFolders, ClaudeLimitsPresentation.listsFolders(folders, open: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(folders, id: \.name) { folder in
                            let line = ClaudeLimitsPresentation.line(for: folder.state)
                            HStack(spacing: 5) {
                                Image(systemName: line.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(line.tone == .neutral ? Color.nookSecondary : line.tone.color).frame(width: 10)
                                Text(folder.name).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.primary.opacity(line.tone == .neutral ? 0.55 : 0.8))
                                Text(line.words).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            }.accessibilityElement(children: .combine).accessibilityLabel("\(folder.name), \(line.words)")
                        }
                    }
                }
            }
        }, actions: {
            if let action = shown.action {
                RowButton(title: action.title, symbol: action.symbol, prominent: action == .enable) {
                    // Its own confirmation dialog runs first; the folders are read again once it closes.
                    model.toggleClaudeStatusLine()
                    permissions.refresh()
                }
            }
        }, guide: {
            GuideSteps(steps: [
                "Pulsa «Activar…» y confirma. Nook añade a settings.json de cada carpeta de Claude una línea de estado que solo le pasa sus datos a Nook.",
                "Si ya tenías una línea de estado, sigue mostrándose igual: Nook la ejecuta después de la suya.",
                ClaudeLimitsPresentation.pickup + " No hace falta reabrirlas.",
                "Para quitarla, pulsa «Quitar…»: tu línea de estado vuelve a ser exactamente la que era y se borran los datos guardados.",
            ], note: ClaudeLimitsPresentation.keepsInDetail(folder: NookStatusLine.statusFolder.path) + " " + ClaudeLimitsPresentation.backups, settings: nil)
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.title), \(shown.chip)")
    }
}

/// The card every row sits in. Its parts are slots so the permissions and Claude's signals share one look.
private struct RowFrame<Header: View, Detail: View, Actions: View, Guide: View>: View {
    var tone: PermissionTone
    /// The row asks for attention: it gets an outline in its tone.
    var emphasized: Bool
    /// There is something to do: the row shows what it is for and its button without being opened. Otherwise it is one line.
    var needsAction: Bool
    /// There is something to say without a button (a settings file Nook cannot read): the row shows its detail without being opened.
    var showsDetail: Bool
    /// The button is there once the row is open, too (to take back what is on).
    var actionsWhenOpen: Bool
    var title: String
    var open: Bool
    var toggleGuide: () -> Void
    var header: Header
    var detail: Detail
    var actions: Actions
    var guide: Guide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tone: PermissionTone, emphasized: Bool, needsAction: Bool, showsDetail: Bool = false, actionsWhenOpen: Bool = false, title: String, open: Bool, toggleGuide: @escaping () -> Void,
         @ViewBuilder header: () -> Header, @ViewBuilder detail: () -> Detail, @ViewBuilder actions: () -> Actions, @ViewBuilder guide: () -> Guide) {
        self.tone = tone; self.emphasized = emphasized; self.needsAction = needsAction; self.showsDetail = showsDetail; self.actionsWhenOpen = actionsWhenOpen
        self.title = title; self.open = open; self.toggleGuide = toggleGuide
        self.header = header(); self.detail = detail(); self.actions = actions(); self.guide = guide()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if reduceMotion { toggleGuide() } else { withAnimation(.easeOut(duration: 0.18)) { toggleGuide() } }
            } label: { header.contentShape(Rectangle()) }
                .nookPress(.none, depth: PressDepth.row).help("Cómo hacerlo")
                .accessibilityLabel("Cómo hacerlo: \(title)").accessibilityValue(open ? "Abierto" : "Cerrado")
            if needsAction || showsDetail || open { detail }
            if needsAction || (open && actionsWhenOpen) { HStack(spacing: 8) { actions; Spacer(minLength: 0) } }
            if open { guide.transition(.opacity) }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nookWash(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(emphasized ? tone.color.opacity(0.42) : Color.nookWash(0.07), lineWidth: emphasized ? 0.9 : 0.6))
    }
}

/// Icon, title, the state's chip and the guide's chevron. A chip too long for the line (Terminal closed) drops under the title.
private struct RowHeader: View {
    var symbol: String
    var title: String
    var chip: String
    var chipSymbol: String
    var tone: PermissionTone
    var open: Bool

    private var icon: some View {
        Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tone.color)
            .frame(width: 24, height: 24).background(tone.wash, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private var heading: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary).lineLimit(1).fixedSize()
    }
    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(open ? PermissionPalette.mint : Color.nookSecondary)
            .rotationEffect(.degrees(open ? 180 : 0)).frame(width: 16, height: 24)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                icon
                heading
                Spacer(minLength: 6)
                StateChip(text: chip, symbol: chipSymbol, tone: tone)
                chevron
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { icon; heading; Spacer(minLength: 0); chevron }
                StateChip(text: chip, symbol: chipSymbol, tone: tone)
            }
        }
    }
}

/// The state, as a small capsule: a symbol and a word, never colour alone.
struct StateChip: View {
    var text: String
    var symbol: String
    var tone: PermissionTone

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }.foregroundStyle(tone.color).padding(.horizontal, 7).frame(height: 20)
            .background(tone.wash, in: Capsule()).fixedSize()
    }
}

/// A row's button: mint when it is the thing to do, quiet otherwise (the same chips as the size presets).
struct RowButton: View {
    var title: String
    var symbol: String
    var prominent: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }.padding(.horizontal, 10).frame(height: 26)
                .foregroundStyle(prominent ? Color.nookText : Color.primary.opacity(0.8))
                .background(prominent ? PermissionPalette.mint.opacity(hovering ? 0.32 : 0.22) : Color.nookWash(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PermissionPalette.mint.opacity(prominent ? 0.55 : 0), lineWidth: 0.8))
                .contentShape(Rectangle())
        }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).onHover { hovering = $0 }.accessibilityLabel(title)
    }
}

// MARK: - The guide

/// "Cómo hacerlo": the steps, numbered, an aside when the permission has one, and a way to the pane for the rows whose button is
/// something else.
private struct GuideSteps: View {
    var steps: [String]
    var note: String?
    var settings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CÓMO HACERLO").font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(Color.nookSecondary)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(index + 1)").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(PermissionPalette.mint)
                        .frame(width: 16, height: 16).background(PermissionPalette.mint.opacity(0.16), in: Circle())
                    Text(step).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine).accessibilityLabel("Paso \(index + 1). \(step)")
            }
            if let note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(PermissionPalette.amber)
                    Text(note).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PermissionPalette.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let settings {
                RowButton(title: PermissionAction.openSettings.title, symbol: PermissionAction.openSettings.symbol, prominent: false, action: settings)
            }
        }
        .padding(.top, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color.nookWash(0.08)).frame(height: 0.5) }
    }
}

/// "Ver permisos": the pill a notice or an error offers when what went wrong is a permission.
struct SeePermissionsButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield").font(.system(size: 9.5, weight: .semibold))
                Text("Ver permisos").font(.system(size: 10.5, weight: .semibold))
            }.foregroundStyle(PermissionPalette.mint).padding(.horizontal, 9).frame(height: 22)
                .background(PermissionPalette.mint.opacity(hovering ? 0.26 : 0.17), in: Capsule()).contentShape(Capsule())
        }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).onHover { hovering = $0 }.help("Abrir los permisos de Nook").accessibilityLabel("Ver permisos")
    }
}
