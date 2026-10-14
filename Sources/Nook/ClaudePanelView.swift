import SwiftUI
import AppKit

// What the island shows while Claude has a panel open in its terminal (/usage, /status, /config, /mcp, a skills list…): the
// panel itself, live, in the place of the conversation and the message field, with the keys that move through it.
//
//   ClaudePanelCard   the card: a toolbar (its name, the keys and "Cerrar · esc") over the panel's text
//   PanelRows         the panel's rows drawn in the chat's monospaced font (columns kept), bars as bars, tabs as tabs
//   PanelKeyCatcher   the keyboard: ← → ↑ ↓ ⇥ ↵ and Esc typed in Nook travel to Claude, Esc included (it closes the panel)
//
// The terminal still owns the panel: every key is pressed there (see `AppModel.press`), and what the card shows is whatever
// the next reading of the screen says, so the card never claims a tab or a row the screen did not.
//
// The same card is also Nook's own usage card (`init(nookUsage:…)`, the usage button's, `AppModel.openUsage`): the usage dashboard made of what Claude's status line and
// its usage reading give, with no panel of Claude's behind it. It is the card's frame and its content with a toolbar of its own: no keys (there is no panel to move through),
// «Cerrar · esc» and the Esc key close it in Nook alone, and «Detalle en Claude» asks Claude for its full /usage (`AppModel.openClaudeUsage`). Nothing it does presses a key in the terminal.

/// What the usage bars are drawn in (they are graphics, not text): mint while there is room, amber and then coral as it fills.
private let panelMint = Color.nookMintFill
private let panelAmber = Color.nookAmberFill
private let panelCoral = Color.nookCoralFill

struct ClaudePanelCard: View {
    var text: String
    /// The user's chat text size; the panel's own text may be a little smaller to keep a wide line in one piece.
    var fontSize: Double = DisplaySettings.defaultChatSize
    /// The tab's terminal is alive: the keys have somewhere to go.
    var running = true
    /// The keys need the Accessibility permission and it is not granted yet (a Terminal tab).
    var needsAccessibility = false
    /// Whenever this changes the card takes the keyboard.
    var focusRequest = 0
    /// Nook is scrolling Claude's panel to read the rest of it (`TerminalSession.readingPanel`): the usage card says so, quietly.
    var reading = false
    var onKey: (TerminalKey) -> Void = { _ in }
    /// "más", the button where Nook holds only part of Claude's panel: Claude's panel scrolls about a screen, down or up (`AppModel.scrollPanel`). Without it the card
    /// presses the arrow once, as it did.
    var onScroll: ((_ down: Bool) -> Void)?
    /// The island makes itself as tall as the usage card asks (`IslandRoomKeeper`): the card is then drawn as it is for room to spare, whatever the island is just now, so that
    /// what it asks does not depend on the height it has been given (a dense card asks for less, and the island would grow twice).
    var growsIsland = false
    /// What Claude's status line gave Nook for this tab (`NookStatusLine.swift`): the usage card fills what the panel's screen lacks with it, and marks it "en vivo".
    var live: ClaudeLiveUsage?

    private let panel: ClaudePanel
    /// The panel as a dashboard, when it is Claude's usage panel (see `UsageContent`); nil for any other. For Nook's own card, what its figures make (`ClaudeUsage.nookCard`).
    private let usage: ClaudeUsage?
    /// What only Nook's own usage card has (`init(nookUsage:…)`); nil for Claude's panel.
    private let own: Own?

    /// Nook's own usage card's toolbar: the two things it does, and neither reaches the terminal as a key.
    struct Own {
        /// «Cerrar · esc», and the Esc key: the card goes, in Nook alone.
        var onClose: () -> Void
        /// «Detalle en Claude»: Claude's own /usage in its terminal, for what Nook's card does not have (the tokens by model, what feeds the limits).
        var onOpenClaude: () -> Void
        /// That /usage is on its way: the button says so and waits, and the card stays until the panel arrives.
        var opening: Bool

