import SwiftUI
import AppKit

private let accent = Color(red: 0.32, green: 0.73, blue: 0.61)
/// Claude's spinner color, so its symbol reads the same as in the terminal.
let claudeSpinner = Color(nsColor: PetView.claudeSpinner)

struct NookPanel: View {
    @ObservedObject var model: AppModel
    /// Which tab's agents list is open. Shared by the tabs' badges and the list drawn over the tab row; held without
    /// observing it, so a hover over a badge redraws only the list, not the panel.
    @State private var agentList: TabAgentListPresenter

    init(model: AppModel) { self.init(model: model, agentList: TabAgentListPresenter()) }

    /// Previews and render tests pass a presenter with a list already open.
    init(model: AppModel, agentList: TabAgentListPresenter) {
        self.model = model
        _agentList = State(initialValue: agentList)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black
                content
                    .frame(width: model.islandSize.width, height: model.islandSize.height, alignment: .top)
                    .opacity(model.islandContentVisible ? 1 : 0)
                    .allowsHitTesting(model.islandContentVisible)
                    .environment(\.colorScheme, .dark)
                    // The conversation sits straight on the island's black in every system appearance, so glass
                    // cards that float over it always have a dark backdrop.
                    .environment(\.nookDarkBackdrop, true)
                HStack {
                    CatIcon(color: .white, animated: model.animations, working: model.working).frame(width: 24, height: 24).scaleEffect(0.6)
                    Spacer()
                    ActivityGlyph(working: model.working, unread: model.unreadCount, animated: model.animations, glyph: model.activityGlyph)
                        .overlay(alignment: .topTrailing) { AgentCountBadge(running: model.runningSubagents).offset(x: 4, y: -1.5) }
                }.padding(.horizontal, 8)
                    // The window keeps its expanded size; the collapsed cat sits where the notch's wings are.
                    .frame(width: model.controller?.compactFrame.width ?? geometry.size.width, height: model.neckHeight)
                    .opacity(model.islandContentVisible ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
        }
        // Esc in an agent's conversation goes back to Claude's; only without one does it put the island away.
        .onExitCommand { if !model.leaveAgentView() { model.controller?.collapse(force: true) } }
    }

    /// The pane's layout in this island: its size and the user's settings.
    private var paneLayout: PaneLayout { .of(island: model.islandSize, neck: model.neckHeight, settings: model.display) }

    private var content: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    HeaderPetStage(animated: model.animations, working: model.working, needsAttention: model.unreadCount > 0, controller: model.controller)
                        .frame(width: petStageWidth, height: model.neckHeight)
                    Spacer()
                    Button { model.openLatestNotice() } label: { ActivityGlyph(working: model.working, unread: model.unreadCount, animated: model.animations, glyph: model.activityGlyph) }
                        .buttonStyle(.plain).help(model.unreadCount > 0 ? "Ver aviso de la terminal" : "Actividad de la terminal").disabled(model.unreadCount == 0)
                    IconButton(symbol: model.pinned ? "pin.fill" : "pin", label: model.pinned ? "Desfijar panel" : "Mantener abierto") { model.pinned.toggle() }
                    IconButton(symbol: "chevron.up", label: "Recoger panel") { model.controller?.collapse(force: true) }
                }.padding(.horizontal, 12).frame(height: model.neckHeight)
                if model.sessions.isEmpty {
                    WelcomeView(model: model)
                } else {
                    // Above the session pane so the recap card it opens receives clicks.
                    sessionTabs.zIndex(1)
                    if let selected = model.selected {
                        SessionPane(model: model, session: selected).id(selected.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let notice = model.notice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(notice).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            // A notice about a missing permission offers the Permisos tab.
                            if PermissionHelp.opensPermissions(notice) { SeePermissionsButton { model.notice = nil; model.showPermissions() } }
                        }
                        Spacer(minLength: 0)
                        Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }.buttonStyle(.plain).help("Cerrar aviso")
                    }.padding(10).nookGlassCard(radius: 12, tint: accent.opacity(0.14), dimColor: Color(white: 0.13), fill: Color(white: 0.13), stroke: accent.opacity(0.2))
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(12)
            }
            if model.connectionSheet {
                Color.black.opacity(0.18)
                    ScrollView { ConnectionView(model: model).padding(18) }.scrollIndicators(.hidden)
                    .nookGlassCard(radius: 22, dim: 0.6, fill: .regularMaterial, stroke: Color.primary.opacity(0.09))
                    .padding(15)
                    .shadow(color: .black.opacity(0.15), radius: 25, y: 10)
            }
        }
        .background(Color.black)
    }

    private var petStageWidth: CGFloat {
        NotchGeometry.petStageWidth(islandWidth: model.islandSize.width, cutout: model.controller?.notchWidth ?? 180)
    }

    private var sessionTabs: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        SessionTab(model: model, session: session, agentList: agentList)
                    }
                }
            }
            Menu {
                ForEach(SessionKind.allCases, id: \.self) { kind in Button(kind.title) { model.create(kind) } }
                Divider()
                Button("Conectar una terminal…") { model.showConnections() }
                Button("Nueva sesión en una carpeta…") { chooseFolder() }
            } label: { Image(systemName: "plus").frame(width: 24, height: 26) }
                .menuStyle(.borderlessButton).fixedSize().help("Nueva sesión")
            if let selected = model.selected {
                ObservedRecapButton(object: selected, id: \.id, recap: \.recap)
                IconButton(symbol: "arrow.up.right.square", label: "Mostrar terminal completa") { model.controller?.focusSession() }
                Menu {
                    if !selected.isExternal {
                        Button("Abrir en Terminal de macOS") { model.controller?.openInTerminal() }
                        Button("Copiar conexión") { model.copyConnection() }
                    }
                    Button("Conectar otra terminal…") { model.showConnections() }
                    Button(model.claudeSignalsEnabled ? "Desactivar avisos de Claude…" : "Activar avisos de Claude…") { model.enableClaudeSignals() }
                    Divider()
                    Button("Renombrar y cambiar color…") { model.editingSessionID = selected.id }
                    Button("Cerrar pestaña de Nook") { model.close(selected) }
                    if selected.record.ownsSession {
                        Divider()
                        Button("Terminar sesión…", role: .destructive) { model.terminate(selected) }
                    }
                    if selected.drivesAgent { Button("Pegar imagen del portapapeles (⌘V o ⌃V)") { model.pasteImage(into: selected) { NotificationCenter.default.post(name: .nookAttachPath, object: $0) } } }
                    if selected.isExternal { Button("Copiar diagnóstico") { model.copyDiagnostics(selected) } }
                    Divider()
                    Button("Ajustes…") { model.controller?.toggleSettings(tab: .island) }
                    Button("Permisos…") { model.controller?.toggleSettings(tab: .permissions) }
                    Divider()
                    // Quitting closes only Nook: terminals, tmux sessions and their processes keep running.
                    Button("Salir de Nook") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").frame(width: 16, height: 20) }.menuStyle(.borderlessButton).fixedSize()
            }
        }.padding(.horizontal, 15).frame(height: 30)
            // The tabs' agent badges report where they are in this space, and their list opens in it. It is an overlay
            // of the row because the tabs' scroll view would clip a card hanging from one of them.
            .coordinateSpace(name: TabAgentListPresenter.space)
            .overlay(alignment: .topLeading) {
                TabAgentListHost(presenter: agentList, sessions: model.sessions, containerWidth: model.islandSize.width,
                                 animated: model.animations, width: paneLayout.tabListWidth, maxHeight: paneLayout.tabListMaxHeight) { session, agent in
                    // A click on an agent's row enters its conversation; the list has done its job.
                    agentList.close()
                    model.openAgent(agent, in: session)
                }
            }
            .onChange(of: model.islandContentVisible) { _, visible in
                if !visible { agentList.close(); model.agentListRequest = nil } else { openRequestedAgentList() }
            }
            // The collapsed island's agent pill asked for a tab's list: it opens once the island's content is on screen.
            .onChange(of: model.agentListRequest) { _, _ in openRequestedAgentList() }
    }

    private func openRequestedAgentList() {
        guard model.islandContentVisible, let request = model.agentListRequest else { return }
        model.agentListRequest = nil
        if model.sessions.contains(where: { $0.id == request.sessionID }) { agentList.openList(request.sessionID) }
    }
    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.prompt = "Abrir terminal aquí"
        if picker.runModal() == .OK, let url = picker.url { model.create(.shell, directory: url.path) }
    }
}

