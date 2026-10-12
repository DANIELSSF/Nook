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

final class NotchPanel: CapturePrivacyPanel {
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

    /// What the panel is, in the Spaces log (`SpacesJournal`).
    var spaceRole: String?
    // Ordered in again, a panel keeps the Spaces it had; one that lost a Space (a wake reconfigured the display while it was put away) would
    // come back missing it, so each time it comes on screen it is made a member of every Space of its display again (`SpaceMembership`).
    // Only on the way in: a panel already showing (the drag ghost follows the pointer with an order per move) asks nothing.
    override func orderFrontRegardless() {
        let shown = isVisible
        super.orderFrontRegardless()
        if !shown { rejoinSpaces() }
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        let shown = isVisible
        super.order(place, relativeTo: otherWin)
        if place != .out, !shown { rejoinSpaces() }
        // What moves in it stops at once, without waiting for its occlusion to be reported (`PetSight`).
        if place == .out, shown { NotificationCenter.default.post(name: PetSight.wentOffScreen, object: self) }
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        let shown = isVisible
        super.makeKeyAndOrderFront(sender)
        if !shown { rejoinSpaces() }
    }
    private func rejoinSpaces() {
        guard isVisible else { return }
        SpaceMembership.shared.rejoin(self, reason: "al mostrarse")
        // The cats in it keep no timer while it is away; this wakes them at once, without waiting for its occlusion to be reported.
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: self)
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
    private var driver = PetDriver(layout: .compact)
    /// The cat that sleeps when Nook opens at night is this cat too (`PetBedtime`).
    private var bedtime = PetBedtimeFollower()
    private var petBedtime: PetBedtime? { model?.petBedtime }
    var pose = PetPose()
    /// How the cat is dressed now (`AppModel.pet.look`), read whenever the model changes, so a change in the settings shows at once.
    private(set) var look = PetLook()
    private lazy var ticker = PetTicker(timed: { [weak self] lead in self?.step(lead: lead) })
    /// Seconds between the cat's frames right now: 0 when it has no timer at all (a still cat, or one nobody can see).
    var frameInterval: TimeInterval { ticker.interval }
    /// The ticks the cat has taken (each computes a pose and may repaint): tests count them.
    private(set) var ticks = 0
    private var user = PetUserProbe()
    private var dayClock = PetClock()
    private var dots = PetDotsClock()
    private var lastNow = 0.0
    /// The pointer was already within the cat's notice, so it has to go a little further to be forgotten.
    private var noticed = false
    private var modelWatch: AnyCancellable?
    /// A refresh is already on its way for the model's changes of this turn of the run loop.
    private var refreshQueued = false
    /// What the cat and the dots were last told by the model: only a change in it calls for a frame (`refresh`).
    private var heard: PetHeard?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    /// The agent pill's own tracking area: the pointer resting on it explains it (a tooltip) instead of opening the island.
    private var pillTracking: NSTrackingArea?
    private var overPill = false
    private lazy var pillTip = AgentPillTip { [weak self] panel in
        panel.capturePrivacy = self?.model?.capturePrivacy
    }
    private var pillTipWork: DispatchWorkItem?
    private var mouseDownPoint: CGPoint?
    private var dragStarted = false
    private var hovering = false
    private var wasVisible = false
    private var animating = false
    private var shown: (unread: Int, working: Bool, connected: Bool, glyph: String?, agents: Int) = (0, false, false, nil, 0)
    /// The working dots' colour, resolved once: the island's mint on black, the one the open island's header has (`NookTheme.swift`).
    private static let dotColor = NookPalette.mintOnBlack.cgColor
    /// Claude's spinner color, so the symbol in the notch matches the terminal (and the open island's: terracotta on black).
    static let claudeSpinner = NookPalette.terracottaOnBlack
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
        observers.append((center, center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh(asked: true) }))
        // A Mac that starts saving power, or running hot, changes what the cat may do; screens that sleep or wake, whether it is seen.
        let defaults = NotificationCenter.default
        observers.append((defaults, defaults.addObserver(forName: PetPowerMonitor.didChange, object: nil, queue: .main) { [weak self] _ in self?.refresh(asked: true) }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        guard let window else { ticker.stop(); wasVisible = false; return }
        driver.pace.backing = window.backingScaleFactor
        // Nobody can see a cat whose window is away or covered, and it keeps no timer: these wake it when it can be seen again.
        windowObservers = PetSight.wakeups(for: window) { [weak self] in self?.step() }
        petBedtime?.lights(dark: effectiveAppearance.nookIsDark)
        refresh()
    }
    override func viewDidUnhide() { super.viewDidUnhide(); step() }
    /// The island's light, as this window shows it: a sleeping cat wakes when it turns light (`PetBedtime.lights`).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        petBedtime?.lights(dark: effectiveAppearance.nookIsDark)
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
        else {
            // The click that opens the island wakes a sleeping cat: it wakes, gently, in the header the island opens with (hovering to open it does not).
            petBedtime?.click()
            controller?.expand(focus: true)
        }
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

    /// The model announces every change of anything in it (tabs, snapshots of Terminal, text), several a second while Claude works:
    /// one refresh answers all the changes of a turn of the run loop.
    private func watchModel() {
        modelWatch = model?.objectWillChange.sink { [weak self] _ in
            guard let self, !self.refreshQueued else { return }
            self.refreshQueued = true
            DispatchQueue.main.async { [weak self] in self?.refreshQueued = false; self?.refresh() }
        }
    }

    /// Re-evaluates what to show: indicators, tooltip and whether the cat moves at all (a still cat has no timer). `asked`: the Mac's
    /// state changed (power, the screens, Reduce Motion), and the cat looks again at once whether it may run and be seen.
    private func refresh(asked: Bool = false) {
        guard let model else { return }
        // Only when it changed: this runs on every change of the model, and setting a tooltip re-registers it with the window.
        let tip = overPill ? nil : model.unreadCount > 0 ? "Una terminal tiene un aviso. Haz clic a la derecha para verlo." : tooltip
        if toolTip != tip { toolTip = tip }
        let state = (unread: model.unreadCount, working: model.working, connected: model.selected != nil, glyph: model.activityGlyph, agents: model.runningSubagents)
        var dirty = state != shown
        if look != model.pet.look { look = model.pet.look; dirty = true }
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
        animating = model.animations && !PetAnimation.motionReduced && PetPowerMonitor.shared.state != .minimal
        if animating {
            if dirty { needsDisplay = true }
            // A frame now only for what the cat or the dots show, or for a cat that has no timer (it may have just come into sight).
            // The rest of the model's traffic (tabs, Terminal's snapshots every two seconds, text) waits for the cat's next tick: a frame
            // for each would wake the Mac and repaint out of the cat's own rhythm.
            let news = PetHeard(model)
            if news != heard || ticker.interval == 0 || asked { heard = news; step() }
            return
        }
        // A still cat has no timer: its pose says what is going on instead of moving to say it.
        heard = nil
        ticker.stop(); driver.settle(); wasVisible = false
        let still = PetAnimation.staticPose(working: model.working, attention: model.unreadCount > 0, asleep: model.petBedtime.isAsleep)
        if pose != still { pose = still; dirty = true }
        if dirty { needsDisplay = true }
    }

    /// Draws the next frame now (an alert starting or ending) instead of at the cat's next tick. With `boost` the
    /// frame rate stays up for the half second the cat takes to react, even if it was only breathing.
    func react(boost: Bool = false) {
        if boost { boostUntil = ProcessInfo.processInfo.systemUptime + 0.5 }
        step()
    }

    /// One tick: from the display link (with how far ahead its frame will be shown), from the timer, or from something that happened.
    private func step(lead: CFTimeInterval? = nil) {
        guard animating, let model else { return }
        // Nobody can see it (the island is open, a full-screen app covers it, the screens sleep or are locked): no timer at all, until
        // what brings it back wakes it (`PetSight`).
        guard PetSight.canSee(self) else { wasVisible = false; hovering = false; ticker.pause(); return }
        ticks += 1
        if !wasVisible { wasVisible = true; driver.settle(); ticker.host = self; ticker.run(every: PetCadence.fast(.compact, power: PetPowerMonitor.shared.state)) }
        let now = max(ProcessInfo.processInfo.systemUptime + (lead ?? 0), lastNow)
        lastNow = now
        // In bed at night, or woken since it last looked.
        bedtime.follow(petBedtime, player: &driver.player, now: ProcessInfo.processInfo.systemUptime)
        // The pointer: noticed from a little way off (the cat looks at it), or anywhere over the island.
        let head = CGPoint(x: PetAnimation.compactAnchor + pose.x + pose.head.x * PetAnimation.compactScale, y: bounds.height / 2 - 9 + (pose.head.y + pose.y) * PetAnimation.compactScale)
        let gaze = petGaze(head: head, enter: 48, leave: 64, noticed: &noticed, over: hovering || mouseDownPoint != nil)
        user.read(now: now); dayClock.read(now: now)
        var input = PetInput(working: model.working, gaze: gaze, dragging: dragStarted || controller?.isDraggingPet == true, completions: model.completions,
                             focus: .from(keyAge: user.keyAge, scrollAge: user.scrollAge), idle: user.idle, needsAttention: model.unreadCount > 0)
        input.prefs = model.pet; input.power = PetPowerMonitor.shared.state; input.dayPart = dayClock.part
        if let amount = perk?(now), amount > 0.001 {
            let since = perkSince ?? now
            perkSince = since
            input.perk = amount; input.perkAge = now - since
        } else { perkSince = nil }
        driver.pace.backing = window?.backingScaleFactor ?? 2
        let tick = driver.tick(now: now, layout: .compact(height: bounds.height), input: input)
        // The working dots wave on their own, so they keep a frame rate of their own (and only theirs, however often the cat ticks).
        // A reaction that has just begun runs at the full rate even if the cat was only breathing.
        let dotFrame = dots.frame(now: now, waving: model.working && model.unreadCount == 0 && model.activityGlyph == nil)
        ticker.run(every: min(now < boostUntil ? min(tick.interval, 1.0 / 20) : tick.interval, dotFrame.within ?? .infinity))
        // Frames repaint only what moved: the cat's wing, and the dots when their frame is due.
        if tick.draw { pose = tick.pose; setNeedsDisplay(Self.catArea(bounds)) }
        if dotFrame.draw { setNeedsDisplay(Self.indicatorArea(bounds)) }
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
    static func drawCat(_ pose: PetPose, look: PetLook = PetLook(), bounds: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        PetWing.drawCat(pose, look: look, bounds: bounds, in: cg)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        // The island's black, and over it the cat; the path is made once per size. Animation frames only dirty the cat's wing; text in
        // the other wing is laid out only when it changes.
        cg.setFillColor(CGColor(gray: 0, alpha: 1))
        cg.addPath(PetWing.islandPath(bounds)); cg.fillPath()
        if dirtyRect.intersects(Self.catArea(bounds)) { PetWing.drawCat(pose, look: look, bounds: bounds, in: cg) }
        if dirtyRect.intersects(Self.indicatorArea(bounds)) { drawIndicators() }
    }

    private func drawIndicators() {
        let working = model?.working == true
        if model?.unreadCount ?? 0 > 0 {
            let rect = NSRect(x: bounds.width - 25, y: bounds.midY - 6, width: 12, height: 12)
            NookPalette.amberOnBlack.setFill()
            NSBezierPath(ovalIn: rect).fill()
            ("!" as NSString).draw(at: NSPoint(x: rect.minX + 4.1, y: rect.minY + 0.5), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black])
        } else if working, let glyph = model?.activityGlyph {
            // The same symbol Claude's spinner shows in the terminal right now.
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: Self.claudeSpinner]
            let size = (glyph as NSString).size(withAttributes: attributes)
            (glyph as NSString).draw(at: NSPoint(x: bounds.width - 19 - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        } else if working, let cg = NSGraphicsContext.current?.cgContext {
            // Three dots that wave (drawn straight into the context: this is repainted eight times a second while Claude works).
            cg.setFillColor(Self.dotColor)
            for i in 0..<3 {
                let offset = animating ? sin(driver.player.wall * 5 + CGFloat(i)) * 2 : 0
                cg.fillEllipse(in: CGRect(x: bounds.width - 27 + CGFloat(i) * 5, y: bounds.midY - 1.5 + offset, width: 3, height: 3))
            }
        } else if model?.selected != nil {
            NookPalette.mintOnBlack.withAlphaComponent(0.65).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 18, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
        AgentNotchBadge.draw(running: model?.runningSubagents ?? 0, in: bounds)
    }
}

/// What the collapsed cat and its dots take from the model: Claude working, the completions it cheers, a notice waiting, what the notch
/// shows instead of the dots, and the user's choices. A change in anything else of the model is no reason for a frame.
private struct PetHeard: Equatable {
    var working: Bool, completions: Int, attention: Bool, glyph: Bool, pet: PetPreferences
    init(_ model: AppModel) {
        working = model.working; completions = model.completions; attention = model.unreadCount > 0
        glyph = model.activityGlyph != nil; pet = model.pet
    }
}

import SwiftUI
/// The cat as a standalone icon: the transition overlay in the panel and, with `scaleFactor`, the drag ghost.
struct CatIcon: NSViewRepresentable {
    /// Kept for callers that pass one: the cat's colour is its coat (`look`).
    var color: NSColor = .labelColor
    var animated = false
    var working = false
    var controller: NotchController?
    /// How the user dressed the cat (`AppModel.pet`).
    var look = PetLook()
    /// The cat is in bed for the night (`PetBedtime`): the overlay stands in for the collapsed cat, which is asleep.
    var asleep = false
    func makeNSView(context: Context) -> CatIconView { let view = CatIconView(); view.xOffset = CatIconView.overlayOffset; return view }
    func updateNSView(_ nsView: CatIconView, context: Context) {
        nsView.controller = controller
        nsView.show(color: color, look: look, animated: animated, working: working, asleep: asleep)
    }
}
final class CatIconView: NSView {
    /// Puts the overlay cat where the compact one sits: the panel lays a 24 pt icon out at x 8 and scales it by 0.6 around its centre.
    static let overlayOffset: CGFloat = (PetAnimation.compactAnchor - 20) / 0.6
    var color: NSColor = .labelColor
    /// The coat and what the cat wears, as the collapsed island's cat has them.
    var look = PetLook()
    var animated = false
    var working = false
    /// Asleep in bed for the night: a still, curled cat.
    var asleep = false
    var scaleFactor: CGFloat = 1
    var xOffset: CGFloat = 0
    weak var controller: NotchController?
    /// The frame last painted caught the cat with its eyes closing or closed (`CatIcon` repaints it at its next update).
    private(set) var holdsBlink = false
    private var dragStart: CGPoint?
    private var dragging = false
    private lazy var ticker = PetTicker { [weak self] in self?.step() }
    private var windowObserver: NSObjectProtocol?
    /// The drag ghost owns its panel; it dangles from the pointer instead of sitting.
    private var isGhost: Bool { window?.contentView === self }
    /// How far the dangling cat has swung, in radians: a pendulum hung from the pointer. It swings against the way the pointer moves,
    /// overshoots, and hangs straight again when the pointer stops.
    private(set) var swing = PetSpring()
    private var lastOrigin: (point: CGPoint, time: Double)?
    /// The swing a pointer moving sideways at `velocity` points a second pulls the cat toward: against the motion, and never far enough
    /// to leave the little window the ghost lives in.
    static func swingTarget(velocity: CGFloat) -> CGFloat { max(-0.4, min(0.4, -velocity * 0.0006)) }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { windowObserver.map(NotificationCenter.default.removeObserver) }

    /// What `CatIcon` hands the view on an update of the panel. It is repainted only when what it shows changed, or when the frame it
    /// holds caught a blink (it stands in for the collapsed cat, whose eyes are open nearly always): SwiftUI updates it whenever the
    /// panel passes it something it cannot tell is the same, it is drawn even while the panel hides it (opacity 0), and a repaint costs
    /// far more than the drawing in it. Returns whether it is repainted.
    @discardableResult func show(color: NSColor, look: PetLook, animated: Bool, working: Bool, asleep: Bool = false) -> Bool {
        let changed = self.color != color || self.look != look || self.animated != animated || self.working != working || self.asleep != asleep
        self.color = color; self.look = look; self.animated = animated; self.working = working; self.asleep = asleep
        guard changed || holdsBlink else { return false }
        needsDisplay = true
        return true
    }
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
        guard isGhost, animated, window?.isVisible == true, !PetAnimation.motionReduced else { ticker.stop(); swing = PetSpring(); lastOrigin = nil; needsDisplay = true; return }
        ticker.host = self
        ticker.run(every: PetAnimation.ghostInterval)
        // Swung by the way the pointer carries it.
        if let window {
            let now = ProcessInfo.processInfo.systemUptime, origin = window.frame.origin
            if let last = lastOrigin, now > last.time {
                let dt = min(now - last.time, 0.1)
                _ = swing.advance(to: Self.swingTarget(velocity: (origin.x - last.point.x) / CGFloat(dt)), PetSpring.Step(w: 8, zeta: 0.28, dt: CGFloat(dt)))
            }
            lastOrigin = (origin, now)
        }
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
        var pose = isGhost ? PetAnimation.lifted(time: animated && moving ? now : 0) : (animated && moving ? PetAnimation.sit(time: now) : PetPose())
        // The cat of the overlay blinks like the one it stands in for; one that sleeps is curled up, still.
        let open = pose.eyes
        let sleeping = asleep && !isGhost
        if sleeping { pose = PetAnimation.asleepPose() }
        if !isGhost, animated, moving, !sleeping { PetLife.apply(&pose, PetLife.Context(time: now)) }
        holdsBlink = pose.eyes < open * 0.9
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: bounds.midX + xOffset * scaleFactor, y: bounds.midY - 15 * scaleFactor)
        cg.scaleBy(x: scaleFactor, y: scaleFactor)
        // Held by the scruff, at the top of the head: the whole cat swings from there.
        if isGhost, swing.x != 0 { cg.translateBy(x: 0, y: 28); cg.rotate(by: swing.x); cg.translateBy(x: 0, y: -28) }
        PetPainter.draw(pose, look: look, in: cg)
        cg.restoreGState()
    }
}
