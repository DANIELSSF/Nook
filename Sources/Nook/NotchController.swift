import AppKit
import SwiftUI
import ApplicationServices
import QuartzCore
import Combine

/// Holds the island's SwiftUI content at full size and shows it through an animated shape. Core
/// Animation morphs the shape on the render server, so opening never resizes the window or lays
/// the panel out again on every frame.
final class IslandView: NSView {
    let shape = CAShapeLayer()
    /// The shape is meant to show the whole of the view (the island open and at rest), as against the notch's size or a size it is on its way to: every `reveal` sets it.
    /// A view that is open and whose shape is not all of it (its window changed size without anyone asking the shape) shows the whole of it once it is laid out.
    var showsAll = false
    private var radius: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.mask = shape
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { false }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.frame = bounds
        CATransaction.commit()
        // What fills the island (the panel's content, the drop view and the corners' handles) is exactly the island, whatever the autoresizing did meanwhile.
        for view in subviews where view.autoresizingMask == [.width, .height] && view.frame != bounds { view.frame = bounds }
        if showsAll, shape.animation(forKey: "reveal") == nil, let box = shape.path?.boundingBox, abs(box.width - bounds.width) > 1 || abs(box.height - bounds.height) > 1 {
            reveal(bounds, radius: radius, duration: 0) {}
        }
    }

    /// The island's outline: square top against the screen edge, rounded bottom corners. Every
    /// outline has the same elements, so Core Animation can morph one into another.
    static func outline(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0.5, min(radius, rect.height / 2, rect.width / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.closeSubpath()
        return path
    }

    /// `from` is where the shape starts when it is not where it is on screen in this view's own coordinates: a window that changed its size moved the origin.
    func reveal(_ rect: CGRect, radius: CGFloat, duration: Double, timing: CAMediaTimingFunction = .init(name: .default), from: CGPath? = nil, completion: @escaping () -> Void) {
        let path = Self.outline(rect, radius: radius)
        showsAll = abs(rect.width - bounds.width) < 1 && abs(rect.height - bounds.height) < 1 && abs(rect.minX) < 1 && abs(rect.minY) < 1
        self.radius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        // No duration is "there now": a shape still on its way to somewhere else (a move that was given up) does not go on meanwhile and show the old place.
        if duration <= 0 { shape.removeAnimation(forKey: "reveal") }
        if duration > 0 {
            let morph = CABasicAnimation(keyPath: "path")
            // An interrupted transition continues from where the shape is on screen.
            morph.fromValue = from ?? shape.presentation()?.path ?? shape.path
            morph.toValue = path
            morph.duration = duration
            morph.timingFunction = timing
            shape.add(morph, forKey: "reveal")
        }
        shape.path = path
        CATransaction.commit()
    }
}

/// Holds the island open while the user works in the terminal Nook brought forward,
/// and lets go by itself once they move on, so normal hiding resumes.
struct TerminalRetention {
    private(set) var appPID: pid_t?
    private(set) var holdsMirror = false
    private var grace = Date.distantPast

    mutating func keep(appPID: pid_t?, mirror: Bool, now: Date) {
        self.appPID = appPID; holdsMirror = mirror
        // Activation takes a moment; the island must not hide while the terminal comes forward.
        grace = now.addingTimeInterval(2)
    }
    mutating func end() { appPID = nil; holdsMirror = false; grace = .distantPast }
    mutating func holds(now: Date, mirrorIsKey: Bool, appIsFrontmost: (pid_t) -> Bool) -> Bool {
        if now < grace || (holdsMirror && mirrorIsKey) { return true }
        if let appPID, appIsFrontmost(appPID) { return true }
        end()
        return false
    }
}

