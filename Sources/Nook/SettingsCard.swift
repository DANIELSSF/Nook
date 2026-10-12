import SwiftUI
import AppKit

// Nook's settings, as a small card in its own look: display, capture privacy, and the permissions Nook
// needs from macOS (`PermissionsPane`). It lives in a window of its own that hangs under the open island (`SettingsWindow`),
// centred on the notch, so the island stays fully visible while a slider moves: the text changes size, the island grows or
// shrinks, and the card (whose position does not depend on the island's width) never moves sideways under the pointer. The
// window follows the card's height as the tab changes and a guide opens.

private let mint = Color.nookMint

/// What the card's tab bar needs to know about a tab (a protocol so the bar can be tried with more tabs than the card has today).
protocol SettingsTabItem: Hashable, Identifiable {
    var title: String { get }
    var symbol: String { get }
    /// What the dot on the tab says when it is out: the tab's value for VoiceOver, and a line in its tooltip.
    var attentionNote: String { get }
}

/// Display, the cat, the alerts' sound, permissions, experimental capture privacy, and screen vision.
enum SettingsTab: String, CaseIterable, Identifiable, SettingsTabItem {
    case island, pet, sound, permissions, privacy, screen
    var id: String { rawValue }
    var attentionNote: String { self == .screen ? "Falta el permiso de grabación de pantalla" : "Falta un permiso necesario" }
    var title: String {
        switch self {
        case .island: return "Isla"
        case .pet: return "Gato"
        case .sound: return "Sonido"
        case .permissions: return "Permisos"
        case .privacy: return "Privacidad"
        case .screen: return "Pantalla"
        }
    }
    var symbol: String {
        switch self {
        case .island: return "slider.horizontal.3"
        case .pet: return "pawprint"
        case .sound: return "speaker.wave.2"
        case .permissions: return "lock.shield"
        case .privacy: return "eye.slash"
        case .screen: return "display"
        }
    }
}

struct SettingsCard: View {
    @ObservedObject var model: AppModel
    /// The screen's size and the header's height, which decide how far the island can grow.
    var screen: CGSize
    var topInset: CGFloat
    var onClose: () -> Void = {}
    /// Called when something that changes the card's height has changed (another tab, a guide opening), so its window can follow.
    var onContentChange: () -> Void = {}
    @ObservedObject var permissions: PermissionsModel
    /// Screen vision has its own tab; it is observed here for the dot on it.
    @ObservedObject private var vision: ScreenVision

    /// The card's own width; its height follows its content.
    static let width: CGFloat = 352

    /// `permissions` is for previews and tests, which pass one that reads and asks nothing; the app's card uses the model's own.
    init(model: AppModel, screen: CGSize, topInset: CGFloat, permissions: PermissionsModel? = nil, onClose: @escaping () -> Void = {}, onContentChange: @escaping () -> Void = {}) {
        self.model = model; self.screen = screen; self.topInset = topInset; self.onClose = onClose; self.onContentChange = onContentChange
        self.permissions = permissions ?? model.permissions
        self.vision = model.screenVision
    }

