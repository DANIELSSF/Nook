import AppKit
import Combine

enum NotchGeometry {
    static let expandedWidth: CGFloat = 572

    static func expandedHeight(topInset: CGFloat) -> CGFloat {
        ((210 + max(topInset, 28)) * 1.1).rounded()
    }

    static func idleFrame(screen: CGRect, left: CGRect?, right: CGRect?, topInset: CGFloat) -> CGRect {
        let notchWidth = left.flatMap { l in right.map { $0.minX - l.maxX } } ?? 180
        let notchCenter = left.flatMap { l in right.map { (l.maxX + $0.minX) / 2 } } ?? screen.midX
        return CGRect(x: notchCenter - notchWidth / 2 - 30, y: screen.maxY - max(topInset, 28), width: notchWidth + 60, height: max(topInset, 28))
    }

    /// The open island's frame: centred on the notch, hanging from the top edge. `settings` carries the user's size; with
    /// none, it is the Normal island (572 wide), clamped to the screen as it always was.
    static func expandedFrame(screen: CGRect, centerX: CGFloat, topInset: CGFloat, settings: DisplaySettings = DisplaySettings()) -> CGRect {
        let size = expandedSize(screen: screen.size, topInset: topInset, settings: settings)
        return CGRect(x: centerX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
}

final class NotchPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    /// Nook has no menu bar, so a command key reaches the window first: the island answers the shortcuts that belong to it
    /// (⌘+ ⌘− ⌘0 for the chat's text size) before the views below see the event. Returns whether it took it.
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Collapsed island: the cat lives in the left wing (30 pt, the camera cutout starts right after it); notices and activity sit in the right wing.
final class PetView: NSView {
    weak var controller: NotchController? { didSet { watchModel(); refresh() } }
    /// Where the indicators come from: the controller's model, unless a preview injects its own.
    var injectedModel: AppModel? { didSet { watchModel(); refresh() } }
    private var model: AppModel? { injectedModel ?? controller?.model }
    /// The cat's reaction to an alert (0...1 at a given system uptime); set only while one is showing.
    var perk: ((Double) -> CGFloat)?
    private var perkSince: Double?
    private var boostUntil = 0.0
    private var player = PetPlayer(layout: .compact, seed: PetPlayer.randomSeed())
    var pose = PetPose()
    private lazy var ticker = PetTicker { [weak self] in self?.step() }
    /// Seconds between the cat's frames right now: 0 when it has no timer at all (a still cat), the watchdog's while hidden.
    var frameInterval: TimeInterval { ticker.interval }
    private var pace = PetPace(fast: PetAnimation.compactInterval)
    private var user = PetUserProbe()
    /// The pointer was already within the cat's notice, so it has to go a little further to be forgotten.
    private var noticed = false
    private var modelWatch: AnyCancellable?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var windowObserver: NSObjectProtocol?
    private var tracking: NSTrackingArea?
    /// The agent pill's own tracking area: the pointer resting on it explains it (a tooltip) instead of opening the island.
    private var pillTracking: NSTrackingArea?
    private var overPill = false
    private let pillTip = AgentPillTip()
    private var pillTipWork: DispatchWorkItem?
    private var mouseDownPoint: CGPoint?
    private var dragStarted = false
    private var hovering = false
    private var wasVisible = false
    private var animating = false
    private var shown: (unread: Int, working: Bool, connected: Bool, glyph: String?, agents: Int) = (0, false, false, nil, 0)
    /// Claude's spinner color, so the symbol in the notch matches the terminal.
    static let claudeSpinner = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    private var tooltip = "Acércate para abrir Nook. Arrastra el gatito a una terminal para conectarla."
    /// Takes the files dragged onto the collapsed island: after a short hover the island opens so they can be dropped on
    /// it. Transparent and above the cat, so the cat's own drag and the hover are untouched.
    let fileDrop = FileDropView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = tooltip
        fileDrop.frame = bounds
        fileDrop.autoresizingMask = [.width, .height]
        addSubview(fileDrop)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Abrir Nook")
        setAccessibilityHelp("También puedes arrastrar aquí un archivo o una carpeta para añadir su ruta al mensaje.")
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        windowObserver.map(NotificationCenter.default.removeObserver)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObserver.map(NotificationCenter.default.removeObserver); windowObserver = nil
        guard let window else { ticker.stop(); wasVisible = false; return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.step() }
        refresh()
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        if let pillTracking { removeTrackingArea(pillTracking); self.pillTracking = nil }
        if let rect = AgentNotchBadge.hitRect(running: shown.agents, in: bounds) {
            let pill = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
            addTrackingArea(pill); pillTracking = pill
        }
        super.updateTrackingAreas()
    }
    private func isOverPill(_ event: NSEvent) -> Bool {
        AgentNotchBadge.hitRect(running: shown.agents, in: bounds)?.contains(convert(event.locationInWindow, from: nil)) ?? false
    }
    override func mouseEntered(with event: NSEvent) {
        if let pillTracking, event.trackingArea === pillTracking { enterPill(); return }
        hovering = true; step()
        // Arriving straight on the pill reads it instead of opening the island.
        if !isOverPill(event) { controller?.scheduleExpand() }
    }
    override func mouseExited(with event: NSEvent) {
        if let pillTracking, event.trackingArea === pillTracking {
            leavePill()
            // Moving from the pill to the rest of the island gives the hover back; leaving the island altogether does not.
            if hovering { controller?.scheduleExpand() }
            return
        }
        hovering = false; controller?.cancelScheduledExpand(); leavePill()
    }

    /// The pointer rests on the agent pill: the island does not open, and after a moment the tooltip says what the pill counts.
    private func enterPill() {
        overPill = true
        controller?.cancelScheduledExpand()
        toolTip = nil
        pillTipWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPillTip() }
        pillTipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func leavePill() {
        guard overPill else { return }
        overPill = false
        pillTipWork?.cancel(); pillTipWork = nil
        pillTip.hide()
        refresh()
    }
    private func showPillTip() {
        // An alert's peek hangs where the tooltip would; it is the louder thing.
        guard overPill, controller?.peekingAlert == nil, let window, let summary = model?.agentPill,
              let rect = AgentNotchBadge.hitRect(running: shown.agents, in: bounds), let screen = window.screen?.frame else { return }
        pillTip.show(AgentPillTooltip.text(summary), pill: window.convertToScreen(convert(rect, to: nil)), island: window.frame, screen: screen)
    }
    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil).x < 36 ? NSEvent.mouseLocation : nil
        dragStarted = false
        controller?.cancelScheduledExpand()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let initial = mouseDownPoint else { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - initial.x, point.y - initial.y) > 5 { dragStarted = true }
        if dragStarted {
            NSCursor.closedHand.set()
            controller?.dragPet(to: point)
        }
    }
    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        if dragStarted { controller?.finishPetDrag(at: NSEvent.mouseLocation) }
        // The agent pill opens the island on its tab with the list of its agents (an alert's peek keeps the click for itself).
        else if controller?.peekingAlert == nil, isOverPill(event) { pillTipWork?.cancel(); pillTip.hide(); controller?.openAgentList() }
        else if convert(event.locationInWindow, from: nil).x > bounds.width - 36, controller?.model.unreadCount ?? 0 > 0 { controller?.model.openLatestNotice() }
        // The island with an alert's peek around it is one thing to click: it opens the tab that is calling.
        else if let alert = controller?.peekingAlert { controller?.openAlertTab(alert) }
        else { controller?.expand(focus: true) }
        mouseDownPoint = nil; dragStarted = false
        controller?.positionPet()
    }
    override func rightMouseDown(with event: NSEvent) { controller?.showMenu(event: event, in: self) }
    override func accessibilityPerformPress() -> Bool { controller?.expand(focus: true); return true }

    /// A way to the agents' list for VoiceOver, which cannot point at a pill drawn into the view.
    private func syncAccessibility(agents: Int) {
        let actions = agents > 0 ? [NSAccessibilityCustomAction(name: "Ver la lista de subagentes") { [weak self] in self?.controller?.openAgentList(); return true }] : []
        if accessibilityCustomActions()?.count ?? 0 != actions.count { setAccessibilityCustomActions(actions) }
    }

    private func watchModel() {
        modelWatch = model?.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
    }

    /// Re-evaluates what to show: indicators, tooltip and whether the cat moves at all (a still cat has no timer).
    private func refresh() {
        guard let model else { return }
        toolTip = overPill ? nil : model.unreadCount > 0 ? "Una terminal tiene un aviso. Haz clic a la derecha para verlo." : tooltip
        let state = (unread: model.unreadCount, working: model.working, connected: model.selected != nil, glyph: model.activityGlyph, agents: model.runningSubagents)
        var dirty = state != shown
        // The pill's area (and its width at ten agents) follows the count.
        let reshaped = (state.agents > 0) != (shown.agents > 0) || (state.agents > 9) != (shown.agents > 9)
        shown = state
        if reshaped { updateTrackingAreas() }
        // The tooltip goes with the pill, and with the collapsed island; it follows the words when they change.
        if overPill {
            if model.expanded || state.agents == 0 { leavePill() }
            else if pillTip.isShown { showPillTip() }
        }
        syncAccessibility(agents: state.agents)
        animating = model.animations && !PetAnimation.motionReduced
        if animating {
            if ticker.interval == 0 { ticker.run(every: PetAnimation.watchdogInterval) }
            if dirty { needsDisplay = true }
            step()
            return
        }
        // A still cat has no timer: its pose says what is going on instead of moving to say it.
        ticker.stop(); player.settle(); wasVisible = false
        let still = PetAnimation.staticPose(working: model.working, attention: model.unreadCount > 0)
        if pose != still { pose = still; dirty = true }
        if dirty { needsDisplay = true }
    }

    /// Draws the next frame now (an alert starting or ending) instead of at the cat's next tick. With `boost` the
    /// frame rate stays up for the half second the cat takes to react, even if it was only breathing.
    func react(boost: Bool = false) {
        if boost { boostUntil = ProcessInfo.processInfo.systemUptime + 0.5 }
        step()
    }

    private func step() {
        guard animating, let model else { return }
        // A hidden island only keeps a slow watchdog alive so the cat wakes up when it collapses again.
        // A window can stay "visible" while fully covered (a full-screen app): only occlusion says it is seen.
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true, !isHidden else { wasVisible = false; hovering = false; ticker.run(every: PetAnimation.watchdogInterval); return }
        if !wasVisible { wasVisible = true; player.settle(); ticker.host = self; ticker.run(every: PetAnimation.compactInterval) }
        let now = ProcessInfo.processInfo.systemUptime
        // The pointer: noticed from a little way off (the cat looks at it), or anywhere over the island.
        let head = CGPoint(x: PetAnimation.compactAnchor + pose.x + pose.head.x * PetAnimation.compactScale, y: bounds.height / 2 - 9 + (pose.head.y + pose.y) * PetAnimation.compactScale)
        let gaze = petGaze(head: head, enter: 48, leave: 64, noticed: &noticed, over: hovering || mouseDownPoint != nil)
        user.read(now: now)
        var input = PetInput(working: model.working, gaze: gaze, dragging: dragStarted || controller?.isDraggingPet == true, completions: model.completions,
                             focus: .from(keyAge: user.keyAge, scrollAge: user.scrollAge), idle: user.idle, needsAttention: model.unreadCount > 0)
        if let amount = perk?(now), amount > 0.001 {
            let since = perkSince ?? now
            perkSince = since
            input.perk = amount; input.perkAge = now - since
        } else { perkSince = nil }
        let next = player.pose(now: now, layout: .compact(height: bounds.height), motion: true, input: input)
        let dots = model.working && model.unreadCount == 0 && model.activityGlyph == nil
        // The working dots wave on their own, so they keep at least 15 frames a second. A gesture under way runs at the full rate.
        var wanted = pace.interval(for: next, now: now)
        if player.isBusy { wanted = PetAnimation.compactInterval }
        ticker.run(every: min(now < boostUntil ? PetAnimation.compactInterval : wanted, dots ? 1.0 / 15 : .infinity))
        // Frames repaint only what moved: the cat's wing, and the dots while they wave.
        if next.distance(to: pose) > 0.01 || next.action != pose.action { pose = next; setNeedsDisplay(Self.catArea(bounds)) }
        if dots { setNeedsDisplay(Self.indicatorArea(bounds)) }
    }

    static func catArea(_ bounds: NSRect) -> NSRect { NSRect(x: 0, y: 0, width: 40, height: bounds.height) }
    static func indicatorArea(_ bounds: NSRect) -> NSRect { NSRect(x: bounds.width - 40, y: 0, width: 40, height: bounds.height) }

    /// The island's black shape: square top against the screen edge, rounded bottom corners.
    static func islandPath(_ bounds: NSRect) -> NSBezierPath {
        let wing = NSBezierPath()
        wing.move(to: NSPoint(x: 0, y: bounds.height))
        wing.line(to: NSPoint(x: bounds.width, y: bounds.height))
        wing.line(to: NSPoint(x: bounds.width, y: 10))
        wing.curve(to: NSPoint(x: bounds.width - 10, y: 0), controlPoint1: NSPoint(x: bounds.width, y: 4), controlPoint2: NSPoint(x: bounds.width - 4, y: 0))
        wing.line(to: NSPoint(x: 10, y: 0))
        wing.curve(to: NSPoint(x: 0, y: 10), controlPoint1: NSPoint(x: 4, y: 0), controlPoint2: NSPoint(x: 0, y: 4))
        wing.close()
        return wing
    }

    /// Paints the cat in the wing of an island of `bounds` (origin at its bottom left). The island's own shape is the
    /// mask: a cat peeking over the edge is cut by it, and nothing can land outside what the island draws.
    static func drawCat(_ pose: PetPose, bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        islandPath(bounds).addClip()
        let ground = bounds.height / 2 - 9
        NSGraphicsContext.current?.cgContext.translateBy(x: PetAnimation.compactAnchor + pose.x, y: ground)
        NSGraphicsContext.current?.cgContext.scaleBy(x: PetAnimation.compactScale, y: PetAnimation.compactScale)
        PetAnimation.draw(pose, color: .white, ledge: -ground / PetAnimation.compactScale)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        Self.islandPath(bounds).fill()
        // Animation frames only dirty the cat's wing; text in the other wing is laid out only when it changes.
        if dirtyRect.intersects(Self.catArea(bounds)) { Self.drawCat(pose, bounds: bounds) }
        if dirtyRect.intersects(Self.indicatorArea(bounds)) { drawIndicators() }
    }

    private func drawIndicators() {
        let working = model?.working == true
        if model?.unreadCount ?? 0 > 0 {
            let rect = NSRect(x: bounds.width - 25, y: bounds.midY - 6, width: 12, height: 12)
            NSColor(red: 0.91, green: 0.79, blue: 0.54, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            ("!" as NSString).draw(at: NSPoint(x: rect.minX + 4.1, y: rect.minY + 0.5), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black])
        } else if working, let glyph = model?.activityGlyph {
            // The same symbol Claude's spinner shows in the terminal right now.
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: Self.claudeSpinner]
            let size = (glyph as NSString).size(withAttributes: attributes)
            (glyph as NSString).draw(at: NSPoint(x: bounds.width - 19 - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        } else if working {
            for i in 0..<3 {
                NSColor.systemMint.setFill()
                let offset = animating ? sin(player.wall * 5 + CGFloat(i)) * 2 : 0
                NSBezierPath(ovalIn: NSRect(x: bounds.width - 27 + CGFloat(i) * 5, y: bounds.midY - 1.5 + offset, width: 3, height: 3)).fill()
            }
        } else if model?.selected != nil {
            NSColor.systemMint.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 18, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
        AgentNotchBadge.draw(running: model?.runningSubagents ?? 0, in: bounds)
    }
}

import SwiftUI
/// The cat as a standalone icon: the transition overlay in the panel and, with `scaleFactor`, the drag ghost.
struct CatIcon: NSViewRepresentable {
    var color: NSColor = .labelColor
    var animated = false
    var working = false
    var controller: NotchController?
    func makeNSView(context: Context) -> CatIconView { let view = CatIconView(); view.xOffset = CatIconView.overlayOffset; return view }
    func updateNSView(_ nsView: CatIconView, context: Context) { nsView.color = color; nsView.animated = animated; nsView.working = working; nsView.controller = controller; nsView.needsDisplay = true }
}
final class CatIconView: NSView {
    /// Puts the overlay cat where the compact one sits: the panel lays a 24 pt icon out at x 8 and scales it by 0.6 around its centre.
    static let overlayOffset: CGFloat = (PetAnimation.compactAnchor - 20) / 0.6
    var color: NSColor = .labelColor
    var animated = false
    var working = false
    var scaleFactor: CGFloat = 1
    var xOffset: CGFloat = 0
    weak var controller: NotchController?
    private var dragStart: CGPoint?
    private var dragging = false
    private lazy var ticker = PetTicker { [weak self] in self?.step() }
    private var windowObserver: NSObjectProtocol?
    /// The drag ghost owns its panel; it dangles from the pointer instead of sitting.
    private var isGhost: Bool { window?.contentView === self }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { windowObserver.map(NotificationCenter.default.removeObserver) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObserver.map(NotificationCenter.default.removeObserver); windowObserver = nil
        guard let window, isGhost else { ticker.stop(); return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in self?.step() }
        step()
    }
    private func step() {
        // The drag ghost follows the same "Animaciones de la mascota" preference as the other cats.
        guard isGhost, animated, window?.isVisible == true, !PetAnimation.motionReduced else { ticker.stop(); needsDisplay = true; return }
        ticker.host = self
        ticker.run(every: 1.0 / 60)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation; dragging = false; controller?.cancelScheduledExpand() }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, controller != nil else { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - start.x, point.y - start.y) > 5 { dragging = true }
        if dragging { NSCursor.closedHand.set(); controller?.dragPet(to: point) }
    }
    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        if dragging { controller?.finishPetDrag(at: NSEvent.mouseLocation) }
        else { controller?.expand(focus: true) }
        dragging = false; dragStart = nil
    }
    override func draw(_ dirtyRect: NSRect) {
        let moving = !PetAnimation.motionReduced
        let now = ProcessInfo.processInfo.systemUptime
        let pose = isGhost ? PetAnimation.lifted(time: animated && moving ? now : 0) : (animated && moving ? PetAnimation.sit(time: now) : PetPose())
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: bounds.midX + xOffset * scaleFactor, y: bounds.midY - 15 * scaleFactor)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scaleFactor, y: scaleFactor)
        PetAnimation.draw(pose, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }
}