        /// What the pointer resting on «Detalle en Claude» is told: what it opens and what it leaves fresh; with the terminal closed, why it cannot.
        static func openTip(running: Bool) -> NookTip {
            NookTip("Detalle en Claude", detail: UsageFigures.unbroken(running
                ? "Abre /usage en la terminal de Claude, con el detalle completo: los tokens por modelo y qué consume tus límites. También actualiza la lectura de los límites por modelo."
                : "La terminal está cerrada."))
        }

        /// What it says over «Cerrar · esc».
        static let closeTip = NookTip("Cerrar", detail: "Esc también lo cierra")
    }
    /// The key just pressed, from the keyboard or a button: it stays lit for a moment so the press is seen to land.
    @State private var flashed: TerminalKey?
    @State private var copied = false
    @State private var scroll = ScrollMetrics()

    static let toolbarHeight: CGFloat = 34

    /// The height the card has in an island this tall: the pane (under the neck and the tab row) less the margins the pane keeps around the card. And the other way
    /// round: how tall an island has to be for a card of this height, which is what the card's ask (`IslandRoom`) is turned into when the island is to grow.
    static func height(inIsland island: CGFloat, neck: CGFloat) -> CGFloat { island - neck - PaneLayout.tabRowHeight - topMargin - ComposerMetrics.bottomInset }
    static func island(forCard card: CGFloat, neck: CGFloat) -> CGFloat { card + neck + PaneLayout.tabRowHeight + topMargin + ComposerMetrics.bottomInset }
    /// The air between the tab row and the card (`SessionPane.panelCard`).
    static let topMargin: CGFloat = 2
    /// The air between the island's sides and the card (`SessionPane.panelCard`), and the card's width in an island this wide.
    static let paneEdge: CGFloat = 15
    static func width(inIsland island: CGFloat) -> CGFloat { island - 2 * paneEdge }
    static let radius: CGFloat = 16
    /// Between the card's edge and its text.
    static let inset: CGFloat = 13
    private static let viewport = "claudePanel"
    private static let surface = Color.nookPanel

    init(text: String, fontSize: Double = DisplaySettings.defaultChatSize, running: Bool = true, needsAccessibility: Bool = false, focusRequest: Int = 0,
         reading: Bool = false, growsIsland: Bool = false, live: ClaudeLiveUsage? = nil, now: Date = Date(), onKey: @escaping (TerminalKey) -> Void = { _ in },
         onScroll: ((_ down: Bool) -> Void)? = nil) {
        self.text = text
        self.fontSize = fontSize
        self.running = running
        self.needsAccessibility = needsAccessibility
        self.focusRequest = focusRequest
        self.reading = reading
        self.growsIsland = growsIsland
        self.live = live
        self.onKey = onKey
        self.onScroll = onScroll
        panel = ClaudePanel(text)
        // What the status line gave and still describes the present fills what the panel's screen lacks.
        usage = ClaudeUsage(panel).map { $0.filled(from: live?.upToDate(at: now), now: now) }
        own = nil
    }

