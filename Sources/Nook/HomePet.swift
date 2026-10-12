import AppKit
import SwiftUI

// The big cats: the one that lives on the home (`HomePetView`) and the sad one of the question before quitting (`SadCatView`).
//
// They are the same cat as the one in the notch and in the header: the same rig, the same coat and accessory (`PetPreferences`), the same director for what it does
// and the same painter, only drawn larger. Nothing here invents a cat. A big cat is still a cat that costs next to nothing: each keeps a timer only while it can be seen
// (`PetSight`) and moves, takes the frame rate its motion asks for (`PetPace`), and stands still with Reduce Motion or with the pets' animations off.

// MARK: - Where the cat looks

/// Where the home's cat looks when the pointer is not near it: at the card the pointer is on (to the right of the cat, a little up or down).
struct HomeGaze: Equatable {
    var dx: CGFloat
    var dy: CGFloat
    /// The cat looks toward the actions on its right.
    static let towardActions = HomeGaze(dx: 0.85, dy: 0.1)

    var gaze: PetGaze { PetGaze(dx: dx, dy: dy) }
}

// MARK: - The home's cat

struct HomePetStage: NSViewRepresentable {
    var animated: Bool
    /// How the user has set the cat up (`AppModel.pet`).
    var pet = PetPreferences()
    /// Points per rig unit: the cat is about 31 units tall.
    var scale: CGFloat
    /// Where the cat sits across the stage, as a fraction of its width.
    var homeFraction: CGFloat = 0.4
    var lookAt: HomeGaze?
    /// Goes up by one each time the cat is to greet (it waves).
    var greetings = 0
    /// Goes up by one each time the cat is to rejoice (an action was chosen): it mews and, when it is in the mood, hops.
    var cheers = 0
    /// Draws this pose and nothing else, with no timer: previews and renders.
    var still: PetPose?
    var controller: NotchController?
    var onHover: (Bool) -> Void = { _ in }
    var onPoke: () -> Void = {}

    func makeNSView(context: Context) -> HomePetView { HomePetView() }
    func updateNSView(_ view: HomePetView, context: Context) {
        view.controller = controller
        view.onHover = onHover; view.onPoke = onPoke
        view.scale = scale; view.homeFraction = homeFraction
        view.lookAt = lookAt?.gaze
        view.still = still
        view.pet = pet
        view.animated = animated
        view.greetings = greetings
        view.rejoicings = cheers
        // The panel updates as the island opens: a cat with no timer (it could not be seen) looks again whether it can.
        view.wake()
    }
}

/// The home's cat on its stage: it sits, breathes, blinks and does what a cat does (the director's gestures, more often than the header's cat, which has a title to share the
/// room with), looks at the pointer when it comes near and at the cards it points at, answers a click with a mew (and a hop, when it is in the mood), and can be picked up by
/// the scruff and dropped on a terminal window as the header's cat can.
final class HomePetView: NSView {
    var animated = true { didSet { if animated != oldValue { refresh() } } }
    var pet = PetPreferences() { didSet { if pet != oldValue { look = pet.look; needsDisplay = true; refresh() } } }
    var scale: CGFloat = 2.4 { didSet { if scale != oldValue { needsDisplay = true; invalidateCat() } } }
    var homeFraction: CGFloat = 0.4 { didSet { if homeFraction != oldValue { needsDisplay = true; invalidateCat() } } }
    var lookAt: PetGaze?
    var greetings = 0 { didSet { if greetings != oldValue { greet() } } }
    var rejoicings = 0 { didSet { if rejoicings != oldValue { rejoice() } } }
    /// A pose to draw instead of a living cat (previews, renders).
    var still: PetPose? { didSet { if still != oldValue { pose = still ?? PetPose(); needsDisplay = true; refresh() } } }
    weak var controller: NotchController? { didSet { if controller !== oldValue { reportLight() } } }
    /// The same cat as the notch's and the header's: it sleeps when Nook opens at night, and wakes (gently) when it is clicked (`PetBedtime`).
    private var bedtime = PetBedtimeFollower()
    private var petBedtime: PetBedtime? { controller?.model.petBedtime }
    /// The pointer came onto the cat or left it; the cat was clicked.
    var onHover: ((Bool) -> Void)?
    var onPoke: (() -> Void)?

