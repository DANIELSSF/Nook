import AppKit
import SwiftUI

struct HeaderPetStage: NSViewRepresentable {
    var animated: Bool
    var working: Bool
    var needsAttention = false
    /// How the user has set the cat up (`AppModel.pet`).
    var pet = PetPreferences()
    var controller: NotchController?
    func makeNSView(context: Context) -> HeaderPetView { HeaderPetView() }
    func updateNSView(_ view: HeaderPetView, context: Context) {
        view.controller = controller; view.animated = animated; view.working = working; view.needsAttention = needsAttention; view.pet = pet
        // The panel updates as the island opens: a cat with no timer (it could not be seen) looks again whether it can.
        view.wake()
    }
}

/// Header stage: the cat sits on the "Nook" title and strolls and plays to its right, never beyond the view.
final class HeaderPetView: NSView {
    var animated = true { didSet { if animated != oldValue { refresh() } } }
    var working = false { didSet { if working != oldValue { refresh() } } }
    var needsAttention = false { didSet { if needsAttention != oldValue { refresh() } } }
    /// Who the cat is, what it looks like, whether it cheers: the user's choices, set by the stage. A change in how it is dressed shows at once.
    var pet = PetPreferences() { didSet { if pet != oldValue { look = pet.look; needsDisplay = true; refresh() } } }
    weak var controller: NotchController? { didSet { if controller !== oldValue { reportLight() } } }
    /// The cat that sleeps when Nook opens at night is this cat too: it follows the model's bedtime (`PetBedtime`).
    private var bedtime = PetBedtimeFollower()
    private var petBedtime: PetBedtime? { controller?.model.petBedtime }
    /// The cat walks the header's middle band; without a title under it, it sits centred in the row.
    static let homeX: CGFloat = 22, ground: CGFloat = 8
    private var driver = PetDriver(layout: .header)
    var pose = PetPose()
    /// How the cat is dressed now (`pet.look`).
    private(set) var look = PetLook()
    private lazy var ticker = PetTicker(timed: { [weak self] lead in self?.step(lead: lead) })
    /// Seconds between the cat's frames right now: 0 when it has no timer at all (a still cat, or one nobody can see: the island is
    /// collapsed most of the day, and the header's cat sits in a window that is put away).
    var frameInterval: TimeInterval { ticker.interval }
    /// The ticks the cat has taken (each computes a pose and may repaint): tests count them.
    private(set) var ticks = 0
    private var user = PetUserProbe()
    private var dayClock = PetClock()
    private var noticed = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var wasVisible = false
    private var lastNow = 0.0
    private var dragStart: CGPoint?
    private var dragging = false