    private var settings: DisplaySettings { model.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SettingsTabBar(tabs: SettingsTab.allCases, selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 }), attention: attention)
                .padding(.horizontal, 16).padding(.bottom, 12)
            switch model.settingsTab {
            case .island:
                VStack(alignment: .leading, spacing: 15) {
                    themeSection
                    sizeSection
                    textSection
                    welcomeSection
                    footer
                }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
            case .pet:
                PetSettingsPane(model: model, maxHeight: maxCardHeight - Self.chromeHeight)
            case .sound:
                SoundSettingsPane(model: model, maxHeight: maxCardHeight - Self.chromeHeight)
            case .permissions:
                PermissionsPane(model: model, permissions: permissions, maxHeight: maxCardHeight - Self.chromeHeight)
            case .privacy:
                CapturePrivacyPane(privacy: model.capturePrivacy, onContentChange: onContentChange)
                    .padding(.horizontal, 16).padding(.bottom, 15)
            case .screen:
                ScreenVisionPane(vision: vision, permissions: permissions, maxHeight: maxCardHeight - Self.chromeHeight, onContentChange: onContentChange)
            }
        }
        .frame(width: Self.width)
        .nookGlassCard(radius: 18, dim: 0.96, dimColor: Color.nookSettings, fill: Color.nookSettings, stroke: Color.nookWash(0.1, light: 0.13))
        .nookCardShadow(0.5, radius: 16, y: 6)
        // The card is a window of its own: it takes the island's theme (and its window the matching appearance), and whether things move when used.
        .nookTheme(settings.theme)
        .nookMotion(model.animations)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ajustes de Nook")
        // Whatever changes the card's height tells its window, which measures it (see `SettingsWindow.remeasure`).
        .onChange(of: layout) { _, _ in onContentChange() }
        // The permissions are read when the card opens (whatever its tab, for the dot on "Permisos"), when that tab comes up, and
        // while it is open whenever the user may have changed one in System Settings (see `PermissionsModel`).
        .onAppear { permissions.setActive(model.settingsOpen) }
        .onChange(of: model.settingsOpen) { _, open in permissions.setActive(open) }
        .onChange(of: model.settingsTab) { _, tab in if tab == .permissions || tab == .screen, model.settingsOpen { permissions.refresh() } }
    }

    /// The tabs that ask for a look: "Permisos" while a needed permission is off, "Pantalla" while screen vision is on and macOS has not let Nook record the screen.
    private var attention: Set<SettingsTab> {
        var tabs = Set<SettingsTab>()
        if permissions.needsAttention { tabs.insert(.permissions) }
        if vision.enabled, [.notAsked, .denied].contains(permissions.states[.screenRecording]) { tabs.insert(.screen) }
        return tabs
    }

    /// Everything the card's height depends on.
    private struct Layout: Equatable {
        var tab: SettingsTab
        var guides: Set<String>
        var states: [NookPermission: NookPermission.State]
        var folders: [ClaudeFolder]?
        /// The "Límites en vivo" row's folders: what it says, and so how tall it is, follows them.
        var limits: [NookStatusLine.Folder]?
        var signals: Bool
        /// How tall the permissions' list and the screen tab may be; only those tabs care, so a slider on the other one costs nothing.
        var cap: CGFloat
        /// The sound tab lists the tabs, so it is as tall as they are many.
        var tabs: Int
    }
    private var layout: Layout {
        Layout(tab: model.settingsTab, guides: permissions.openGuides, states: permissions.states, folders: permissions.claudeFolders, limits: permissions.statusLineFolders,
               signals: model.claudeSignalsEnabled, cap: [.pet, .sound, .permissions, .screen].contains(model.settingsTab) ? maxCardHeight : 0,
               tabs: model.settingsTab == .sound ? model.sessions.count : 0)
    }

    /// The height of the header and the tabs, which the permissions' list has to leave room for.
    static let chromeHeight: CGFloat = 40 + SettingsTabMetrics.barHeight + 12
    /// The tallest the card may be: the room under the open island (a card over its lower part when there is none, as `SettingsPlacement` does).
    private var maxCardHeight: CGFloat {
        max(360, screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape").font(.system(size: 11, weight: .semibold)).foregroundStyle(mint)
            Text("Ajustes de Nook").font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 8)
            switch model.settingsTab {
            case .island:
                // The theme stays: «Restablecer» puts the island's size and texts back, and how the user likes it to look is not one of them.
                Button { model.display = settings.resetKeepingTheme() } label: {
                    Label("Restablecer", systemImage: "arrow.counterclockwise").font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.nookWash(settings.isDefault ? 0.04 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).foregroundStyle(settings.isDefault ? Color.nookSecondary.opacity(0.6) : Color.primary.opacity(0.85))
                    .disabled(settings.isDefault).help("Volver a la isla y los textos de siempre")
            case .pet:
                Button { model.pet = PetPreferences() } label: {
                    Label("Restablecer", systemImage: "arrow.counterclockwise").font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.nookWash(model.pet.isDefault ? 0.04 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).foregroundStyle(model.pet.isDefault ? Color.nookSecondary.opacity(0.6) : Color.primary.opacity(0.85))
                    .disabled(model.pet.isDefault).help("Volver al gato de siempre")
            case .sound:
                // The switches of the tabs stay: «Restablecer» puts the sounds and the volume back.
                Button { model.alertSound = AlertSoundSettings() } label: {
                    Label("Restablecer", systemImage: "arrow.counterclockwise").font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.nookWash(model.alertSound == AlertSoundSettings() ? 0.04 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.6).foregroundStyle(model.alertSound == AlertSoundSettings() ? Color.nookSecondary.opacity(0.6) : Color.primary.opacity(0.85))
                    .disabled(model.alertSound == AlertSoundSettings()).help("Volver a los sonidos y el volumen de siempre")
            case .permissions:
                Button { permissions.refresh() } label: {
                    Label("Comprobar", systemImage: "arrow.clockwise").font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).foregroundStyle(Color.primary.opacity(0.85)).help("Volver a comprobar los permisos")
            case .privacy, .screen:
                EmptyView()
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.nookSecondary).frame(width: 22, height: 22).contentShape(Rectangle())
            }.nookPress(.spin).help("Cerrar los ajustes").accessibilityLabel("Cerrar los ajustes")
        }.padding(.leading, 16).padding(.trailing, 10).frame(height: 40)
    }

    // MARK: Theme

    /// How the island looks: light, dark, or whichever macOS is (and it follows macOS as it changes).
    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Apariencia")
            ThemePicker(selection: Binding(get: { settings.theme }, set: { model.display.theme = $0 }))
        }
    }

    // MARK: Size

    private var island: CGSize { NotchGeometry.expandedSize(screen: screen, topInset: topInset, settings: settings) }
    private var widthRange: ClosedRange<CGFloat> { NotchGeometry.widthRange(screen: screen) }
    private var heightRange: ClosedRange<CGFloat> { NotchGeometry.heightRange(screen: screen, topInset: topInset) }

    /// A slider's value to the nearest multiple of 4 points, so the island's size does not change by a point at a time.
    static func snapped(_ value: Double) -> CGFloat { CGFloat((value / 4).rounded() * 4) }

    private func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
        let size = CGSize(width: width ?? island.width, height: height ?? island.height)
        model.display = NotchGeometry.settings(for: size, screen: screen, topInset: topInset, from: settings)
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Tamaño")
            HStack(spacing: 4) {
                ForEach(IslandPreset.allCases) { preset in
                    PresetChip(title: preset.title, selected: settings.preset == preset) { model.display = settings.applying(preset) }
                }
            }
            // Continuous (a stepped slider draws a tick for every step); the values snap to multiples of 4 points.
            SettingSlider(title: "Ancho", value: Binding(get: { Double(island.width) }, set: { resize(width: Self.snapped($0)) }),
                          range: Double(widthRange.lowerBound)...Double(max(widthRange.upperBound, widthRange.lowerBound + 1)), display: "\(Int(island.width)) pt")
            SettingSlider(title: "Alto", value: Binding(get: { Double(island.height) }, set: { resize(height: Self.snapped($0)) }),
                          range: Double(heightRange.lowerBound)...Double(max(heightRange.upperBound, heightRange.lowerBound + 1)), display: "\(Int(island.height)) pt")
        }
    }

    // MARK: Text

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel("Texto")
            SettingSlider(title: "Chat y consola", value: Binding(get: { settings.chatSize }, set: { model.display.chatSize = $0 }),
                          range: DisplaySettings.chatSizeRange, step: 1, display: "\(Int(settings.chatSize)) pt", small: 9, large: 14)
            SettingSlider(title: "Campo de texto", value: Binding(get: { settings.inputSize }, set: { model.display.inputSize = $0 }),
                          range: DisplaySettings.inputSizeRange, step: 1, display: "\(Int(settings.inputSize)) pt", small: 10, large: 15)
            LinesRow(lines: Binding(get: { settings.inputLines }, set: { model.display.inputLines = $0 }))
        }
    }

    // MARK: Welcome

    /// The greeting of the first run, whenever the user wants to see it again: the island shows it over whatever it has, and gives it back when it is closed.
    private var welcomeSection: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Bienvenida")
                Text("El saludo de Nook, con su gato.").font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            // The button keeps its whole name; it is the text beside it that wraps.
            WelcomeChip { withAnimation(model.animations ? .easeInOut(duration: 0.25) : nil) { model.greetingReplay = true } }.fixedSize()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 10)).foregroundStyle(Color.nookSecondary)
            Text("Con la isla abierta: ⌘+ y ⌘− cambian el texto del chat, ⌘0 lo restablece. También puedes arrastrar una esquina inferior de la isla.")
                .font(.system(size: 10)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pieces

/// The bar's measures. The card takes `barHeight` (and the header's 40 pt) off the room its panes have, so the bar's real height is checked against it in the tests.
enum SettingsTabMetrics {
    /// The height of a tab, like the size presets below it.
    static let chip: CGFloat = 26
    /// Between the bar's edge and its tabs.
    static let inset: CGFloat = 3
    static var barHeight: CGFloat { chip + 2 * inset }
    /// The least between a tab's edge and what is in it. The row shares what is left among its tabs, so at the card's width they have a good deal more.
    static let padding: CGFloat = 4
    /// Between a tab's symbol and its name.
    static let gap: CGFloat = 6
    /// The box every symbol is centred in, so they line up whatever their shapes.
    static let symbol: CGFloat = 16
    /// Between one tab and the next.
    static let spacing: CGFloat = 2
    /// The least of a name that a row too narrow for it still shows (the rest gives way to an ellipsis).
    static let leastName: CGFloat = 24
    /// The corner radius of a tab (and of the pill) and of the bar around them.
    static let radius: CGFloat = 8, barRadius: CGFloat = 11
}

/// What the pointer is told about a tab.
enum SettingsTabHelp {
    /// The name of a tab that does not write it, and what its dot says. The selected tab with no dot has nothing to add.
    static func tooltip(title: String, selected: Bool, note: String?) -> String {
        guard let note else { return selected ? "" : title }
        return title + " · " + note
    }
}

/// The card's tabs in a bar. The selected tab shows its symbol and its name on a mint pill; the others show their symbol alone. With every name written, five tabs
/// left no room between a tab's symbol and the name before it, and a sixth would have cut one; this way the bar is as calm with six tabs as with two. Each tab says
/// its name to the pointer (a tooltip) and to VoiceOver, and a dot on its symbol says a permission it needs is missing.
///
/// The row (`SettingsTabRow`) places every view of the bar itself: the pill, a transparent button over each tab, each tab's symbol and the selected tab's name. When the
/// selection moves, the pill slides and changes its width while the symbols glide to their places; the name of the tab that was selected fades out at once and the new
/// one fades in at its place once the pill is nearly there. Nothing jumps.
struct SettingsTabBar<Tab: SettingsTabItem>: View {
    var tabs: [Tab]
    @Binding var selection: Tab
    var attention: Set<Tab>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tab under the pointer.
    @State private var hovered: Tab.ID?

    var body: some View {
        SettingsTabRow(spacing: SettingsTabMetrics.spacing) {
            RoundedRectangle(cornerRadius: SettingsTabMetrics.radius, style: .continuous).fill(mint.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: SettingsTabMetrics.radius, style: .continuous).stroke(mint.opacity(0.55), lineWidth: 0.8))
                .opacity(tabs.contains(selection) ? 1 : 0)
                .accessibilityHidden(true).layoutValue(key: SettingsTabRoleKey.self, value: .pill)
            ForEach(tabs) { tab in hit(tab) }
            ForEach(tabs) { tab in symbol(tab) }
            // Only the selected tab has its name in the row. It is there, at the place where its tab ends up, once the pill has nearly arrived; the name that was shown fades out at once.
            ForEach(tabs) { tab in
                if selection == tab { name(tab) }
            }
        }
        .padding(SettingsTabMetrics.inset).background(Color.nookWash(0.06), in: RoundedRectangle(cornerRadius: SettingsTabMetrics.barRadius, style: .continuous))
        // Whatever is still on its way (a name fading out as its tab shrinks) is never drawn past the bar's edge.
        .clipShape(RoundedRectangle(cornerRadius: SettingsTabMetrics.barRadius, style: .continuous))
        // Only the bar moves with the selection; the pane below it changes at once, as it always has.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selection)
        .accessibilityElement(children: .contain).accessibilityLabel("Pestañas de los ajustes")
    }

    /// The button over a tab: what takes the click, what VoiceOver finds (the tab's name, whether it is selected, and what its dot says), and the tooltip.
    private func hit(_ tab: Tab) -> some View {
        let selected = selection == tab
        let note = attention.contains(tab) ? tab.attentionNote : nil
        return Button { selection = tab } label: {
            RoundedRectangle(cornerRadius: SettingsTabMetrics.radius, style: .continuous)
                .fill(Color.nookWash(hovered == tab.id && !selected ? 0.08 : 0)).contentShape(Rectangle())
        }.nookPress(.none, depth: PressDepth.flat)
            .onHover { inside in
                if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
            }
            .help(SettingsTabHelp.tooltip(title: tab.title, selected: selected, note: note))
            .accessibilityAddTraits(selected ? .isSelected : []).accessibilityLabel(tab.title)
            // The dot is a picture; what it says is the tab's value.
            .accessibilityValue(note ?? "")
            .layoutValue(key: SettingsTabRoleKey.self, value: .hit).layoutValue(key: SettingsTabSelectedKey.self, value: selected)
    }

    /// A tab's symbol, with the dot on its corner when a permission it needs is missing. It does not take clicks: the button under it does.
    private func symbol(_ tab: Tab) -> some View {
        let selected = selection == tab
        return Image(systemName: tab.symbol).font(.system(size: 13, weight: .medium)).frame(width: SettingsTabMetrics.symbol, height: SettingsTabMetrics.symbol)
            .overlay(alignment: .topTrailing) {
                // The dot that asks for a look sits on the symbol's corner, so it stays with the symbol whether or not the name is beside it.
                if attention.contains(tab) {
                    Circle().fill(PermissionPalette.amberFill).frame(width: 6, height: 6).offset(x: 3.5, y: -3)
                }
            }
            .foregroundStyle(selected ? Color.nookText : Color.primary.opacity(hovered == tab.id ? 0.98 : 0.76))
            // The tab that was chosen answers: its symbol pops.
            .clickMotion(.pop, whenBecomes: selected)
            .allowsHitTesting(false).accessibilityHidden(true).layoutValue(key: SettingsTabRoleKey.self, value: .symbol)
    }

    /// The selected tab's name. It fades in once the pill has nearly arrived (the bar's glide lasts 0.18 s), so on the way it never lies over a symbol that has not landed or
    /// outside the pill, and the name that was shown is gone at once.
    private func name(_ tab: Tab) -> some View {
        Text(tab.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).foregroundStyle(Color.nookText)
            .transition(reduceMotion ? .identity : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.06).delay(0.13)), removal: .opacity.animation(.easeOut(duration: 0.04))))
            .allowsHitTesting(false).accessibilityHidden(true).layoutValue(key: SettingsTabRoleKey.self, value: .name)
    }
}