private struct SessionTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSession
    var agentList: TabAgentListPresenter
    /// What the tab's agent badge shows. It changes when an agent starts or ends, not when a counter ticks.
    @StateObject private var agents: TabAgentTracker

    init(model: AppModel, session: TerminalSession, agentList: TabAgentListPresenter) {
        self.model = model
        self.session = session
        self.agentList = agentList
        _agents = StateObject(wrappedValue: TabAgentTracker(session: session))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { model.select(session) } label: {
                HStack(spacing: 5) {
                    Circle().fill(session.tint.color).frame(width: 5, height: 5)
                    Text(session.displayTitle).font(.system(size: 10, weight: model.selectedID == session.id ? .semibold : .regular)).lineLimit(1)
                    if session.unreadNotice != nil { Image(systemName: "bell.fill").font(.system(size: 8)).foregroundStyle(session.tint.color) }
                    // A question waits in a tab that is not the one on screen.
                    if let prompt = session.prompt, prompt.kind != .selector, model.selectedID != session.id {
                        Image(systemName: "questionmark.circle.fill").font(.system(size: 8.5)).foregroundStyle(claudeSpinner).help("\(session.agent?.title ?? "La IA") espera tu respuesta")
                    }
                }.padding(.leading, 8).padding(.vertical, 5)
            }.buttonStyle(.plain).help(session.recap.map { "Resumen de Claude: " + $0 } ?? session.displayTitle)
            // The tab's Claude has subagents: working ones show, and the list opens under the tab row.
            if agents.state.kind != nil {
                TabAgentIndicator(sessionID: session.id, state: agents.state, animated: model.animations && model.islandContentVisible, presenter: agentList)
            }
            Button { model.close(session) } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .semibold)).frame(width: 16, height: 22) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Cerrar esta pestaña en Nook; conservar la terminal original")
        }.padding(.trailing, 3)
            // A list never outlives its badge or its tab.
            .onChange(of: agents.state.kind) { _, kind in if kind == nil { agentList.close(ifShowing: session.id) } }
            .onDisappear { agentList.close(ifShowing: session.id) }
            .foregroundStyle(model.selectedID == session.id ? Color.primary : Color.secondary)
            .nookGlassSurface(in: RoundedRectangle(cornerRadius: 8), tint: session.tint.color.opacity(0.35), isActive: model.selectedID == session.id, dim: 0.45,
                              fill: session.tint.color.opacity(model.selectedID == session.id ? 0.19 : 0.065), stroke: nil)
            .contextMenu {
                Button("Renombrar y cambiar color…") { model.editingSessionID = session.id }
                Button("Cerrar pestaña de Nook") { model.close(session) }
            }
            .popover(isPresented: Binding(get: { model.editingSessionID == session.id }, set: { if !$0 { model.editingSessionID = nil } }), arrowEdge: .bottom) {
                TabEditor(model: model, session: session)
            }
    }
}

private struct TabEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var name = ""
    @State private var tint: TabTint = .mint
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tu pestaña de Nook").font(.system(size: 12, weight: .semibold))
            TextField("Nombre", text: $name).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(save)
            HStack(spacing: 9) {
                ForEach(TabTint.allCases, id: \.self) { color in
                    Button { tint = color } label: {
                        Circle().fill(color.color).frame(width: 21, height: 21)
                            .overlay(Circle().stroke(tint == color ? Color.primary.opacity(0.8) : .clear, lineWidth: 2).padding(-3))
                    }.buttonStyle(.plain).help(color.name).accessibilityLabel(color.name)
                }
            }.padding(.horizontal, 3)
            HStack { Text("La pestaña original conserva su nombre.").font(.system(size: 9)).foregroundStyle(.secondary); Spacer(); Button("Listo", action: save).keyboardShortcut(.defaultAction) }
        }.padding(17).onAppear { name = session.displayTitle; tint = session.tint }
    }
    private func save() { model.customize(session, title: name, tint: tint); model.editingSessionID = nil }
}

