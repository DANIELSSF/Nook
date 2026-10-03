import SwiftUI
import AppKit

// Nook's settings, as a small card in its own look, with two tabs: the island's display settings, and the permissions Nook
// needs from macOS (`PermissionsPane`). It lives in a window of its own that hangs under the open island (`SettingsWindow`),
// centred on the notch, so the island stays fully visible while a slider moves: the text changes size, the island grows or
// shrinks, and the card (whose position does not depend on the island's width) never moves sideways under the pointer. The
// window follows the card's height as the tab changes and a guide opens.

private let mint = Color(red: 0.32, green: 0.73, blue: 0.61)

/// The card's two tabs: the island's looks, and what Nook needs from macOS.
enum SettingsTab: String, CaseIterable, Identifiable {
    case island, permissions
    var id: String { rawValue }
    var title: String { self == .island ? "Isla" : "Permisos" }
    var symbol: String { self == .island ? "slider.horizontal.3" : "lock.shield" }
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

    /// The card's own width; its height follows its content.
    static let width: CGFloat = 352

    /// `permissions` is for previews and tests, which pass one that reads and asks nothing; the app's card uses the model's own.
    init(model: AppModel, screen: CGSize, topInset: CGFloat, permissions: PermissionsModel? = nil, onClose: @escaping () -> Void = {}, onContentChange: @escaping () -> Void = {}) {
        self.model = model; self.screen = screen; self.topInset = topInset; self.onClose = onClose; self.onContentChange = onContentChange
        self.permissions = permissions ?? model.permissions
    }

    private var settings: DisplaySettings { model.display }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SettingsTabBar(selection: Binding(get: { model.settingsTab }, set: { model.settingsTab = $0 }), attention: permissions.needsAttention)
                .padding(.horizontal, 16).padding(.bottom, 12)
            switch model.settingsTab {
            case .island:
                VStack(alignment: .leading, spacing: 15) {
                    sizeSection
                    textSection
                    footer
                }.padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 15)
            case .permissions:
                PermissionsPane(model: model, permissions: permissions, maxHeight: maxCardHeight - Self.chromeHeight)
            }
        }
        .frame(width: Self.width)
        .nookGlassCard(radius: 18, dim: 0.96, dimColor: Color(white: 0.1), fill: Color(white: 0.105), stroke: Color.white.opacity(0.1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ajustes de Nook")
        // Whatever changes the card's height tells its window, which measures it (see `SettingsWindow.remeasure`).
        .onChange(of: layout) { _, _ in onContentChange() }
        // The permissions are read when the card opens (whatever its tab, for the dot on "Permisos"), when that tab comes up, and
        // while it is open whenever the user may have changed one in System Settings (see `PermissionsModel`).
        .onAppear { permissions.setActive(model.settingsOpen) }
        .onChange(of: model.settingsOpen) { _, open in permissions.setActive(open) }
        .onChange(of: model.settingsTab) { _, tab in if tab == .permissions, model.settingsOpen { permissions.refresh() } }
    }

    /// Everything the card's height depends on.
    private struct Layout: Equatable {
        var tab: SettingsTab
        var guides: Set<String>
        var states: [NookPermission: NookPermission.State]
        var folders: [ClaudeFolder]?
        var signals: Bool
        /// How tall the permissions' list may be; only that tab cares, so a slider on the other one costs nothing.
        var cap: CGFloat
    }
    private var layout: Layout {
        Layout(tab: model.settingsTab, guides: permissions.openGuides, states: permissions.states, folders: permissions.claudeFolders,
               signals: model.claudeSignalsEnabled, cap: model.settingsTab == .permissions ? maxCardHeight : 0)
    }

    /// The height of the header and the tabs, which the permissions' list has to leave room for.
    static let chromeHeight: CGFloat = 40 + 32 + 12
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
                Button { model.display = DisplaySettings() } label: {
                    Label("Restablecer", systemImage: "arrow.counterclockwise").font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.white.opacity(settings.isDefault ? 0.04 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(settings.isDefault ? Color.secondary.opacity(0.6) : Color.primary.opacity(0.85))
                    .disabled(settings.isDefault).help("Volver a la isla y los textos de siempre")
            case .permissions:
                Button { permissions.refresh() } label: {
                    Label("Comprobar", systemImage: "arrow.clockwise").font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.85)).help("Volver a comprobar los permisos")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Cerrar los ajustes").accessibilityLabel("Cerrar los ajustes")
        }.padding(.leading, 16).padding(.trailing, 10).frame(height: 40)
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

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Con la isla abierta: ⌘+ y ⌘− cambian el texto del chat, ⌘0 lo restablece. También puedes arrastrar una esquina inferior de la isla.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pieces

/// "Isla | Permisos": the card's two tabs, as chips like the size presets. A dot on "Permisos" says the needed permission is missing.
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    var attention: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = selection == tab
                Button { selection = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 10.5, weight: .medium))
                        Text(tab.title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        if tab == .permissions && attention {
                            Circle().fill(PermissionPalette.amber).frame(width: 6, height: 6).accessibilityLabel("Falta un permiso necesario")
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.7))
                    .background(selected ? mint.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(mint.opacity(selected ? 0.55 : 0), lineWidth: 0.8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : []).accessibilityLabel(tab.title)
            }
        }.padding(3).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
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
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.78))
                .background(selected ? mint.opacity(0.22) : Color.white.opacity(hovering ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(mint.opacity(selected ? 0.55 : 0), lineWidth: 0.8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
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
            Group { if let small { Text("A").font(.system(size: small, weight: .medium)).foregroundStyle(.secondary) } else { Color.clear } }.frame(width: 10)
            Group {
                if let step { Slider(value: $value, in: range, step: step) } else { Slider(value: $value, in: range) }
            }.controlSize(.small).tint(mint)
            Group { if let large { Text("A").font(.system(size: large, weight: .medium)).foregroundStyle(.secondary) } else { Color.clear } }.frame(width: 12)
            Text(display).font(.system(size: 10.5, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
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
            }.background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("antes de desplazar").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(height: 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Líneas del campo antes de desplazar").accessibilityValue("\(lines)")
    }

    private func step(_ symbol: String, enabled: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(enabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.4)).disabled(!enabled)
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