/// What a view of the row is for.
private enum SettingsTabRole { case pill, hit, symbol, name }
private struct SettingsTabRoleKey: LayoutValueKey { static let defaultValue = SettingsTabRole.hit }
private struct SettingsTabSelectedKey: LayoutValueKey { static let defaultValue = false }

/// The bar's tabs in a row. Each tab is as wide as it needs (the selected one holds its symbol and its name, the others their symbol) plus an equal share of what is left,
/// so the pill has room around its name and the other tabs around their symbols; a row that is too narrow takes first from the name. The row fills the width it is offered.
/// It places the pill behind the selected tab and, for every tab, its button over the whole tab and its symbol; the selected tab's symbol and its name are centred as one.
struct SettingsTabRow: Layout {
    var spacing: CGFloat = SettingsTabMetrics.spacing

    /// The width of each tab in a row `available` wide, for tabs that need `natural` and can give up to `natural - floors` of it. A row with room left shares it equally. A row
    /// that is too narrow takes from the tabs that can give before the others are touched, and if even the floors do not fit, everything shrinks in proportion.
    static func widths(of natural: [CGFloat], floors: [CGFloat], in available: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        let room = max(available - spacing * CGFloat(natural.count - 1), 0)
        let need = natural.reduce(0, +), least = floors.reduce(0, +)
        if room >= need { return natural.map { $0 + (room - need) / CGFloat(natural.count) } }
        if room >= least, need > least {
            let give = (need - room) / (need - least)
            return zip(natural, floors).map { $0 - ($0 - $1) * give }
        }
        guard least > 0 else { return natural.map { _ in room / CGFloat(natural.count) } }
        return floors.map { $0 * room / least }
    }