final class NotchController: NSObject, NSWindowDelegate, QuitPromptHost {
    let model: AppModel
    let petPanel: NotchPanel
    let panel: NotchPanel
    let petView: PetView
    private var alertPeek: AlertPeekController!
    /// The pill under the island that says screen vision took a picture (`ScreenVisionCue.swift`).
    private var captureCue: ScreenVisionCue!
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var trackingTimer: Timer?
    /// The island is open and wants the pointer watched (`retimeTracking`), and what tells it the screens slept or woke.
    private var trackingWanted = false
    private var trackingWatch: NSObjectProtocol?
    private var mirrors: [String: (NSWindow, ActivityTerminalView)] = [:]
    private var statusItem: NSStatusItem?
    private var capturePrivacyWatch: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    /// Where the Space, wake and unlock notifications come from (`watchSpaces`): the workspace's, or a test's own.
    private let workspaceCenter: NotificationCenter
    private var spaceObservers: [NSObjectProtocol] = []
    /// The checks still to come after a wake or a new screen (`checkSpacesSoon`).
    private var spaceChecks: [DispatchWorkItem] = []
    /// The collapsed island is meant to be on screen: the controller showed it and has not put it away since (a quiet controller's is not, until
    /// its island first closes).
    private var petOut = false
    private var transitionID = 0
    private var targetPID: pid_t?
    private var targetWindowID: Int?
    private var dragPanel: NotchPanel?
    private var draggingPet = false
    var isDraggingPet: Bool { draggingPet }
    /// The cat put down after a drag lands softly in the expanded header once that is showing it.
    private var petLanding = PetLanding()
    /// The alert whose peek is on screen, if any.
    var peekingAlert: NookAlert? { alertPeek.current }
    private var retention = TerminalRetention()
    /// The display settings' card, a window under the open island (made the first time it is asked for).
    private var settingsWindow: SettingsWindow?
    /// Armed when the user is sent to System Settings from the card's Permisos tab: opening the island soon after brings that tab back.
    private var permissionsResume = SettingsResume()
    /// The tab the user was on when sent to System Settings: the Pantalla tab asks for Screen Recording too, and is the one that comes back for it.
    private var resumeTab = SettingsTab.permissions
    private let island = IslandView()
    /// Takes the files dragged over the open island, wherever on it they are.
    private let islandDrop = FileDropView()
    /// The handles on the open island's bottom corners that drag its size.
    private let grip = IslandResizeGrip()
    /// The island's size is being dragged by its corner: it stays open however the pointer wanders meanwhile.
    private var resizingIsland = false
    /// What a file drag does: opens the collapsed island, keeps it open, hands the paths to the composer.
    private(set) var fileDrops: FileDropCoordinator!
    /// The island's curve for opening, closing and growing for a card: one, so they feel the same.
    private static let islandCurve = IslandRoomKeeper.curve
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The collapsed island inside the panel, which keeps the size of the island it was (the user's, or the one a card made it) while it closes.
    private var compactShape: CGRect {
        let full = panel.frame, compact = compactFrame
        return CGRect(x: compact.minX - full.minX, y: compact.minY - full.minY, width: compact.width, height: compact.height)
    }
    /// Takes the island to the size a card asks for while it is open, and back (`IslandGrowth.swift`).
    private(set) lazy var roomKeeper = IslandRoomKeeper(host: self)
    private weak var focusedMirror: NSWindow?
    /// How opaque the island is when it is open: fully, and for a quiet controller (tests) all but invisible, taking no pointer.
    private let restingAlpha: CGFloat

    var screen: NSScreen { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first! }
    var neckHeight: CGFloat { max(screen.safeAreaInsets.top, 28) }
    var notchWidth: CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { return right.minX - left.maxX }
        return 180
    }
    var compactFrame: NSRect {
        NotchGeometry.idleFrame(screen: screen.frame, left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea, topInset: screen.safeAreaInsets.top)
    }
    /// The island's frame as the user's settings make it on this screen.
    var userFrame: NSRect {
        NotchGeometry.expandedFrame(screen: screen.frame, centerX: compactFrame.midX, topInset: screen.safeAreaInsets.top, settings: model.display)
    }
    /// The open island's frame now: the user's, or the one it took for the card that is open (`IslandRoomKeeper`). The content is laid out for its size (`AppModel.islandSize`);
    /// the window follows it as the shape does.
    var expandedFrame: NSRect {
        guard let grown = roomKeeper.grown else { return userFrame }
        return NotchGeometry.frame(of: grown, screen: screen.frame, centerX: compactFrame.midX)
    }