    /// Nook's own usage card: the figures Claude's status line and its usage reading give for this tab (`ClaudeUsage.nookCard`, as of `now`), with no panel behind them. `running` is the
    /// tab's terminal being alive: «Detalle en Claude» has somewhere to go (Esc and «Cerrar» never need it). With nothing to show it draws an empty card; the island shows none then.
    init(nookUsage live: ClaudeLiveUsage?, fontSize: Double = DisplaySettings.defaultChatSize, running: Bool = true, focusRequest: Int = 0, growsIsland: Bool = false,
         opening: Bool = false, now: Date = Date(), onClose: @escaping () -> Void = {}, onOpenClaude: @escaping () -> Void = {}) {
        text = ""
        self.fontSize = fontSize
        self.running = running
        self.focusRequest = focusRequest
        self.growsIsland = growsIsland
        self.live = live
        panel = ClaudePanel("")
        usage = ClaudeUsage.nookCard(from: live, now: now)
        own = Own(onClose: onClose, onOpenClaude: onOpenClaude, opening: opening)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 0) {
            toolbar
            content
        }
        .background(Self.surface, in: shape)
        .overlay(shape.stroke(Color.nookWash(0.08, light: 0.12), lineWidth: 0.5))
        .clipShape(shape)
        .background { PanelKeyCatcher(focusRequest: focusRequest, onKey: press) }
        // How tall the card would be with all of its content showing, for the island to give it that room. Only the usage card asks: any other panel is plain text that scrolls.
        .preference(key: IslandRoomKey.self, value: usage != nil && growsIsland && scroll.height > 0 ? IslandRoom(height: Self.toolbarHeight + scroll.height, width: scroll.width) : nil)
        // Nook's own card has no panel's text to copy.
        .contextMenu { if own == nil { Button("Copiar el texto del panel") { copy() } } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(own == nil ? "Panel de Claude" : "Uso y límites")
        .task(id: flashed) {
            guard flashed != nil else { return }
            try? await Task.sleep(for: .seconds(0.18))
            if !Task.isCancelled { flashed = nil }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }

    private func press(_ key: TerminalKey) {
        // Nook's own card has no panel behind it, so no key of a panel's is its own: Esc closes the card, here, and the rest does nothing. Nothing reaches the terminal.
        if let own {
            guard key == .escape else { return }
            flashed = key
            own.onClose()
            return
        }
        guard running else { return }
        flashed = key
        onKey(key)
    }

    /// A press of «más»: the arrow lights as a press of it does, and the panel scrolls about a screen when the owner can do that (one arrow press when it cannot).
    private func more(down: Bool) {
        guard running else { return }
        guard let onScroll else { press(down ? .down : .up); return }
        flashed = down ? .down : .up
        onScroll(down)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    // MARK: Toolbar

    /// Its name, the keys that move through the panel and the way out, in one row: the panel gets all the height that is left.
    /// When the island is too narrow for all of it, the panel's own name goes first. Nook's own card has no keys: its name, «Detalle en Claude» and the way out,
    /// and the action's words go first.
    private var toolbar: some View {
        Group {
            if let own {
                ViewThatFits(in: .horizontal) {
                    ownToolbarRow(own, labelled: true)
                    ownToolbarRow(own, labelled: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    toolbarRow(named: true)
                    toolbarRow(named: false)
                }
            }
        }.padding(.horizontal, 10).frame(height: Self.toolbarHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.nookWash(0.07)).frame(height: 0.5) }
    }

    /// Nook's own card's toolbar: what it is, the way to Claude's full panel, and the way out.
    private func ownToolbarRow(_ own: Own, labelled: Bool) -> some View {
        HStack(spacing: 8) {
            Text("✻").font(.system(size: 14, weight: .bold)).foregroundStyle(claudeSpinner).frame(width: 14)
            Text("Uso y límites").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            openClaudeButton(own, labelled: labelled)
            ownCloseButton
        }
    }

    /// «Detalle en Claude»: a quiet action beside «Cerrar», for what Nook's card does not have. It asks Claude for its own /usage, which also leaves Claude a fresh reading of the
    /// limits by model. Once asked, and until Claude's panel arrives, it is not a button any more but what is happening, so that it reads as work under way and not as something
    /// that is not available.
    @ViewBuilder private func openClaudeButton(_ own: Own, labelled: Bool) -> some View {
        if own.opening {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 12, height: 12)
                if labelled { Text("Abriendo…").font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize() }
            }.foregroundStyle(UsageMetrics.secondary).padding(.horizontal, 7).frame(height: 24)
                .accessibilityElement(children: .ignore).accessibilityLabel("Abriendo el detalle en Claude")
        } else {
            Button(action: own.onOpenClaude) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 10.5, weight: .medium)).nookIconMotion(.nudgeUpRight, strength: 0.6)
                    if labelled { Text("Detalle en Claude").font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize() }
                }.foregroundStyle(UsageMetrics.secondary).padding(.horizontal, 7).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(PanelButtonStyle(radius: 8)).disabled(!running)
                .nookTip(Own.openTip(running: running), id: "usage-open-claude")
                .accessibilityLabel("Ver el detalle en Claude").accessibilityHint("Abre /usage en la terminal de Claude, con el detalle completo y la lectura al día de los límites por modelo")
        }
    }

    private func toolbarRow(named: Bool) -> some View {
        HStack(spacing: 8) {
            Text("✻").font(.system(size: 14, weight: .bold)).foregroundStyle(claudeSpinner).frame(width: 14)
            HStack(spacing: 6) {
                Text("Panel de Claude").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if copied {
                    Text("·").font(.system(size: 12)).foregroundStyle(Color.nookSecondary)
                    Text("Copiado al portapapeles").font(.system(size: 12)).foregroundStyle(Color.nookMint).lineLimit(1)
                } else if named, let name = usage == nil ? panel.name : "Uso" {
                    // The usage card says what it is in Spanish; any other panel carries Claude's own names for itself.
                    Text("·").font(.system(size: 12)).foregroundStyle(Color.nookSecondary)
                    Text(name).font(.system(size: 12)).foregroundStyle(Color.nookSecondary).lineLimit(1)
                }
            }.fixedSize().help("Claude muestra este panel en su terminal, y aquí lo ves en vivo. Se cierra con Esc.")
            Spacer(minLength: 8)
            keyStrip
            closeButton
        }
    }

    private var keyStrip: some View {
        HStack(spacing: 0) {
            keyButton(.left); keyButton(.right)
            divider
            keyButton(.up); keyButton(.down)
            divider
            keyButton(.tab); keyButton(.enter)
        }.background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 12).padding(.horizontal, 3)
    }

    private func keyButton(_ key: TerminalKey) -> some View {
        Button { press(key) } label: {
            Image(systemName: key.symbol).font(.system(size: 11, weight: .semibold)).nookIconMotion(ClickMotion.forSymbol(key.symbol), strength: 0.6)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(PanelButtonStyle(lit: flashed == key, radius: 7)).foregroundStyle(Color.primary.opacity(0.8)).disabled(!running)
            .help(Self.help(for: key, needsAccessibility: needsAccessibility)).accessibilityLabel(key.label)
    }

    private var closeButton: some View {
        Button { press(.escape) } label: { closeLabel }
            .buttonStyle(PanelButtonStyle(lit: flashed == .escape, rest: 0.1, radius: 8)).disabled(!running)
            .help(Self.help(for: .escape, needsAccessibility: needsAccessibility)).accessibilityLabel("Cerrar el panel")
    }

    private var closeLabel: some View {
        HStack(spacing: 6) {
            Text("Cerrar").font(.system(size: 10.5, weight: .medium))
            PanelKeycap(text: "esc")
        }.foregroundStyle(Color.primary.opacity(0.9)).padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
    }

    /// «Cerrar · esc» on Nook's own card: the card goes in Nook alone, so it needs no terminal to be alive (it is never disabled), and Esc says it too.
    private var ownCloseButton: some View {
        Button { press(.escape) } label: { closeLabel }
            .buttonStyle(PanelButtonStyle(lit: flashed == .escape, rest: 0.1, radius: 8))
            .nookTip(Own.closeTip, id: "usage-card-close")
            .accessibilityLabel("Cerrar uso y límites")
    }

    /// What a key does in Claude's panels, and what it needs.
    static func help(for key: TerminalKey, needsAccessibility: Bool) -> String {
        let action: String
        switch key {
        case .left: action = "pestaña anterior"
        case .right: action = "pestaña siguiente"
        case .up: action = "subir"
        case .down: action = "bajar"
        case .tab: action = "siguiente pestaña"
        case .enter: action = "elegir"
        case .escape: action = "cerrar el panel de Claude"
        case .pasteImage: action = "pegar imagen"
        case .backtab: action = "cambiar de modo"
        case .keyS: action = "usar solo en esta sesión"
        }
        // ⌃V is the exception: a Terminal tab never gets it (the image travels as a file), so it needs no permission.
        return "\(key.label) · \(action)" + (needsAccessibility && key.needsDirectKeys && key != .pasteImage ? " (requiere Accesibilidad)" : "")
    }

    // MARK: Content

    private var content: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 2 * Self.inset)
            let size = ClaudePanelMetrics.fontSize(columns: panel.columns, width: width, chatSize: fontSize)
            // The usual island leaves the usage card little height: what matters most is made to fit it. An island that grows for the card is never short of room.
            let dense = !growsIsland && geometry.size.height < UsageMetrics.denseBelow
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Group {
                        if let usage {
                            UsageContent(usage: usage, panel: own == nil ? panel : nil, chatSize: fontSize, dense: dense, reading: reading, onMore: { more(down: $0) }, enabled: running)
                        } else if own != nil {
                            // Nook's own card with no figure left to show: the island puts it away then, this is only the moment in between.
                            Text("Sin datos de uso por ahora").font(.system(size: 11)).foregroundStyle(UsageMetrics.secondary)
                        } else {
                            PanelRows(panel: panel, size: size, onMore: { more(down: $0) }, enabled: running)
                        }
                    }
                        .padding(.horizontal, Self.inset).padding(.top, usage != nil && dense ? 5 : 7)
                        .padding(.bottom, usage != nil && dense ? 6 : 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // How far the text has scrolled and how tall it is, read from where it stands in the scroll view (a preference of its own, set from inside the
                        // scroll view, was never delivered with a height: the fade below and the height the card asks of the island depend on this).
                        .onGeometryChange(for: ScrollMetrics.self) { proxy in
                            ScrollMetrics(offset: -proxy.frame(in: .named(Self.viewport)).minY, height: proxy.size.height, width: proxy.size.width)
                        } action: { metrics in
                            if metrics.height > 0, metrics != scroll { scroll = metrics }
                        }
                }
                .coordinateSpace(name: Self.viewport)
                // The row the cursor is on stays in view as the arrows move it; a new panel (another tab) starts at its top.
                .onChange(of: panel.cursorIndex) { _, index in
                    if let index { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index) } }
                }
                .onChange(of: panel.name) { _, _ in proxy.scrollTo(PanelRows.top, anchor: .top) }
                .onAppear { if let index = panel.cursorIndex { proxy.scrollTo(index) } }
                // More below: the last visible row fades out instead of ending in a cut.
                .nookScrollFade(active: scroll.height - scroll.offset - geometry.size.height > 2, height: 22, surface: Self.surface)
            }
        }
    }
}