    /// What `count` tabs need and the least they can be, when the one at `selected` (if any) has a name `name` wide.
    private static func needs(count: Int, selected: Int?, name: CGFloat) -> (natural: [CGFloat], floors: [CGFloat]) {
        let base = 2 * SettingsTabMetrics.padding + SettingsTabMetrics.symbol
        var natural = [CGFloat](repeating: base, count: count), floors = natural
        if let selected {
            natural[selected] = base + SettingsTabMetrics.gap + name
            floors[selected] = min(natural[selected], base + SettingsTabMetrics.gap + SettingsTabMetrics.leastName)
        }
        return (natural, floors)
    }

    private func views(_ subviews: Subviews, _ role: SettingsTabRole) -> [LayoutSubview] { subviews.filter { $0[SettingsTabRoleKey.self] == role } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let hits = views(subviews, .hit)
        let name = views(subviews, .name).first?.sizeThatFits(.unspecified).width ?? 0
        let needs = Self.needs(count: hits.count, selected: hits.firstIndex { $0[SettingsTabSelectedKey.self] }, name: name)
        let width = needs.natural.reduce(0, +) + spacing * CGFloat(max(hits.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: SettingsTabMetrics.chip)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let hits = views(subviews, .hit), symbols = views(subviews, .symbol)
        guard hits.count == symbols.count else { return }
        let selected = hits.firstIndex { $0[SettingsTabSelectedKey.self] }
        let name = views(subviews, .name).first
        let needs = Self.needs(count: hits.count, selected: selected, name: name?.sizeThatFits(.unspecified).width ?? 0)
        let widths = Self.widths(of: needs.natural, floors: needs.floors, in: bounds.width, spacing: spacing)
        let symbol = SettingsTabMetrics.symbol, gap = SettingsTabMetrics.gap
        var x = bounds.minX
        var pill = CGRect(x: bounds.minX, y: bounds.minY, width: 0, height: bounds.height)
        for index in hits.indices {
            let tab = CGRect(x: x, y: bounds.minY, width: widths[index], height: bounds.height)
            hits[index].place(at: tab.origin, anchor: .topLeading, proposal: ProposedViewSize(tab.size))
            if index == selected, let name {
                // The symbol and the name, centred as one in the tab. The name is as wide as the tab leaves it (an ellipsis when that is less than it needs).
                let shown = min(name.sizeThatFits(.unspecified).width, max(tab.width - 2 * SettingsTabMetrics.padding - symbol - gap, 0))
                let symbolX = tab.minX + (tab.width - (symbol + gap + shown)) / 2
                symbols[index].place(at: CGPoint(x: symbolX, y: tab.midY), anchor: .leading, proposal: ProposedViewSize(width: symbol, height: symbol))
                name.place(at: CGPoint(x: symbolX + symbol + gap, y: tab.midY), anchor: .leading, proposal: ProposedViewSize(width: shown, height: nil))
            } else {
                symbols[index].place(at: CGPoint(x: tab.midX, y: tab.midY), anchor: .center, proposal: ProposedViewSize(width: symbol, height: symbol))
            }
            if index == selected { pill = tab }
            x += widths[index] + spacing
        }
        for view in views(subviews, .pill) { view.place(at: pill.origin, anchor: .topLeading, proposal: ProposedViewSize(pill.size)) }
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(Color.nookSecondary)
    }
}

/// «Ver la bienvenida otra vez»: a chip with the cat's hand, which waves when it is pressed.
private struct WelcomeChip: View {
    var action: () -> Void
    @State private var hovering = false
    @State private var clicks = 0