private struct ActivityGlyph: View {
    var working: Bool
    var unread: Int
    var animated: Bool
    /// The symbol Claude's spinner shows right now; it changes with the terminal, not on a timer.
    var glyph: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !working || glyph != nil || !animated || reduceMotion)) { context in
            if unread > 0 {
                Image(systemName: "bell.badge.fill").font(.system(size: 11)).foregroundStyle(Color(red: 0.91, green: 0.79, blue: 0.54)).frame(width: 20, height: 20)
            } else if working, let glyph {
                Text(glyph).font(.system(size: 14, weight: .bold)).foregroundStyle(claudeSpinner).frame(width: 20, height: 20)
            } else if working {
                HStack(spacing: 2) {
                    ForEach(0..<3) { i in
                        Circle().fill(accent).frame(width: 3, height: 3).offset(y: animated && !reduceMotion ? sin(context.date.timeIntervalSinceReferenceDate * 6 + Double(i)) * 2 : 0)
                    }
                }.frame(width: 20, height: 20)
            } else { Circle().fill(accent.opacity(0.65)).frame(width: 4, height: 4).frame(width: 20, height: 20) }
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 7)
            Text("Tu IA, a mano.")
                .font(.system(size: 15, weight: .semibold, design: .rounded)).tracking(-0.25)
                .multilineTextAlignment(.center)
            Text("Abre una sesión o conecta tu terminal.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.top, 6)
            HStack(spacing: 10) {
                ForEach(SessionKind.allCases, id: \.self) { kind in
                    Button { model.create(kind) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: kind.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(kind == .shell ? Color.secondary : accent)
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(kind.title).font(.system(size: 11, weight: .medium))
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .nookGlassSurface(in: RoundedRectangle(cornerRadius: 15), interactive: true, dim: 0.5, fill: Color.primary.opacity(0.035))
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 13).padding(.horizontal, 18)
            Button { model.showConnections() } label: {
                Label("Conectar una terminal que ya uso", systemImage: "link").font(.system(size: 11, weight: .medium))
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.top, 12)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                Image(systemName: "hand.draw").font(.system(size: 10))
                Text("Arrastra el gatito a tu terminal para conectarla.").font(.system(size: 9))
            }.foregroundStyle(.tertiary).padding(.bottom, 11)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SessionPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSession
    @StateObject private var speech = SpeechController()
    @State private var draft: String
    @State private var beforeDictation = ""
    @State private var copiedAt: Date?
    /// The joined box the user closed the warning for; trying to send shows it again.
    @State private var dismissedJoin: String?
    @State private var history = HistoryCursor()
    /// The "/" menu: the commands matching the draft, worked out when the draft changes.
    @State private var slashMenu = SlashMenuState()
    /// Whether the key strip (↑ ↓ ⇥ esc ↵ and interrupt) is out. It opens by itself while Claude shows a numbered menu, and
    /// stays open afterwards only when the user opened it by hand (`keysPinned`).
    @State private var keysOpen: Bool
    @State private var keysPinned: Bool
    /// The prompt (by signature) whose card the user folded away, and the one being answered by typing; in both the
    /// composer shows instead of the card. A new prompt has another signature, so its card comes back by itself.
    @State private var cardHiddenFor: String?
    @State private var typingFor: String?
    /// The prompt (by signature) the user confirmed sending a message into, after being warned.
    @State private var confirmedSendFor: String?
    /// After an answer that asks the user to tell the agent something, the field's placeholder says so for a while.
    @State private var followUpHint: String?
    /// When dropped paths went into the draft while a question's card stood in the composer's place (the tag says so for a moment).
    @State private var droppedAt: Date?
    /// Bumped to put the keyboard in the message field (see `ComposerField.focusRequest`).
    @State private var focusRequest = 0
    /// The composer's height as laid out now: the field grows with its text, and what floats above it (the "/" menu, the
    /// agents' list) follows.
    @State private var composerHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the prompt card stands when the pane opens; previews and render tests use it.
    enum PromptCardState { case options, typing, hidden }

    /// `draft`, `keysOpen`, `promptState` and `dictationError` seed the field, the key strip, the prompt card and the status line's
    /// dictation error; previews and render tests use them.
    init(model: AppModel, session: TerminalSession, draft: String? = nil, keysOpen: Bool = false, promptState: PromptCardState = .options, dictationError: String? = nil) {
        self.model = model
        self.session = session
        let speech = SpeechController()
        speech.error = dictationError
        _speech = StateObject(wrappedValue: speech)
        _draft = State(initialValue: draft ?? session.draft)
        _keysOpen = State(initialValue: keysOpen)
        _keysPinned = State(initialValue: keysOpen)
        _cardHiddenFor = State(initialValue: promptState == .hidden ? session.prompt?.signature : nil)
        _typingFor = State(initialValue: promptState == .typing ? session.prompt?.signature : nil)
        _composerHeight = State(initialValue: ComposerMetrics.composerHeight(lines: 1, size: model.display.inputSize))
    }

    /// The pane's measures. The conversation takes whatever height the composer leaves (`PaneLayout` knows how much that
    /// is for the island's size and the settings).
    private enum Metrics {
        /// Margin between the island's edge and the composer.
        static let edge: CGFloat = 15
        static let composerRadius: CGFloat = 18
        /// Where the composer's text starts inside it; the conversation's text starts at about the same x.
        static let composerInset: CGFloat = 13
        /// The mirror's own text inset is 7 pt (container inset 2 plus line padding 5), so this brings its text to the
        /// composer's text column.
        static let mirrorInset: CGFloat = composerInset - 7
        static let controlHeight: CGFloat = 28
        static let keyHeight: CGFloat = 24
        /// Secondary labels carry information (status, hints, keys), so they use `.secondary`, never `.tertiary`.
        static let labelSize: CGFloat = 10.5
    }

    var body: some View {
        // The pane's own size decides how much the composer, the "/" menu and the question card can take.
        GeometryReader { geometry in
            let layout = PaneLayout(width: geometry.size.width, height: geometry.size.height, settings: model.display)
            pane(layout)
                .onChange(of: layout.slashRows(composerHeight: composerHeight), initial: true) { _, rows in slashMenu.setVisibleRows(rows) }
        }
            .task(id: copiedAt) {
                guard copiedAt != nil else { return }
                try? await Task.sleep(for: .seconds(1.4))
                copiedAt = nil
            }
            // A dictation error has no row of its own any more; it takes the status line's place for a while.
            .task(id: speech.error) {
                guard let error = speech.error else { return }
                // A permission takes a trip to System Settings to fix: its message stays longer.
                try? await Task.sleep(for: .seconds(PermissionHelp.opensPermissions(error) ? 20 : 8))
                if !Task.isCancelled { speech.error = nil }
            }
            .onChange(of: wantsKeys, initial: true) { _, showing in
                // A menu without a card (not recognised, or folded away) needs the arrows and Enter: bring the keys out,
                // and put them away when it is gone.
                if showing { if !keysOpen { withAnimation(.easeOut(duration: 0.18)) { keysOpen = true } } }
                else if !keysPinned, keysOpen { withAnimation(.easeOut(duration: 0.18)) { keysOpen = false } }
            }
            .onChange(of: showsCard) { _, shows in
                // The field was recreated with the composer; typing continues where it was before the question.
                guard !shows else { return }
                if session.isExternal { DispatchQueue.main.async { focusField() } }
            }
            // The same question asked again later gets its card again; a redraw that blinks it off for a moment does not count.
            .task(id: prompt == nil) {
                guard prompt == nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { cardHiddenFor = nil; typingFor = nil; confirmedSendFor = nil }
            }
            .task(id: followUpHint) {
                guard followUpHint != nil else { return }
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { followUpHint = nil }
            }
            .task(id: droppedAt) {
                guard droppedAt != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { droppedAt = nil } }
            }
            .onChange(of: speech.transcript) { _, text in draft = beforeDictation + (beforeDictation.isEmpty ? "" : " ") + text }
            .onDisappear { speech.stop() }
            .onAppear { if session.isExternal { focusField() } }
            .onChange(of: draft) { _, text in session.draft = text }
            .onChange(of: draft, initial: true) { _, text in refreshSlashMenu(for: text) }
            // The "…" menu has no access to the draft; its image fallback arrives as a path.
            .onReceive(NotificationCenter.default.publisher(for: .nookAttachPath)) { note in
                if let path = note.object as? String { attach(path) }
            }
            // Files dropped on the island arrive as their paths, whichever part of it they landed on.
            .onReceive(NotificationCenter.default.publisher(for: .nookDropFiles)) { note in
                if let request = note.object as? FileDropRequest { receiveDrop(request) }
            }
            .onChange(of: model.islandContentVisible) { _, visible in if visible && session.isExternal { focusField() }; if !visible { speech.stop() } }
    }

    /// The conversation, the composer (or the agent's question in its place) and what floats over them.
    private func pane(_ layout: PaneLayout) -> some View {
        VStack(spacing: 6) {
            // No card around the conversation: it is plain text on the island's black, like the Claude app.
            conversation.frame(maxWidth: .infinity, minHeight: showsCard ? 0 : 40, maxHeight: .infinity)
                // A card with many options takes the pane; the sliver of conversation left would only show a cut line.
                .opacity(covered(by: layout) ? 0 : 1).allowsHitTesting(!covered(by: layout))
            // A question the agent is waiting on takes the composer's place: nothing typed now could answer it.
            ZStack {
                if let prompt = cardPrompt { promptCard(prompt, layout).transition(.opacity) } else { composer(layout).transition(.opacity) }
            }.animation(.easeOut(duration: 0.16), value: showsCard)
                // Files dragged over the island: the slot lights up, whichever of the two it holds.
                .overlay { FileDropFeedback(state: model.fileDrop, radius: Metrics.composerRadius) }
                .overlay(alignment: .top) { droppedNote }
        }.padding(.horizontal, Metrics.edge).padding(.bottom, ComposerMetrics.bottomInset).frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) { joinedWarning }
    }

    @ViewBuilder private var conversation: some View {
        if session.isExternal {
            VStack(spacing: 6) {
                // An agent's own conversation is on show: whose it is, and the way back (the composer still writes to Claude).
                if let viewed = session.viewedAgent {
                    AgentViewBar(agent: session.subagents.first { $0.id == viewed }, animated: model.animations && model.islandContentVisible) {
                        model.view(agent: nil, in: session)
                    }.padding(.top, 2)
                }
                LiveTerminalSurface(text: mirrorText, transcript: session.agent == .claude, fontSize: model.display.chatSize, contentID: session.viewedAgent ?? "") { copiedAt = Date() }
                    .padding(.horizontal, Metrics.mirrorInset).padding(.top, session.viewedAgent == nil ? 2 : 0)
                    .overlay {
                        // The agent has no record yet (or it is being read): nothing to show but a word about it.
                        if let viewed = session.viewedAgent, session.displayText.isEmpty { AgentViewPlaceholder().id(viewed) }
                    }
            }
        } else {
            // SwiftTerm draws to the very edge of its view, so the margin comes from padding.
            TerminalSurface(session: session, fontSize: model.display.chatSize).padding(.horizontal, Metrics.composerInset).padding(.vertical, 4)
        }
    }

    // MARK: Composer

    /// One rounded container, as in the Claude app: the message on top, and a row of controls at the bottom.
    private func composer(_ layout: PaneLayout) -> some View {
        VStack(spacing: 0) {
            inputRow(layout)
            controlsRow
        }.nookGlassSurface(in: RoundedRectangle(cornerRadius: Metrics.composerRadius, style: .continuous), dim: 0.55, dimColor: Color(white: 0.055),
                          fill: Color.white.opacity(0.07), stroke: Color.white.opacity(0.07))
            // The field grows with its text, and the "/" menu and the agents' list above it follow.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            // Floats over the conversation, bottom edge just above the composer, so nothing is laid out again when it comes and goes.
            .overlay(alignment: .top) {
                if slashMenu.isVisible {
                    SlashMenuView(commands: slashMenu.items, highlighted: slashMenu.highlighted, top: slashMenu.top, query: SlashCatalog.query(in: draft) ?? "",
                                  visibleRows: slashMenu.visible, onPick: pick)
                        .offset(y: -(SlashMenuView.height(rows: slashMenu.items.count, visible: slashMenu.visible) + SlashMenuView.gap))
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: slashMenu.isVisible)
    }

    private func inputRow(_ layout: PaneLayout) -> some View {
        // The tag and the capsule sit beside the field's first line, whatever the field's height.
        let firstLine = ComposerMetrics.fieldHeight(lines: 1, size: model.display.inputSize)
        return HStack(alignment: .top, spacing: 8) {
            ComposerField(text: $draft, placeholder: placeholder, fontSize: model.display.inputSize, maxLines: layout.fieldLines, focusRequest: focusRequest,
                          accessibilityHint: "Arrastra archivos o carpetas a la isla para añadir su ruta al mensaje. Intro envía; Mayús Intro añade una línea.",
                          onKey: composerKey)
            if draft.isEmpty, !speech.recording, session.suggestion != nil {
                Text("⇥ usar").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    .help("Tab, → o Enter copian la sugerencia de Claude a este campo; después Enter la envía.")
                    .frame(height: firstLine)
            }
            // The agents' capsule sits here, not in the controls row: its list opens upward from its right edge.
            SubagentCapsule(agents: session.subagents, animated: model.animations, listMaxHeight: layout.capsuleListMaxHeight(composerHeight: composerHeight),
                            onManage: { model.press(.down, on: session) }, onOpen: { model.openAgent($0, in: session) })
                .frame(height: firstLine)
        }.padding(.leading, Metrics.composerInset).padding(.trailing, 6).padding(.top, ComposerMetrics.topPadding)
            // With no field outline, the whole row answers a click by focusing the field.
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { focusField() } }
    }

    /// Puts the keyboard in the message field.
    private func focusField() { focusRequest += 1 }

    /// Claude's grey suggestion goes into an empty field, caret at its end, and is not sent (Enter on the empty field does
    /// the same, and Enter again sends). False when there is nothing to take or the field has text.
    private func takeSuggestion() -> Bool {
        guard draftIsEmpty, !slashMenu.isVisible, let suggestion = session.suggestion else { return false }
        draft = suggestion
        return true
    }

    /// What the field's keys do. ↵ sends at once; ⇧↵ and ⌥↵ add a line (the field does that, so they are left alone here).
    /// With the "/" menu showing the arrows walk its rows; otherwise the caret walks the lines of the draft and, only on
    /// its first or last line, ↑ and ↓ recall the sent messages. Esc closes the menu and stops there; with no menu it
    /// goes on to collapse the island. ⌃V pastes the clipboard's image into the agent, as in its own terminal (so does ⌘V when
    /// the clipboard has an image and no text: the field decides, see `ClipboardPaste`).
    private func composerKey(_ key: ComposerKey, _ caret: ComposerCaret) -> Bool {
        switch key {
        case .submit: submit(); return true
        case .newline: return false
        case .up, .down:
            let up = key == .up
            if slashMenu.isVisible { return slashKey(up ? .up : .down) == .handled }
            guard up ? caret.onFirstLine : caret.onLastLine else { return false }
            return recall(older: up) == .handled
        // ⇥ completes the highlighted command while the menu shows; on an empty field it takes Claude's suggestion instead.
        case .tab: return slashKey(.tab) == .handled || takeSuggestion()
        // → on an empty field takes the suggestion too (Claude's box does); anywhere else it is the caret's.
        case .right: return draft.isEmpty && takeSuggestion()
        case .escape:
            // The menu closes first; then an agent's conversation goes back to Claude's. Only after both does Esc put the island away.
            if slashKey(.escape) == .handled { return true }
            guard session.viewedAgent != nil else { return false }
            model.view(agent: nil, in: session)
            return true
        case .pasteImage: pasteImage(); return true
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if session.isExternal { Circle().fill(session.isRunning ? accent : Color.orange).frame(width: 5, height: 5) }
                statusLabel
            }.frame(maxWidth: .infinity, alignment: .leading)
            if keysOpen {
                keyPad.transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
            }
            HStack(spacing: 6) {
                keysToggle
                micButton
                primaryButton
            }
        }.padding(.leading, Metrics.composerInset).padding(.trailing, 6).padding(.top, 1).padding(.bottom, 6)
    }

    /// The session's own menus answer these keys; Nook never substitutes its options. Interrupt closes the strip, so it
    /// stays reachable when Claude's spinner is not on screen (a shell, Codex) and the stop button is not showing.
    private var keyPad: some View {
        HStack(spacing: 0) {
            ForEach(TerminalKey.menuKeys) { key in
                Button { model.press(key, on: session) } label: {
                    Group {
                        if let caption = key.caption { Text(caption).font(.system(size: 11, weight: .semibold, design: .rounded)) }
                        else { Image(systemName: key.symbol).font(.system(size: 11, weight: .semibold)) }
                    }.frame(width: 27, height: Metrics.keyHeight).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.78)).disabled(!session.isRunning)
                    .help(key.label + (session.isExternal && key.needsDirectKeys ? " en la pestaña original (requiere Accesibilidad)" : " en la terminal"))
                    .accessibilityLabel(key.label)
            }
            Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 12).padding(.horizontal, 3)
            Button { model.interrupt(session) } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold))
                    .frame(width: 27, height: Metrics.keyHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.78)).disabled(!session.isRunning)
                .help(interruptHelp).accessibilityLabel("Interrumpir")
        }.background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var keysToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                // Closing also drops the pin; opening pins it, so a menu closing later does not take the keys away.
                keysOpen.toggle()
                keysPinned = keysOpen
            }
        } label: {
            Image(systemName: "keyboard").font(.system(size: 13))
                .foregroundStyle(keysOpen ? Color.primary : Color.primary.opacity(0.7))
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                .background(Color.primary.opacity(keysOpen ? 0.14 : 0), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain)
            .help(keysOpen ? "Ocultar las teclas de menú" : "Teclas de menú: ↑ ↓ ⇥ esc ↵ e interrumpir")
            .accessibilityLabel(keysOpen ? "Ocultar las teclas de menú" : "Mostrar las teclas de menú")
    }

    private var interruptHelp: String { session.drivesAgent ? "Enviar Escape para detener a la IA" : "Enviar Control-C" }

    /// The AI is busy: Claude's own spinner says so (a finished summary does not count); Codex has no status Nook can read,
    /// so recent output stands in for it. A plain shell never turns the send button into a stop button.
    private var aiWorking: Bool {
        guard session.isRunning, session.drivesAgent else { return false }
        if session.agent == .claude { return session.agentStatus?.working == true }
        return model.working
    }

    private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// As in the Claude app: while the AI works and there is nothing to send, the send circle is a stop button.
    @ViewBuilder private var primaryButton: some View {
        if aiWorking, draftIsEmpty { stopButton } else { sendButton }
    }

    private var stopButton: some View {
        Button { model.interrupt(session) } label: {
            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                // Claude's own terracotta: the thing being stopped is Claude's work.
                .background(claudeSpinner, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(interruptHelp).accessibilityLabel("Interrumpir")
    }

    private var micButton: some View {
        Button {
            if !speech.recording { beforeDictation = draft }
            speech.toggle()
        } label: {
            Image(systemName: speech.recording ? "stop.fill" : "mic")
                .font(.system(size: 13, weight: speech.recording ? .semibold : .regular)).foregroundStyle(speech.recording ? Color.red : Color.primary.opacity(0.78))
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                .background(speech.recording ? Color.red.opacity(0.16) : Color.primary.opacity(0.09), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(speech.recording ? "Terminar dictado" : "Dictar un mensaje")
            .accessibilityLabel(speech.recording ? "Terminar dictado" : "Dictar un mensaje")
    }

    /// Mint, not Claude's terracotta: mint is the user's voice in Nook (the message block in the mirror), terracotta is Claude's.
    private var sendButton: some View {
        let empty = draftIsEmpty
        return Button(action: send) {
            Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                .foregroundStyle(empty ? Color.secondary : Color.white)
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                .nookGlassSurface(in: Circle(), tint: accent, isActive: !empty, interactive: true,
                                  fill: empty ? Color.primary.opacity(0.09) : accent, stroke: nil)
        }.buttonStyle(.plain).disabled(empty || !session.isRunning || session.sending).help("Enviar a la terminal")
            .accessibilityLabel("Enviar")
    }

    @ViewBuilder private var joinedWarning: some View {
        if let box = session.joinedBox, dismissedJoin != box {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.badge.plus").foregroundStyle(Color(red: 0.91, green: 0.79, blue: 0.54))
                    Text("Tu mensaje quedó en la caja de Claude sin enviarse; no lo volveré a pegar. Envíalo así o corrígelo en la terminal.").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { dismissedJoin = box } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }.buttonStyle(.plain).help("Cerrar aviso")
                }
                Text("«\(box)»").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Mostrar terminal") { model.controller?.focusSession() }.font(.system(size: 11))
                    Button("Enviar así") {
                        model.press(.enter, on: session)
                        session.joinedBox = nil; draft = ""; beforeDictation = ""
                    }.font(.system(size: 11, weight: .medium)).buttonStyle(.borderedProminent).tint(accent)
                }
            }.padding(10).nookGlassCard(radius: 12, tint: Color(red: 0.91, green: 0.79, blue: 0.54).opacity(0.14), dimColor: Color(white: 0.13), fill: Color(white: 0.13), stroke: Color(red: 0.91, green: 0.79, blue: 0.54).opacity(0.25))
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
    /// Claude's grey suggestion takes the placeholder's place, as in its own box.
    private var placeholder: String {
        if speech.recording { return "Te escucho…" }
        if let prompt, prompt.signature == typingFor { return "Escribe tu respuesta…" }
        if let followUpHint { return followUpHint }
        // While an agent's conversation is shown, what is written still goes to Claude; the field says so.
        if session.viewedAgent != nil { return "Mensaje para Claude…" }
        if let suggestion = session.suggestion { return suggestion }
        if let agent = session.agent { return "Mensaje o /comando para \(agent.title)…" }
        return session.isExternal ? "Mensaje a la pestaña original…" : "Escribe o dicta para tu terminal…"
    }
    /// One line for what is going on, by priority: a dictation error, sending, the copy feedback, dictation, Claude's own
    /// status, and finally a hint about the keys.
    @ViewBuilder private var statusLabel: some View {
        if let error = speech.error {
            HStack(spacing: 8) {
                Text(error).font(.system(size: 10)).foregroundStyle(Color.orange).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(error)
                // What went wrong is a permission: the way to the card that shows them is right here.
                if PermissionHelp.opensPermissions(error) { SeePermissionsButton { model.showPermissions() }.fixedSize().layoutPriority(1) }
            }
        } else if session.sending {
            Text("Enviando…").font(.system(size: Metrics.labelSize)).foregroundStyle(.secondary)
        } else if let prompt, prompt.signature == typingFor || prompt.signature == cardHiddenFor {
            // The question is still open but its card is out of the way: say so, and give the way back.
            HStack(spacing: 8) {
                Text(prompt.signature == typingFor ? "Tu respuesta · ↵ enviar" : "\(session.agent?.title ?? "La IA") espera tu respuesta")
                    .font(.system(size: Metrics.labelSize)).foregroundStyle(.secondary).lineLimit(1)
                Button { typingFor = nil; cardHiddenFor = nil } label: {
                    Label("Opciones", systemImage: "list.bullet").font(.system(size: Metrics.labelSize, weight: .medium)).foregroundStyle(accent).fixedSize()
                }.buttonStyle(.plain).help("Volver a las opciones de la pregunta")
            }
        } else if copiedAt == nil, !speech.recording, session.isExternal, session.isRunning, let status = session.agentStatus {
            // Claude's own status lives here instead of inside the chat.
            (Text(status.glyph.map { $0 + " " } ?? "").foregroundStyle(status.working ? claudeSpinner : Color.secondary) + Text(Self.statusText(status.text)))
                .font(.system(size: Metrics.labelSize)).foregroundStyle(status.working ? Color.primary.opacity(0.85) : Color.secondary).lineLimit(1).truncationMode(.tail)
                .help(status.text)
        } else {
            Text(copiedAt != nil ? "Copiado al portapapeles" : speech.recording ? "Dictando · revisa antes de enviar" : session.isExternal ? (session.isRunning ? "\(session.agent?.title ?? "Terminal") · en vivo · ↵ enviar" : "Terminal · conexión interrumpida") : "↵ enviar · dictado en borrador")
                .font(.system(size: Metrics.labelSize)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    /// Whether a numbered menu is open at the bottom of the mirror: a highlighted option ("❯ 1. Yes") with at least one more
    /// numbered option beside it, in the last lines. A numbered list inside a reply has no highlighted option, so it
    /// is not a menu.
    static func showsNumberedMenu(_ text: String) -> Bool {
        let lines = text.suffix(1800).split(separator: "\n", omittingEmptySubsequences: false).suffix(12)
        var highlighted = 0, options = 0
        for line in lines {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.count - trimmed.count
            guard indent <= 4 else { continue }
            let marked = trimmed.first.map { "❯›".contains($0) } ?? false
            let body = marked ? trimmed.dropFirst().drop(while: { $0 == " " }) : trimmed
            guard body.range(of: #"^\d{1,2}[.)]\s+\S"#, options: .regularExpression) != nil else { continue }
            options += 1
            if marked { highlighted += 1 }
        }
        return highlighted >= 1 && options >= 2
    }
    private var menuShowing: Bool { session.isExternal && (session.prompt != nil || Self.showsNumberedMenu(session.displayText)) }
    /// The keys come out by themselves for a menu the card does not cover.
    private var wantsKeys: Bool { menuShowing && !showsCard }

    // MARK: Prompt card

    private var prompt: AgentPrompt? { session.isExternal ? session.prompt : nil }
    /// The prompt whose card is on screen: the composer's place is taken until it is answered or folded away.
    private var cardPrompt: AgentPrompt? {
        guard let prompt, prompt.signature != cardHiddenFor, prompt.signature != typingFor else { return nil }
        return prompt
    }
    private var showsCard: Bool { cardPrompt != nil }
    /// A card with many options takes the pane; a taller island leaves room for more of them beside the conversation.
    private func covered(by layout: PaneLayout) -> Bool {
        cardPrompt.map { AgentPromptCard.coversMirror(optionCount: $0.options.count, besideMirror: layout.cardOptionsBesideMirror) } ?? false
    }

    private func promptCard(_ prompt: AgentPrompt, _ layout: PaneLayout) -> some View {
        // The agents' capsule keeps its place; its "Gestionar" button (↓) is left out because ↓ would move the question's highlight.
        AgentPromptCard(prompt: prompt, agent: session.agent, busy: session.answering, needsAccessibility: session.isExternal && !DirectKeys.allowed,
                        accessory: AnyView(SubagentCapsule(agents: session.subagents, animated: model.animations)),
                        visibleRows: layout.cardRows,
                        onChoose: { choose($0, of: prompt) },
                        onCancel: { model.cancelPrompt(on: session) },
                        onHide: { cardHiddenFor = prompt.signature })
    }

    /// A click on an option. Options that ask for text bring the composer back (the field takes the keyboard whenever the
    /// card goes away) with a placeholder that says what to write.
    private func choose(_ index: Int, of prompt: AgentPrompt) {
        guard prompt.options.indices.contains(index) else { return }
        let input = prompt.options[index].input
        model.answer(prompt, option: index, on: session) { result in
            guard result == .sent else { return }
            switch input {
            case .none: break
            case .inline: typingFor = prompt.signature
            case .followUp: followUpHint = "Dile a \(session.agent?.title ?? "la IA") qué hacer…"
            }
        }
    }

    /// Nook has its own interrupt button, so Claude's "esc to interrupt" hint is redundant here.
    static func statusText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*·?\s*esc to interrupt"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    private func send() {
        // Enter on an empty field takes Claude's suggestion into it, like Claude does; Enter again sends.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let suggestion = session.suggestion { draft = suggestion; return }
        guard session.isRunning, !session.sending, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The message already sits in Claude's box behind other text; pasting again would duplicate it.
        if session.joinedBox != nil { dismissedJoin = nil; return }
        // A question is open and the option on it takes no text: the paste would be lost and Enter would answer the
        // question with that option. The user decides, on a second Enter, whether that is what they want.
        if let prompt, prompt.options[prompt.highlighted].input != .inline, confirmedSendFor != prompt.signature {
            confirmedSendFor = prompt.signature
            model.notice = "\(session.agent?.title ?? "La IA") tiene una pregunta abierta: lo que envíes no se escribiría en ella y el Enter podría responderla sin querer. Elige una opción (botón «Opciones»), o pulsa Enter otra vez para enviar de todos modos."
            return
        }
        speech.stop()
        // The field empties and the message shows in the mirror at once; delivery can take a moment
        // (Nook waits for the agent to show it before pressing Enter). A failure gives it back.
        // Line breaks the user left at either end are not part of the message.
        let sentDraft = draft.trimmingCharacters(in: .newlines)
        draft = ""; beforeDictation = ""; history.reset(); followUpHint = nil
        model.remember(sentDraft, for: session)
        // Owned tmux sessions show the live terminal itself; only the text mirror needs a placeholder.
        if session.isExternal { session.showPending(sentDraft) }
        session.send(sentDraft) { success in
            guard !success else { return }
            session.pendingMessage = nil
            if draft.isEmpty { draft = sentDraft }
        }
    }

    private func pasteImage() {
        model.pasteImage(into: session) { path in attach(path) }
    }
    /// Without ⌃V the image travels as a file path in the message.
    private func attach(_ path: String) {
        draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + path
    }

    // MARK: Dropped files

    /// The paths of files dropped on the island go into the message; nothing is sent. While the field is being edited they
    /// go in through its editor, after the selection where the cursor is, so the user can undo them like typing. Otherwise
    /// they are added at the end, the field takes the keyboard and the cursor is left after them.
    private func receiveDrop(_ request: FileDropRequest) {
        guard request.sessionID == session.id, !request.text.isEmpty else { return }
        // A dictation in progress would write its transcript over the draft.
        if speech.recording { speech.stop() }
        // A question's card stands where the field should be: the paths wait in the draft for when it comes back.
        guard !showsCard else {
            draft = DroppedPaths.insert(request.text, into: draft).text
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { droppedAt = Date() }
            return
        }
        if let editor = ComposerEditor.active(in: request.window) {
            if editor.hasMarkedText() { editor.unmarkText() }
            let edit = DropPlacement.replacement(of: request.text, in: editor.string, selection: editor.selectedRange())
            editor.insertText(edit.piece, replacementRange: edit.range)
        } else {
            let placed = DroppedPaths.insert(request.text, into: draft)
            draft = placed.text
            focusField()
            ComposerEditor.place(cursor: placed.cursor, expecting: placed.text, in: request.window)
        }
    }

    /// Confirms, on the composer's top edge, that dropped paths went into the draft behind a question's card.
    @ViewBuilder private var droppedNote: some View {
        if droppedAt != nil {
            FileDropTag(symbol: "checkmark.circle.fill", text: "Ruta añadida · la verás al responder")
                .offset(y: -FileDropTag.overhang).transition(.opacity)
        }
    }

    /// ↑ and ↓ walk what was sent to this tab, like a shell's history.
    private func recall(older: Bool) -> KeyPress.Result {
        guard let text = history.step(older: older, history: session.sentHistory, draft: draft) else { return .ignored }
        draft = text
        return .handled
    }

    // MARK: Slash menu

    /// Works out the menu for a new draft. A message recalled from the history is not a command being typed: the menu
    /// stays out of it, so ↑ goes on walking the history.
    private func refreshSlashMenu(for text: String) {
        let recalled = history.index.map { session.sentHistory.indices.contains($0) && session.sentHistory[$0] == text } ?? false
        var next = slashMenu
        next.update(recalled ? [] : model.completions(for: session, draft: text))
        // Most drafts are ordinary messages that match nothing: the menu stays as it was, and nothing redraws for it.
        if next != slashMenu { slashMenu = next }
    }

    /// A key for the menu: handled while it shows, left to the field otherwise.
    private func slashKey(_ key: SlashMenuState.Key) -> KeyPress.Result {
        switch slashMenu.press(key) {
        case .ignored: return .ignored
        case .handled: return .handled
        case .fill(let text): draft = text; return .handled
        case .send(let text): draft = text; send(); return .handled
        }
    }

    /// Enter: the highlighted command when the menu shows (as Claude does), the draft otherwise.
    private func submit() {
        if slashKey(.enter) == .ignored { send() }
    }

    /// A click on a row fills the field and leaves the cursor in it.
    private func pick(_ command: SlashCommand) {
        draft = SlashMenuState.completion(of: command)
        focusField()
    }

    /// The mirror plus the message on its way, shaped like a prompt so it reads as the user's.
    private var mirrorText: String {
        // The card shows the question and its options, so the mirror ends at what they are about.
        let shown = showsCard ? AgentPrompt.withoutPrompt(session.displayText) : session.displayText
        guard let pending = session.pendingMessage else { return shown }
        return shown + "\n\n> " + pending.replacingOccurrences(of: "\n", with: "\n  ")
    }
}

extension Notification.Name {
    /// A saved clipboard image's path for the selected tab's draft.
    static let nookAttachPath = Notification.Name("NookAttachPath")
}

/// A shell-like walk through sent messages: ↑ goes back, ↓ forward, and past the newest one the
/// draft that was being written comes back.
struct HistoryCursor {
    private(set) var index: Int?
    private var draftBefore = ""

    /// The text for the field, or nil when the key should keep its usual meaning.
    mutating func step(older: Bool, history: [String], draft: String) -> String? {
        guard !history.isEmpty else { return nil }
        if older {
            let next = (index ?? history.count) - 1
            guard next >= 0 else { return draft }
            if index == nil { draftBefore = draft }
            index = next
            return history[next]
        }
        guard let current = index else { return nil }
        if current + 1 < history.count { index = current + 1; return history[current + 1] }
        index = nil
        return draftBefore
    }
    mutating func reset() { index = nil }
}

struct LiveTerminalSurface: NSViewRepresentable {
    var text: String
    /// Claude's transcript gets per-voice styling; any other output stays as it is.
    var transcript = false
    /// The user's chat text size, in points.
    var fontSize = DisplaySettings.defaultChatSize
    /// Which text this is: Claude's conversation ("") or an agent's (its call id). Switching between them keeps where the
    /// reader was in each.
    var contentID = ""
    var onCopy: () -> Void = {}
    func makeNSView(context: Context) -> LiveTerminalScrollView {
        LiveTerminalScrollView()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LiveTerminalScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 410, height: proposal.height ?? 92)
    }
    func updateNSView(_ scroll: LiveTerminalScrollView, context: Context) {
        // The text sits straight on the island's black, so the mirror is always dark. Restyling touches every
        // character, so only a real theme or agent change does it.
        scroll.setTheme(dark: true, transcript: transcript)
        scroll.setFontSize(fontSize)
        scroll.textView.onCopy = onCopy
        scroll.setContent(contentID)
        scroll.setText(text)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    /// The user's chat text size, in points; the live terminal follows it as the text mirror does.
    var fontSize = DisplaySettings.defaultChatSize
    func makeNSView(context: Context) -> ActivityTerminalView { session.terminal }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActivityTerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 410, height: proposal.height ?? 92)
    }
    func updateNSView(_ nsView: ActivityTerminalView, context: Context) {
        // Black like the island, in every system appearance (see `TerminalSession.applyTheme`).
        nsView.appearance = NSAppearance(named: .darkAqua)
        session.applyTheme(nsView)
        session.applyConsoleSize(fontSize)
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 28, height: 28) }
            .nookGlassButton().help(label).accessibilityLabel(label)
    }
}