// MARK: - Nook's own card, kept honest

/// What the pane does around Nook's own usage card (the usage button's) while it is asked for:
///
///   - Claude's own panel takes the card's place when one opens (typed in the terminal, or asked for with «Detalle en Claude»): Nook's card is closed, its figures are in that panel;
///   - putting the island away closes it: a glance at the limits does not wait there for the next time the island opens, to stand in the way of the conversation and the field;
///   - Claude leaving the tab (it quit) or having no figure left to show (every limit it had has reset, the reading is gone) closes it too, rather than leave a card that would come back
///     by itself when Claude or new figures return;
///   - the /usage asked of Claude from the card (`handoff`) holds the card up until Claude's panel arrives, and lets go after `handoffHold` if it never does.
struct UsageCardLifecycle: ViewModifier {
    /// Claude has a panel open in its terminal.
    var claudePanelOpen: Bool
    /// The island is on show.
    var islandVisible: Bool
    /// The card is asked for, and cannot be on show for good: Claude is not the tab's agent any more, or there is no figure to put in it.
    var unavailable: Bool
    @Binding var handoff: Bool
    /// Closes the card, in Nook alone (`AppModel.closeUsageCard`).
    var close: () -> Void

    /// How long the card waits for Claude's panel after «Detalle en Claude»: the terminal gets its /usage and Nook reads the screen again.
    static var handoffHold = 4.0

