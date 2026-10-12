import SwiftUI
import AppKit

/// Nook's own colour (done, on, the connection's dot): the deep mint on the light island and the vivid one on the dark (`NookTheme.swift`).
private let accent = Color.nookMint
/// What the header strip and the collapsed island draw in, which is always on black: the vivid colours, whatever the theme.
private let mintOnBlack = Color(nsColor: NookPalette.mintOnBlack)
private let amberOnBlack = Color(nsColor: NookPalette.amberOnBlack)
private let terracottaOnBlack = Color(nsColor: NookPalette.terracottaOnBlack)
/// Claude's spinner color, so its symbol reads the same as in the terminal. Terracotta for what is drawn (a glyph, a button's fill); the light island
/// has a slightly brighter one for it than for text (`Color.nookTerracotta`, which is deep enough to read).
let claudeSpinner = Color.nookTerracottaFill

struct NookPanel: View {
    @ObservedObject var model: AppModel
    /// Which tab's agents list is open. Shared by the tabs' badges and the list drawn over the tab row; held without
    /// observing it, so a hover over a badge redraws only the list, not the panel.
    @State private var agentList: TabAgentListPresenter
    /// Where the usage card's ask for room goes: to the island's controller, which makes the island as tall as the card wants (`IslandRoomKeeper`).
    private let onRoom: (IslandRoom?) -> Void
    /// Whether anyone can see the island (`IslandSightProbe`): the moving pictures in it pause while nobody can (`\.islandSeen`).
    @State private var seen = true
    /// How wide the tab strip's viewport is, which a tab being carried to its edge scrolls by.
    @State private var tabsWidth: CGFloat = 0

    init(model: AppModel) { self.init(model: model, agentList: TabAgentListPresenter()) }

    /// Previews and render tests pass a presenter with a list already open, and may take the card's ask for themselves.
    init(model: AppModel, agentList: TabAgentListPresenter, onRoom: ((IslandRoom?) -> Void)? = nil) {
        self.model = model
        _agentList = State(initialValue: agentList)
        self.onRoom = onRoom ?? { [weak model] room in model?.controller?.cardAsksForRoom(room) }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black
                // Laid out for the island's size, and never wider than the window it is in: a card drawn wider than its island would be cut at the island's edge.
                content
                    .frame(width: min(model.islandSize.width, geometry.size.width), height: model.islandSize.height, alignment: .top)
                    .opacity(model.islandContentVisible ? 1 : 0)
                    // The question before quitting takes the island: what is under it is out of the pointer's way and VoiceOver's, and a little out of focus.
                    .allowsHitTesting(model.islandContentVisible && !asksToQuit)
                    .accessibilityHidden(asksToQuit)
                    .blur(radius: asksToQuit ? 3 : 0)
                    // The conversation sits straight on the island's own surface, black or paper (`IslandSurface`), and its text takes the theme's colours, so the glass
                    // cards that float over it are always fit to be glass.
                    .environment(\.nookDarkBackdrop, true)
                HStack {
                    CatIcon(color: .white, animated: model.animations, working: model.working, look: model.pet.look, asleep: model.petBedtime.isAsleep).frame(width: 24, height: 24).scaleEffect(0.6)
                    Spacer()
                    // Under the content while it shows (opacity 0): its dots wave only while it is the one on show.
                    ActivityGlyph(working: model.working, unread: model.unreadCount, animated: model.animations, glyph: model.activityGlyph, live: !model.islandContentVisible)
                        .overlay(alignment: .topTrailing) { AgentCountBadge(running: model.runningSubagents).offset(x: 4, y: -1.5) }
                }.padding(.horizontal, 8)
                    // The window keeps its expanded size; the collapsed cat sits where the notch's wings are.
                    .frame(width: model.controller?.compactFrame.width ?? geometry.size.width, height: model.neckHeight)
                    .environment(\.colorScheme, IslandSurface.headerScheme)
                    .opacity(model.islandContentVisible ? 0 : 1)
                    .allowsHitTesting(false)
                // "¿Seguro que quieres salir?": over everything, the header's strip included (`QuitPromptView.swift`). It waits for the island's content to be on screen.
                if model.quitPrompt != nil, model.islandContentVisible {
                    QuitPromptView(look: model.pet.look, stay: { model.answerQuit(false) }, quit: { model.answerQuit(true) })
                        .id(model.quitPrompt?.id)
                        .frame(width: min(model.islandSize.width, geometry.size.width), height: model.islandSize.height, alignment: .top)
                        .transition(.opacity)
                }
            }
            // A fade, which Reduce Motion keeps (the card's own spring is the part it drops); nothing at all with the animations off.
            .animation(model.animations ? .easeOut(duration: 0.18) : nil, value: model.quitPrompt)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            // The selected tab's colour on the island's own edge: a hairline inside the outline the island is clipped to.
            .overlay {
                if let selected = model.selected { SelectedIslandRim(session: selected).opacity(model.islandContentVisible ? 1 : 0) }
            }
            .clippedToIslandOutline()
        }
        // The user's theme for everything in the island, and the window's appearance to match it (`NookTheme.swift`).
        .nookTheme(model.display.theme)
        // Whether the buttons and cards move when used: the app's switch for animations (Reduce Motion is read where it is used).
        .nookMotion(model.animations)
        // Nobody can see the island (the screens sleep or are locked, its window is away or covered): what moves by itself in it pauses.
        .environment(\.islandSeen, seen)
        .background(IslandSightProbe(seen: $seen))
        // Esc closes a panel Claude has open, then an agent's conversation goes back to Claude's; only without either does it put
        // the island away.
        .onExitCommand { if !model.dismissPanel(), !model.leaveAgentView() { model.controller?.collapse(force: true) } }
    }

    /// The pane's layout in this island: its size and the user's settings.
    private var paneLayout: PaneLayout { .of(island: model.islandSize, neck: model.neckHeight, settings: model.display) }

    /// The question before quitting is up.
    private var asksToQuit: Bool { model.quitPrompt != nil }

    private var content: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    HeaderPetStage(animated: model.animations, working: model.working, needsAttention: model.unreadCount > 0, pet: model.pet, controller: model.controller)
                        .frame(width: petStageWidth, height: model.neckHeight)
                    Spacer()
                    Button { model.openLatestNotice() } label: { ActivityGlyph(working: model.working, unread: model.unreadCount, animated: model.animations, glyph: model.activityGlyph, live: model.islandContentVisible) }
                        .nookPress(.wiggle).help(model.unreadCount > 0 ? "Ver aviso de la terminal" : "Actividad de la terminal").disabled(model.unreadCount == 0)
                    IconButton(symbol: model.pinned ? "pin.fill" : "pin", label: model.pinned ? "Desfijar panel" : "Mantener abierto") { model.pinned.toggle() }
                    IconButton(symbol: "chevron.up", label: "Recoger panel") { model.controller?.collapse(force: true) }
                }.padding(.horizontal, 12).frame(height: model.neckHeight)
                    // The strip is the notch's black in both themes (`IslandSurface`): what is in it is drawn for black.
                    .environment(\.colorScheme, IslandSurface.headerScheme)
                if model.showsGreeting {
                    GreetingView(model: model).noticeArea().transition(.opacity)
                } else if model.sessions.isEmpty {
                    HomeView(model: model).noticeArea().transition(.opacity)
                } else {
                    // Above the session pane so the recap card it opens receives clicks.
                    sessionTabs.zIndex(1)
                    if let selected = model.selected {
                        SessionPane(model: model, session: selected, growsIsland: true).id(selected.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The usage card says how tall it wants to be, and the island takes that height while the card is open (`IslandRoomKeeper`). Here and not in the pane: the pane
            // goes with its tab, and what the card asked has to be taken back when it does.
            .onPreferenceChange(IslandRoomKey.self) { room in onRoom(room) }
            // The notice hangs, for a few seconds, from the top of the chat area the pane on show reports (`noticeArea`; the welcome reports its own), centred across it.
            .overlayPreferenceValue(NoticeAreaKey.self) { area in NoticeToastLayer(model: model, area: area) }
            if model.connectionSheet {
                // The sheet covers the island, scrim and card: nothing under it claims the pointer.
                Color.black.opacity(0.22).pointerHole()
                    ScrollView { ConnectionView(model: model).padding(18) }.scrollIndicators(.hidden)
                    .nookGlassCard(radius: 22, dim: 0.6, fill: .regularMaterial, stroke: Color.primary.opacity(0.09))
                    .padding(15)
                    .shadow(color: .black.opacity(0.15), radius: 25, y: 10)
            }
        }
        // The island's shell is black; in the light theme the paper is laid into it under the header strip.
        .background { ZStack { Color.black; IslandPaper(neck: model.neckHeight) } }
    }

    private var petStageWidth: CGFloat {
        NotchGeometry.petStageWidth(islandWidth: model.islandSize.width, cutout: model.controller?.notchWidth ?? 180)
    }

    private var sessionTabs: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    SessionTabRow(model: model, sessions: model.sessions, agentList: agentList, scroller: proxy, viewportWidth: tabsWidth)
                }
                .coordinateSpace(name: TabStrip.viewport)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                // A tab that is carried lifts and throws a shadow, which the scroll view would cut at its own edge: it lets what it holds overflow, and the row clips the strip to its
                // own width and a little above and below, with a plain rectangle (a mask or a custom shape would draw the tabs' symbols white).
                .scrollClipDisabled()
                .padding(.vertical, TabStrip.liftRoom).clipped().padding(.vertical, -TabStrip.liftRoom)
            }
            Menu {
                ForEach(SessionKind.allCases, id: \.self) { kind in Button { model.create(kind) } label: { Label(kind.title, systemImage: kind.symbol) } }
                Divider()
                Button { model.showConnections() } label: { Label("Conectar una terminal…", systemImage: "link") }
                Button { chooseFolder() } label: { Label("Nueva terminal en una carpeta…", systemImage: "folder.badge.plus") }
                // What a slip of the ✕ took, or Terminal lost, comes back from here with its name and colour.
                if !model.recentlyClosed.isEmpty {
                    Divider()
                    ForEach(ReopenMenu.entries(model.recentlyClosed)) { entry in Button { model.reopen(entry.tab) } label: { Label(entry.label, systemImage: "arrow.uturn.backward") } }
                }
            } label: {
                // Drawn as the icon buttons beside it are (the secondary ink, the same weight), with the chevron that says a menu opens.
                NookMenuGlyph(motion: .spin, highlight: true) { Image(systemName: "plus").font(.system(size: 12.5, weight: .medium)) } beside: { NookMenuChevron() }
                    .foregroundStyle(Color.nookSecondary).frame(height: 26)
            }
                .nookMenu().help("Nueva pestaña en Terminal").accessibilityLabel("Nueva pestaña")
            if let selected = model.selected {
                ObservedRecapButton(object: selected, id: \.id, recap: \.recap)
                IconButton(symbol: "arrow.up.right.square", label: "Mostrar terminal completa") { model.controller?.focusSession() }
                SessionMenu(model: model, session: selected, signalsEnabled: model.claudeSignalsEnabled)
            }
        }.padding(.horizontal, 15).frame(height: 30)
            // The tabs' agent badges report where they are in this space, and their list opens in it. It is an overlay
            // of the row because the tabs' scroll view would clip a card hanging from one of them.
            .coordinateSpace(name: TabAgentListPresenter.space)
            .overlay(alignment: .topLeading) {
                TabAgentListHost(presenter: agentList, sessions: model.sessions, containerWidth: model.islandSize.width,
                                 animated: model.animations, width: paneLayout.tabListWidth, maxHeight: paneLayout.tabListMaxHeight,
                                 onOpen: { session, agent in
                    // A click on an agent's row enters its conversation, and one on a shell's its output; the list has done its job.
                    agentList.close()
                    model.openAgent(agent, in: session)
                }, onOpenShell: { session, shell in
                    agentList.close()
                    model.openShell(shell, in: session)
                })
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
        model.capturePrivacy.prepare(picker)
        if picker.runModal() == .OK, let url = picker.url { model.create(.shell, directory: url.path) }
    }
}

extension EnvironmentValues {
    /// The pointer is over the tab row. The tabs do not get narrower while it is (`SessionTab`): a badge that goes, or a title that
    /// shortens, would slide the close button out from under a pointer that was on its way to something else.
    var nookTabRowHeld: Bool {
        get { self[NookTabRowHeldKey.self] }
        set { self[NookTabRowHeldKey.self] = newValue }
    }
}

private struct NookTabRowHeldKey: EnvironmentKey { static let defaultValue = false }

/// The tabs, side by side, and the dragging of a tab along them (`TabStrip.swift` says how it is done). The row follows the pointer itself, so that going onto it or off it redraws
/// the row and not the whole panel.
///
/// Pressing a tab and moving the pointer a few points picks it up: it lifts, follows the pointer, and the tabs it passes slide aside, each in its own spring, while the model's order
/// follows live (`AppModel.moveSession`). Let go, it settles into its place. A click that does not move is a click (the tab's own button takes it), and a drag changes no
/// selection. With Reduce Motion, or the animations off, the tab still follows the pointer and the order still changes, but nothing lifts, springs or slides.
private struct SessionTabRow: View {
    let model: AppModel
    var sessions: [TerminalSession]
    var agentList: TabAgentListPresenter
    /// To scroll the strip when a tab is carried to its edge, and how wide the strip's viewport is.
    var scroller: ScrollViewProxy?
    var viewportWidth: CGFloat = 0
    /// The tab being carried, and the order the row shows while one is (the order the tabs had when it was picked up).
    @State private var carry: TabCarry?
    @State private var frozen: [String]?
    /// Each tab's width, as it told it, and where the strip starts in the viewport (it moves as the strip scrolls).
    @State private var widths: [String: CGFloat] = [:]
    @State private var origin: CGFloat = 0
    @State private var settling: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var moves: Bool { model.animations && !reduceMotion }
    private static let spring = Animation.spring(response: 0.3, dampingFraction: 0.78)
    private static let lift = Animation.spring(response: 0.22, dampingFraction: 0.7)
    /// How long a tab takes to settle into its place before the row follows the model's order again.
    private static let settleTime = 0.45

    /// The tabs as the row shows them.
    private var shown: [TerminalSession] {
        guard let frozen else { return sessions }
        return frozen.compactMap { id in sessions.first { $0.id == id } }
    }
    private func width(of session: TerminalSession) -> CGFloat { widths[session.id] ?? TabStrip.assumedWidth }