struct ConnectionView: View {
    @ObservedObject var model: AppModel
    var body: some View { ConnectionContents(model: model, bridge: model.terminalBridge) }
}

private struct ConnectionContents: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: TerminalAppBridge
    @State private var socket = "/tmp/tmux-\(getuid())/default"
    @State private var available: [String] = []
    @State private var searched = false
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Image(systemName: "link").foregroundStyle(accent)
                Text(model.targetAppName.map { "Conectar con \($0)" } ?? "Conecta tu terminal").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                IconButton(symbol: "xmark", label: "Cerrar conexión") { model.connectionSheet = false }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Terminal de macOS · ya abierta").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(bridge.searching ? "Buscando…" : "Buscar") { bridge.discover() }.font(.system(size: 11)).disabled(bridge.searching)
                }
                Text("Elige solo la pestaña que quieres seguir. Tu IA sigue en el mismo proceso; Enter envía el mensaje allí.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = bridge.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if PermissionHelp.opensPermissions(error) { SeePermissionsButton { model.showPermissions() } }
                } else if bridge.windows.isEmpty && !bridge.searching {
                    Text("No hay ventanas de Terminal abiertas.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(bridge.windows) { window in
                    Text(window.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    ForEach(window.tabs) { tab in
                        Button { model.connectTerminalTab(tab) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "terminal").foregroundStyle(accent)
                                Text(tab.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                if tab.selected { Text("activa").font(.system(size: 8)).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "plus").font(.system(size: 11))
                            }.padding(9).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button(model.claudeSignalsEnabled ? "Desactivar avisos de Claude…" : "Activar avisos y actividad de Claude…") { model.enableClaudeSignals() }.font(.system(size: 11)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 9) {
                Text("Compartir desde Nook").font(.system(size: 13, weight: .semibold))
                Text("Copia la conexión y pégala en una terminal libre. Después inicia tu IA: la verás aquí y allí al mismo tiempo.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    if model.selected == nil || model.selected?.isExternal == true { model.create(.shell) }
                    if model.targetAppName != nil { model.controller?.associateTarget() }
                    else { model.copyConnection(); model.connectionSheet = false }
                } label: { Label(model.selected == nil ? "Crear sesión y copiar conexión" : "Copiar conexión de esta sesión", systemImage: "doc.on.doc").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.borderedProminent).tint(accent)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 9) {
                Text("Conectar una sesión existente de tmux").font(.system(size: 13, weight: .semibold))
                HStack {
                    TextField("Ruta del socket de tmux", text: $socket).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    Button("Buscar") { available = model.backend.sessions(socket: socket); searched = true }.font(.system(size: 12))
                }
                if !available.isEmpty {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(available, id: \.self) { name in
                                Button { model.importSession(name: name, socket: socket) } label: {
                                    HStack { Image(systemName: "terminal"); Text(name); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 12)).padding(8)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 90)
                } else if searched { Text("No encontramos sesiones en este socket.").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Text("La conexión directa muestra el texto y el historial reciente de Terminal; se actualiza cada medio segundo. Para conservar colores y controles interactivos completos, usa una sesión compartida. Otras apps de terminal se conectan mediante tmux.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
