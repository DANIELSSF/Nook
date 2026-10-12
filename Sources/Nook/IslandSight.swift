import AppKit
import SwiftUI

// Whether anyone can see the open island, for the pictures in it that move by themselves (a tab's icon, the working dots, the agents'
// spinners and pulses, a notice's countdown, a shell's clock).
//
// A `TimelineView(.animation)` keeps its schedule while its window is covered: measured, one in a window behind the desktop still
// renders twenty frames a second, and the island left open on a locked Mac kept a core at 11% with Claude at work. Each of those
// frames is not the small picture's alone: SwiftUI renders it through the island's whole hosting view (`NSHostingView.layout` from the
// root, the glass's springs, AppKit's layout pass over the window), which on the island costs far more than the picture. So the island
// tells its content when nobody can see it, and every moving picture in it pauses then:
//
//   \.islandSeen         false while the screens sleep or are locked (`PetPowerMonitor.screensDark`) or the island's window is away or
//                        covered (`PetSight`). True outside the island (previews, tests, other windows), where nothing changes.
//   IslandSightProbe     the AppKit view, in the island's background, that watches its window and the screens and sets it.
//
// A picture drawn from the clock (`context.date`) shows the right moment on its first frame back, so a pause leaves no trace.

extension EnvironmentValues {
    /// Whether anyone can see the island right now: a screen is awake and unlocked, and the island's window is on screen and not covered.
    /// The island's moving pictures pause while it is false.
    var islandSeen: Bool {
        get { self[IslandSeenKey.self] }
        set { self[IslandSeenKey.self] = newValue }
    }
}

private struct IslandSeenKey: EnvironmentKey { static let defaultValue = true }

/// Watches the window it is in and the screens, and keeps `seen` up to date. Put it in the background of the island's content.
struct IslandSightProbe: NSViewRepresentable {
    @Binding var seen: Bool

    func makeNSView(context: Context) -> IslandSightView { IslandSightView() }
    func updateNSView(_ view: IslandSightView, context: Context) {
        let binding = $seen
        view.onChange = { now in if binding.wrappedValue != now { binding.wrappedValue = now } }
        view.report()
    }
}

/// The probe itself: it draws nothing and takes no clicks. It hears its window's occlusion change, a `NotchPanel` coming on screen or
/// going away, and the screens sleeping, waking, locking or unlocking (`PetPowerMonitor.didChange`), and says so only when it changes.
final class IslandSightView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var last: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = window.map { PetSight.wakeups(for: $0) { [weak self] in self?.report() } } ?? []
        observers.append(NotificationCenter.default.addObserver(forName: PetPowerMonitor.didChange, object: nil, queue: .main) { [weak self] _ in self?.report() })
        report()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Looks whether the island can be seen, and says so if that changed. Never from inside SwiftUI's update of the view: the state
    /// changes on the next turn of the run loop.
    func report() {
        let now = PetSight.canSee(self)
        guard now != last else { return }
        last = now
        DispatchQueue.main.async { [weak self] in self?.onChange?(now) }
    }
}

/// The clock the island's self-painting pictures read their moment from. Tests set it to draw a chosen moment; nil-free and cheap.
enum IslandClock {
    static var now: () -> Date = Date.init
}

/// What a picture on a shared clock does on each of its ticks.
protocol IslandTicking: AnyObject {
    func islandTick()
}

/// One clock for many small pictures that move at the same rate (the agents' spinners, the capsule's marks): one wakeup a frame for all of
/// them, however many there are, and none while none is on it. It holds them weakly.
final class IslandTicker {
    private let interval: TimeInterval
    private let members = NSHashTable<AnyObject>.weakObjects()
    private lazy var ticker = PetTicker { [weak self] in self?.tick() }
    /// Seconds between ticks right now: 0 while nothing is on it.
    var frameInterval: TimeInterval { ticker.interval }

    init(every interval: TimeInterval) { self.interval = interval }

    func add(_ member: IslandTicking) {
        members.add(member)
        ticker.run(every: interval)
    }
    func remove(_ member: IslandTicking) {
        members.remove(member)
        if members.allObjects.isEmpty { ticker.pause() }
    }
    private func tick() {
        let all = members.allObjects.compactMap { $0 as? IslandTicking }
        if all.isEmpty { ticker.pause() }
        all.forEach { $0.islandTick() }
    }
}