    /// `quiet`: the controller builds its windows and nothing else (no cat on screen, no menu bar item, no event monitors), for tests, which drive it by hand with
    /// windows nobody can see. `workspace` is where it hears of Space changes, wakes and unlocks (tests post their own there).
    init(model: AppModel, quiet: Bool = false, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.model = model
        workspaceCenter = workspace
        restingAlpha = quiet ? 0.01 : 1
        petPanel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        petView = PetView(frame: .zero)
        super.init()
        model.controller = self
        model.quitPromptHost = self
        model.permissions.onOpenedSettings = { [weak self] in self?.permissionsHandOff() }
        petView.controller = self
        for window in [petPanel, panel] {
            window.capturePrivacy = model.capturePrivacy
            window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hidesOnDeactivate = false
        }
        petPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        petPanel.allowsKey = false
        petPanel.hasShadow = false
        petPanel.contentView = petView
        petPanel.spaceRole = "isla cerrada"
        panel.spaceRole = "isla abierta"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        panel.hasShadow = true
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] event in self?.handleShortcut(event) ?? false }
        let hosting = NSHostingView(rootView: NookPanel(model: model))
        // SwiftTerm's preferred size must never resize the island's NSWindow.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.autoresizingMask = [.width, .height]
        island.addSubview(hosting)
        // Last, so it is the front-most view that registers for file drags (it is invisible to the pointer, so clicks pass through).
        islandDrop.frame = island.bounds
        islandDrop.autoresizingMask = [.width, .height]
        island.addSubview(islandDrop)
        // The corners' handles take clicks only on themselves (the rest of the view is invisible to the pointer).
        grip.frame = island.bounds
        grip.autoresizingMask = [.width, .height]
        // Not while a card has made the island the size it asks for: that is not the user's size, which is what a drag sets.
        grip.isActive = { [weak self] in self?.model.expanded == true && self?.model.islandContentVisible == true && self?.roomKeeper.grown == nil }
        grip.onBegin = { [weak self] _ in
            guard let self, self.model.expanded, self.roomKeeper.grown == nil else { return nil }
            self.resizingIsland = true
            return self.userFrame.size
        }
        grip.onResize = { [weak self] size in self?.resizeIsland(to: size) }
        grip.onEnd = { [weak self] in
            self?.resizingIsland = false
            // A card that asked for room while the corner was being dragged is asked about again.
            self?.roomKeeper.reconsider()
        }
        island.addSubview(grip)
        panel.contentView = island
        panel.minSize = .zero
        positionPet()
        if quiet {
            for window in [petPanel, panel] { window.alphaValue = restingAlpha; window.ignoresMouseEvents = true }
        } else {
            petPanel.orderFrontRegardless(); petOut = true
            setupMenu()
        }
        alertPeek = AlertPeekController(notch: self)
        captureCue = ScreenVisionCue(host: self)
        fileDrops = FileDropCoordinator(model: model, isExpanded: { [weak self] in self?.model.expanded == true },
                                        // The drag belongs to another app: the island opens without taking the keyboard from it.
                                        expand: { [weak self] in self?.expand(focus: false) },
                                        // The paths are in; the user types next, so the island takes the keyboard as a click on it would.
                                        focus: { [weak self] in
                                            NSApp.activate(ignoringOtherApps: true)
                                            self?.panel.makeKeyAndOrderFront(nil)
                                        },
                                        window: { [weak self] in self?.panel })
        fileDrops.attach(islandDrop, place: .island)
        fileDrops.attach(petView.fileDrop, place: .notch)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.alertPeek.cancel(); self?.captureCue.cancel(); self?.positionPet(); self?.positionPanel(); self?.placeSettings()
            // A reconfigured display (a wake with the lid opened, a monitor plugged in) is when a panel can lose a Space.
            self?.checkSpacesSoon(reason: "pantalla reconfigurada")
        }
        watchSpaces()
        guard !quiet else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clickedOutside() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // The tab editor's popover and Nook's alerts belong to the island; other Nook windows don't.
            if event.window !== self.panel, event.window !== self.petPanel, !self.alertPeek.owns(event.window), self.model.editingSessionID == nil, NSApp.modalWindow == nil { self.clickedOutside() }
            return event
        }
    }
    deinit {
        trackingTimer?.invalidate()
        trackingWatch.map(NotificationCenter.default.removeObserver)
        spaceChecks.forEach { $0.cancel() }
        spaceObservers.forEach(workspaceCenter.removeObserver)
        screenObserver.map(NotificationCenter.default.removeObserver)
    }

    func positionPet() {
        // The compact surface extends both sides of the hardware cutout as one island.
        petPanel.setFrame(compactFrame, display: true)
        petView.frame = NSRect(origin: .zero, size: petPanel.frame.size)
    }
    private func positionPanel() {
        // A new screen or new settings: the island takes the user's own size at once, with no move, and what a card asked for is asked about again.
        let wasGrown = roomKeeper.grown != nil
        roomKeeper.release()
        if wasGrown { model.objectWillChange.send() }
        panel.setFrame(expandedFrame, display: model.expanded)
        island.layoutSubtreeIfNeeded()
        if model.expanded {
            island.reveal(island.bounds, radius: 22, duration: 0) {}
            panel.invalidateShadow()
            roomKeeper.reconsider()
        }
    }

    // MARK: Display settings

    /// The settings changed (`AppModel.display`). Text sizes reach the views through SwiftUI; only a new island size has to
    /// reach the window, and only while it is open: a collapsed island takes its size when it opens next.
    func displayChanged(from old: DisplaySettings) {
        let resized = old.widthExtra != model.display.widthExtra || old.heightExtra != model.display.heightExtra
        guard resized, model.expanded else { return }
        // The size a card asked for was worked out from the user's old one: it is worked out again from the new one.
        guard panel.frame != userFrame || roomKeeper.grown != nil else { return }
        positionPanel()
        placeSettings()
    }

    /// A drag on a corner asks for this size: it becomes the settings' offsets, clamped to the screen as the card's sliders are.
    func resizeIsland(to size: CGSize) {
        let screen = self.screen
        let next = NotchGeometry.settings(for: size, screen: screen.frame.size, topInset: screen.safeAreaInsets.top, from: model.display)
        if next != model.display { model.display = next }
    }

    /// ⌘+ and ⌘− change the chat's text size by a point, ⌘0 puts it back, while the island has the keyboard.
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard model.expanded, let shortcut = ChatSizeShortcut(event: event) else { return false }
        model.display = model.display.applying(shortcut)
        return true
    }

    /// "Ajustes…" and "Permisos…": the card under the open island, on that tab. Asking for the tab it is already on closes it.
    func toggleSettings(tab: SettingsTab = .island) {
        if model.settingsOpen, model.settingsTab == tab { closeSettings() } else { openSettings(tab: tab) }
    }
    func openSettings(tab: SettingsTab = .island) {
        permissionsResume.clear()
        model.settingsTab = tab
        model.settingsOpen = true
        if model.expanded, model.islandContentVisible { showSettings() } else { expand(focus: true) }
    }
    /// `keepingResume`: the island is being put away, not the card dismissed (see `permissionsHandOff`).
    func closeSettings(keepingResume: Bool = false) {
        if !keepingResume { permissionsResume.clear() }
        model.settingsOpen = false
        settingsWindow?.hide()
    }

    /// The user was sent to System Settings from the Permisos tab. The card and the island put themselves away (so they do not cover
    /// the pane), and the next time the island opens within a few minutes the card comes back on that tab, which reads the permissions
    /// again: they come back to see what they switched on.
    func permissionsHandOff() {
        permissionsResume.arm(now: Date())
        resumeTab = model.settingsTab == .screen ? .screen : .permissions
        // Out of the pane's way at once: the card would cover the very switch the user is being sent to.
        closeSettings(keepingResume: true)
        collapse()
    }
    private func resumePermissionsIfDue() {
        guard permissionsResume.due(now: Date()), !model.settingsOpen else { return }
        model.settingsTab = resumeTab
        model.settingsOpen = true
    }
    private func showSettings() {
        guard model.settingsOpen else { return }
        if settingsWindow == nil {
            let screen = self.screen
            let window = SettingsWindow(model: model, screen: screen.frame.size, topInset: screen.safeAreaInsets.top, level: panel.level) { [weak self] in self?.closeSettings() }
            // The text-size shortcuts work while the card has the keyboard too.
            window.panel.onKeyEquivalent = panel.onKeyEquivalent
            settingsWindow = window
        }
        placeSettings()
        settingsWindow?.show(animated: !reduceMotion)
    }
    /// Where the settings card is while it is out, for what hangs under the island and must not cover it (`ScreenVisionCue`).
    var settingsCardFrame: CGRect? { settingsWindow.flatMap { $0.isVisible ? $0.cardFrame : nil } }
    private func placeSettings() {
        guard model.settingsOpen else { return }
        settingsWindow?.place(under: panel.frame, on: screen.frame)
    }
    /// Whether a point on the screen belongs to the island, its collapsed shape or the settings card.
    private func owns(point: NSPoint, slack: CGFloat = 0) -> Bool {
        panel.frame.insetBy(dx: -slack, dy: -slack).contains(point) || petPanel.frame.insetBy(dx: -min(slack, 5), dy: -min(slack, 5)).contains(point)
            || (settingsWindow.map { $0.isVisible && $0.cardFrame.insetBy(dx: -slack, dy: -slack).contains(point) } ?? false)
    }
    func scheduleExpand() {
        cancelScheduledExpand()
        let work = DispatchWorkItem { [weak self] in self?.expand(focus: false) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }
    func cancelScheduledExpand() { hoverWork?.cancel(); hoverWork = nil }
    func expand(focus: Bool) {
        cancelScheduledExpand(); collapseWork?.cancel()
        // An open peek hands its shape to the island, which grows from it; the peek's window goes once the
        // island's is up, so the black never blinks.
        let peekShape = alertPeek.visibleShape()
        if focus { endTerminalPresentation() }
        startTracking()
        if !model.expanded {
            transitionID += 1
            let transition = transitionID
            model.expanded = true
            model.islandContentVisible = false
            // The window keeps its expanded size; only the visible shape grows from the notch, so
            // nothing is laid out again while it animates. One that was left at the size of an island grown for a card, and is still on screen closing, takes the island's own
            // with the shape where it is.
            var resume: CGPath?
            if panel.isVisible { resume = roomKeeper.align(to: expandedFrame) }
            else if panel.frame != expandedFrame { panel.setFrame(expandedFrame, display: false); island.layoutSubtreeIfNeeded() }
            if !panel.isVisible {
                let full = expandedFrame
                let start = peekShape.map { (CGRect(x: $0.rect.minX - full.minX, y: $0.rect.minY - full.minY, width: $0.rect.width, height: $0.rect.height), $0.radius) }
                island.reveal(start?.0 ?? compactShape, radius: start?.1 ?? 10, duration: 0) {}
            }
            // The window shadow can't follow a moving shape; it returns once the island settles.
            panel.hasShadow = false
            panel.alphaValue = restingAlpha
            panel.orderFrontRegardless()
            petPanel.orderOut(nil); petOut = false
            island.reveal(island.bounds, radius: 22, duration: reduceMotion ? 0 : 0.32, timing: Self.islandCurve, from: resume) { [weak self] in
                guard let self, self.transitionID == transition, self.model.expanded else { return }
                self.panel.hasShadow = true; self.panel.invalidateShadow()
                // The content fades in, also with Reduce Motion: the island's shape takes its size at once then, and the fade is all that is left of the opening.
                withAnimation(.easeOut(duration: self.reduceMotion ? 0.16 : 0.13)) { self.model.islandContentVisible = true }
                self.resumePermissionsIfDue()
                self.showSettings()
                if focus { self.focusTerminal() }
                // The island is on show: a card that was open before it closed (or opened meanwhile) is asked about now.
                self.roomKeeper.reconsider()
            }
        }
        alertPeek.cancel()
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if model.islandContentVisible { focusTerminal() }
        }
    }
    /// A click on an alert's peek: its own tab, open in the island. (The badge keeps opening the latest notice.)
    func openAlertTab(_ alert: NookAlert) {
        if let session = model.sessions.first(where: { $0.id == alert.sessionID }) { model.select(session) }
        expand(focus: true)
    }
    /// A click on the collapsed island's agent pill: the island opens on the tab it counts, with that tab's list of agents open.
    func openAgentList() {
        if let session = model.selected { model.requestAgentList(for: session) }
        expand(focus: true)
    }

    // MARK: The question before quitting

    /// The island opened for the question before quitting (it was collapsed when it was asked): answering "stay" puts it away again.
    private var openedForQuitPrompt = false
    /// Whether the island can ask before quitting so that the user sees the question now. When it can't, `AppModel.shouldTerminate` asks
    /// with the plain alert instead, so a quit is never cancelled into a question nobody can see (`islandReachesUser`).
    var canShowQuitPrompt: Bool {
        Self.islandReachesUser(hasScreen: !NSScreen.screens.isEmpty, screensDark: PetPowerMonitor.shared.screensDark, windowsShow: restingAlpha >= 1)
    }
    /// Whether something shown in the island reaches the user right now: there is a screen to show it on, someone can see a screen (none
    /// asleep, the Mac not locked, the user's session not switched away: `PetPowerMonitor.screensDark`), and the island's windows show (a
    /// quiet controller's are all but invisible). The island's windows join every Space as they come on screen (`NotchPanel`), so the
    /// Space the user is on never hides it.
    static func islandReachesUser(hasScreen: Bool, screensDark: Bool, windowsShow: Bool) -> Bool {
        hasScreen && !screensDark && windowsShow
    }
    /// The question is up (`AppModel.quitPrompt`): the island opens with the keyboard, so Esc and a second ⌘Q reach it, and holds
    /// while it is up (`trackPointer`, `collapse`).
    func showQuitPrompt() { showQuitPrompt(focus: true) }
    /// `focus` is false only in tests, which must never take the keyboard from the app in front.
    func showQuitPrompt(focus: Bool) {
        openedForQuitPrompt = !model.expanded
        expand(focus: focus)
    }
    /// The question was answered "stay": the island goes back to how it was before it was asked.
    func quitPromptDismissed() {
        guard openedForQuitPrompt else { return }
        openedForQuitPrompt = false
        collapse()
    }
    /// Puts the keyboard in the selected Nook session's terminal. Not while the agent's conversation is on show in its place (a
    /// Terminal tab's, or a Nook session with Claude running): the composer has the keyboard then. Nor while the question before quitting is
    /// up: it holds the keyboard (`QuitKeys`), and a Return meant for «Quedarme» must never reach a shell.
    func focusTerminal() {
        guard let selected = model.selected, !selected.mirrorsAgent, model.quitPrompt == nil else { return }
        let terminal = selected.terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.model.expanded, self.model.quitPrompt == nil, self.panel.isKeyWindow else { return }
            self.panel.makeFirstResponder(terminal)
        }
    }
    func collapse(force: Bool = false) {
        // The question before quitting is the island's topmost thing: putting the island away (Esc, the chevron, a click outside)
        // answers it "stay" first, which leaves the island as it was before the question (`quitPromptDismissed`).
        if model.quitPrompt != nil { model.answerQuit(false); return }
        // A question waiting on the user holds the island open like the pin does; only an explicit collapse lets go,
        // and it also stops that same prompt from opening the island again.
        if (model.pinned || model.promptHoldsIsland) && !force { return }
        if force { model.dismissPrompt() }
        endTerminalPresentation()
        cancelScheduledExpand(); collapseWork?.cancel()
        guard model.expanded else { return }
        // Closing from the size a card made it: the shape goes from there to the notch, and the next opening is the user's own size.
        roomKeeper.release()
        fileDrops.reset()
        petLanding.cancel()
        transitionID += 1
        let transition = transitionID
        model.expanded = false; model.connectionSheet = false; model.editingSessionID = nil; model.islandContentVisible = false
        closeSettings(keepingResume: true)
        panel.hasShadow = false
        island.reveal(compactShape, radius: 10, duration: reduceMotion ? 0 : 0.25, timing: Self.islandCurve) { [weak self] in
            guard let self, self.transitionID == transition, !self.model.expanded else { return }
            self.stopTracking()
            self.panel.orderOut(nil)
            self.positionPet(); self.petPanel.orderFrontRegardless(); self.petOut = true
        }
    }
    /// Pointer tracking only matters while the island is open; collapsed, the cat's own tracking
    /// area notices the pointer, so nothing wakes the app up several times a second.
    private func startTracking() {
        trackingWanted = true
        if trackingWatch == nil {
            trackingWatch = NotificationCenter.default.addObserver(forName: PetPowerMonitor.didChange, object: nil, queue: .main) { [weak self] _ in self?.retimeTracking() }
        }
        retimeTracking()
    }
    private func stopTracking() { trackingWanted = false; retimeTracking() }
    /// The pointer is looked at while the island is open and a screen can be seen. With the screens asleep or locked nobody moves it, and
    /// six checks a second would only wake the Mac: the timer goes, and comes back with the screens (`PetPowerMonitor.didChange`).
    private func retimeTracking() {
        let runs = trackingWanted && !PetPowerMonitor.shared.screensDark
        if runs, trackingTimer == nil {
            trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.trackPointer() }
            trackingTimer?.tolerance = 0.05
        } else if !runs {
            trackingTimer?.invalidate(); trackingTimer = nil
        }
    }

    /// A click anywhere outside the island hides it, also after showing a terminal. Only a cat drag
    /// and the macOS permission prompt that discovery may raise keep it open (pinning still wins).

    private func clickedOutside() {
        guard !draggingPet, !model.terminalBridge.searching, !model.permissions.isRequesting else { return }
        let point = NSEvent.mouseLocation
        guard !owns(point: point) else { return }
        // The user moved on: the question before quitting is answered "stay", and the island goes as after any click outside.
        if model.quitPrompt != nil { model.answerQuit(false) }
        collapse()
    }
    private func trackPointer() {
        if isDisplayingTerminal { collapseWork?.cancel(); collapseWork = nil; return }
        if draggingPet { collapseWork?.cancel(); collapseWork = nil; return }
        // Files being dragged over the island keep it open, as the pointer resting on it does.
        if fileDrops.holdsIsland { collapseWork?.cancel(); collapseWork = nil; return }
        if model.editingSessionID != nil { collapseWork?.cancel(); collapseWork = nil; return }
        // The settings card is open, or a corner is being dragged: the island stays while the user adjusts it, however it
        // resizes under the pointer.
        if model.settingsOpen || resizingIsland { collapseWork?.cancel(); collapseWork = nil; return }
        // The question before quitting holds the island like the pin; only an answer, Esc or a click outside lets go.
        if model.quitPrompt != nil { collapseWork?.cancel(); collapseWork = nil; return }
        // A tab being dragged along the strip may stray past the island's edge. No button down means the drag is over, whatever
        // the view heard of its end.
        if model.tabDragInProgress {
            if NSEvent.pressedMouseButtons & 1 != 0 { collapseWork?.cancel(); collapseWork = nil; return }
            model.tabDragInProgress = false
        }
        guard model.expanded, !model.pinned, !model.promptHoldsIsland, !model.connectionSheet, model.editingSessionID == nil else { return }
        let point = NSEvent.mouseLocation
        let inside = owns(point: point, slack: 12)
        if inside { collapseWork?.cancel(); collapseWork = nil }
        else if collapseWork == nil && !panel.isKeyWindow {
            let work = DispatchWorkItem { [weak self] in
                // A tab drag that began in the moment since the pointer left keeps the island.
                guard let self, !self.model.tabDragInProgress else { return }
                self.collapse()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }
    func focusSession() {
        guard let session = model.selected else { return }
        if let tty = session.externalTTY, let windowID = session.externalWindowID {
            // Terminal may have relaunched since the tab was connected; use its current process.
            keepIslandWithTerminal(appPID: TerminalAppBridge.terminalPID ?? session.externalAppPID)
            model.terminalBridge.select(windowID: windowID, tty: tty, raise: true) { [weak self] success in
                if !success { self?.endTerminalPresentation() }
            }
            return
        }
        if let pid = session.externalAppPID, let app = NSRunningApplication(processIdentifier: pid) {
            keepIslandWithTerminal(appPID: pid)
            app.activate(options: [.activateAllWindows])
            raiseWindow(pid: pid, windowID: session.externalWindowID)
            return
        }
        openMirror(session)
    }
    func openMirror(_ session: TerminalSession) {
        if let (window, view) = mirrors[session.id] {
            keepIslandWithTerminal(mirror: window)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
            return
        }
        let terminal = session.makeMirror()
        let window = CapturePrivacyWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.capturePrivacy = model.capturePrivacy
        window.title = session.title + " · Nook"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 360)
        window.delegate = self
        window.contentView = terminal
        window.center()
        mirrors[session.id] = (window, terminal)
        keepIslandWithTerminal(mirror: window)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(terminal)
    }

    /// Showing the original terminal keeps the island, its tab and the session in place.
    func keepIslandWithTerminal(appPID: pid_t? = nil, mirror: NSWindow? = nil) {
        focusedMirror = mirror
        retention.keep(appPID: appPID, mirror: mirror != nil, now: Date())
        collapseWork?.cancel(); collapseWork = nil
    }

    /// The keyboard goes back where it was before keys brought Terminal forward (`TerminalAppBridge.press`). Nook was in front: it
    /// comes back as `expand(focus: true)` brings it. Another app: it comes back over Terminal, and the island, when it had the
    /// keyboard (a click on it gives it without changing the app in front), takes it again once that app is in front; before,
    /// the app's own window would take it back. Terminal was in front: only the island's keyboard comes back. A collapsed
    /// island is never shown for it.
    func returnKeyboard(_ focus: KeyFocus) {
        let island = focus.island && model.expanded && panel.isVisible
        if focus.app == ProcessInfo.processInfo.processIdentifier {
            NSApp.activate(ignoringOtherApps: true)
            if island { panel.makeKeyAndOrderFront(nil) }
            return
        }
        guard let app = NSRunningApplication(processIdentifier: focus.app), !app.isTerminated else { return }
        if app.isActive { if island { panel.makeKeyAndOrderFront(nil) }; return }
        guard island else { app.activate(options: []); return }
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        func stopWatching() { if let token = observer { center.removeObserver(token); observer = nil } }
        observer = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == focus.app else { return }
            stopWatching()
            guard let self, self.model.expanded, self.panel.isVisible else { return }
            self.panel.makeKeyAndOrderFront(nil)
        }
        app.activate(options: [])
        // An activation that never comes (the app hangs): the island keeps what it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { stopWatching() }
    }

    private func endTerminalPresentation() {
        focusedMirror = nil; retention.end()
    }

    private var isDisplayingTerminal: Bool {
        let holding = retention.holds(now: Date(), mirrorIsKey: focusedMirror?.isKeyWindow == true) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == $0
        }
        if !holding { focusedMirror = nil }
        return holding
    }
    func closeMirror(for session: TerminalSession) {
        if let (window, _) = mirrors[session.id] { window.close() }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = mirrors.first(where: { $0.value.0 === window }) else { return }
        model.sessions.first { $0.id == entry.key }?.releaseMirror(entry.value.1)
        mirrors.removeValue(forKey: entry.key)
    }
    func openInTerminal() {
        guard let session = model.selected else { return }
        if session.isExternal { focusSession(); return }
        // Like every terminal Nook opens: a tab of Terminal's front window, or a new window when it has none.
        keepIslandWithTerminal(appPID: TerminalAppBridge.terminalPID)
        model.terminalBridge.openTab(running: model.backend.attachmentCommand(for: session.record)) { [weak self, weak session] result in
            guard let self, let session else { return }
            guard case .success(let (opened, _)) = result else {
                self.model.notice = "macOS no permitió abrir Terminal. Usa ‘Copiar conexión’ y pega el comando en una terminal libre."
                return
            }
            session.externalWindowID = opened.windowID
            session.externalAppPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
            self.keepIslandWithTerminal(appPID: session.externalAppPID)
        }
    }

    func connectWindow(at point: CGPoint) {
        let quartzPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - point.y)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let supported = ["Terminal", "iTerm2", "iTerm", "Ghostty", "Warp", "Alacritty", "WezTerm", "kitty", "Cursor", "Code"]
        let target = windows.first { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  supported.contains(owner),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(quartzPoint)
        }
        if let target {
            targetPID = target[kCGWindowOwnerPID as String] as? pid_t
            targetWindowID = target[kCGWindowNumber as String] as? Int
            model.targetAppName = target[kCGWindowOwnerName as String] as? String
        } else {
            targetPID = nil; targetWindowID = nil; model.targetAppName = nil
            model.notice = "Suelta la mascota sobre una ventana de terminal. También puedes conectar una sesión desde aquí."
        }
        expand(focus: true)
        let terminalApp = targetPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } == "com.apple.Terminal"
        model.showConnections(windowID: terminalApp ? targetWindowID : nil)
    }
    func dragPet(to point: CGPoint) {
        draggingPet = true; cancelScheduledExpand(); collapseWork?.cancel(); collapseWork = nil
        if dragPanel == nil {
            alertPeek.cancel()
            let ghost = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            ghost.capturePrivacy = model.capturePrivacy
            ghost.allowsKey = false; ghost.isOpaque = false; ghost.backgroundColor = .clear; ghost.hasShadow = false
            ghost.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
            ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            ghost.spaceRole = "gato arrastrado"
            let cat = CatIconView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            cat.color = .white; cat.look = model.pet.look; cat.scaleFactor = 0.6; cat.animated = model.animations
            cat.wantsLayer = true; cat.layer?.backgroundColor = NSColor.black.cgColor; cat.layer?.cornerRadius = 10
            ghost.contentView = cat; dragPanel = ghost
        }
        (dragPanel?.contentView as? CatIconView)?.animated = model.animations
        (dragPanel?.contentView as? CatIconView)?.look = model.pet.look
        dragPanel?.setFrameOrigin(NSPoint(x: point.x - 16, y: point.y - 16))
        dragPanel?.orderFrontRegardless()
    }
    func finishPetDrag(at point: CGPoint) {
        dragPanel?.orderOut(nil); draggingPet = false
        petLanding.dropped(at: ProcessInfo.processInfo.systemUptime)
        connectWindow(at: point)
    }
    /// True once, when a cat that was dragged can land (see `PetLanding`).
    func takePetLanding(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        petLanding.ready(now: now, expanded: model.expanded, contentVisible: model.islandContentVisible, connectionSheet: model.connectionSheet)
    }
    func associateTarget() {
        guard let session = model.selected else { return }
        session.externalAppPID = targetPID
        session.externalWindowID = targetWindowID
        model.copyConnection()
        model.connectionSheet = false
        if let pid = targetPID { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        collapse(force: true)
    }
    private func raiseWindow(pid: pid_t, windowID: Int?) {
        if let windowID, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.Terminal" {
            let source = "tell application \"Terminal\"\nset index of window id \(windowID) to 1\nactivate\nend tell"
            DispatchQueue.global().async { _ = try? TerminalAppBridge.execute(source) }
            return
        }
        // Raising an exact third-party window works when the user already grants Accessibility.
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let window = windows.first else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.isVisible = !model.capturePrivacy.enabled
        statusItem?.button?.image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Nook") ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Nook")
        statusItem?.menu = menu()
        capturePrivacyWatch = model.capturePrivacy.$enabled.removeDuplicates().sink { [weak self] enabled in
            self?.statusItem?.isVisible = !enabled
        }
    }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action, key) in [("Abrir Nook", #selector(openPanel), ""), ("Nueva terminal", #selector(newTerminal), ""), ("Conectar una terminal…", #selector(connect), ""), ("Ajustes…", #selector(showSettingsFromMenu), ""), ("Permisos…", #selector(showPermissionsFromMenu), ""), ("Animaciones de la mascota", #selector(toggleAnimations), ""), ("Salir de Nook", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self
            if action == #selector(toggleAnimations) { item.state = model.animations ? .on : .off }
            menu.addItem(item)
        }
        return menu
    }
    func showMenu(event: NSEvent, in view: NSView) { NSMenu.popUpContextMenu(menu(), with: event, for: view) }
    @objc private func openPanel() { expand(focus: true) }
    @objc private func showSettingsFromMenu() { openSettings(tab: .island) }
    @objc private func showPermissionsFromMenu() { openSettings(tab: .permissions) }
    @objc private func newTerminal() { model.create(.shell) }
    @objc private func connect() { expand(focus: true); model.showConnections() }
    @objc private func toggleAnimations() { model.animations.toggle(); UserDefaults.standard.set(model.animations, forKey: "animations"); statusItem?.menu = menu() }
    /// Asks first, in the island (`AppModel.shouldTerminate`).
    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - On every Space