    var body: some View {
        Button {
            clicks += 1
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "hand.wave").font(.system(size: 10.5, weight: .medium)).clickMotion(.wiggle, trigger: clicks)
                Text("Ver la bienvenida otra vez").font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 9).frame(height: 26)
            .background(Color.nookWash(hovering ? 0.13 : 0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.card))
        .onHover { hovering = $0 }
        .accessibilityLabel("Ver la bienvenida otra vez")
    }
}

/// One of the size presets: a small chip, mint when it is the island's current size.
private struct PresetChip: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 26)
                .foregroundStyle(selected ? Color.nookText : Color.primary.opacity(0.78))
                .background(selected ? mint.opacity(0.22) : Color.nookWash(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(mint.opacity(selected ? 0.55 : 0), lineWidth: 0.8))
                .contentShape(Rectangle())
        // A text chip gives a little squeeze, as the island's other text chips do (gentle: it stands a few points from the next one).
        }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.35).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel("Tamaño \(title)")
    }
}

/// A labelled slider with its value on the right, and the small and large "A" at its ends for the text sizes.
private struct SettingSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    /// nil: continuous. A step draws a tick for each value, which suits the few text sizes and not the island's points.
    var step: Double?
    var display: String
    var small: CGFloat?
    var large: CGFloat?

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double? = nil, display: String, small: CGFloat? = nil, large: CGFloat? = nil) {
        self.title = title; _value = value; self.range = range; self.step = step; self.display = display; self.small = small; self.large = large
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.85)).frame(width: 96, alignment: .leading).lineLimit(1)
            // The slots at the track's ends are kept on every row so all the tracks line up.
            Group { if let small { Text("A").font(.system(size: small, weight: .medium)).foregroundStyle(Color.nookSecondary) } else { Color.clear } }.frame(width: 10)
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }.controlSize(.small).tint(mint)
            Group { if let large { Text("A").font(.system(size: large, weight: .medium)).foregroundStyle(Color.nookSecondary) } else { Color.clear } }.frame(width: 12)
            Text(display).font(.system(size: 10.5, design: .monospaced)).monospacedDigit().foregroundStyle(Color.nookSecondary)
                .frame(width: 46, alignment: .trailing)
        }.frame(height: 22)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title).accessibilityValue(display)
    }
}