    func body(content: Content) -> some View {
        content
            .onChange(of: claudePanelOpen, initial: true) { _, open in if open { close() } }
            .onChange(of: islandVisible) { _, visible in if !visible { close() } }
            .onChange(of: unavailable, initial: true) { _, gone in if gone { close() } }
            .task(id: handoff) {
                guard handoff else { return }
                try? await Task.sleep(for: .seconds(Self.handoffHold))
                if !Task.isCancelled { handoff = false }
            }
    }
}

// MARK: - Rows

/// The panel's rows in the chat's monospaced font. Rows keep their columns (a row's indent is its columns in spaces), long
/// lines wrap under their own indent (a value under itself, not under its label), and the rows Claude draws as a graphic
/// (rules, bars, tabs) are drawn as one.
struct PanelRows: View {
    let panel: ClaudePanel
    /// Claude's own "↓" (or "↑"): more of the panel beyond its screen. The row it leaves is a button that sends the key.
    let onMore: (_ down: Bool) -> Void
    let enabled: Bool
    /// The row the cursor is on is where the user is: it wears the tab's color. The bars keep mint (they say how full, not who).
    @Environment(\.tabTint) private var tint

    static let top = "top"
    private static let primary = Color.nookWash(0.88)
    private static let quiet = Color.nookSecondary