    /// The cat's feet are this far above the stage's bottom edge, as the header's are.
    static let ground = HeaderPetView.ground
    private var driver = PetDriver(layout: .header, rhythm: PetDirector.homeRhythm)
    private(set) var pose = PetPose()
    private(set) var look = PetLook()
    private lazy var ticker = PetTicker(timed: { [weak self] lead in self?.step(lead: lead) })
    /// Seconds between the cat's frames right now: 0 when it has no timer at all.
    var frameInterval: TimeInterval { ticker.interval }
    private(set) var ticks = 0
    private var user = PetUserProbe()
    private var dayClock = PetClock()
    private var noticed = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?
    private var wasVisible = false
    private var lastNow = 0.0
    private var dragStart: CGPoint?
    private var dragging = false
    private var overCat = false
    private var cursorX: CGFloat = .nan
    /// A click's reaction: when it began (system uptime), and the cheers asked of the director.
    private var perkStart: Double?
    private var cheers = 0
    private static let perkLength = 1.5

    var homeX: CGFloat { bounds.width * homeFraction }
    /// Room to the right of home for a stroll, in points.
    var travel: CGFloat { max(0, bounds.width - homeX - PetAnimation.reach.right * scale - 4) }
    var layout: PetPlayer.Layout { .header(travel: travel, scale: scale, height: bounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Gatito de Nook")
        setAccessibilityHelp("Púlsalo para que te salude. Arrástralo a una ventana de Terminal para conectarla.")
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
        let defaults = NotificationCenter.default
        observers.append((defaults, defaults.addObserver(forName: PetPowerMonitor.didChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { poke(); return true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        guard let window else { ticker.stop(); wasVisible = false; return }
        driver.pace.backing = window.backingScaleFactor
        // Nobody can see a cat whose panel is away or covered, and it keeps no timer: these wake it when it can be seen again.
        windowObservers = PetSight.wakeups(for: window) { [weak self] in self?.step() }
        reportLight()
        refresh()
    }
    override func viewDidUnhide() { super.viewDidUnhide(); step() }
    private func reportLight() { petBedtime?.lights(dark: effectiveAppearance.nookIsDark) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reportLight()
        refresh()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { pointerMoved(to: convert(event.locationInWindow, from: nil)); step() }
    override func mouseExited(with event: NSEvent) { setOverCat(false); noticed = false }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(catRect(), cursor: .openHand)
        cursorX = pose.x
    }

    private func pointerMoved(to point: CGPoint) { setOverCat(catRect().contains(point)) }
    private func setOverCat(_ over: Bool) {
        guard over != overCat else { return }
        overCat = over
        onHover?(over)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        guard catRect().contains(convert(event.locationInWindow, from: nil)) else { dragStart = nil; return }
        dragStart = NSEvent.mouseLocation
        controller?.cancelScheduledExpand()
        step()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, controller != nil else { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - start.x, point.y - start.y) > 5 { dragging = true }
        if dragging { NSCursor.closedHand.set(); controller?.dragPet(to: point) }
    }
    override func mouseUp(with event: NSEvent) {
        let wasDown = dragStart != nil
        if dragging { NSCursor.arrow.set(); controller?.finishPetDrag(at: NSEvent.mouseLocation) }
        else if wasDown { poke() }
        dragging = false; dragStart = nil
    }

    /// A click: the cat mews, looks up and flicks its tail at once; and when the director allows (it waits a few seconds between cheers) it hops.
    func poke(announcing: Bool = true) {
        // A click on a sleeping cat wakes it, gently (`PetAnimation.waking`), and says nothing: it is asleep.
        if announcing {
            if petBedtime?.click() == true { refresh(); return }
            if driver.player.wake() { step(); return }
        }
        perkStart = ProcessInfo.processInfo.systemUptime
        cheers += 1
        if announcing { onPoke?() }
        step()
    }

    /// An action was chosen on the home: the cat is glad of it.
    private func rejoice() {
        guard still == nil else { return }
        poke(announcing: false)
    }

    /// The cat is to wave hello (the greeting). A cat asleep has to wake up first: the greeting asks the bedtime to wake it (`GreetingView`), and the wave comes after.
    private func greet() {
        guard greetings > 0, still == nil, !driver.player.isPinnedAsleep, !driver.player.isWaking else { return }
        driver.player.begin(.wave, layout: layout)
        step()
    }

    // MARK: Moving

    /// Whether the cat moves at all: not with Reduce Motion, nor with the pets' animations off, nor on a Mac too hot to spare it, nor when a still pose is asked for.
    private var canAnimate: Bool { animated && still == nil && !PetAnimation.motionReduced && PetPowerMonitor.shared.state != .minimal }

    /// Re-evaluates whether the cat should move at all; a still cat has no timer.
    private func refresh() {
        guard canAnimate else {
            ticker.stop(); driver.settle(); wasVisible = false
            let rest = still ?? PetAnimation.staticPose(working: false, attention: false, asleep: petBedtime?.isAsleep ?? false)
            if pose != rest { pose = rest; needsDisplay = true }
            return
        }
        step()
    }

    /// Looks again whether the cat can be seen, if it has no timer; a cat that is running needs nothing.
    func wake() { if ticker.interval == 0, canAnimate { step() } }

    /// One tick: from the display link (with how far ahead its frame will be shown), from the timer, or from something that happened.
    private func step(lead: CFTimeInterval? = nil) {
        guard canAnimate else { return refresh() }
        guard PetSight.canSee(self) else { wasVisible = false; ticker.pause(); return }
        ticks += 1
        if !wasVisible { wasVisible = true; driver.settle(); ticker.host = self; ticker.run(every: PetCadence.fast(.header, power: PetPowerMonitor.shared.state)) }
        let now = max(ProcessInfo.processInfo.systemUptime + (lead ?? 0), lastNow)
        lastNow = now
        // In bed at night, or woken since it last looked.
        bedtime.follow(petBedtime, player: &driver.player, now: ProcessInfo.processInfo.systemUptime)
        let head = CGPoint(x: homeX + pose.x + pose.head.x * scale, y: Self.ground + (pose.head.y + pose.y) * scale)
        // The pointer is noticed from a good way off (the cat is the star of the home); a card the pointer is on draws the cat's eyes to it.
        var gaze = petGaze(head: head, enter: 120, leave: 150, noticed: &noticed, over: overCat || dragStart != nil)
        if gaze == nil { gaze = lookAt }
        user.read(now: now); dayClock.read(now: now)
        var input = PetInput(working: false, gaze: gaze, dragging: dragging, completions: cheers, focus: .from(keyAge: user.keyAge, scrollAge: user.scrollAge),
                             idle: user.idle, needsAttention: false)
        // The cat of the home cheers when it is poked, whatever it does when Claude finishes.
        input.prefs = pet; input.prefs.celebrates = true
        input.power = PetPowerMonitor.shared.state; input.dayPart = dayClock.part
        if let start = perkStart {
            let age = now - start
            if age < Self.perkLength {
                input.perk = PetAnimation.ramp(age, 0, 0.12) * (1 - PetAnimation.ramp(age, 0.9, Self.perkLength))
                input.perkAge = age
            } else { perkStart = nil }
        }
        driver.pace.backing = window?.backingScaleFactor ?? 2
        let tick = driver.tick(now: now, layout: layout, input: input)
        ticker.run(every: tick.interval)
        // Only where the cat was and where it is now.
        if tick.draw {
            let was = pose
            pose = tick.pose
            setNeedsDisplay(Self.paintedRect(was, scale: scale, homeX: homeX).union(Self.paintedRect(pose, scale: scale, homeX: homeX)))
            // The hand cursor follows the cat when it strolls.
            if cursorX.isNaN || abs(pose.x - cursorX) > 6 { window?.invalidateCursorRects(for: self) }
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        cg.clip(to: bounds)
        Self.paint(pose, look: look, scale: scale, homeX: homeX, in: cg)
    }

    /// Paints the cat on the stage, its feet `ground` points up and its home `homeX` points in, drawn at `scale` points per rig unit.
    static func paint(_ pose: PetPose, look: PetLook, scale: CGFloat, homeX: CGFloat, in cg: CGContext) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.translateBy(x: homeX + pose.x, y: ground); cg.scaleBy(x: scale, y: scale)
        PetPainter.draw(pose, look: look, ledge: -ground / scale, in: cg)
    }

    /// Where `pose` paints on the stage, in view points, with room for what its bounds leave out and the antialiased edge.
    static func paintedRect(_ pose: PetPose, scale: CGFloat, homeX: CGFloat) -> NSRect {
        let b = pose.bounds, margin = 4 * scale + 1.5
        return NSRect(x: homeX + pose.x + b.minX * scale, y: ground + b.minY * scale, width: b.width * scale, height: b.height * scale).insetBy(dx: -margin, dy: -margin)
    }

    /// The cat itself, for the pointer: its bounds as it is now, a little roomier than the drawing.
    func catRect() -> NSRect {
        let b = pose.bounds
        return NSRect(x: homeX + pose.x + b.minX * scale, y: Self.ground + b.minY * scale, width: b.width * scale, height: b.height * scale).insetBy(dx: -4, dy: -3)
    }

    private func invalidateCat() { window?.invalidateCursorRects(for: self) }
}

// MARK: - The sad cat

struct SadCatStage: NSViewRepresentable {
    var animated: Bool
    var look = PetLook()
    /// Points per rig unit.
    var scale: CGFloat

    func makeNSView(context: Context) -> SadCatView { SadCatView() }
    func updateNSView(_ view: SadCatView, context: Context) {
        view.scale = scale
        view.look = look
        view.animated = animated
        view.wake()
    }
}

/// The cat of the question before quitting, as `PetAnimation.sad` makes it: it droops as the question comes up (its head and ears first), breathes slowly, blinks long, sighs
/// now and then, and cries one tear at a time. It is a pure function of the seconds since the question appeared, so it needs no director: it ticks at the rate its motion asks
/// for and stops while nobody can see it.
final class SadCatView: NSView {
    var animated = true { didSet { if animated != oldValue { refresh() } } }
    var look = PetLook() { didSet { if look != oldValue { needsDisplay = true } } }
    var scale: CGFloat = 2.2 { didSet { if scale != oldValue { needsDisplay = true } } }
    private(set) var pose = PetPose()
    private var startedAt: Double?
    private var pace = PetPace(fast: 1.0 / 30)
    private lazy var ticker = PetTicker { [weak self] in self?.step() }
    private var windowObservers: [NSObjectProtocol] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private(set) var ticks = 0
    var frameInterval: TimeInterval { ticker.interval }
    /// The pose it holds still in (Reduce Motion, animations off): drooped, with a tear on its cheek.
    static var restingPose: PetPose {
        var p = PetAnimation.sad(time: 0.5)
        p.tear = 0.5
        return p
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Un gatito triste")
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
        let defaults = NotificationCenter.default
        observers.append((defaults, defaults.addObserver(forName: PetPowerMonitor.didChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        guard let window else { ticker.stop(); startedAt = nil; return }
        pace.backing = window.backingScaleFactor
        windowObservers = PetSight.wakeups(for: window) { [weak self] in self?.step() }
        refresh()
    }
    override func viewDidUnhide() { super.viewDidUnhide(); step() }

    private var canAnimate: Bool { animated && !PetAnimation.motionReduced && PetPowerMonitor.shared.state != .minimal }

    private func refresh() {
        guard canAnimate else {
            ticker.stop(); startedAt = nil
            if pose != Self.restingPose { pose = Self.restingPose; needsDisplay = true }
            return
        }
        step()
    }

    func wake() { if ticker.interval == 0, canAnimate { step() } }

    private func step() {
        guard canAnimate else { return refresh() }
        guard PetSight.canSee(self) else { ticker.pause(); return }
        ticks += 1
        let now = ProcessInfo.processInfo.systemUptime
        // The scene begins when it is first seen, so the entrance is always watched.
        if startedAt == nil { startedAt = now; pace.reset(); ticker.host = self }
        let t = now - (startedAt ?? now)
        let next = PetAnimation.sad(time: t, amount: PetAnimation.sadAmount(at: t))
        ticker.run(every: pace.interval(for: next, now: now, scale: scale))
        if next.displacement(to: pose, scale: scale) * pace.backing >= 0.25 { pose = next; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        cg.clip(to: bounds)
        // The cat sits at the middle of its stage, its feet on the same 8 pt of ground as the header's and the home's.
        cg.translateBy(x: bounds.midX + pose.x + (PetAnimation.sadShift - 0.5) * scale, y: HeaderPetView.ground); cg.scaleBy(x: scale, y: scale)
        PetPainter.draw(pose, look: look, ledge: -HeaderPetView.ground / scale, in: cg)
    }
}

/// The sad cat as a picture, for the alert that asks when there is no island to ask in: the cat on the island's black, in the shape of an app's icon.
enum SadCatImage {
    static func make(size: CGFloat = 128, look: PetLook = PetLook()) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(CGColor(gray: 0, alpha: 1))
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)); cg.fillPath()
            let scale = min(size * 0.62 / 31.4, size * 0.86 / PetAnimation.sadReach)
            cg.saveGState()
            cg.translateBy(x: rect.midX + (PetAnimation.sadShift - 0.5) * scale, y: size * 0.12); cg.scaleBy(x: scale, y: scale)
            // A drooped cat with a tear halfway down its cheek.
            var pose = PetAnimation.sad(time: 0.5)
            pose.tear = 0.45
            PetPainter.draw(pose, look: look, in: cg)
            cg.restoreGState()
            return true
        }
    }
}