    var body: some View {
        let list = shown
        let tabWidths = list.map(width(of:))
        let origins = TabStrip.origins(of: tabWidths)
        let shifts = carry.map { TabStrip.shifts(widths: tabWidths, from: $0.from, to: $0.to) } ?? []
        HStack(spacing: TabStrip.spacing) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, session in
                let carried = carry?.id == session.id
                let lifted = carried && carry?.released == false
                // How far the tab stands from where it is laid out: where the pointer holds it, or aside to make room.
                let dx: CGFloat = carried ? (carry.map { $0.minX - origins[min($0.from, origins.count - 1)] } ?? 0) : (index < shifts.count ? shifts[index] : 0)
                SessionTab(model: model, session: session, agentList: agentList)
                    .scaleEffect(lifted && moves ? 1.045 : 1)
                    .shadow(color: Color.nookShadow(lifted && moves ? 0.45 : 0), radius: lifted && moves ? 7 : 0, y: lifted && moves ? 3 : 0)
                    .animation(moves ? Self.lift : nil, value: lifted)
                    .offset(x: dx)
                    .zIndex(carried ? 2 : 0)
                    .animation(lifted || !moves ? nil : Self.spring, value: dx)
                    .id(session.id)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[session.id] = $0 }
                    // High priority: once the pointer has moved a few points it is a drag, and the tab's own button does not also take it as a click (nothing selects).
                    .highPriorityGesture(carryGesture(session.id))
                    .transition(moves ? .asymmetric(insertion: .scale(scale: 0.8, anchor: .leading).combined(with: .opacity), removal: .scale(scale: 0.85).combined(with: .opacity)) : .identity)
            }
        }
        // Tabs that come and go (a new session, a ✕) take their places with a spring too; not while one is carried, which moves them itself.
        .animation(moves && carry == nil ? Self.spring : nil, value: list.map(\.id))
        .modifier(TabRowPointer())
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TabStrip.viewport)).minX } action: { origin = $0 }
        // The strip scrolled under a tab that is carried: it keeps to the pointer.
        .onChange(of: origin) { _, _ in
            if let carry, !carry.released { carryMoved(carry.id, pointer: carry.pointer) }
        }
        // A tab came or went while one was carried: the drag ends where it is.
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let frozen, Set(frozen) != Set(ids) { cancelCarry() }
        }
        // The island let go of the drag (no button is down, or it was put away).
        .onChange(of: model.tabDragInProgress) { _, now in
            if !now, let carry, !carry.released { carryEnded(carry.id) }
        }
        .onDisappear { if carry != nil { cancelCarry() } }
        // While a tab is carried to the edge of the strip, the strip scrolls toward the tabs beyond it, a step at a time.
        .task(id: carry?.released == false ? carry?.id : nil) {
            guard carry?.released == false else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TabStrip.scrollEvery))
                if !Task.isCancelled { scrollStep() }
            }
        }
    }

    // MARK: Carrying

    private func carryGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: TabStrip.dragThreshold, coordinateSpace: .named(TabStrip.viewport))
            .onChanged { value in carryMoved(id, pointer: value.location.x, start: value.startLocation.x) }
            .onEnded { _ in carryEnded(id) }
    }

    /// The pointer is at `pointer` (in the viewport's coordinates); `start` is where it first pressed, given the first time.
    private func carryMoved(_ id: String, pointer: CGFloat, start: CGFloat? = nil) {
        if carry?.released == true { finishSettling() }
        let list = shown
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let tabWidths = list.map(width(of:))
        var state: TabCarry
        if let current = carry, current.id == id {
            state = current
        } else {
            // Picked up: the row holds the order the tabs have now until it is let go.
            guard let start else { return }
            let origins = TabStrip.origins(of: tabWidths)
            state = TabCarry(id: id, from: index, to: index, grab: (start - origin) - origins[index], minX: origins[index], pointer: pointer)
            frozen = list.map(\.id)
            model.tabDragInProgress = true
            agentList.close()
        }
        state.pointer = pointer
        state.minX = TabStrip.clamped(minX: (pointer - origin) - state.grab, width: tabWidths[state.from], content: TabStrip.contentWidth(of: tabWidths))
        // The place it takes in the order, now: it passes a neighbour once its leading edge has crossed that neighbour's middle.
        let next = TabStrip.target(of: state.to, minX: state.minX, widths: TabStrip.moved(tabWidths, from: state.from, to: state.to))
        if next != state.to {
            state.to = next
            // The model's order is the shown order with the carried tab at `next`. The row does not follow it until the tab is let go.
            model.moveSession(id, to: next)
        }
        carry = state
    }

    /// The tab is let go: it slides into its place (the pointer's, or the one it was given), and then the row follows the model's order again.
    private func carryEnded(_ id: String) {
        guard var state = carry, state.id == id, !state.released else { return }
        model.tabDragInProgress = false
        let tabWidths = shown.map(width(of:))
        state.released = true
        state.minX = TabStrip.origins(of: TabStrip.moved(tabWidths, from: state.from, to: state.to))[min(state.to, max(0, tabWidths.count - 1))]
        guard moves else {
            carry = state
            finishSettling()
            return
        }
        withAnimation(Self.spring) { carry = state }
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .seconds(Self.settleTime))
            if !Task.isCancelled { finishSettling() }
        }
    }

    /// The tab sat in its place: the row shows the model's order, which is the one it has been showing, with nothing moved aside, and nothing animates in doing so.
    private func finishSettling() {
        settling?.cancel(); settling = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { frozen = nil; carry = nil }
    }

    private func cancelCarry() {
        if model.tabDragInProgress { model.tabDragInProgress = false }
        finishSettling()
    }

    /// One step of the strip's scrolling: when the carried tab is at an edge of the viewport and there are tabs beyond it, the nearest of them is brought into view.
    private func scrollStep() {
        guard let carry, !carry.released, let scroller, viewportWidth > 0 else { return }
        let list = shown
        let tabWidths = list.map(width(of:))
        let origins = TabStrip.origins(of: tabWidths)
        let content = TabStrip.contentWidth(of: tabWidths)
        let leading = carry.minX + origin, trailing = leading + tabWidths[min(carry.from, tabWidths.count - 1)]
        let direction = TabStrip.scrollDirection(leading: leading, trailing: trailing, viewport: viewportWidth, canScrollBack: origin < -1, canScrollForward: origin + content > viewportWidth + 1)
        guard direction != 0 else { return }
        let hidden = list.indices.filter { index in
            let left = origins[index] + origin
            return direction < 0 ? left < -1 : left + tabWidths[index] > viewportWidth + 1
        }
        guard let target = direction < 0 ? hidden.last : hidden.first else { return }
        // With Reduce Motion (or the animations off) the strip jumps to it instead of gliding.
        withAnimation(moves ? .easeOut(duration: 0.2) : nil) { scroller.scrollTo(list[target].id, anchor: direction < 0 ? .leading : .trailing) }
    }
}

/// Tells the tabs when the pointer is on their row (`\.nookTabRowHeld`). It is a modifier of its own and not a part of the row: SwiftUI keeps a hover's
/// callback in its responders until the next event reaches them, and a callback written in the row holds the row, with its whole list of tabs, a
/// closed one included. This one holds only the pointer's state.
private struct TabRowPointer: ViewModifier {
    @State private var pointerOnTabs = false

    func body(content: Content) -> some View {
        content.onHover { pointerOnTabs = $0 }.environment(\.nookTabRowHeld, pointerOnTabs)
    }
}

/// Not private so the layout tests can mount one.
struct SessionTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSession
    var agentList: TabAgentListPresenter
    /// What the tab's agent badge shows. It changes when an agent starts or ends, not when a counter ticks.
    @StateObject private var agents: TabAgentTracker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nookTabRowHeld) private var held
    /// The tab's width as last laid out, and the widest it has been since the pointer came onto the row (0 while it is not on it). A tab
    /// is never narrower than that while the pointer is there: what leaves it (the agent badge after its minute, a shorter title) becomes
    /// room between its title and the close button, so the button stays where the pointer found it. The room goes when the pointer does.
    @State private var width: CGFloat = 0
    @State private var heldWidth: CGFloat = 0

    init(model: AppModel, session: TerminalSession, agentList: TabAgentListPresenter) {
        self.model = model
        self.session = session
        self.agentList = agentList
        _agents = StateObject(wrappedValue: TabAgentTracker(session: session))
    }

    /// Claude's own spinner says the tab's AI works, read from the tab's screen. Neither of the other signals will do: `busy` is
    /// Terminal's "a process is running", which is Claude itself the whole time it is open, and a hook's `taskState` of "working"
    /// is only cleared for a tab that is out of sight (`AppModel.raiseAlert`). Only a Claude tab has a spinner to read.
    private var working: Bool { session.agentStatus?.working == true }

    var body: some View {
        // What SwiftUI builds later or keeps on to (the context menu, the popover, the buttons' actions) is given the model, the tab's id and a weak
        // reference to the tab, never `self`, which holds the tab: SwiftUI's graph can keep such a closure after the tab is closed, and with it the
        // tab's terminal.
        let model = self.model, agentList = self.agentList, id = session.id, soundOn = session.alertSoundOn
        HStack(spacing: 0) {
            Button { [weak session = self.session] in if let session { model.select(session) } } label: {
                HStack(spacing: 5) {
                    // The tab's icon, in its colour; it moves while the tab's AI works, and is still with the animations off or the island collapsed.
                    TabIconView(icon: session.icon, color: session.tint.color, working: working, animated: model.animations && model.islandContentVisible)
                        // The tab has no press of its own (it may be the start of a drag): the tab that is chosen answers instead, its icon hopping once.
                        .clickMotion(.pop, whenBecomes: model.selectedID == session.id)
                        .accessibilityHidden(true)
                    Text(session.displayTitle).font(.system(size: 10, weight: model.selectedID == session.id ? .semibold : .regular)).lineLimit(1)
                    // This tab's alerts are silent (`AppModel.setAlertSound`): a small slashed speaker, in the tab's own colour, quiet.
                    if !session.alertSoundOn {
                        Image(systemName: "speaker.slash.fill").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(session.tint.color.opacity(0.7))
                            .help(SoundCopy.mutedTab).accessibilityLabel(SoundCopy.mutedTab)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    if session.unreadNotice != nil { Image(systemName: "bell.fill").font(.system(size: 8)).foregroundStyle(session.tint.color) }
                    // A question waits in a tab that is not the one on screen.
                    if let prompt = session.prompt, prompt.kind != .selector, model.selectedID != session.id {
                        Image(systemName: "questionmark.circle.fill").font(.system(size: 8.5)).foregroundStyle(claudeSpinner).help("\(session.agent?.title ?? "La IA") espera tu respuesta")
                    }
                }.padding(.leading, 8).padding(.vertical, 5)
            // No press of its own: pressing a tab may be the start of dragging it, and a tab that sank under the pointer would not be the one that lifts.
            }.buttonStyle(NookPressStyle(motion: .none, depth: PressDepth.flat))
                // What the tab is, and that it can be dragged: nothing else on screen says so.
                .help((session.recap.map { "Resumen de Claude: " + $0 } ?? session.displayTitle) + "\n" + TabStripCopy.dragHint)
                // The icon is hidden from VoiceOver; what it says (the AI works) goes here.
                .accessibilityValue(working ? "trabajando" : "")
                // Dragging is the pointer's; VoiceOver and the keyboard move the tab a place at a time.
                .accessibilityAction(named: TabStripCopy.moveLeft) { model.moveSession(id, by: -1) }
                .accessibilityAction(named: TabStripCopy.moveRight) { model.moveSession(id, by: 1) }
            // The tab's Claude has subagents: working ones show, and the list opens under the tab row.
            if agents.state.kind != nil {
                TabAgentIndicator(sessionID: session.id, state: agents.state, animated: model.animations && model.islandContentVisible, presenter: agentList)
                    .padding(.leading, 4)
            }
            // The room a held tab keeps (see `heldWidth`) is here, so the close button stays where it was.
            Spacer(minLength: 0)
            Button { [weak session = self.session] in if let session { model.close(session) } } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .semibold)).frame(width: 16, height: 22) }
                .nookPress(.spin).foregroundStyle(Color.nookSecondary).help("Cerrar esta pestaña en Nook; conservar la terminal original")
                .accessibilityLabel("Cerrar pestaña")
                .padding(.leading, 4)
        }.padding(.trailing, 3)
            .frame(minWidth: heldWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                width = new
                if held { heldWidth = max(heldWidth, new) }
            }
            .onChange(of: held) { _, now in
                // Going away, the room closes smoothly (the tab narrows to what it needs); coming onto the row it is simply kept.
                withAnimation(now || reduceMotion || !model.animations ? nil : .easeOut(duration: 0.18)) { heldWidth = now ? width : 0 }
            }
            // A list never outlives its badge or its tab.
            .onChange(of: agents.state.kind) { _, kind in if kind == nil { agentList.close(ifShowing: id) } }
            .onDisappear { agentList.close(ifShowing: id) }
            .foregroundStyle(model.selectedID == session.id ? Color.primary : Color.nookSecondary)
            .nookGlassSurface(in: RoundedRectangle(cornerRadius: 8), tint: session.tint.color.opacity(0.35), isActive: model.selectedID == session.id, dim: 0.45,
                              fill: session.tint.color.opacity(model.selectedID == session.id ? 0.19 : 0.065), stroke: nil)
            // A new colour fades in, like the rest of the island's.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: session.tint)
            .contextMenu {
                Button { model.editingSessionID = id } label: { Label("Renombrar y cambiar color…", systemImage: "paintpalette") }
                Button { [weak session = self.session] in if let session { model.setAlertSound(!soundOn, for: session) } } label: {
                    Label(SoundCopy.tabToggle(on: soundOn), systemImage: soundOn ? "speaker.slash" : "speaker.wave.2")
                }
                Button { [weak session = self.session] in if let session { model.close(session) } } label: { Label("Cerrar pestaña de Nook", systemImage: "xmark") }
            }
            // The slashed speaker comes and goes with a pop.
            .animation(reduceMotion || !model.animations ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: soundOn)
            .popover(isPresented: Binding(get: { model.editingSessionID == id }, set: { if !$0 { model.editingSessionID = nil } }), arrowEdge: .bottom) { [weak session = self.session] in
                if let session {
                    TabEditor(model: model, session: session)
                        .background(CapturePrivacyAttachment(privacy: model.capturePrivacy))
                }
            }
    }
}