    private let size: Double
    private let font: Font
    private let column: CGFloat
    private let lineHeight: CGFloat
    private let barTrailingColumns: Int

    init(panel: ClaudePanel, size: Double, onMore: @escaping (Bool) -> Void = { _ in }, enabled: Bool = true) {
        self.panel = panel
        self.size = size
        self.onMore = onMore
        self.enabled = enabled
        font = .system(size: size, design: .monospaced)
        column = ClaudePanelMetrics.columnWidth(size: size)
        lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)))
        // The "25% used" beside each bar takes the same room, so the bars end in one column.
        barTrailingColumns = panel.rows.reduce(0) { widest, row in if case .bar(_, _, _, let trailing) = row { max(widest, trailing.count) } else { widest } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).id(Self.top)
            if panel.moreAbove { moreRow(down: false) }
            ForEach(Array(panel.rows.enumerated()), id: \.offset) { index, row in
                view(of: row).id(index)
            }
            if panel.moreBelow { moreRow(down: true) }
        }
    }

    private func moreRow(down: Bool) -> some View {
        Button { onMore(down) } label: {
            HStack(spacing: 3) {
                Image(systemName: down ? "arrow.down" : "arrow.up").font(.system(size: 8.5, weight: .bold)).nookIconMotion(down ? .nudgeDown : .nudgeUp, strength: 0.6)
                Text("más").font(.system(size: 10, weight: .medium))
            }.foregroundStyle(Color.primary.opacity(0.85)).padding(.horizontal, 8).frame(height: 20).contentShape(Capsule())
        }.buttonStyle(PanelButtonStyle(rest: 0.1, radius: 10)).disabled(!enabled)
            .frame(maxWidth: .infinity, alignment: .trailing).padding(.vertical, 3)
            .help(down ? "Claude tiene más contenido debajo; ↓ lo baja" : "Claude tiene más contenido arriba; ↑ lo sube")
            .accessibilityLabel(down ? "Más contenido debajo" : "Más contenido arriba")
    }

    @ViewBuilder private func view(of row: ClaudePanel.Row) -> some View {
        switch row {
        case .blank:
            Color.clear.frame(height: lineHeight * 0.5)
        case .rule:
            Rectangle().fill(Color.nookWash(0.1)).frame(height: 0.5).padding(.vertical, lineHeight * 0.3)
        case .tabs(let title, let names, let active):
            PanelTabs(title: title, names: names, active: active).padding(.top, 2).padding(.bottom, 3)
        case .heading(let indent, let text):
            indented(indent) { Text(text).font(font.weight(.bold)).foregroundStyle(Color.nookText) }
        case .text(let indent, let label, let body):
            indented(indent) {
                if label.isEmpty {
                    Text(body).font(font).foregroundStyle(Self.primary)
                } else {
                    // The value wraps under itself, not under the label.
                    HStack(alignment: .top, spacing: 0) {
                        Text(label).font(font).foregroundStyle(Self.quiet).lineLimit(1).frame(width: column * CGFloat(label.count), alignment: .leading)
                        Text(body).font(font).foregroundStyle(Self.primary).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .caption(let indent, let text):
            indented(indent) { Text(text).font(font).foregroundStyle(Self.quiet) }
        case .cursor(let indent, let text):
            indented(indent) {
                HStack(alignment: .top, spacing: 0) {
                    Text("❯").font(font.weight(.bold)).foregroundStyle(tint.ink).frame(width: column * 2, alignment: .leading)
                    Text(text).font(font.weight(.medium)).foregroundStyle(Color.nookText).fixedSize(horizontal: false, vertical: true)
                }
            }
            // Behind the row without taking room: the rows around it do not move when the cursor does.
            .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.accent.opacity(0.14)).padding(.horizontal, -6).padding(.vertical, -1) }
        case .bar(let indent, let lead, let fraction, let trailing):
            indented(indent) {
                HStack(spacing: 9) {
                    if !lead.isEmpty { Text(lead).font(font).foregroundStyle(Self.quiet).fixedSize() }
                    PanelBar(fraction: fraction).frame(maxWidth: 380)
                    Text(trailing).font(font).foregroundStyle(Self.primary).lineLimit(1)
                        .frame(width: column * CGFloat(barTrailingColumns), alignment: .leading)
                }.frame(height: lineHeight + 3)
            }
        case .hint(let text):
            Text(text).font(.system(size: size * 0.92, design: .monospaced)).foregroundStyle(Self.quiet.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
    }

    /// A row's own indent in columns, then its content, which wraps inside what is left.
    private func indented<Content: View>(_ indent: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if indent > 0 { Color.clear.frame(width: column * CGFloat(indent), height: 1) }
            content().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Claude's "█████░░░░ 25% used" as a bar: mint while there is room, amber and then coral as it fills.
struct PanelBar: View {
    var fraction: Double

    /// What the bar is drawn in.
    static func color(for fraction: Double) -> Color {
        fraction >= 0.95 ? panelCoral : fraction >= 0.8 ? panelAmber : panelMint
    }

    /// The same colour for words (the percent beside the bar): the deep shade that reads on the light island.
    static func ink(for fraction: Double) -> Color {
        fraction >= 0.95 ? Color.nookCoral : fraction >= 0.8 ? Color.nookAmber : Color.nookMint
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.nookWash(0.1))
                if fraction > 0.004 {
                    Capsule().fill(Self.color(for: fraction)).frame(width: max(geometry.size.height, geometry.size.width * fraction))
                }
            }
        }.frame(height: 7).accessibilityElement().accessibilityLabel("\(Int((fraction * 100).rounded())) por ciento")
    }
}

/// The dialog's title and its tabs. The open tab stands out when the panel says which it is; otherwise they are all alike.
private struct PanelTabs: View {
    var title: String?
    var names: [String]
    var active: Int?
    @Environment(\.tabTint) private var tint

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let title {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.nookWash(0.9)).padding(.trailing, 4)
                }
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    let open = index == active
                    Text(name).font(.system(size: 10.5, weight: open ? .semibold : .regular)).lineLimit(1).fixedSize()
                        .foregroundStyle(open ? Color.nookText : Color.nookSecondary)
                        .padding(.horizontal, 9).frame(height: 21)
                        .background(open ? tint.accent.opacity(0.26) : Color.nookWash(0.07), in: Capsule())
                        .overlay(Capsule().strokeBorder(open ? tint.accent.opacity(0.6) : Color.clear, lineWidth: 0.8))
                        .accessibilityLabel(name).accessibilityValue(open ? "abierta" : "")
                }
            }
        }
    }
}