    var scale: CGFloat { min(0.5, max(0.3, (bounds.height - 15.5) / 31.5)) }
    var travel: CGFloat { max(0, bounds.width - Self.homeX - PetAnimation.reach.right * scale - 4) }
    var layout: PetPlayer.Layout { .header(travel: travel, scale: scale, height: bounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Arrastra el gatito a la terminal que quieres seguir."
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Gatito de Nook; arrastrar para conectar una terminal")
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
        // A Mac that starts saving power, or running hot, changes what the cat may do.
        let defaults = NotificationCenter.default
        observers.append((defaults, defaults.addObserver(forName: PetPowerMonitor.didChange, object: nil, queue: .main) { [weak self] _ in self?.refresh() }))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { controller?.expand(focus: true); return true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver); windowObservers = []
        guard let window else { ticker.stop(); wasVisible = false; return }
        reportLight()
        driver.pace.backing = window.backingScaleFactor
        // Nobody can see a cat whose panel is away or covered, and it keeps no timer: these wake it when it can be seen again.
        windowObservers = PetSight.wakeups(for: window) { [weak self] in self?.step() }
        refresh()
    }
    override func viewDidUnhide() { super.viewDidUnhide(); step() }
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation; dragging = false; controller?.cancelScheduledExpand(); step() }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, controller != nil else { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - start.x, point.y - start.y) > 5 { dragging = true }
        if dragging { NSCursor.closedHand.set(); controller?.dragPet(to: point) }
    }
    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        if dragging { controller?.finishPetDrag(at: NSEvent.mouseLocation) }
        else {
            // A click wakes a sleeping cat (gently: `PetAnimation.waking`); the island is open, so the click's other meaning, to open it, changes nothing.
            wakeFromClick()
            controller?.expand(focus: true)
        }
        dragging = false; dragStart = nil
    }

    /// A click on a sleeping cat: the cat that went to bed at night wakes (and so does every other cat, which follows the same bedtime), or the cat's own nap ends.
    func wakeFromClick() {
        if petBedtime?.click() == true { refresh(); return }
        if driver.player.wake() { step() }
    }

    /// The island's light, as this window shows it: a sleeping cat wakes when it turns light (`PetBedtime.lights`).
    private func reportLight() { petBedtime?.lights(dark: effectiveAppearance.nookIsDark) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reportLight()
        refresh()
    }

    /// Whether the cat moves at all: not with Reduce Motion, nor with the pets' animations off, nor on a Mac too hot to spare it.
    private var canAnimate: Bool { animated && !PetAnimation.motionReduced && PetPowerMonitor.shared.state != .minimal }

    /// Re-evaluates whether the cat should move at all; a still cat has no timer.
    private func refresh() {
        guard canAnimate else {
            ticker.stop(); driver.settle(); wasVisible = false
            let still = PetAnimation.staticPose(working: working, attention: needsAttention, asleep: petBedtime?.isAsleep ?? false)
            if pose != still { pose = still; needsDisplay = true }
            return
        }
        step()
    }

    /// Looks again whether the cat can be seen, if it has no timer; a cat that is running needs nothing.
    func wake() { if ticker.interval == 0, canAnimate { step() } }

    /// One tick: from the display link (with how far ahead its frame will be shown), from the timer, or from something that happened.
    private func step(lead: CFTimeInterval? = nil) {
        guard canAnimate else { return refresh() }
        // Nobody can see it (the island is collapsed, covered, or the screens sleep or are locked): no timer at all, until what brings it
        // back wakes it (`PetSight`).
        guard PetSight.canSee(self) else { wasVisible = false; ticker.pause(); return }
        ticks += 1
        if !wasVisible { wasVisible = true; driver.settle(); ticker.host = self; ticker.run(every: PetCadence.fast(.header, power: PetPowerMonitor.shared.state)) }
        let now = max(ProcessInfo.processInfo.systemUptime + (lead ?? 0), lastNow)
        lastNow = now
        // In bed at night, or woken since it last looked.
        bedtime.follow(petBedtime, player: &driver.player, now: ProcessInfo.processInfo.systemUptime)
        let model = controller?.model
        let head = CGPoint(x: Self.homeX + pose.x + pose.head.x * scale, y: Self.ground + (pose.head.y + pose.y) * scale)
        let gaze = petGaze(head: head, enter: 34, leave: 46, noticed: &noticed, over: dragStart != nil)
        user.read(now: now); dayClock.read(now: now)
        // Typing in Nook's own field, or the panel having the keyboard, is the user reading and writing here.
        let focus = PetFocus.from(keyAge: user.keyAge, scrollAge: user.scrollAge, composing: model?.selected?.draft.isEmpty == false, panelKey: window?.isKeyWindow == true)
        // Put down after a drag: it lands once the panel is showing again (after the connection sheet, if any).
        if controller?.takePetLanding() == true { driver.player.land() }
        var input = PetInput(working: working, gaze: gaze, dragging: dragging, completions: model?.completions ?? 0, focus: focus, idle: user.idle, needsAttention: needsAttention)
        input.prefs = pet; input.power = PetPowerMonitor.shared.state; input.dayPart = dayClock.part
        driver.pace.backing = window?.backingScaleFactor ?? 2
        let tick = driver.tick(now: now, layout: layout, input: input)
        ticker.run(every: tick.interval)
        // Only where the cat was and where it is now: a frame repaints a few dozen points of the stage, not all of it.
        if tick.draw { let was = pose; pose = tick.pose; setNeedsDisplay(Self.paintedRect(was, scale: scale).union(Self.paintedRect(pose, scale: scale))) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState(); defer { cg.restoreGState() }
        cg.clip(to: bounds)
        Self.paint(pose, look: look, scale: scale, in: cg)
    }

    /// Paints the cat on the stage, its feet `ground` points up and its home `homeX` points in, drawn at `scale` points per rig unit.
    static func paint(_ pose: PetPose, look: PetLook, scale: CGFloat, in cg: CGContext) {
        cg.saveGState(); defer { cg.restoreGState() }
        cg.translateBy(x: homeX + pose.x, y: ground); cg.scaleBy(x: scale, y: scale)
        PetPainter.draw(pose, look: look, ledge: -ground / scale, in: cg)
    }

    /// Where `pose` paints on the stage, in view points: its bounds at `scale`, with room for what they leave out (an ear turned on its
    /// pivot, the black seam round a raised paw) and the antialiased edge. A frame's dirty rect is this for the pose on screen and the
    /// new one (`PetPainterTests` checks that repainting only there gives the very picture a full repaint does).
    static func paintedRect(_ pose: PetPose, scale: CGFloat) -> NSRect {
        let b = pose.bounds, margin = 4 * scale + 1.5
        return NSRect(x: homeX + pose.x + b.minX * scale, y: ground + b.minY * scale, width: b.width * scale, height: b.height * scale).insetBy(dx: -margin, dy: -margin)
    }
}