extension NotchController {
    /// When the checks after a wake, an unlock or a new screen run, in seconds: soon, and again once WindowServer and the Dock have had time to put
    /// their Spaces back.
    static let spaceCheckDelays: [TimeInterval] = [0.5, 2, 6]

    /// Two frames within a point of each other on every side.
    static func sameFrame(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.maxX - b.maxX) <= 1 && abs(a.maxY - b.maxY) <= 1
    }

    /// The island has to be at the notch on every Space, full-screen apps included, and a panel can turn out missing from one (`SpaceMembership`).
    /// A swipe to another Space is checked at once, so a panel missing there shows up as the swipe ends; a wake, an unlock or a reconfigured screen
    /// a few times over the following seconds, so it is right before the user swipes at all.
    fileprivate func watchSpaces() {
        spaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepOnEverySpace(reason: "cambio de espacio")
        })
        let later: [(Notification.Name, String)] = [(NSWorkspace.didWakeNotification, "despertar"), (NSWorkspace.screensDidWakeNotification, "pantallas encendidas"),
                                                    (NSWorkspace.sessionDidBecomeActiveNotification, "sesión activa")]
        for (name, reason) in later {
            spaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.checkSpacesSoon(reason: reason) })
        }
    }

    /// Checks the panels' Spaces after each delay; a new notification starts the series again (a wake brings several at once). The first check
    /// writes what it found to the Spaces log (`SpacesJournal`), before repairing anything; the later ones only what they had to repair.
    func checkSpacesSoon(reason: String, delays: [TimeInterval] = NotchController.spaceCheckDelays) {
        spaceChecks.forEach { $0.cancel() }
        spaceChecks = delays.enumerated().map { index, delay in
            let work = DispatchWorkItem { [weak self] in self?.keepOnEverySpace(reason: reason, report: index == 0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    /// Puts what the island's state wants on screen where it belongs, on every Space. Cheap enough for every swipe: it reads the visible panels'
    /// Spaces and changes nothing that is right.
    ///
    /// Collapsed, the cat's window is at the notch and shown, except while the island is still closing (its window goes, and the cat's comes, once
    /// the shape has reached the notch) or the cat is being dragged; open, the island's window is shown. Nothing in Nook puts those away otherwise,
    /// but if anything did they come back. Then every visible panel (either island, an alert's peek, the agents' tooltip, the settings card, the
    /// screen vision cue) is made a member of the Spaces of its display it is missing. Panels put away are seen to as they come back
    /// (`NotchPanel.orderFrontRegardless`).
    func keepOnEverySpace(reason: String, report: Bool = false) {
        let membership = SpaceMembership.shared
        if report, let journal = membership.journal {
            let displays = membership.backend.isAvailable ? membership.backend.displaySpaces() : []
            journal("\(reason) · " + [petPanel, panel].map { membership.describe($0, displays: displays) }.joined(separator: " · "))
        }
        var restored: NotchPanel?
        // A controller that was let go of (a test closing its windows) leaves them closed; with no display yet (a wake still bringing it back)
        // there is no notch to put anything at.
        if model.controller === self, !NSScreen.screens.isEmpty {
            if model.expanded {
                if !panel.isVisible { panel.alphaValue = restingAlpha; panel.orderFrontRegardless(); restored = panel }
            } else if petOut, !draggingPet, !panel.isVisible {
                // AppKit puts the window on whole points (the notch's centre can fall on a half), so only a real move counts.
                if !Self.sameFrame(petPanel.frame, compactFrame) { positionPet() }
                if !petPanel.isVisible { petPanel.orderFrontRegardless(); restored = petPanel }
            }
        }
        if let restored { membership.journal?("\(reason) · \(SpaceMembership.role(of: restored)): no estaba en pantalla, vuelve a mostrarse") }
        let repaired = membership.rejoinVisible(NSApplication.shared.windows, reason: reason)
        // The cat draws its next frame now rather than at its next tick, in case it sat out the sleep paused.
        if petPanel.isVisible, repaired > 0 || restored != nil || report { petView.needsDisplay = true; petView.react() }
    }
}

// MARK: - Growing for a card

extension NotchController {
    /// The usage card says how tall it wants to be (nil: it is gone). The island takes that height once the asks have settled, and gives it back when the card goes.
    func cardAsksForRoom(_ room: IslandRoom?) { roomKeeper.ask(room) }
}

extension NotchController: IslandRoomHost {
    var roomPanel: NSWindow { panel }
    var roomIsland: IslandView { island }
    var roomScreen: IslandScreen {
        let screen = self.screen
        return IslandScreen(frame: screen.frame, visible: screen.visibleFrame, topInset: screen.safeAreaInsets.top, neck: neckHeight, centerX: compactFrame.midX)
    }
    var roomUserSize: CGSize { userFrame.size }
    var roomMayMove: Bool { model.expanded && model.islandContentVisible && !resizingIsland && panel.isVisible }
    func roomDuration(_ base: Double) -> Double { reduceMotion || !model.animations ? 0 : base }
    func roomChanged() {
        // The content is laid out for `AppModel.islandSize` again, and the settings card, which hangs under the island, goes where the island ends. The corners' handles
        // are for the user's own size: they are there when the island has it, and not when it has a card's.
        model.objectWillChange.send()
        placeSettings()
        captureCue.reposition()
        grip.window?.invalidateCursorRects(for: grip)
    }
}