/// A key's name on a small cap, like the ones on the prompt card and the "/" menu.
private struct PanelKeycap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Color.nookSecondary)
            .padding(.horizontal, 4.5).frame(height: 15)
            .background(Color.nookWash(0.09), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The panel's buttons: a quiet fill at rest (or none), a brighter one under the pointer, and the brightest while pressed or
/// while the keyboard's own press of the same key is landing (`lit`).
struct PanelButtonStyle: ButtonStyle {
    var lit = false
    var rest = 0.0
    var radius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Fill(configuration: configuration, lit: lit, rest: rest, radius: radius)
    }

    private struct Fill: View {
        let configuration: ButtonStyleConfiguration
        let lit: Bool
        let rest: Double
        let radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        @State private var clicks = 0
        private let gate = NookMotionGate()

        var body: some View {
            let strength = lit || configuration.isPressed ? 0.22 : (hovering && enabled ? rest + 0.1 : rest)
            // A key gives under the finger as the island's other buttons do (`NookPressStyle`), and its icon answers (`nookIconMotion`). The wash says the press
            // whatever the motion settings are.
            let sunk = configuration.isPressed && gate.allows
            configuration.label
                .environment(\.nookClicks, clicks)
                .background(Color.nookWash(strength), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .scaleEffect(sunk ? 0.92 : 1)
                .animation(sunk ? .easeOut(duration: 0.07) : .spring(response: 0.3, dampingFraction: 0.6), value: sunk)
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: strength)
                .onChange(of: configuration.isPressed) { _, pressed in if !pressed { clicks += 1 } }
        }
    }
}