/// How many lines the message field grows to before it scrolls.
private struct LinesRow: View {
    @Binding var lines: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("Líneas del campo").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                step("minus", enabled: lines > DisplaySettings.linesRange.lowerBound, label: "Menos líneas") { lines -= 1 }
                Text("\(lines)").font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 26)
                step("plus", enabled: lines < DisplaySettings.linesRange.upperBound, label: "Más líneas") { lines += 1 }
            }.background(Color.nookWash(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("antes de desplazar").font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1)
        }.frame(height: 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Líneas del campo antes de desplazar").accessibilityValue("\(lines)")
    }

    private func step(_ symbol: String, enabled: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }.nookPress(symbol: symbol).foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color.nookSecondary.opacity(0.4)).disabled(!enabled)
            .accessibilityLabel(label)
    }
}

// MARK: - The window under the island

/// Where the card goes: centred on the island's axis (the notch), a little under its bottom edge. Centred, because the island
/// grows and shrinks around that axis while a slider moves: the card never shifts sideways under the pointer. When the
/// island leaves no room below it on the screen, the card sits over the island's lower part instead.
enum SettingsPlacement {
    static let gap: CGFloat = 10
    /// Kept between the card and the screen's edges.
    static let margin: CGFloat = 12

    /// `island` and `screen` are in screen coordinates (origin at the bottom left); `card` is the card's own size.
    static func frame(island: CGRect, screen: CGRect, card: CGSize) -> CGRect {
        var x = island.midX - card.width / 2
        x = min(max(x, screen.minX + margin), screen.maxX - margin - card.width)
        var y = island.minY - gap - card.height
        if y < screen.minY + margin { y = screen.minY + margin }
        return CGRect(x: x, y: y, width: card.width, height: card.height)
    }
}