/// The popover that renames a tab and gives it a colour and an icon. Not private so the render tests can show it.
///
/// The name is written beside a preview of the tab's mark (the icon, in the colour chosen, moving as it will while the AI works), the colours are a grid of
/// swatches in the shade each has in the island's theme, and the icons a grid of chips drawn in the colour just chosen, so the two are judged together. The
/// popover follows the island's theme, not only macOS's: it is a window of its own.
struct TabEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TerminalSession
    @State private var name = ""
    @State private var tint: TabTint = .mint
    @State private var icon: TabIcon = .dot

    /// The editor's content is as wide as the grid of icons.
    static let contentWidth = TabIconPicker.width
    private var animated: Bool { model.animations && model.islandContentVisible }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tu pestaña de Nook").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                // What the tab will wear: the icon in the colour chosen, moving as it does while the AI works.
                TabIconView(icon: icon, color: tint.color, size: 16, working: true, animated: animated)
                    .frame(width: 30, height: 26)
                    .background(tint.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                TextField("Nombre", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { SectionLabel("Color"); Spacer(); Text(tint.name).font(.system(size: 10)).foregroundStyle(Color.nookSecondary) }
                TabTintPicker(selection: $tint)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { SectionLabel("Icono"); Spacer(); Text(icon.title).font(.system(size: 10)).foregroundStyle(Color.nookSecondary) }
                // The icons are drawn in the colour just chosen, so the two are judged together.
                TabIconPicker(selection: $icon, tint: tint, animated: animated)
                Text("El icono se mueve mientras la IA trabaja.").font(.system(size: 9)).foregroundStyle(Color.nookSecondary)
            }
            soundRow
            HStack {
                Text("La pestaña original conserva su nombre.").font(.system(size: 9)).foregroundStyle(Color.nookSecondary)
                Spacer()
                Button("Listo", action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: Self.contentWidth + 32)
            .onAppear { name = session.displayTitle; tint = session.tint; icon = session.icon }
            // The editor is a window of its own: it takes the island's theme (and so its look follows the user's choice, not only macOS's).
            .nookTheme(model.display.theme)
    }
    private func save() { model.customize(session, title: name, tint: tint, icon: icon); model.editingSessionID = nil }

    /// This tab's own switch for the alerts' sound (`AppModel.setAlertSound`): it takes effect as it is switched, like the rest of Nook's switches, and is not part of what «Listo» saves.
    private var soundRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: session.alertSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.system(size: 12))
                .foregroundStyle(session.alertSoundOn ? tint.ink : Color.nookTertiary).frame(width: 18)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(SoundCopy.title).font(.system(size: 11, weight: .medium))
                Text(model.alertSound.enabled ? SoundCopy.editorDetail : SoundCopy.editorOff).font(.system(size: 9)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle(SoundCopy.title, isOn: Binding(get: { session.alertSoundOn }, set: { model.setAlertSound($0, for: session) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(tint.accent)
        }
        .padding(.top, 2)
        .animation(model.animations ? .easeOut(duration: 0.16) : nil, value: session.alertSoundOn)
    }
}

/// The tab's colours as a grid of swatches, each in the shade it has on the island's theme, in the order of the colour wheel. The chosen one carries a check
/// and a ring; each says its name to the pointer and to VoiceOver.
struct TabTintPicker: View {
    @Binding var selection: TabTint
    @Environment(\.colorScheme) private var scheme

    static let columns = 6
    static let spacing: CGFloat = 8
    static var swatchWidth: CGFloat { (TabIconPicker.width - CGFloat(columns - 1) * spacing) / CGFloat(columns) }

    var body: some View {
        let tints = TabTint.pickerOrder
        let rows = stride(from: 0, to: tints.count, by: Self.columns).map { Array(tints[$0..<min($0 + Self.columns, tints.count)]) }
        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.self) { color in
                        let chosen = selection == color
                        Button { selection = color } label: {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.color)
                                .frame(width: Self.swatchWidth, height: 24)
                                .overlay {
                                    if chosen {
                                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                                            .foregroundStyle(scheme == .dark ? Color.black.opacity(0.72) : Color.white)
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 10.5, style: .continuous).strokeBorder(chosen ? Color.nookText.opacity(0.85) : .clear, lineWidth: 1.5).padding(-3))
                        }.nookPress(.pop).help(color.name).accessibilityLabel(color.name).accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// What the connection sheet says of a saved session. It observes the session, so a renamed tab reads with its new name while the sheet
/// is open (the island is not redrawn on a timer that would catch it up).
private struct SavedSessionNote: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        Text("«\(session.displayTitle)» es una sesión de tmux que Nook guardó antes. Copia su comando de conexión y pégalo en otra terminal para verla también allí.")
            .font(.system(size: 12)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The selected tab's "…" menu. It observes the tab, so what it offers follows the tab's own state (an agent that starts in it brings the
/// paste of an image) and not only the model's changes: the island is not redrawn on a timer that would catch it up.
private struct SessionMenu: View {
    let model: AppModel
    @ObservedObject var session: TerminalSession
    var signalsEnabled: Bool

    var body: some View {
        let model = self.model, session = self.session
        Menu {
            if !session.isExternal {
                Button { model.controller?.openInTerminal() } label: { Label("Abrir en Terminal de macOS", systemImage: "arrow.up.right.square") }
                Button { model.copyConnection() } label: { Label("Copiar conexión", systemImage: "doc.on.doc") }
            }
            Button { model.showConnections() } label: { Label("Conectar otra terminal…", systemImage: "link") }
            Button { model.enableClaudeSignals() } label: {
                Label(signalsEnabled ? "Desactivar avisos de Claude…" : "Activar avisos de Claude…", systemImage: signalsEnabled ? "bell.slash" : "bell.badge")
            }
            // This tab's own sound for the alerts; the rest of the sound's settings are in Ajustes.
            Button { model.setAlertSound(!session.alertSoundOn, for: session) } label: {
                Label(SoundCopy.tabToggle(on: session.alertSoundOn), systemImage: session.alertSoundOn ? "speaker.slash" : "speaker.wave.2")
            }
            Divider()
            Button { model.editingSessionID = session.id } label: { Label("Renombrar y cambiar color…", systemImage: "paintpalette") }
            Button { model.close(session) } label: { Label("Cerrar pestaña de Nook", systemImage: "xmark") }
            if session.record.ownsSession {
                Divider()
                Button(role: .destructive) { model.terminate(session) } label: { Label("Terminar sesión…", systemImage: "stop.circle") }
            }
            if session.drivesAgent {
                Button { model.pasteImage(into: session) { NotificationCenter.default.post(name: .nookAttachPath, object: $0) } } label: {
                    Label("Pegar imagen del portapapeles (⌘V o ⌃V)", systemImage: "photo.on.rectangle")
                }
            }
            if session.isExternal { Button { model.copyDiagnostics(session) } label: { Label("Copiar diagnóstico", systemImage: "stethoscope") } }
            Divider()
            Button { model.controller?.toggleSettings(tab: .island) } label: { Label("Ajustes…", systemImage: "gearshape") }
            Button { model.controller?.toggleSettings(tab: .sound) } label: { Label("Sonido de avisos…", systemImage: "speaker.wave.2") }
            Button { model.controller?.toggleSettings(tab: .permissions) } label: { Label("Permisos…", systemImage: "lock.shield") }
            Divider()
            // Quitting closes only Nook: terminals, tmux sessions and their processes keep running.
            Button { NSApp.terminate(nil) } label: { Label("Salir de Nook", systemImage: "power") }
        } label: {
            NookMenuGlyph(motion: .squeeze, highlight: true) { Image(systemName: "ellipsis").font(.system(size: 12.5, weight: .medium)) } beside: { NookMenuChevron() }
                .foregroundStyle(Color.nookSecondary).frame(height: 26)
        }.nookMenu().help("Más opciones de esta pestaña").accessibilityLabel("Más opciones de la pestaña")
    }
}

private struct ActivityGlyph: View {
    var working: Bool
    var unread: Int
    var animated: Bool
    /// The symbol Claude's spinner shows right now; it changes with the terminal, not on a timer.
    var glyph: String?
    /// This copy is the one on show (the header's while the content shows, the collapsed row's while it does not): only then do its dots
    /// wave. Both are always there, one at opacity 0, and a timeline under opacity 0 still renders every frame.
    var live = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandSeen) private var seen
    var body: some View {
        if unread > 0 {
            Image(systemName: "bell.badge.fill").font(.system(size: 11)).foregroundStyle(amberOnBlack).frame(width: 20, height: 20)
        } else if working, let glyph {
            Text(glyph).font(.system(size: 14, weight: .bold)).foregroundStyle(terracottaOnBlack).frame(width: 20, height: 20)
        } else if working {
            // The dots wave by themselves, eight times a second: drawn by a view of their own (`WorkingDotsView`), so a frame repaints
            // only them and not the whole island (a `TimelineView` here renders every frame through the island's hosting view).
            WorkingDots(waving: animated && !reduceMotion, running: live && seen).frame(width: 20, height: 20)
        } else { Circle().fill(mintOnBlack.opacity(0.65)).frame(width: 4, height: 4).frame(width: 20, height: 20) }
    }
}

/// The three working dots in SwiftUI: the AppKit view that draws them, told whether they wave and whether their clock runs, and in what colour (the header's
/// mint unless told; the home's cards draw them in their own).
struct WorkingDots: NSViewRepresentable {
    var waving: Bool
    var running: Bool
    var color: NSColor = WorkingDotsView.tint
    func makeNSView(context: Context) -> WorkingDotsView { WorkingDotsView(frame: NSRect(x: 0, y: 0, width: WorkingDotsView.side, height: WorkingDotsView.side)) }
    func updateNSView(_ view: WorkingDotsView, context: Context) {
        view.color = color
        view.show(waving: waving, running: running)
    }
}

/// Three mint dots side by side in a 20 pt box, each rising and falling two points on a wave a second long, a step apart, as they always
/// did; drawn from the clock (each frame is the moment's), eight times a second while `running` and not at all otherwise. They take no clicks
/// and are no element of their own for VoiceOver.
final class WorkingDotsView: NSView {
    static let side: CGFloat = 20
    /// The frame rate the dots' `TimelineView` had.
    static let interval = 0.12
    /// The island's mint on black (they stand in the header strip), as the SwiftUI views around them use it.
    static let tint = NookPalette.mintOnBlack
    private(set) var waving = true
    private(set) var running = false
    var color: NSColor = WorkingDotsView.tint { didSet { if color != oldValue { needsDisplay = true } } }
    private lazy var ticker = PetTicker { [weak self] in self?.needsDisplay = true }
    /// Seconds between frames right now: 0 while they hold still.
    var frameInterval: TimeInterval { ticker.interval }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }

    func show(waving: Bool, running: Bool) {
        // A change of form, or back in sight: the picture of this moment at once.
        if waving != self.waving || (running && !self.running) { needsDisplay = true }
        self.waving = waving; self.running = running
        schedule()
    }

    private func schedule() {
        guard window != nil, running, waving else { ticker.pause(); return }
        ticker.run(every: Self.interval)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        Self.paint(at: waving ? Date().timeIntervalSinceReferenceDate : nil, color: color, in: cg)
    }

    /// The dots at `time` (nil: level), in a 20 pt box whose y points down: three 3 pt dots two points apart, centred, as the `HStack`
    /// of circles they replace laid them out.
    static func paint(at time: Double?, color: NSColor = tint, in cg: CGContext) {
        cg.setFillColor(color.cgColor)
        for i in 0..<3 {
            let rise = time.map { CGFloat(sin($0 * 6 + Double(i)) * 2) } ?? 0
            cg.fillEllipse(in: CGRect(x: 3.5 + CGFloat(i) * 5, y: 8.5 + rise, width: 3, height: 3))
        }
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
    /// What was written as the answer to a dialog's text field and is on its way: the bar over the field says so until the screen shows how the dialog took it.
    @State private var sentAnswer: String?
    /// ↵ was pressed with nothing written as the answer: the line under the field says what is missing for a moment.
    @State private var answerNudged = false
    /// The notes written in the card of a question with a preview, for that question (`WrittenNotes`): the card is rebuilt each time it comes back (folded away with its chevron,
    /// a redraw that blinks the dialog off for a moment), and the notes must be there when it does.
    @State private var writtenNotes: WrittenNotes?
    /// When dropped paths went into the draft while a question's card stood in the composer's place (the tag says so for a moment).
    @State private var droppedAt: Date?
    /// Bumped to put the keyboard in the message field (see `ComposerField.focusRequest`).
    @State private var focusRequest = 0
    /// The composer's height as laid out now: the field grows with its text, and what floats above it (the "/" menu, the
    /// agents' list) follows.
    @State private var composerHeight: CGFloat
    /// The panel Claude has open (/usage, /status, /config, /mcp…), as the island shows it. It follows `session.panel`, but a
    /// reading that misses the panel for a moment (a screen caught while Claude redraws) does not make it blink away: it
    /// leaves only once the screen has stopped showing it for `ClaudePanelHold.delay`.
    @State private var shownPanel: String?
    /// The welcome of a fresh Claude shows Claude's suggestion as its chip (`ClaudeWelcomeSuggestionKey`): the field's placeholder does not say it again.
    @State private var welcomeShowsSuggestion = false
    /// Bumped to put the keyboard in the panel's card (see `PanelKeyCatcher`).
    @State private var panelFocus = 0
    /// Images attached to the message (pasted from the clipboard): their files, shown as thumbnails above the field. They are not in the
    /// draft; their paths join the message when it is sent. What each tab holds is kept in `MessageAttachments`.
    @State private var attachments: [String]
    /// Claude's effort levels are out in the composer's bottom row (where the chip is), the level the keyboard is on, and the one just
    /// asked for: shown on the chip as Claude's until its screen says what it really did.
    @State private var effortOpen: Bool
    @State private var effortHighlight = ClaudeEffort.high
    @State private var effortAsked: ClaudeEffort?
    /// The list of Claude's models is open over the bottom row (where the model chip is), the row of it the keyboard is on (an index into the list's
    /// rows, the last being the one that opens Claude's picker), and whether a model was just chosen and Claude has not answered yet: the chip stays
    /// lit until its banner or its answer to /model names the new one.
    @State private var modelMenuOpen: Bool
    @State private var modelHighlight: Int?
    @State private var modelAsked = false
    /// Which sessions' startup warnings were dismissed. Observed, so the notice goes the moment it is dismissed.
    @ObservedObject private var dismissals: RecapSeenStore
    /// Screen vision, observed here (the model does not forward it): the composer's toggle appears and disappears with its setting, and the row says while a message waits for its picture.
    @ObservedObject private var vision: ScreenVision
    /// The warnings' card is open when the pane opens; previews and render tests use it.
    private let warningsOpen: Bool
    /// The island grows for the usage card (`IslandRoomKeeper`): the card is drawn for room to spare and says how tall it wants to be. The island's panel says so;
    /// a pane mounted on its own (previews, render tests) has no island to grow.
    private let growsIsland: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The island's theme, which the mirror and the user's colours are dressed for.
    @Environment(\.colorScheme) private var colorScheme

    /// Where the prompt card stands when the pane opens; previews and render tests use it.
    enum PromptCardState { case options, typing, hidden }

    /// `draft`, `keysOpen`, `promptState`, `dictationError`, `attachments`, `warningsOpen`, `modelMenuOpen`, `modelHighlight`, `sentAnswer`, `answerNudged` and `promptNotes` seed
    /// the field, the key strip, the prompt card, the status line's dictation error, the attached images, the startup warnings' card, the list of models, the
    /// answer on its way, the hint of an empty ↵ and the notes written on a question with a preview; previews and render tests use them. `dismissals`
    /// is where the warnings' dismissals are kept (tests give it a memory of its own).
    init(model: AppModel, session: TerminalSession, draft: String? = nil, keysOpen: Bool = false, promptState: PromptCardState = .options, dictationError: String? = nil,
         attachments: [String]? = nil, effortOpen: Bool = false, warningsOpen: Bool = false, dismissals: RecapSeenStore = .startupWarnings,
         modelMenuOpen: Bool = false, modelHighlight: Int? = nil, growsIsland: Bool = false, sentAnswer: String? = nil, answerNudged: Bool = false, promptNotes: String? = nil) {
        self.model = model
        self.session = session
        self.warningsOpen = warningsOpen
        self.growsIsland = growsIsland
        _sentAnswer = State(initialValue: sentAnswer)
        _writtenNotes = State(initialValue: promptNotes.map { text in session.prompt.flatMap { WrittenNotes.keeping(text, for: $0.signature) } } ?? WrittenNotesStore.shared.notes(for: session.id))
        _answerNudged = State(initialValue: answerNudged)
        _dismissals = ObservedObject(wrappedValue: dismissals)
        _vision = ObservedObject(wrappedValue: model.screenVision)
        // The autoclosure runs once, for the first pane of this view: the init runs on every redraw, and a controller made out here would be one per redraw.
        _speech = StateObject(wrappedValue: SpeechController(error: dictationError))
        _draft = State(initialValue: draft ?? session.draft)
        _attachments = State(initialValue: attachments ?? MessageAttachments.shared.paths(for: session.id))
        _effortOpen = State(initialValue: effortOpen)
        _modelMenuOpen = State(initialValue: modelMenuOpen)
        _modelHighlight = State(initialValue: modelHighlight)
        _effortHighlight = State(initialValue: session.effort ?? .high)
        _keysOpen = State(initialValue: keysOpen)
        _keysPinned = State(initialValue: keysOpen)
        _cardHiddenFor = State(initialValue: promptState == .hidden ? session.prompt?.signature : nil)
        _typingFor = State(initialValue: promptState == .typing ? session.prompt?.signature : Self.signatureOfChosenField(in: session))
        _composerHeight = State(initialValue: ComposerMetrics.composerHeight(lines: 1, size: model.display.inputSize))
        _shownPanel = State(initialValue: session.mirrorsAgent && session.prompt == nil ? session.panel : nil)
    }

    /// The open dialog's signature when its text field was chosen on the card and no answer went since (`TerminalSession.chosenField`). A pane made while that stands (the
    /// user left the tab and came back) gives the composer its place again, as the click did: the model remembers the choice, and the card must not stand over it.
    private static func signatureOfChosenField(in session: TerminalSession) -> String? {
        guard let prompt = session.prompt, let chosen = session.chosenField, chosen.signature == prompt.signature else { return nil }
        return chosen.signature
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
        /// The band between the bar over the field and the field, while the composer answers a text field (the bar already gives the room the
        /// plain composer's top band does).
        static let answerTopPadding: CGFloat = 3
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
                if session.mirrorsAgent { DispatchQueue.main.async { focusField() } }
            }
            // Claude's panel takes the keyboard while it is open and gives it back to the field when it is gone.
            .onChange(of: session.panel, initial: true) { _, found in if let found { shownPanel = found } }
            .task(id: session.panel == nil) {
                guard session.panel == nil, shownPanel != nil else { return }
                // Esc pressed on the panel asked for the closing: it leaves as soon as the screen says it has.
                let asked = session.panelEscapedAt.map { Date().timeIntervalSince($0) < ClaudePanelHold.askedWindow } ?? false
                try? await Task.sleep(for: .seconds(asked ? ClaudePanelHold.afterEsc : ClaudePanelHold.delay))
                if !Task.isCancelled { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { shownPanel = nil } }
            }
            .onChange(of: showsPanel) { _, shows in
                if shows { panelFocus += 1 } else if session.mirrorsAgent { DispatchQueue.main.async { focusField() } }
            }
            // An agent starting in a Nook session turns its terminal into the mirror: the keyboard goes to the field (typing into the
            // terminal that is no longer on show would reach Claude unseen). When it quits the terminal is back and takes it again.
            .onChange(of: session.mirrorsAgent) { _, mirrors in
                if mirrors { focusInput() } else { model.controller?.focusTerminal() }
            }
            // The same question asked again later gets its card again; a redraw that blinks it off for a moment does not count. (The text field chosen on the old
            // one is forgotten by the model after as long, `TerminalSession.chosenFieldGrace`.)
            .task(id: prompt == nil) {
                guard prompt == nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { cardHiddenFor = nil; typingFor = nil; confirmedSendFor = nil; keepNotes(nil) }
            }
            .task(id: followUpHint) {
                guard followUpHint != nil else { return }
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { followUpHint = nil }
            }
            // The answer to a dialog's text field: what is on its way, the hint of an empty ↵, and the composer turning into (or out of) the answer's.
            .modifier(FieldAnswerLifecycle(sentAnswer: $sentAnswer, nudged: $answerNudged, delivering: session.answering, signature: prompt?.signature,
                                           answersField: answersField) { now in
                if now { effortOpen = false; modelMenuOpen = false }
                refreshSlashMenu(for: draft)
            })
            .task(id: droppedAt) {
                guard droppedAt != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { droppedAt = nil } }
            }
            .onChange(of: speech.transcript) { _, text in draft = beforeDictation + (beforeDictation.isEmpty ? "" : " ") + text }
            .onDisappear { speech.stop() }
            .onAppear { if session.mirrorsAgent { focusInput() } }
            .onChange(of: draft) { _, text in session.draft = text }
            .onChange(of: attachments) { _, paths in MessageAttachments.shared.set(paths, for: session.id) }
            // The levels are for choosing, not for typing past: the first word closes them. Keys, a quit Claude or a hidden island do too.
            .onChange(of: draft) { _, text in if !text.isEmpty { effortOpen = false; modelMenuOpen = false } }
            .onChange(of: keysOpen) { _, open in if open { effortOpen = false; modelMenuOpen = false } }
            .onChange(of: session.agent) { _, agent in if agent != .claude { effortOpen = false; effortAsked = nil; modelMenuOpen = false; modelAsked = false } }
            .onChange(of: session.isRunning) { _, running in if !running { effortOpen = false; modelMenuOpen = false } }
            // The list is for choosing while a model can be chosen: Claude starting work, or asking something, takes it away.
            .onChange(of: modelChipBlock) { _, reason in if reason != nil { modelMenuOpen = false } }
            .onChange(of: session.currentModel) { _, _ in modelAsked = false }
            .task(id: modelAsked) {
                // Claude answers /model in a moment, or its picker takes longer to be picked in: either way the chip goes back to what the screen says.
                guard modelAsked else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { modelAsked = false }
            }
            .onChange(of: session.effort) { _, level in if level == effortAsked { effortAsked = nil } }
            .task(id: effortAsked) {
                // Claude answers in a moment, or says the model has no such level: either way the chip goes back to what the screen says.
                guard effortAsked != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { effortAsked = nil }
            }
            .onChange(of: draft, initial: true) { _, text in refreshSlashMenu(for: text) }
            // The "…" menu has no access to the draft; its image fallback arrives as a path.
            .onReceive(NotificationCenter.default.publisher(for: .nookAttachPath)) { note in
                if let path = note.object as? String { attach(path) }
            }
            // Files dropped on the island arrive as their paths, whichever part of it they landed on.
            .onReceive(NotificationCenter.default.publisher(for: .nookDropFiles)) { note in
                if let request = note.object as? FileDropRequest { receiveDrop(request) }
            }
            .onChange(of: model.islandContentVisible) { _, visible in if visible && session.mirrorsAgent { focusInput() }; if !visible { speech.stop(); effortOpen = false; modelMenuOpen = false } }
            // The tab's colour for everything in the pane: the send button, the highlighted rows, the drop outline, the composer's surface.
            .tabTint(session.tint)
    }

    /// Claude's panel in the place of everything else, or the conversation, the composer (or the agent's question in its place)
    /// and what floats over them. The conversation stays where it is under the panel (its text, its scroll, the draft): the panel
    /// only covers it.
    private func pane(_ layout: PaneLayout) -> some View {
        ZStack {
            conversationPane(layout)
                .opacity(showsPanel ? 0 : 1).allowsHitTesting(!showsPanel).accessibilityHidden(showsPanel)
                // Faded out it is still there, and its text views would go on claiming the pointer over the card: they step out of AppKit's
                // way once the fade is over, and are back as the card starts to go.
                .underCover(showsPanel)
            if let panel = shownPanel, showsPanel {
                panelCard(panel).transition(.opacity)
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsPanel)
            // The tip of the control the pointer rests on (`NookTip`), above everything the pane draws. With the list of models open over the row it stays
            // away: the list would be under it.
            .overlayPreferenceValue(NookTipKey.self) { entry in
                NookTipLayer(entry: entry, enabled: model.islandContentVisible && !(modelMenuOpen && showsAgentControls), animated: model.animations)
            }
    }

    /// The panel's card, with the drop feedback and its confirmation: a file dropped meanwhile goes into the draft.
    private func panelCard(_ text: String) -> some View {
        ClaudePanelCard(text: text, fontSize: model.display.chatSize, running: session.isRunning,
                        needsAccessibility: session.isExternal && !DirectKeys.allowed, focusRequest: panelFocus, reading: session.readingPanel, growsIsland: growsIsland,
                        live: session.liveUsage, onKey: { model.press($0, on: session) }, onScroll: { model.scrollPanel(down: $0, on: session) })
            .overlay { FileDropFeedback(state: model.fileDrop, radius: ClaudePanelCard.radius) }
            .overlay(alignment: .top) { droppedNote }
            // The notice hangs from under the panel's toolbar (its keys and «Cerrar»), over the panel's text.
            .noticeArea(below: ClaudePanelCard.toolbarHeight)
            .padding(.horizontal, ClaudePanelCard.paneEdge).padding(.top, ClaudePanelCard.topMargin).padding(.bottom, ComposerMetrics.bottomInset)
    }

    private func conversationPane(_ layout: PaneLayout) -> some View {
        VStack(spacing: 6) {
            // What Claude said as the session started (its banner, and the warnings it printed), in one quiet line over the conversation.
            if let banner = stripBanner(layout) {
                SessionStrip(banner: banner, effort: session.effort, warnings: visibleWarnings, chatSize: model.display.chatSize,
                             islandVisible: model.islandContentVisible, cardWidth: min(StartupWarningsCard.width, max(240, layout.width - 2 * Metrics.edge)),
                             maxBodyHeight: min(320, max(60, layout.height - 56)), initiallyOpen: warningsOpen, keepsOpen: warningsOpen,
                             onDismiss: { dismissals.dismiss(session.startupWarnings, in: session.id) })
                    .padding(.horizontal, Metrics.composerInset)
                    // Above the conversation, so the warnings' card that hangs from it is drawn over the text.
                    .zIndex(1)
            }
            // No card around the conversation: it is plain text on the island's black, like the Claude app.
            // The conversation asks for 40 pt unless a question has the composer's place or its bar is over the field (the card, and the composer that answers it, take what they need).
            conversation.frame(maxWidth: .infinity, minHeight: showsCard || answersField ? 0 : 40, maxHeight: .infinity)
                // A Claude nobody has spoken to yet greets in the conversation's place (`ClaudeWelcome`); the strip takes over once something is said.
                .overlay { welcomeLayer(layout) }
                // Over the composer while it shows: the card of its warnings hangs over what is below it.
                .zIndex(showsWelcome(layout) ? 1 : 0)
                // The notice hangs from the top of the conversation, under the bar of an agent's conversation or a shell's output when there is one. Claude's panel
                // (`panelCard`) and a question's card that takes the pane (below) report their own area instead.
                // (Out of sight under the composer that answers a text field it still stands where the notice hangs: the card's own area is not there to take it.)
                .noticeArea(!showsPanel && (!covered(by: layout) || answersField), below: viewBarInset)
                // A card with many options takes the pane; the sliver of conversation left would only show a cut line.
                .opacity(covered(by: layout) ? 0 : 1).allowsHitTesting(!covered(by: layout))
                .underCover(covered(by: layout))
            // A question the agent is waiting on takes the composer's place: nothing typed now could answer it.
            ZStack {
                if let prompt = cardPrompt {
                    // With the conversation out of sight the notice hangs from under the card's bar (the question and «Cancelar»), over the options.
                    promptCard(prompt, layout).noticeArea(covered(by: layout), below: AgentPromptCard.headerHeight).transition(.opacity)
                } else { composer(layout).transition(.opacity) }
            }.animation(.easeOut(duration: 0.16), value: showsCard)
                // Files dragged over the island: the slot lights up, whichever of the two it holds.
                .overlay { FileDropFeedback(state: model.fileDrop, radius: Metrics.composerRadius) }
                .overlay(alignment: .top) { droppedNote }
                // The list of models hangs from the composer's row and may reach up past the strip: while it is open it is drawn over it.
                .zIndex(modelMenuOpen ? 2 : 0)
        }.padding(.horizontal, Metrics.edge).padding(.bottom, ComposerMetrics.bottomInset).frame(maxHeight: .infinity, alignment: .top)
            .background { hiddenTerminal }
            .overlay(alignment: .bottom) { joinedWarning }
    }

    /// How far down the bar over an agent's conversation or a shell's output ends, which the notice hangs below (the way back to Claude is in it); 0 with neither.
    private var viewBarInset: CGFloat {
        session.mirrorsAgent && (session.viewedAgent != nil || session.viewedShell != nil) ? NoticeMetrics.viewBar : 0
    }

    /// A Nook session's own terminal while its agent's conversation is on show instead. It stays in the hierarchy, as wide as it was
    /// on show (the island's width less the margins): tmux sizes the agent's pane to the view that shows it, so taking the terminal out
    /// would shrink the pane and make Claude wrap and redraw for a view nobody sees. Invisible, and it takes no clicks or keys: nor
    /// does it claim the pointer (`TerminalSurface.hidden`), which matters because it lies under the whole pane, the composer's controls too.
    @ViewBuilder private var hiddenTerminal: some View {
        if session.mirrorsAgent && !session.isExternal {
            TerminalSurface(session: session, fontSize: model.display.chatSize, hidden: true)
                .padding(.horizontal, Metrics.edge + Metrics.composerInset).padding(.vertical, 4)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var conversation: some View {
        if session.mirrorsAgent {
            ZStack {
                claudeConversation
                    // A shell's output takes the conversation's place. The conversation stays under it (its text, its scroll and its selection are as they
                    // were when it comes back), out of sight, out of the pointer's way and out of VoiceOver's.
                    .opacity(session.viewedShell == nil ? 1 : 0).allowsHitTesting(session.viewedShell == nil)
                    .accessibilityHidden(session.viewedShell != nil).underCover(session.viewedShell != nil)
                if let viewed = session.viewedShell {
                    // The shell may have left the list (it ended a while ago) while its output is still shown: the bar copes without its row.
                    ShellOutputPane(id: viewed, shell: session.shells.first { $0.id == viewed }, output: session.shellOutput, fontSize: model.display.chatSize,
                                    inset: Metrics.mirrorInset, animated: model.animations && model.islandContentVisible, ticking: model.islandContentVisible,
                                    onBack: { model.view(shell: nil, in: session) }, onCopy: { copiedAt = Date() })
                }
            }
        } else {
            // SwiftTerm draws to the very edge of its view, so the margin comes from padding.
            TerminalSurface(session: session, fontSize: model.display.chatSize).padding(.horizontal, Metrics.composerInset).padding(.vertical, 4)
        }
    }

    /// Claude's conversation in the mirror, or an agent's own with its bar.
    private var claudeConversation: some View {
        VStack(spacing: 6) {
            // An agent's own conversation is on show: whose it is, and the way back (the composer still writes to Claude).
            if let viewed = session.viewedAgent {
                AgentViewBar(agent: session.subagents.first { $0.id == viewed }, animated: model.animations && model.islandContentVisible) {
                    model.view(agent: nil, in: session)
                }.padding(.top, 2)
            }
            LiveTerminalSurface(text: mirrorText, transcript: session.agent == .claude, fontSize: model.display.chatSize, contentID: session.viewedAgent ?? "",
                                taskLabel: session.viewedAgent == nil ? nil : "Tarea", voice: session.tint.voice(colorScheme), messages: mirrorMessages) { copiedAt = Date() }
                .padding(.horizontal, Metrics.mirrorInset).padding(.top, session.viewedAgent == nil ? 2 : 0)
                .overlay {
                    // The agent has no record yet (or it is being read): nothing to show but a word about it.
                    if let viewed = session.viewedAgent, session.displayText.isEmpty { AgentViewPlaceholder().id(viewed) }
                }
        }
    }

    // MARK: Composer

    /// One rounded container, as in the Claude app: the message on top, and a row of controls at the bottom.
    private func composer(_ layout: PaneLayout) -> some View {
        VStack(spacing: 0) {
            // A dialog's text field is being answered: whose question it is, and the way back to its options.
            if answersField, let prompt {
                FieldAnswerBar(prompt: prompt, agent: session.agent, sending: sentAnswer, onBack: leaveAnswer)
            }
            if !attachments.isEmpty {
                AttachmentRow(paths: attachments) { path in attachments.removeAll { $0 == path } }
                    .padding(.leading, Metrics.composerInset).padding(.top, 6)
            }
            inputRow(layout)
            controlsRow(layout)
        }.composerSurface(radius: Metrics.composerRadius)
            // The user's colour round it while it answers: what is written here is the answer to the question in the bar, not a message to the agent.
            .overlay {
                if answersField {
                    RoundedRectangle(cornerRadius: Metrics.composerRadius, style: .continuous).strokeBorder(tabAccent.opacity(0.55), lineWidth: 1)
                        .allowsHitTesting(false).transition(.opacity)
                }
            }
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
            ComposerField(text: $draft, placeholder: placeholder, fontSize: model.display.inputSize, maxLines: fieldLines(layout), focusRequest: focusRequest,
                          accessibilityLabel: answersField ? "Respuesta" : "Mensaje",
                          accessibilityHint: answersField ? FieldAnswerCopy.fieldHint(agentName: session.agent?.title ?? "el agente")
                                                       : "Arrastra archivos o carpetas a la isla para añadir su ruta al mensaje. Intro envía; Mayús Intro añade una línea.",
                          onKey: composerKey, capturedLetters: modelMenuOpen && showsAgentControls && modelHighlight != nil ? ["s"] : [])
            if !answersField, Self.showsSuggestionTag(draft: draft, recording: speech.recording, suggestion: session.suggestion, onWelcome: welcomeShowsSuggestion) {
                Text("⇥ usar").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.nookSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
                    .help("Tab, → o Enter copian la sugerencia de Claude a este campo; después Enter la envía.")
                    .frame(height: firstLine)
            }
            // The agents' capsule sits here, not in the controls row: its list opens upward from its right edge.
            // Its dots breathe while anything runs, and a shell can run all day: not while the island is out of sight.
            SubagentCapsule(agents: session.subagents, shells: session.shells, screenShellCount: session.screenShellCount, animated: model.animations && model.islandContentVisible,
                            listMaxHeight: layout.capsuleListMaxHeight(composerHeight: composerHeight),
                            onManage: { model.press(.down, on: session) }, onOpen: { model.openAgent($0, in: session) },
                            onOpenShell: { model.openShell($0, in: session) })
                .frame(height: firstLine)
        }.padding(.leading, Metrics.composerInset).padding(.trailing, 6).padding(.top, answersField ? Metrics.answerTopPadding : ComposerMetrics.topPadding)
            // With no field outline, the whole row answers a click by focusing the field.
            .background { Color.clear.contentShape(Rectangle()).onTapGesture { focusField() } }
    }

    /// The lines the field shows before it scrolls: the pane's room for them, less the bar's while the composer answers a text field.
    private func fieldLines(_ layout: PaneLayout) -> Int {
        guard answersField else { return layout.fieldLines }
        var tighter = layout
        tighter.height -= FieldAnswerBar.tallest
        return tighter.fieldLines
    }

    /// «⇥ usar» beside the field: ⇥ takes Claude's suggestion, and the tag says so where that suggestion is in the field to be seen: not while the welcome has it as
    /// its chip (which has its own ⇥), nor when there is none.
    static func showsSuggestionTag(draft: String, recording: Bool, suggestion: String?, onWelcome: Bool) -> Bool {
        draft.isEmpty && !recording && suggestion != nil && !onWelcome
    }

    /// Puts the keyboard in the message field.
    private func focusField() { focusRequest += 1 }

    /// Puts the keyboard where the user types now: Claude's panel while it is open, the message field otherwise.
    private func focusInput() { if showsPanel { panelFocus += 1 } else { focusField() } }

    /// Claude's grey suggestion goes into an empty field, caret at its end, and is not sent (Enter on the empty field does
    /// the same, and Enter again sends). False when there is nothing to take or the field has text.
    private func takeSuggestion() -> Bool {
        // Claude's suggestion is for its own box, not for an answer.
        guard draftIsEmpty, !slashMenu.isVisible, !answersField, let suggestion = session.suggestion else { return false }
        // What a fresh Claude shows in its empty box is an example in quotes (`Try "write a test for <filepath>"`): what is taken is the example, not the "Try".
        draft = ClaudeWelcomeText.suggestion(from: suggestion) ?? suggestion
        return true
    }

    /// What the field's keys do. ↵ sends at once; ⇧↵ and ⌥↵ add a line (the field does that, so they are left alone here).
    /// With the "/" menu showing the arrows walk its rows; otherwise the caret walks the lines of the draft and, only on
    /// its first or last line, ↑ and ↓ recall the sent messages. Esc closes the menu and stops there; with no menu it
    /// goes on to collapse the island. ⌃V pastes the clipboard's image into the agent, as in its own terminal (so does ⌘V when
    /// the clipboard has an image and no text: the field decides, see `ClipboardPaste`).
    private func composerKey(_ key: ComposerKey, _ caret: ComposerCaret) -> Bool {
        // With the list of models out, the arrows walk its rows (the last opens Claude's picker), ↵ applies the one chosen as the default and S for this
        // session only, as Claude's picker does, and Esc closes; any other key goes on. Until a row is chosen ↵ is the field's own and S is a letter.
        if modelMenuOpen {
            let rows = modelPlan.rows
            switch key {
            case .up, .down:
                modelHighlight = ModelMenuKey.moved(from: modelHighlight, by: key, models: rows.count, current: rows.firstIndex(where: \.isCurrent))
                return true
            case .submit:
                switch ModelMenuKey.chosen(modelHighlight, models: rows.count) {
                case .model(let index)?: chooseModel(rows[index], scope: .default); return true
                case .picker?: openClaudesModelPicker(); return true
                // Nothing was chosen: ↵ does what it always does, with the list out of the way.
                case nil: modelMenuOpen = false
                }
            case .letter("s"):
                if case .model(let index)? = ModelMenuKey.chosen(modelHighlight, models: rows.count) { chooseModel(rows[index], scope: .sessionOnly) }
                return true
            case .escape: modelMenuOpen = false; return true
            default: break
            }
        }
        // With Claude's levels out, the keys walk them: ↓ → ⇥ to the next, ↑ to the one before, ↵ chooses, Esc closes.
        if effortOpen {
            if let moved = EffortPickerKey.moved(from: effortHighlight, by: key) { effortHighlight = moved; return true }
            switch key {
            case .submit: chooseEffort(effortHighlight); return true
            case .escape: effortOpen = false; return true
            default: break
            }
        }
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
            // The menu closes first; then a dialog's text field being answered gives the options back; then an agent's conversation, or a shell's output, goes
            // back to Claude's. Only after all of them does Esc put the island away.
            if slashKey(.escape) == .handled { return true }
            // Back to the options of the question: nothing is sent (Esc is not Claude's own «cancel» here), and the island stays. While the answer is
            // on its way the key is taken and does nothing: there is nothing to go back to until it is known how it went.
            if answersField { if sentAnswer == nil { leaveAnswer() }; return true }
            guard session.viewedAgent != nil || session.viewedShell != nil else { return false }
            model.view(agent: nil, in: session)
            return true
        case .pasteImage: pasteImage(); return true
        // Only while the model list asks for a letter (above); anywhere else the field types it.
        case .letter: return false
        }
    }

    /// Why the mode chip cannot pass to the next mode now (see `ClaudeModeStyle.block`); nil when it can.
    private var modeChipBlock: String? {
        ClaudeModeStyle.block(running: session.isRunning, questionOpen: prompt != nil, panelOpen: showsPanel)
    }

    /// Claude's own controls stand in the row while its conversation is on show; the strip of menu keys needs the room, so they step aside.
    private var showsAgentControls: Bool { session.agent == .claude && session.mirrorsAgent && session.isRunning && !keysOpen }

    /// Screen vision's toggle stands in the row while its setting is on and an agent that opens images (Claude or Codex) runs in the tab; like Claude's chips it
    /// steps aside for the strip of menu keys.
    private var showsScreenChip: Bool { ScreenVisionChipCopy.offers(vision, agent: session.agent, keysOpen: keysOpen) }

    private func controlsRow(_ layout: PaneLayout) -> some View {
        HStack(spacing: 10) {
            // The levels take the status line's and the chips' place, unfolding out of the chip's side; the keys, the mic and send stay put.
            EffortSwap(showsLevels: effortOpen && showsAgentControls, reduceMotion: reduceMotion, animationsOn: model.animations) {
                HStack(spacing: 10) {
                    // The chips are a symbol each (four round chips, 24 pt and 6 apart), so the status keeps nearly all the rest of the row.
                    HStack(spacing: 6) {
                        if session.isExternal { Circle().fill(session.isRunning ? accent : Color.nookAmberFill).frame(width: 5, height: 5) }
                        statusLabel
                    }.frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                    // Not while a text field is being answered: none of them applies to an answer (and Claude's own are blocked by the question anyway).
                    if (showsAgentControls || showsScreenChip) && !answersField {
                        HStack(spacing: 6) {
                            // Each message carries a picture of the screen (one more round chip, for Claude and Codex alike), first, next to Claude's mode.
                            if showsScreenChip { ScreenVisionChip(vision: vision, agent: session.agent, animated: model.animations) }
                            if showsAgentControls {
                                // The permission mode the screen shows under Claude's box; a click passes to the next one, as ⇧⇥ does there.
                                if let mode = session.agentMode {
                                    ClaudeModeChip(mode: mode, blocked: modeChipBlock, needsAccessibility: session.isExternal && !DirectKeys.allowed) { model.cycleMode(on: session) }
                                }
                                // The model the tab uses; a click opens the list of every model Claude offers.
                                ClaudeModelChip(model: session.currentModel, open: modelMenuOpen, blocked: modelChipBlock, waiting: modelAsked) { toggleModelMenu() }
                                EffortChip(effort: effortAsked ?? session.effort, asking: effortAsked != nil) { openEffortPicker() }
                                UsageButton(glance: UsageGlance.tip(from: session.liveUsage)) { model.openUsage(on: session) }
                            }
                        }.layoutPriority(1)
                    }
                }
            } levels: {
                EffortPicker(current: effortAsked ?? session.effort, highlighted: effortHighlight, onPick: chooseEffort, onClose: { effortOpen = false })
            }
            if keysOpen {
                keyPad.transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)))
            }
            HStack(spacing: 6) {
                keysToggle
                micButton
                primaryButton
            }
        }.padding(.leading, Metrics.composerInset).padding(.trailing, 6).padding(.top, 1).padding(.bottom, 6)
            // The list of models, above the row at its end, over the conversation (and the field's line, when the island is small).
            .modelMenu(isOpen: modelMenuOpen && showsAgentControls, animated: model.animations, onClose: { modelMenuOpen = false }) {
                ClaudeModelMenuHost(model: model, session: session, store: model.models, highlighted: modelHighlight,
                                    width: min(ClaudeModelMenu.width, layout.width - 2 * Metrics.edge - 16), maxHeight: max(110, layout.height - ComposerMetrics.bottomInset - 44),
                                    needsAccessibility: session.isExternal && !DirectKeys.allowed, effort: effortAsked ?? session.effort,
                                    onSelect: { modelHighlight = $0 }, onChoose: chooseModel, onEffortStep: stepEffort, onOpenPicker: openClaudesModelPicker)
                    .padding(.trailing, 8)
            }
    }

    // MARK: The model chip

    /// Why the list of models cannot be used now (Claude works, asks something, is not running…), in the words of the chip's tooltip; nil when it can.
    private var modelChipBlock: String? { model.modelSwitchBlocked(on: session) }

    /// What the list says for this tab now: the models Claude's picker offers (or, with no list, the aliases), and whether the list is old or lacks some.
    private var modelPlan: ModelMenuPlan {
        ModelMenuPlan(choices: model.availableModels(for: session), stale: model.modelListIsStale(for: session), missing: model.missingModels(for: session))
    }

    /// What Claude's own picker (its card) lists: the models Claude's picker offers, never the aliases Nook adds when it knows no list (the picker has no row
    /// to move to for them).
    private var pickerPlan: ModelMenuPlan {
        ModelMenuPlan(choices: model.availableModels(for: session).filter { !$0.isAlias }, stale: model.modelListIsStale(for: session), missing: model.missingModels(for: session))
    }

    private func toggleModelMenu() {
        guard modelChipBlock == nil else { return }
        effortOpen = false
        modelHighlight = nil
        modelMenuOpen.toggle()
    }

    /// The model chosen in the list, applied as Claude's picker applies it: as the default for new sessions (↵) or for this session only (S). The chip
    /// stays lit until Claude says it did, unless the model is the one the tab already uses (then there is nothing to wait for).
    private func chooseModel(_ choice: ClaudeModelChoice, scope: ClaudeModelScope) {
        modelMenuOpen = false
        modelAsked = !choice.isCurrent
        model.setModel(choice, on: session, scope: scope)
    }

    /// The effort's ‹ › in the list: one level down or up, asked as the picker of levels asks it (`/effort <level>`).
    private func stepEffort(_ delta: Int) {
        let levels = ClaudeEffort.allCases
        let now = effortAsked ?? session.effort ?? .high
        guard let at = levels.firstIndex(of: now) else { return }
        let next = levels[min(max(at + delta, 0), levels.count - 1)]
        guard next != now else { return }
        effortAsked = next
        model.setEffort(next, on: session)
    }

    private func openClaudesModelPicker() {
        modelMenuOpen = false
        model.openModelPicker(on: session)
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
                }.nookPress(.squeeze, strength: 0.7).foregroundStyle(Color.primary.opacity(0.78)).disabled(!session.isRunning)
                    .nookTip(NookTip(key.label, detail: session.isExternal && key.needsDirectKeys && key != .pasteImage ? "Se envía a la pestaña original · requiere Accesibilidad" : "Se envía a la terminal"), id: "key-\(key.id)")
                    .accessibilityLabel(key.label)
            }
            Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 12).padding(.horizontal, 3)
            Button { model.interrupt(session) } label: {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold))
                    .frame(width: 27, height: Metrics.keyHeight).contentShape(Rectangle())
            }.nookPress(.pulse, strength: 0.6).foregroundStyle(Color.primary.opacity(0.78)).disabled(!session.isRunning)
                .nookTip(interruptTip, id: "interrupt").accessibilityLabel("Interrumpir")
        }.background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func openEffortPicker() {
        effortHighlight = effortAsked ?? session.effort ?? .high
        modelMenuOpen = false
        effortOpen = true
    }

    /// Sets Claude's level the way its own command does (it sends `/effort <level>` as a message), never through its slider.
    private func chooseEffort(_ level: ClaudeEffort) {
        effortOpen = false
        // The level Claude already has is not worth another line in its conversation: the picker just closes.
        guard level != session.effort else { effortAsked = nil; return }
        effortAsked = level
        model.setEffort(level, on: session)
    }

    private var keysToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                // Closing also drops the pin; opening pins it, so a menu closing later does not take the keys away.
                keysOpen.toggle()
                keysPinned = keysOpen
            }
        } label: {
            Image(systemName: "keyboard").nookIconMotion(.squeeze).font(.system(size: 13))
                .foregroundStyle(keysOpen ? Color.primary : Color.primary.opacity(0.7))
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                .background(Color.primary.opacity(keysOpen ? 0.14 : 0), in: Circle())
                .contentShape(Circle())
        }.nookPress(.none)
            .nookTip(keysOpen ? NookTip("Teclas de menú", value: "visibles", detail: "Pulsa para ocultarlas")
                              : NookTip("Teclas de menú", detail: "↑ ↓ ⇥ esc ↵ e interrumpir, para los menús de la terminal"), id: "keys")
            .accessibilityLabel(keysOpen ? "Ocultar las teclas de menú" : "Mostrar las teclas de menú")
            .accessibilityHint("Flechas, tabulador, escape, intro e interrumpir, para los menús de la terminal")
    }

    private var interruptHelp: String { session.drivesAgent ? "Enviar Escape para detener a la IA" : "Enviar Control-C" }

    /// The stop buttons' tip (the key strip's and the send circle's): what it is and what it sends.
    private var interruptTip: NookTip {
        NookTip("Interrumpir", detail: session.drivesAgent ? "Envía Esc para detener a \(session.agent?.title ?? "la IA")" : "Envía Ctrl-C a la terminal")
    }

    /// The AI is busy: Claude's own spinner says so (a finished summary does not count); Codex has no status Nook can read,
    /// so recent output stands in for it. A plain shell never turns the send button into a stop button.
    private var aiWorking: Bool {
        guard session.isRunning, session.drivesAgent else { return false }
        if session.agent == .claude { return session.agentStatus?.working == true }
        return model.working
    }

    private var draftIsEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// There is something to send: words, or an image on its own (the agent opens it from the path).
    private var hasMessage: Bool { !draftIsEmpty || !attachments.isEmpty }

    /// As in the Claude app: while the AI works and there is nothing to send, the send circle is a stop button. Not while a dialog's text field is being
    /// answered: the agent waits for that answer, and a stop (Esc) would cancel the question.
    @ViewBuilder private var primaryButton: some View {
        if aiWorking, !hasMessage, !answersField { stopButton } else { sendButton }
    }

    private var stopButton: some View {
        Button { model.interrupt(session) } label: {
            Image(systemName: "stop.fill").nookIconMotion(.pulse).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                // Claude's own terracotta: the thing being stopped is Claude's work.
                .background(claudeSpinner, in: Circle())
                .contentShape(Circle())
        }.nookPress(.none).nookTip(interruptTip, id: "stop").accessibilityLabel("Interrumpir").accessibilityHint(interruptHelp)
    }

    private var micButton: some View {
        Button {
            if !speech.recording { beforeDictation = draft }
            speech.toggle()
        } label: {
            Image(systemName: speech.recording ? "stop.fill" : "mic").nookIconMotion(.pulse)
                .font(.system(size: 13, weight: speech.recording ? .semibold : .regular)).foregroundStyle(speech.recording ? Color.nookCoral : Color.primary.opacity(0.78))
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                .background(speech.recording ? Color.nookCoral.opacity(0.16) : Color.primary.opacity(0.09), in: Circle())
                .contentShape(Circle())
        }.nookPress(.none)
            .nookTip(speech.recording ? NookTip("Dictando", detail: "Pulsa para terminar y revisar el texto") : NookTip("Dictar", detail: "Habla y revisa el texto antes de enviarlo"), id: "mic")
            .accessibilityLabel(speech.recording ? "Terminar dictado" : "Dictar un mensaje")
            .accessibilityHint(speech.recording ? "Termina el dictado para que revises el texto" : "Habla y revisa el texto antes de enviarlo")
    }

    /// The tab's colour (mint unless the user chose another), not Claude's terracotta: the tab's colour is the user's voice in Nook
    /// (the message block in the mirror is in it too), terracotta is Claude's.
    private var tabAccent: Color { session.tint.accent }
    /// The same colour for small text (the accent is a fill: the light island's text in the user's colour is a deeper shade of it).
    private var tabInk: Color { session.tint.ink }

    private var sendButton: some View {
        // An answer is words: the attached images do not make one (they stay for the next message).
        let empty = answersField ? draftIsEmpty : !hasMessage
        // Disabled too while the message before it waits for its picture of the screen (`send` would ignore it): the wait the status line says. And while
        // an answer goes: the field is already empty then, and a second one would be written over it.
        return Button(action: send) {
            Image(systemName: "arrow.up").nookIconMotion(.nudgeUp).font(.system(size: 14, weight: .bold))
                .foregroundStyle(empty ? Color.nookSecondary : Color.white)
                .frame(width: Metrics.controlHeight, height: Metrics.controlHeight)
                .nookGlassSurface(in: Circle(), tint: tabAccent, isActive: !empty, interactive: true,
                                  fill: empty ? Color.primary.opacity(0.09) : tabAccent, stroke: nil)
        }.nookPress(.none).disabled(empty || !session.isRunning || session.sending || vision.capturing || (answersField && session.answering))
            .nookTip(answersField ? NookTip("Enviar respuesta", detail: FieldAnswerCopy.sendDetail(empty: empty))
                                  : NookTip("Enviar", detail: empty ? "Escribe un mensaje primero" : "↵ envía · ⇧↵ añade una línea"), id: "send")
            .accessibilityLabel(answersField ? "Enviar respuesta" : "Enviar")
            .accessibilityHint(answersField ? "Intro envía tu respuesta al campo de texto de la pregunta" : "Intro envía el mensaje; Mayúsculas Intro añade una línea")
    }

    @ViewBuilder private var joinedWarning: some View {
        if let box = session.joinedBox, dismissedJoin != box {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.badge.plus").foregroundStyle(Color.nookAmber)
                    Text("Tu mensaje quedó en la caja de Claude sin enviarse; no lo volveré a pegar. Envíalo así o corrígelo en la terminal.").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { dismissedJoin = box } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }.nookPress(.spin).help("Cerrar aviso")
                }
                Text("«\(box)»").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.nookSecondary).lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Mostrar terminal") { model.controller?.focusSession() }.font(.system(size: 11))
                    Button("Enviar así") {
                        model.press(.enter, on: session)
                        // The message in Claude's box went with its pictures: the chips above the field are not the next message's.
                        session.joinedBox = nil; draft = ""; attachments = []; beforeDictation = ""
                    }.font(.system(size: 11, weight: .medium)).buttonStyle(.borderedProminent).tint(tabAccent)
                }
            }.padding(10).nookGlassCard(radius: 12, tint: Color.nookAmberFill.opacity(0.14), dimColor: Color.nookCardRaised, fill: Color.nookCardRaised, stroke: Color.nookAmberFill.opacity(0.32))
                .nookCardShadow(0.35, radius: 10, y: 3)
                // It floats over the composer: the arrow shows over it, not the field's I-beam.
                .pointerHole()
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }
    /// Claude's grey suggestion takes the placeholder's place, as in its own box.
    private var placeholder: String {
        if speech.recording { return "Te escucho…" }
        if answersField { return sentAnswer == nil ? FieldAnswerCopy.placeholder : FieldAnswerCopy.sendingPlaceholder }
        if let followUpHint { return followUpHint }
        // While an agent's conversation or a shell's output is shown, what is written still goes to Claude; the field says so.
        if session.viewedAgent != nil || session.viewedShell != nil { return "Mensaje para Claude…" }
        // Said once: the welcome's chip has it while the welcome is up, and the field then has the placeholder it has with no suggestion.
        if let suggestion = session.suggestion, !welcomeShowsSuggestion { return suggestion }
        if let agent = session.agent { return "Mensaje o /comando para \(agent.title)…" }
        return session.isExternal ? "Mensaje a la pestaña original…" : "Escribe o dicta para tu terminal…"
    }
    /// One line for what is going on, by priority: a dictation error, sending, the copy feedback, dictation, Claude's own
    /// status, and finally a hint about the keys.
    @ViewBuilder private var statusLabel: some View {
        if let error = speech.error {
            HStack(spacing: 8) {
                Text(error).font(.system(size: 10)).foregroundStyle(Color.nookAmber).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(error)
                // What went wrong is a permission: the way to the card that shows them is right here.
                if PermissionHelp.opensPermissions(error) { SeePermissionsButton { model.showPermissions() }.fixedSize().layoutPriority(1) }
            }
        } else if vision.capturing {
            // The message waits for its picture of the screen (the field has already let go of it).
            Text("Capturando tu pantalla…").font(.system(size: Metrics.labelSize)).foregroundStyle(Color.nookSecondary)
        } else if session.sending {
            Text("Enviando…").font(.system(size: Metrics.labelSize)).foregroundStyle(Color.nookSecondary)
        } else if answersField {
            answerStatus
        } else if let prompt, prompt.signature == typingFor || prompt.signature == cardHiddenFor {
            // The question is still open but its card is out of the way: say so, and give the way back.
            HStack(spacing: 8) {
                Text("\(session.agent?.title ?? "La IA") espera tu respuesta")
                    .font(.system(size: Metrics.labelSize)).foregroundStyle(Color.nookSecondary).lineLimit(1)
                Button(action: leaveAnswer) {
                    Label("Opciones", systemImage: "list.bullet").font(.system(size: Metrics.labelSize, weight: .medium)).foregroundStyle(tabInk).fixedSize()
                }.nookPress(.squeeze, depth: PressDepth.card, strength: 0.5).help("Volver a las opciones de la pregunta")
            }
        } else if copiedAt == nil, !speech.recording, session.mirrorsAgent, session.isRunning, let status = session.agentStatus {
            // Claude's own status lives here instead of inside the chat; the wait for background agents is told in Spanish.
            ClaudeStatusLine(status: status, size: Metrics.labelSize)
        } else {
            Text(copiedAt != nil ? "Copiado al portapapeles" : speech.recording ? "Dictando · revisa antes de enviar" : session.mirrorsAgent ? (session.isRunning ? "\(session.agent?.title ?? "Terminal") · en vivo · ↵ enviar" : "Terminal · conexión interrumpida") : "↵ enviar · dictado en borrador")
                .font(.system(size: Metrics.labelSize)).foregroundStyle(Color.nookSecondary).lineLimit(1)
        }
    }
    /// What stands under the field while it answers a dialog's text field, by priority: that it listens (dictation), that the answer is on its way, what
    /// an empty ↵ lacks, and where the answer goes.
    @ViewBuilder private var answerStatus: some View {
        Group {
            if speech.recording {
                Text("Dictando · revisa antes de enviar").foregroundStyle(Color.nookSecondary)
            } else if sentAnswer != nil {
                Text(FieldAnswerCopy.sending).foregroundStyle(Color.nookSecondary)
            } else if answerNudged {
                // The user's own colour, not an alarm: nothing is wrong, the answer only has to be written.
                Text(FieldAnswerCopy.missing).foregroundStyle(tabInk)
            } else {
                Text(FieldAnswerCopy.hint(multiSelect: prompt?.multiSelect == true)).foregroundStyle(Color.nookSecondary)
            }
        }.font(.system(size: Metrics.labelSize)).lineLimit(1)
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
    private var menuShowing: Bool { session.mirrorsAgent && (session.prompt != nil || Self.showsNumberedMenu(session.displayText)) }
    /// The keys come out by themselves for a menu the card does not cover. Not for a text field being answered: the composer is for typing then, and a key
    /// of the strip (↵, esc, ↑ ↓) would press the dialog's own, which cancels the question or moves away from the field.
    private var wantsKeys: Bool { menuShowing && !showsCard && !answersField }

    // MARK: Prompt card

    private var prompt: AgentPrompt? { session.mirrorsAgent ? session.prompt : nil }
    /// The prompt whose card is on screen: the composer's place is taken until it is answered or folded away.
    private var cardPrompt: AgentPrompt? {
        guard let prompt, prompt.signature != cardHiddenFor, prompt.signature != typingFor else { return nil }
        return prompt
    }
    private var showsCard: Bool { cardPrompt != nil }

    /// The composer answers a text field of the dialog on screen ("Type something."): the card is out of the way and the field is the one chosen on it, or
    /// the one the terminal has highlighted (`AppModel.fieldAnswer`, which is also where ↵ sends). Whatever is written then is the answer to the question in
    /// the bar, not a message to the agent. It holds while the answer is on its way, until the screen shows how the dialog took it.
    private var answersField: Bool {
        guard prompt != nil, !showsCard else { return false }
        return sentAnswer != nil || model.fieldAnswer(for: session) != nil
    }

    /// Back to the options of the question without answering: the field chosen on the card is forgotten (a message would not go into it any more), the card
    /// comes back and takes the keyboard. Nothing is sent to the terminal, and what was written stays in the field.
    private func leaveAnswer() {
        session.forgetChosenField()
        typingFor = nil; cardHiddenFor = nil; answerNudged = false
    }
    /// Claude's panel is on screen. A question's card wins: with one open there is no panel to show.
    private var showsPanel: Bool { shownPanel != nil && session.mirrorsAgent && prompt == nil }

    // MARK: Session strip

    /// Claude's banner, when the strip over the conversation shows. It gives way to what matters more: an agent's own conversation or a shell's output
    /// (their bar takes the place), a question's card, and a conversation that would be left with less than its minimum height (a long draft in a small island).
    private func stripBanner(_ layout: PaneLayout) -> ClaudeBanner? {
        guard session.agent == .claude, session.mirrorsAgent, session.viewedAgent == nil, session.viewedShell == nil, !showsCard, !showsWelcome(layout),
              let banner = session.banner else { return nil }
        let room = layout.height - ComposerMetrics.bottomInset - composerHeight - ComposerMetrics.spacing
        let strip = SessionStrip.room(chatSize: model.display.chatSize) + ComposerMetrics.spacing
        return room - strip >= ComposerMetrics.minConversation ? banner : nil
    }

    /// The welcome of a fresh Claude takes the conversation's place while nothing has been said (`awaitsFirstMessage`) and the conversation has room for even its
    /// smallest layout. It gives way to what matters more, as the strip does: an agent's own conversation or a shell's output, and any question Claude has open.
    /// Claude's panel wins too, whatever the session says meanwhile: a /usage sent from the welcome is no conversation, so once its bubble has gone `awaitsFirstMessage`
    /// is true again with the panel still open; the welcome comes back when the panel is gone. The strip is what shows where the welcome does not, and where the room is
    /// too small for it.
    private func showsWelcome(_ layout: PaneLayout) -> Bool {
        guard session.awaitsFirstMessage, session.agent == .claude, session.mirrorsAgent, session.viewedAgent == nil, session.viewedShell == nil,
              !showsCard, session.prompt == nil, !showsPanel, session.panel == nil, session.banner != nil else { return false }
        let room = layout.height - ComposerMetrics.bottomInset - composerHeight - ComposerMetrics.spacing
        return room >= ClaudeWelcomeMetrics.minimumHeight(chatSize: model.display.chatSize)
    }

    /// The welcome, over the conversation's (still empty) text. It comes in and goes with a short fade, which belongs to it alone: the layout around it changes
    /// at once, as it does for the strip.
    private func welcomeLayer(_ layout: PaneLayout) -> some View {
        let shows = showsWelcome(layout)
        let animation: Animation? = reduceMotion || !model.animations ? nil : .easeOut(duration: 0.2)
        return ZStack {
            if shows, let banner = session.banner {
                ClaudeWelcome(banner: banner, effort: session.effort, suggestion: session.suggestion, warnings: visibleWarnings, chatSize: model.display.chatSize,
                              islandVisible: model.islandContentVisible, animated: model.animations && model.islandContentVisible,
                              cardWidth: min(StartupWarningsCard.width, max(240, layout.width - 2 * Metrics.edge)), maxBodyHeight: min(320, max(60, layout.height - 56)),
                              warningsOpen: warningsOpen, keepsOpen: warningsOpen,
                              onUseSuggestion: { if takeSuggestion() { focusField() } },
                              onDismissWarnings: { dismissals.dismiss(session.startupWarnings, in: session.id) })
                    .transition(animation == nil ? .identity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }.animation(animation, value: shows)
            .onPreferenceChange(ClaudeWelcomeSuggestionKey.self) { welcomeShowsSuggestion = $0 }
    }

    /// The warnings the user has not dismissed.
    private var visibleWarnings: [ClaudeStartupWarning] {
        dismissals.areDismissed(session.startupWarnings, in: session.id) ? [] : session.startupWarnings
    }

    /// A card that takes most of the pane (many options, long texts) leaves the conversation only a sliver, which would show a cut line: it steps
    /// aside. How tall the card is comes from its texts measured at its width (`PromptCardText.estimatedHeight`), not from the card as laid out:
    /// the card shows what it is about when it covers the conversation, which makes it taller, and a decision that fed on its own result would
    /// flip back and forth.
    private func covered(by layout: PaneLayout) -> Bool {
        // The composer that answers a text field has its bar over the field: in a small island what is left of the conversation is a sliver that would only show a
        // cut line, and it steps aside as it does for the card (by what the composer measures, which takes the bar).
        if answersField { return layout.height - ComposerMetrics.bottomInset - composerHeight - ComposerMetrics.spacing < PaneLayout.minConversationBesideCard }
        guard let prompt = cardPrompt else { return false }
        return AgentPromptCard.coversMirror(cardHeight: estimatedCardHeight(prompt, layout), room: layout.cardRoom)
    }

    /// The card's height for this prompt in this pane, capped by the room the pane has for it.
    private func estimatedCardHeight(_ prompt: AgentPrompt, _ layout: PaneLayout) -> CGFloat {
        min(PromptCardText.estimatedHeight(prompt, width: layout.width - 2 * Metrics.edge, chatSize: model.display.chatSize, hasAccessory: true, modelPicker: ClaudeModelStore.isModelPicker(prompt),
                                           filled: filledFields(of: prompt), inputSize: model.display.inputSize),
            layout.cardRoom - ComposerMetrics.spacing)
    }

    private func promptCard(_ prompt: AgentPrompt, _ layout: PaneLayout) -> some View {
        // The agents' capsule keeps its place; its "Gestionar" button (↓) is left out because ↓ would move the question's highlight.
        AgentPromptCard(prompt: prompt, agent: session.agent, busy: session.answering, needsAccessibility: session.isExternal && !DirectKeys.allowed,
                        accessory: AnyView(SubagentCapsule(agents: session.subagents, shells: session.shells, screenShellCount: session.screenShellCount,
                                                           animated: model.animations && model.islandContentVisible)),
                        maxHeight: layout.cardRoom - ComposerMetrics.spacing, chatSize: model.display.chatSize,
                        // With the conversation out of sight, the card says what the question is about.
                        showsContext: covered(by: layout),
                        // Claude's own model picker is drawn as the model button's list, and a model is applied as the picker applies it (↵ or S).
                        modelPicker: ClaudeModelStore.isModelPicker(prompt)
                            ? ModelPickerContext(plan: pickerPlan, needsAccessibility: session.isExternal && !DirectKeys.allowed, onPick: { model.setModel($0, on: session, scope: $1) }) : nil,
                        // A field that already holds the user's answer: its row says so, and a click toggles its box (`choose`).
                        filledFields: filledFields(of: prompt),
                        // A question with a preview arranges itself by the card's width (the pane less its margins) and keeps its notes here, which outlive the card.
                        width: layout.width - 2 * Metrics.edge, inputSize: model.display.inputSize,
                        notes: Binding(get: { WrittenNotes.text(writtenNotes, for: prompt.signature) }, set: { keepNotes(WrittenNotes.keeping($0, for: prompt.signature)) }),
                        onChoose: { choose($0, of: prompt) },
                        onChooseWithNotes: { choose($0, of: prompt, notes: $1) },
                        onCancel: { model.cancelPrompt(on: session) },
                        onHide: { cardHiddenFor = prompt.signature },
                        onKey: { model.press($0, on: session) })
    }

    /// A click on an option. Options that ask for text bring the composer back (the field takes the keyboard whenever the card goes away). A text field of the
    /// dialog ("Type something.") presses nothing: the model remembers it as the target of the next answer (`TerminalSession.chosenField`), and the composer comes
    /// back as that answer's (the bar with the question, `FieldAnswerBar`); "Chat about this" and its like leave the dialog, and the field's placeholder says what to
    /// write. A field that already holds the answer (a question with several answers keeps its dialog) is no target: the click toggles its box with the keys, like on
    /// any option, and the card stays. So the composer takes the card's place only when the model took the field as the target, not by the option's kind.
    ///
    /// With `notes` (written in the card of a question with a preview, for an option that takes them) the option and its notes go as one answer: arrows, the notes and Terminal's
    /// own Return in one write, with the screen read before and after (`AppModel.answer(_:option:notes:on:)`). The notes are given up only once they went: a refusal keeps
    /// them in the card, and the model's notice says why.
    private func choose(_ index: Int, of prompt: AgentPrompt, notes: String? = nil) {
        guard prompt.options.indices.contains(index) else { return }
        if let notes {
            model.answer(prompt, option: index, notes: notes, on: session) { result in
                if result == .sent { keepNotes(nil) }
            }
            return
        }
        let input = prompt.options[index].input
        model.answer(prompt, option: index, on: session) { result in
            guard result == .sent else { return }
            switch input {
            case .none: break
            case .inline:
                guard let chosen = session.chosenField, chosen.option == index, chosen.signature == prompt.signature else { return }
                answerNudged = false; typingFor = prompt.signature
            case .followUp: followUpHint = "Dile a \(session.agent?.title ?? "la IA") qué hacer…"
            }
        }
    }

    /// The notes written in the card of a question with a preview: this pane's, and the tab's (`WrittenNotesStore`), which outlive the pane.
    private func keepNotes(_ notes: WrittenNotes?) {
        writtenNotes = notes
        WrittenNotesStore.shared.set(notes, for: session.id)
    }

    /// The text fields of `prompt` that already hold an answer Nook wrote (`TerminalSession.isFilledField`): the card's rows say so, and a click on one toggles its box.
    private func filledFields(of prompt: AgentPrompt) -> Set<Int> {
        Set(prompt.options.indices.filter { prompt.options[$0].input == .inline && session.isFilledField($0, of: prompt) })
    }

    /// Nook has its own interrupt button, so Claude's "esc to interrupt" hint is redundant here.
    static func statusText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*·?\s*esc to interrupt"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
    private func send() {
        // A dialog's text field is being answered: what is written goes into it and never to the agent's box. Before everything a message goes through (the
        // suggestion, the effort's levels, the joined box, the open question's confirmation): none of it is about an answer.
        if answersField { sendAnswer(); return }
        // Enter on an empty field takes Claude's suggestion into it, like Claude does (the example, as Tab takes it); Enter again sends.
        if !hasMessage, takeSuggestion() { return }
        guard session.isRunning, !session.sending, hasMessage else { return }
        // A message is still waiting for its screenshot: this one stays in the field until it has gone.
        guard !model.screenVision.capturing else { return }
        // Claude's own /effort opens a slider Nook cannot show and that closes by itself: here the levels open in the row instead.
        if session.agent == .claude, attachments.isEmpty, EffortPickerKey.asksForTheLevels(draft) {
            draft = ""; keysOpen = false; keysPinned = false
            openEffortPicker()
            return
        }
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
        // Line breaks the user left at either end are not part of the message. The attached images go after the words, as their paths.
        let sentText = draft.trimmingCharacters(in: .newlines)
        let sentFiles = attachments
        // Screen vision's toggle: a screenshot of the screen as it is now (Nook's windows left out) goes after the attached images.
        let withScreen = model.screenVision.attaches(text: sentText, agent: session.agent)
        draft = ""; attachments = []; beforeDictation = ""; history.reset(); followUpHint = nil
        model.screenVision.prepareMessage(files: sentFiles, withScreen: withScreen) { files in
            let sentDraft = MessageAttachments.message(text: sentText, files: files)
            // The history keeps what the user wrote and attached, not the screenshot: sending it again takes a new one.
            model.remember(MessageAttachments.message(text: sentText, files: sentFiles), for: session)
            // A shell shows the live terminal itself; the agent's mirror needs a placeholder until the agent's own record has the message.
            if session.mirrorsAgent { session.showPending(sentDraft) }
            session.send(sentDraft) { success in
                guard !success else { return }
                session.pendingMessage = nil
                // This pane may be gone by now (the user went to another tab while the message was on its way), and what it holds with it: the message goes back
                // to the tab's own stores, which are what the pane the user comes back to reads, and to this pane's if it is still there.
                let gave = Self.giveBack(sentText, files: sentFiles, to: session)
                if gave.draft { draft = sentText }
                if gave.attachments { attachments = sentFiles }
            }
        } failed: { notice in
            // Without the screenshot Claude would not see the screen: nothing went, and the message comes back to the field (before
            // anything typed meanwhile). The tab's own stores get it too, in case the user moved to another tab while it was captured.
            let typed = session.draft
            let restored = typed.isEmpty ? sentText : sentText + "\n" + typed
            draft = restored; session.draft = restored
            if MessageAttachments.shared.paths(for: session.id).isEmpty {
                attachments = sentFiles; MessageAttachments.shared.set(sentFiles, for: session.id)
            }
            model.notice = notice
        }
    }

    /// ↵ (or the send button) while the composer answers a dialog's text field: the text goes into it (`AppModel.sendToField`: the arrows, the text and Enter, in one
    /// go). No picture of the screen goes with it and the attached images stay in the composer: an answer is a line of text, and there is no pending bubble in the
    /// conversation (Claude records the answer itself). The field empties at once and the bar says what is on its way; a failure gives the text back to the
    /// field (the model's notice says why), and a success leaves the next card, or the conversation, to the screen. An empty answer is never sent: Enter on an
    /// empty field would cancel Claude's whole question.
    private func sendAnswer() {
        switch FieldAnswerEnter.decide(draft: draft, busy: !session.isRunning || session.sending || session.answering || model.screenVision.capturing) {
        case .wait:
            return
        case .missing:
            answerNudged = true
        case .send(let text):
            speech.stop()
            draft = ""; beforeDictation = ""; history.reset(); followUpHint = nil; answerNudged = false
            sentAnswer = text
            model.remember(text, for: session)
            let started = model.sendToField(text, on: session) { delivered in
                guard !delivered else { return }
                sentAnswer = nil
                // This pane may be gone by now (another tab was opened while the answer went): the tab's own draft gets the text, and this pane's if it is still there.
                if Self.giveBack(text, files: [], to: session).draft { draft = text }
            }
            // The dialog changed under the user's hands (there is no field to answer any more): nothing went, and the text stays where it was written.
            if !started { sentAnswer = nil; draft = text }
        }
    }

    /// A message that could not be delivered goes back to where the user writes it, in the tab's own stores (its draft, and `MessageAttachments`), unless the user has
    /// written something there meanwhile. Says what each store took, for the pane that may still be on screen to follow.
    @MainActor @discardableResult
    static func giveBack(_ text: String, files: [String], to session: TerminalSession, store: MessageAttachments? = nil) -> (draft: Bool, attachments: Bool) {
        let store = store ?? MessageAttachments.shared
        var gave = (draft: false, attachments: false)
        if session.draft.isEmpty, !text.isEmpty { session.draft = text; gave.draft = true }
        if store.paths(for: session.id).isEmpty, !files.isEmpty { store.set(files, for: session.id); gave.attachments = true }
        return gave
    }

    private func pasteImage() {
        // A text field of a dialog takes a line of text: the image would stay behind as a thumbnail that does not go with the answer.
        guard !answersField else { model.notice = FieldAnswerCopy.imageRefusal; return }
        model.pasteImage(into: session) { path in attach(path) }
    }
    /// A Terminal tab never gets ⌃V (that would bring Terminal forward), so the image is a file and travels as its path in the message.
    /// The composer shows it as a thumbnail; the path joins the message when it is sent.
    private func attach(_ path: String) {
        if !attachments.contains(path) { attachments.append(path) }
        focusField()
    }

    // MARK: Dropped files

    /// The paths of files dropped on the island go into the message; nothing is sent. While the field is being edited they
    /// go in through its editor, after the selection where the cursor is, so the user can undo them like typing. Otherwise
    /// they are added at the end, the field takes the keyboard and the cursor is left after them.
    private func receiveDrop(_ request: FileDropRequest) {
        guard request.sessionID == session.id, !request.text.isEmpty else { return }
        // A dictation in progress would write its transcript over the draft.
        if speech.recording { speech.stop() }
        // A question's card (or Claude's panel) stands where the field should be: the paths wait in the draft for when it comes back.
        guard !showsCard, !showsPanel else {
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
            FileDropTag(symbol: "checkmark.circle.fill", text: showsPanel ? "Ruta añadida · la verás al cerrar el panel" : "Ruta añadida · la verás al responder")
                .offset(y: -FileDropTag.overhang).transition(.opacity)
        }
    }

    /// ↑ and ↓ walk what was sent to this tab, like a shell's history. A message that went with images comes back as it was written: its words in the field and its
    /// pictures as the thumbnails above it, not as the paths that carried them (`HistoryCursor.step(older:history:draft:attachments:)`).
    private func recall(older: Bool) -> KeyPress.Result {
        guard let next = history.step(older: older, history: session.sentHistory, draft: draft, attachments: attachments) else { return .ignored }
        draft = next.draft
        if attachments != next.attachments { attachments = next.attachments }
        return .handled
    }

    // MARK: Slash menu

    /// Works out the menu for a new draft. A message recalled from the history is not a command being typed: the menu
    /// stays out of it, so ↑ goes on walking the history.
    private func refreshSlashMenu(for text: String) {
        let recalled = history.index.map { session.sentHistory.indices.contains($0) && MessageAttachments.parts(of: session.sentHistory[$0]).text == text } ?? false
        var next = slashMenu
        // A text field's answer is no command: "/" in it is a character (the menu's Enter would complete a command instead of sending the answer).
        next.update(recalled || answersField ? [] : model.completions(for: session, draft: text))
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

    /// The mirror's text. Claude's transcript gets the messages on their way apart (`mirrorMessages`), dressed by the mirror itself; another
    /// agent's plain mirror gets the message just sent as a line of text, shaped like a prompt so it reads as the user's.
    private var mirrorText: String {
        // The card shows the question and its options, so the mirror ends at what they are about. So does the bar over a text field being answered: the
        // question is in it, and the options are one click (Esc) away; the conversation keeps the shape it had under the card.
        let shown = showsCard || answersField ? AgentPrompt.withoutPrompt(session.displayText) : session.displayText
        guard session.agent != .claude, let pending = session.pendingMessage else { return shown }
        return shown + "\n\n> " + Self.displayedMessage(pending).replacingOccurrences(of: "\n", with: "\n  ")
    }

    /// A message as the conversation shows it before the agent's record has it: its words and, where the paths of its attached images were, "[Image #N]", as Claude's
    /// own record writes them once it takes the message (`ClaudeImagePaste`). The message that goes out is the same as ever: the paths are what the agent opens.
    static func displayedMessage(_ message: String) -> String {
        let parts = MessageAttachments.parts(of: message)
        guard !parts.files.isEmpty else { return message }
        return ([parts.text] + parts.files.indices.map { "[Image #\($0 + 1)]" }).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What Claude's conversation shows after its record: what Claude holds in its queue (also what was typed in its own terminal)
    /// as queued, and the message Nook just sent while it is not queued: being delivered, or delivered and not in the record yet.
    /// An agent's own conversation has none of these: they belong to Claude's.
    private var mirrorMessages: [MirrorMessage] {
        guard session.agent == .claude, session.viewedAgent == nil else { return [] }
        var messages = session.claudeQueue.map { MirrorMessage(text: Self.displayedMessage($0), state: .queued) }
        if let pending = session.pendingMessage, !session.pendingQueued {
            messages.append(MirrorMessage(text: Self.displayedMessage(pending), state: session.sending ? .sending : .waiting))
        }
        return messages
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
    mutating func reset() { index = nil; attachmentsBefore = [] }

    /// The images the draft had when ↑ first brought back a sent message, for ↓ to give back with the draft.
    private var attachmentsBefore: [String] = []

    /// The same step, with the pictures that go with the words: what the field and the thumbnails above it hold after it. A sent message comes back as its words and
    /// the images it went with (`MessageAttachments.parts`); the draft that was being written, past the newest message, comes back with the images it had. Nothing moves
    /// at the ends of the history (the field and the pictures stay as they are); nil when the key keeps its usual meaning.
    mutating func step(older: Bool, history: [String], draft: String, attachments: [String]) -> (draft: String, attachments: [String])? {
        let before = index
        guard let text = step(older: older, history: history, draft: draft) else { return nil }
        guard index != before else { return (draft, attachments) }
        guard index != nil else { return (text, attachmentsBefore) }
        if before == nil { attachmentsBefore = attachments }
        let parts = MessageAttachments.parts(of: text)
        return (parts.text, parts.files)
    }
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
    /// A word on the first message's top edge ("Tarea" for an agent's conversation).
    var taskLabel: String?
    /// The colours of the user's message blocks: the tab's, in the island's theme (`TabTint.voice(_:)`).
    var voice = TabVoice.mint
    /// Messages that stand after the conversation until Claude's record has them (Claude's transcript only; see `MirrorMessages`).
    var messages: [MirrorMessage] = []
    var onCopy: () -> Void = {}
    /// A card has taken the place of the conversation and faded it out (`\.nookCovered`): the mirror gives up the pointer, whose I-beam would
    /// otherwise show over the card. It stays where it is, and its text goes on updating.
    @Environment(\.nookCovered) private var covered
    /// The island's theme: the mirror is drawn for the paper or for the black.
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> LiveTerminalScrollView {
        LiveTerminalScrollView()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LiveTerminalScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 410, height: proposal.height ?? 92)
    }
    func updateNSView(_ scroll: LiveTerminalScrollView, context: Context) {
        scroll.setClaimsPointer(!covered)
        // The text sits straight on the island's own surface, black or paper. Restyling touches every character, so only a real theme or agent change does it.
        scroll.setTheme(dark: scheme == .dark, transcript: transcript)
        scroll.setFontSize(fontSize)
        scroll.setVoice(voice)
        scroll.textView.onCopy = onCopy
        scroll.setContent(contentID)
        scroll.update(text: text, messages: messages)
        // After the text: when the content changes, only the text that stays on show has to be restyled for the label.
        scroll.setTaskLabel(taskLabel)
    }
}

struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    /// The user's chat text size, in points; the live terminal follows it as the text mirror does.
    var fontSize = DisplaySettings.defaultChatSize
    /// The terminal is laid out but not on show (it stands under the mirror, see `SessionPane.hiddenTerminal`). It is hidden from AppKit,
    /// not just drawn clear: SwiftTerm's view claims an I-beam pointer over all its bounds, and a view that is merely transparent still
    /// counts, so the I-beam would show over whatever is drawn above it (the effort levels, the buttons, a question's card). A hidden
    /// view is still sized by SwiftUI, which keeps tmux's pane the width of the island; SwiftUI's own `.hidden()` is no stand-in, as it
    /// never puts the view in the window and so never sizes it.
    var hidden = false
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> ActivityTerminalView { session.terminal }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActivityTerminalView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 410, height: proposal.height ?? 92)
    }
    func updateNSView(_ nsView: ActivityTerminalView, context: Context) {
        // The session's one terminal view moves between the two places it can stand, so each pass says which this is.
        nsView.isHidden = hidden
        // Like the island's own surface, in the theme it has (see `TerminalSession.applyTheme`, which is for the dark one, and `IslandTerminalTheme`).
        nsView.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        session.applyTheme(nsView)
        IslandTerminalTheme.apply(to: nsView, dark: scheme == .dark)
        session.applyConsoleSize(fontSize)
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    /// What the icon does when it is clicked; by default the motion its symbol calls for (the pin tilts, a chevron nudges the way it points, a ✕ turns).
    var motion: ClickMotion?
    var action: () -> Void

    init(symbol: String, label: String, motion: ClickMotion? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.motion = motion
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.nookSecondary).frame(width: 28, height: 28) }
            .nookGlassButton(motion: motion ?? ClickMotion.forSymbol(symbol)).help(label).accessibilityLabel(label)
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
            // The cat was dropped on another terminal app: Nook follows tabs of Terminal only, and says so.
            if let app = model.targetAppName, app != "Terminal" {
                Text("«\(app)» todavía no tiene conexión directa con Nook. Abre tu IA en Terminal de macOS para seguirla aquí o, si ejecutas tmux en \(app), conecta su sesión más abajo.")
                    .font(.system(size: 11)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Terminal de macOS · ya abierta").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(bridge.searching ? "Buscando…" : "Buscar") { bridge.discover() }.font(.system(size: 11)).disabled(bridge.searching)
                }
                Text("Elige solo la pestaña que quieres seguir. Tu IA sigue en el mismo proceso; Enter envía el mensaje allí.")
                    .font(.system(size: 11)).foregroundStyle(Color.nookSecondary).fixedSize(horizontal: false, vertical: true)
                if let error = bridge.error {
                    Text(error).font(.system(size: 10)).foregroundStyle(Color.nookAmber).fixedSize(horizontal: false, vertical: true)
                    if PermissionHelp.opensPermissions(error) { SeePermissionsButton { model.showPermissions() } }
                } else if bridge.windows.isEmpty && !bridge.searching {
                    Text("No hay ventanas de Terminal abiertas.").font(.system(size: 11)).foregroundStyle(Color.nookSecondary)
                }
                ForEach(bridge.windows) { window in
                    Text(window.title).font(.system(size: 10)).foregroundStyle(Color.nookSecondary).lineLimit(1)
                    ForEach(window.tabs) { tab in
                        Button { model.connectTerminalTab(tab) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "terminal").foregroundStyle(accent)
                                Text(tab.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                if tab.selected { Text("activa").font(.system(size: 8)).foregroundStyle(Color.nookSecondary) }
                                Spacer(); Image(systemName: "plus").font(.system(size: 11))
                            }.padding(9).background(Color.nookWash(0.05), in: RoundedRectangle(cornerRadius: 9))
                        }.nookPress(.none, depth: PressDepth.row)
                    }
                }
            }
            Button(model.claudeSignalsEnabled ? "Desactivar avisos de Claude…" : "Activar avisos y actividad de Claude…") { model.enableClaudeSignals() }.font(.system(size: 11)).foregroundStyle(accent)
            // Nook no longer hosts terminals of its own (a new one is a tab of Terminal), so there is nothing new to share. A session saved from
            // before is still a tmux session, and its connection command can still be pasted into another terminal.
            if let saved = model.selected, !saved.isExternal {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Compartir una sesión guardada").font(.system(size: 13, weight: .semibold))
                    SavedSessionNote(session: saved)
                    Button {
                        if model.targetAppName != nil { model.controller?.associateTarget() }
                        else { model.copyConnection(); model.connectionSheet = false }
                    } label: { Label("Copiar conexión de esta sesión", systemImage: "doc.on.doc").font(.system(size: 12, weight: .medium)) }
                        .buttonStyle(.borderedProminent).tint(accent)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            }
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
                                }.nookPress(.none, depth: PressDepth.row)
                            }
                        }
                    }.frame(maxHeight: 90)
                } else if searched { Text("No encontramos sesiones en este socket.").font(.system(size: 11)).foregroundStyle(Color.nookSecondary) }
            }
            Text("La conexión directa muestra el texto y el historial reciente de Terminal; se actualiza cada medio segundo. Otras apps de terminal solo se conectan si ejecutas tmux en ellas: pega arriba el socket de su sesión.")
                .font(.system(size: 10)).foregroundStyle(Color.nookTertiary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
