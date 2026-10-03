import AppKit
import SwiftUI
import ApplicationServices
import QuartzCore

/// Holds the island's SwiftUI content at full size and shows it through an animated shape. Core
/// Animation morphs the shape on the render server, so opening never resizes the window or lays
/// the panel out again on every frame.
final class IslandView: NSView {
    let shape = CAShapeLayer()

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

    func reveal(_ rect: CGRect, radius: CGFloat, duration: Double, timing: CAMediaTimingFunction = .init(name: .default), completion: @escaping () -> Void) {
        let path = Self.outline(rect, radius: radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        if duration > 0 {
            let morph = CABasicAnimation(keyPath: "path")
            // An interrupted transition continues from where the shape is on screen.
            morph.fromValue = shape.presentation()?.path ?? shape.path
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

final class NotchController: NSObject, NSWindowDelegate {
    let model: AppModel
    let petPanel: NotchPanel
    let panel: NotchPanel
    let petView: PetView
    private var alertPeek: AlertPeekController!
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var localMonitor: Any?
    private var trackingTimer: Timer?
    private var mirrors: [String: (NSWindow, ActivityTerminalView)] = [:]
    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
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
    private let island = IslandView()
    /// Takes the files dragged over the open island, wherever on it they are.
    private let islandDrop = FileDropView()
    /// The handles on the open island's bottom corners that drag its size.
    private let grip = IslandResizeGrip()
    /// The island's size is being dragged by its corner: it stays open however the pointer wanders meanwhile.
    private var resizingIsland = false
    /// What a file drag does: opens the collapsed island, keeps it open, hands the paths to the composer.
    private(set) var fileDrops: FileDropCoordinator!
    private static let islandCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The collapsed island inside the panel, which always keeps its expanded size.
    private var compactShape: CGRect {
        let full = expandedFrame, compact = compactFrame
        return CGRect(x: compact.minX - full.minX, y: compact.minY - full.minY, width: compact.width, height: compact.height)
    }
    private weak var focusedMirror: NSWindow?

    var screen: NSScreen { NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first! }
    var neckHeight: CGFloat { max(screen.safeAreaInsets.top, 28) }
    var notchWidth: CGFloat {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { return right.minX - left.maxX }
        return 180
    }
    var compactFrame: NSRect {
        NotchGeometry.idleFrame(screen: screen.frame, left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea, topInset: screen.safeAreaInsets.top)
    }
    var expandedFrame: NSRect {
        NotchGeometry.expandedFrame(screen: screen.frame, centerX: compactFrame.midX, topInset: screen.safeAreaInsets.top, settings: model.display)
    }

    init(model: AppModel) {
        self.model = model
        petPanel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        petView = PetView(frame: .zero)
        super.init()
        model.controller = self
        model.permissions.onOpenedSettings = { [weak self] in self?.permissionsHandOff() }
        petView.controller = self
        for window in [petPanel, panel] {
            window.isOpaque = false; window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.hidesOnDeactivate = false
        }
        petPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        petPanel.allowsKey = false
        petPanel.hasShadow = false
        petPanel.contentView = petView
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
        grip.isActive = { [weak self] in self?.model.expanded == true && self?.model.islandContentVisible == true }
        grip.onBegin = { [weak self] _ in
            guard let self, self.model.expanded else { return nil }
            self.resizingIsland = true
            return self.expandedFrame.size
        }
        grip.onResize = { [weak self] size in self?.resizeIsland(to: size) }
        grip.onEnd = { [weak self] in self?.resizingIsland = false }
        island.addSubview(grip)
        panel.contentView = island
        panel.minSize = .zero
        positionPet()
        petPanel.orderFrontRegardless()
        setupMenu()
        alertPeek = AlertPeekController(notch: self)
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
            self?.alertPeek.cancel(); self?.positionPet(); self?.positionPanel(); self?.placeSettings()
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clickedOutside() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // The tab editor's popover and Nook's alerts belong to the island; other Nook windows don't.
            if event.window !== self.panel, event.window !== self.petPanel, !self.alertPeek.owns(event.window), self.model.editingSessionID == nil, NSApp.modalWindow == nil { self.clickedOutside() }
            return event
        }
    }

    func positionPet() {
        // The compact surface extends both sides of the hardware cutout as one island.
        petPanel.setFrame(compactFrame, display: true)
        petView.frame = NSRect(origin: .zero, size: petPanel.frame.size)
    }
    private func positionPanel() {
        panel.setFrame(expandedFrame, display: model.expanded)
        island.layoutSubtreeIfNeeded()
        if model.expanded { island.reveal(island.bounds, radius: 22, duration: 0) {}; panel.invalidateShadow() }
    }

    // MARK: Display settings

    /// The settings changed (`AppModel.display`). Text sizes reach the views through SwiftUI; only a new island size has to
    /// reach the window, and only while it is open: a collapsed island takes its size when it opens next.
    func displayChanged(from old: DisplaySettings) {
        let resized = old.widthExtra != model.display.widthExtra || old.heightExtra != model.display.heightExtra
        guard resized, model.expanded, panel.frame != expandedFrame else { return }
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
        // Out of the pane's way at once: the card would cover the very switch the user is being sent to.
        closeSettings(keepingResume: true)
        collapse()
    }
    private func resumePermissionsIfDue() {
        guard permissionsResume.due(now: Date()), !model.settingsOpen else { return }
        model.settingsTab = .permissions
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
            // nothing is laid out again while it animates.
            if panel.frame != expandedFrame { panel.setFrame(expandedFrame, display: false); island.layoutSubtreeIfNeeded() }
            if !panel.isVisible {
                let full = expandedFrame
                let start = peekShape.map { (CGRect(x: $0.rect.minX - full.minX, y: $0.rect.minY - full.minY, width: $0.rect.width, height: $0.rect.height), $0.radius) }
                island.reveal(start?.0 ?? compactShape, radius: start?.1 ?? 10, duration: 0) {}
            }
            // The window shadow can't follow a moving shape; it returns once the island settles.
            panel.hasShadow = false
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            petPanel.orderOut(nil)
            island.reveal(island.bounds, radius: 22, duration: reduceMotion ? 0 : 0.32, timing: Self.islandCurve) { [weak self] in
                guard let self, self.transitionID == transition, self.model.expanded else { return }
                self.panel.hasShadow = true; self.panel.invalidateShadow()
                withAnimation(.easeOut(duration: self.reduceMotion ? 0 : 0.13)) { self.model.islandContentVisible = true }
                self.resumePermissionsIfDue()
                self.showSettings()
                if focus { self.focusTerminal() }
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
    private func focusTerminal() {
        guard let selected = model.selected, !selected.isExternal else { return }
        let terminal = selected.terminal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.model.expanded, self.panel.isKeyWindow else { return }
            self.panel.makeFirstResponder(terminal)
        }
    }
    func collapse(force: Bool = false) {
        // A question waiting on the user holds the island open like the pin does; only an explicit collapse lets go,
        // and it also stops that same prompt from opening the island again.
        if (model.pinned || model.promptHoldsIsland) && !force { return }
        if force { model.dismissPrompt() }
        endTerminalPresentation()
        cancelScheduledExpand(); collapseWork?.cancel()
        guard model.expanded else { return }
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
            self.positionPet(); self.petPanel.orderFrontRegardless()
        }
    }
    /// Pointer tracking only matters while the island is open; collapsed, the cat's own tracking
    /// area notices the pointer, so nothing wakes the app up several times a second.
    private func startTracking() {
        guard trackingTimer == nil else { return }
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.trackPointer() }
        trackingTimer?.tolerance = 0.05
    }
    private func stopTracking() { trackingTimer?.invalidate(); trackingTimer = nil }

    /// A click anywhere outside the island hides it, also after showing a terminal. Only a cat drag
    /// and the macOS permission prompt that discovery may raise keep it open (pinning still wins).

    private func clickedOutside() {
        guard !draggingPet, !model.terminalBridge.searching, !model.permissions.isRequesting else { return }
        let point = NSEvent.mouseLocation
        if !owns(point: point) { collapse() }
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
        guard model.expanded, !model.pinned, !model.promptHoldsIsland, !model.connectionSheet, model.editingSessionID == nil else { return }
        let point = NSEvent.mouseLocation
        let inside = owns(point: point, slack: 12)
        if inside { collapseWork?.cancel(); collapseWork = nil }
        else if collapseWork == nil && !panel.isKeyWindow {
            let work = DispatchWorkItem { [weak self] in self?.collapse() }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
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
        let command = model.backend.attachmentCommand(for: session.record)
        let appleString = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\nset sharedTab to do script \"\(appleString)\"\nreturn id of front window\nend tell"
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
            var scriptError: NSDictionary?
            let result: NSAppleEventDescriptor?
            do { result = try TerminalAppBridge.execute(source) }
            catch { result = nil; scriptError = [NSAppleScript.errorMessage: error.localizedDescription] as NSDictionary }
            DispatchQueue.main.async {
                guard let self, let session else { return }
                if scriptError != nil {
                    self.model.notice = "macOS no permitió abrir Terminal. Usa ‘Copiar conexión’ y pega el comando en una terminal libre."
                    return
                }
                session.externalWindowID = result.map { Int($0.int32Value) }
                session.externalAppPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first?.processIdentifier
                self.keepIslandWithTerminal(appPID: session.externalAppPID)
            }
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
            ghost.allowsKey = false; ghost.isOpaque = false; ghost.backgroundColor = .clear; ghost.hasShadow = false
            ghost.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
            ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let cat = CatIconView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
            cat.color = .white; cat.scaleFactor = 0.6; cat.animated = model.animations
            cat.wantsLayer = true; cat.layer?.backgroundColor = NSColor.black.cgColor; cat.layer?.cornerRadius = 10
            ghost.contentView = cat; dragPanel = ghost
        }
        (dragPanel?.contentView as? CatIconView)?.animated = model.animations
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
        statusItem?.button?.image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Nook") ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Nook")
        statusItem?.menu = menu()
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
    @objc private func quit() { NSApp.terminate(nil) }
}