/// The settings card's window: a panel of the island's kind (it can take clicks and keys without activating Nook) that
/// follows the open island, and its card as it grows and shrinks (another tab, a guide opening).
final class SettingsWindow: NSObject {
    let panel: NotchPanel
    private let hosting: NSHostingView<AnyView>
    /// Room around the card for its shadow, inside the window.
    private static let shadowRoom: CGFloat = 22
    private(set) var cardSize = CGSize(width: SettingsCard.width, height: 320)
    /// Where the card was last placed, so a change of height keeps its top edge where it was.
    private var placement: (island: CGRect, screen: CGRect)?
    private var shrinkWork: DispatchWorkItem?

    /// `permissions` is for tests, which pass one that reads and asks nothing.
    init(model: AppModel, screen: CGSize, topInset: CGFloat, level: NSWindow.Level, permissions: PermissionsModel? = nil, onClose: @escaping () -> Void) {
        let room = Self.shadowRoom
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.capturePrivacy = model.capturePrivacy
        let card = SettingsCard(model: model, screen: screen, topInset: topInset, permissions: permissions, onClose: onClose,
                                onContentChange: { [weak self] in self?.contentChanged() })
        // Top-aligned: while the window is a frame behind the card's height, the card stays put instead of drifting.
        hosting.rootView = AnyView(card.padding(room).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).onExitCommand(perform: onClose))
        // The hosting view reports the card's size (`remeasure`) but never sizes the window: the window follows it by itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        let fitting = hosting.fittingSize
        cardSize = CGSize(width: SettingsCard.width, height: max(fitting.height - 2 * room, 200))
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = level
        panel.animationBehavior = .none
        panel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: CGSize(width: cardSize.width + 2 * room, height: cardSize.height + 2 * room))
    }

    /// The card's frame on the screen (without the shadow's room).
    var cardFrame: CGRect { panel.frame.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom) }
    var isVisible: Bool { panel.isVisible }

    /// Puts the card where `SettingsPlacement` says for this island.
    func place(under island: CGRect, on screen: CGRect) {
        placement = (island, screen)
        let card = SettingsPlacement.frame(island: island, screen: screen, card: cardSize)
        let frame = card.insetBy(dx: -Self.shadowRoom, dy: -Self.shadowRoom)
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    /// Something that decides the card's height changed (see `SettingsCard.Layout`). The change arrives while SwiftUI is updating,
    /// so the card is measured on the next turn, when it has the new content.
    private func contentChanged() {
        DispatchQueue.main.async { [weak self] in self?.remeasure() }
    }

    /// Measures the card and follows its height. The window grows at once, so the card is never clipped; it shrinks once the
    /// content's own animation is over, for the same reason. Either way the card's top edge stays under the island.
    func remeasure() {
        let height = max(hosting.fittingSize.height - 2 * Self.shadowRoom, 200)
        guard abs(height - cardSize.height) > 0.5 else { return }
        shrinkWork?.cancel(); shrinkWork = nil
        if height > cardSize.height || !panel.isVisible {
            resize(to: height)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.resize(to: height) }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    private func resize(to height: CGFloat) {
        cardSize.height = height
        if let placement { place(under: placement.island, on: placement.screen) }
    }

    func show(animated: Bool) {
        guard !panel.isVisible else { return }
        remeasure()
        panel.alphaValue = animated ? 0 : 1
        panel.orderFrontRegardless()
        guard animated else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        panel.orderOut(nil)
        panel.alphaValue = 1
    }
}