// MARK: - Scroll metrics

/// Where the panel's text is in its scroll view: how far it moved, how tall it is and how wide, measured from inside it.
private struct ScrollMetrics: Equatable, Sendable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var width: CGFloat = 0
}

// MARK: - Keyboard

/// Takes the keyboard while the panel is on screen and hands the panel's keys to the card. Everything else typed is ignored
/// (the panel has no field), never beeped at. Held keys do not repeat: each one is a trip to the terminal.
struct PanelKeyCatcher: NSViewRepresentable {
    var focusRequest: Int
    var onKey: (TerminalKey) -> Void

    func makeNSView(context: Context) -> PanelKeyView {
        let view = PanelKeyView()
        view.onKey = onKey
        view.focusRequest = focusRequest
        return view
    }

    func updateNSView(_ view: PanelKeyView, context: Context) {
        view.onKey = onKey
        if view.focusRequest != focusRequest {
            view.focusRequest = focusRequest
            view.takeKeyboard()
        }
    }
}

final class PanelKeyView: NSView {
    var onKey: ((TerminalKey) -> Void)?
    var focusRequest = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { takeKeyboard() }
    }

    /// One turn later: the view has to be in the window before it can take the keyboard. Someone typing in a text field of the
    /// island (the tmux socket on the connection sheet, say) keeps the keyboard; the message field is not one of those.
    func takeKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            if (window.firstResponder as? NSText)?.isFieldEditor == true { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if let key = ClaudePanelKey.key(event: event) {
            if !event.isARepeat { onKey?(key) }
            return
        }
        // Command keys that got here are the system's; anything else typed has no place in a panel.
        if event.modifierFlags.contains(.command) { super.keyDown(with: event) }
    }
}
