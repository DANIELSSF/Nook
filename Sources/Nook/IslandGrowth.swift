import AppKit
import SwiftUI
import QuartzCore
import os

// While Claude's usage card is open the island takes the height the card asks for, so everything on it is on show without scrolling, and it goes back to the
// user's own size when the card is gone. The user's size (the display settings) is never touched: the size taken lives only here, is never saved, and is
// dropped with the card, the island's closing, or a change of screen or settings.
//
//   IslandRoom         what a card asks of the island: how tall it wants to be with all of its content on show, measured at the width it had
//   IslandRoomKey      how a card says it (a preference, read where the panel is hosted)
//   IslandScreen       the screen the island hangs from: its edges, what the Dock leaves, the notch's axis and the header's height
//   IslandGrowth       the size the island takes for a card, and the screen's limit on it (plain values, so every screen is tried in tests)
//   IslandStage        the island's window and the shape that shows it, going from one size to another around the island's top edge
//   IslandRoomKeeper   the state: the card's last ask, the size taken for it and when to move; it asks `IslandRoomHost` (the controller) for the rest
//
// The window of an island keeps its size while its shape moves (see `IslandView`): opening it never lays the panel out again on every frame. Growing is the same:
// the window takes its new size at once and the shape grows down to it, the way it grew from the notch; shrinking, the window keeps its size until the shape has
// got to the smaller one. The content (SwiftUI) is laid out for the new size at once in both, which is what `AppModel.islandSize` answers.

/// What the island's size does, for whoever has to look into it: `log show --predicate 'subsystem == "dev.nook.mac" && category == "island"'`.
let islandLog = Logger(subsystem: "dev.nook.mac", category: "island")

// MARK: - What a card asks

struct IslandRoom: Equatable {
    /// How tall the card wants to be to show all of its content at once, at `width`.
    var height: CGFloat
    /// The card's own width when it measured that: a reading made for another width is not about the island as it is now.
    var width: CGFloat
}

struct IslandRoomKey: PreferenceKey {
    static var defaultValue: IslandRoom? { nil }
    static func reduce(value: inout IslandRoom?, nextValue: () -> IslandRoom?) {
        guard let next = nextValue() else { return }
        if let current = value, current.height >= next.height { return }
        value = next
    }
}

// MARK: - The screen

/// The screen the island hangs from, as the growth needs it.
struct IslandScreen: Equatable {
    /// The display and the part of it that the menu bar and the Dock leave (AppKit's `frame` and `visibleFrame`).
    var frame: CGRect
    var visible: CGRect
    /// The notch's height (0 on a display without one) and the island's header's, which is never under 28 pt.
    var topInset: CGFloat
    var neck: CGFloat
    /// The notch's axis: the island is centred on it.
    var centerX: CGFloat

    /// The island's frame for a size: centred on the notch, hanging from the top edge.
    func frame(of size: CGSize) -> CGRect { NotchGeometry.frame(of: size, screen: frame, centerX: centerX) }
}

extension NotchGeometry {
    /// The frame of an island of `size` on `screen`: centred on `centerX`, hanging from the screen's top edge (so it can never leave the notch's side of the screen).
    static func frame(of size: CGSize, screen: CGRect, centerX: CGFloat) -> CGRect {
        CGRect(x: centerX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
}

// MARK: - How much the island gives

enum IslandGrowth {
    /// The air kept between the grown island's lower edge and what is under it (the Dock, or the screen's own edge).
    static let bottomMargin: CGFloat = 12
    /// A change this small is not worth a move: the island stays as it is.
    static let tolerance: CGFloat = 2
    /// How long the shape takes to get to a bigger size and to a smaller one: the island's opening and closing.
    static let growDuration = 0.32
    static let shrinkDuration = 0.25

    /// The width the island opens to when a card does not fit in the height the screen leaves it at its own width: the "Amplia" island's. A wider island is a shorter one.
    static var wideWidth: CGFloat { NotchGeometry.expandedWidth + IslandPreset.wide.widthExtra }
    /// Only an island narrower than this is widened. Below it the card has one column (two sections side by side need 474 pt), and a second and a third halve its height;
    /// from there up another column only moves the sections about (the findings, the tallest of them, stay as tall), so it is not worth an island that moves its edges.
    static let widenBelow: CGFloat = 480

    /// The most the island may be tall: what the display allows any island (40 pt short of its height), and what the Dock leaves under it, less a margin.
    static func maxHeight(on screen: IslandScreen) -> CGFloat {
        let display = NotchGeometry.clampedHeight(.greatestFiniteMagnitude, screen: screen.frame.size, topInset: screen.topInset)
        let underDock = screen.frame.maxY - screen.visible.minY - bottomMargin
        return floor(min(display, underDock))
    }

    /// The most the island may be wide: what the display allows any island.
    static func maxWidth(on screen: IslandScreen) -> CGFloat {
        NotchGeometry.clampedWidth(.greatestFiniteMagnitude, screen: screen.frame.size)
    }

    /// The size the island takes for what the card on show asks, when it is `now` this size and the user's own is `user`.
    ///
    /// - With no card asking, the user's. It never goes under that.
    /// - The height the card wants, up to what the screen allows; past that the card scrolls, as it did.
    /// - A card that does not fit the screen's height, in an island too narrow for two columns (`widenBelow`), asks for a wider island first (a wide card is a short one)
    ///   and says nothing more of the height until the card has measured itself again at the new width; the width never goes back while the card stays.
    /// - A reading made for another width than the island's now is not acted on: the card measures again once it has the new width.
    ///
    /// Asked again with the size it gave, it gives that size back: the island settles in one step and stays.
    static func size(for room: IslandRoom?, now: CGSize, user: CGSize, screen: IslandScreen) -> CGSize {
        guard let room, room.height > 0, room.width > 0 else { return user }
        guard abs(room.width - ClaudePanelCard.width(inIsland: now.width)) <= 1 else { return now }
        let wanted = ceil(ClaudePanelCard.island(forCard: room.height, neck: screen.neck))
        let ceiling = max(maxHeight(on: screen), user.height)
        let wide = min(wideWidth, maxWidth(on: screen)).rounded()
        if wanted > ceiling, now.width < widenBelow, now.width < wide - tolerance {
            return CGSize(width: wide, height: now.height)
        }
        var height = min(max(wanted, user.height), ceiling)
        if abs(height - now.height) < tolerance { height = now.height }
        return CGSize(width: now.width, height: height)
    }
}

// MARK: - The stage

/// The island's window and the shape that shows it. A move takes the window to the union of its frame and the new one (so the shape has room to go either way),
/// carries the shape from where it is on screen to the new frame, and then, if the window is bigger than the island now is, takes it down to the island's size.
/// Whatever the move, the island's top edge and its axis stay where they were: a frame is always the notch's and the screen's top.
final class IslandStage {
    private let panel: NSWindow
    private let island: IslandView
    private var token = 0
    /// What the window's shadow was before a move put it away (it cannot follow a shape that is moving); nil with no move under way.
    private var shadow: Bool?
    /// The end of the move under way, and when it is overdue: a move whose end is late (Core Animation's word that the shape got there never came) is finished by hand.
    private var arrival: (() -> Void)?
    private var deadline = Date.distantFuture

    init(panel: NSWindow, island: IslandView) {
        self.panel = panel
        self.island = island
    }

    var isMoving: Bool { shadow != nil }

    /// Gives a move that is under way up: it does not finish (the window keeps the frame it has) and the shadow is as it was.
    func cancel() {
        token += 1
        arrival = nil
        endMove()
    }

    /// Takes the island to `target` (a frame on the screen). `completion` runs once it has got there, never for a move that was given up. Answers the window's frame
    /// as it is once it has taken the new size (it is what it was asked, unless the system did not allow it).
    @discardableResult
    func move(to target: NSRect, radius: CGFloat = 22, duration: Double, timing: CAMediaTimingFunction = .init(name: .default), completion: @escaping () -> Void = {}) -> NSRect {
        token += 1
        let mine = token
        arrival = nil
        if shadow == nil { shadow = panel.hasShadow }
        panel.hasShadow = false
        let before = panel.frame
        // Where the shape is on screen right now, in the window's own coordinates, before the window changes.
        let shown = island.shape.presentation()?.path ?? island.shape.path
        let window = before.union(target)
        // The shape is about to be on its way: a window that changes size meanwhile is not a reason to give it the whole of the view.
        island.showsAll = false
        if window != before {
            panel.setFrame(window, display: false)
            island.layoutSubtreeIfNeeded()
        }
        let from = shown.map { Self.moved($0, dx: before.minX - window.minX, dy: before.minY - window.minY) }
        let arrive = { [weak self] in
            guard let self, self.token == mine else { return }
            // Whoever gets here first (the shape's own word, or the deadline's) ends the move: the other finds it ended.
            self.token += 1
            self.arrival = nil
            if window != target {
                // The shape is where the island is now: the window can take the island's own size, with the shape all over it.
                self.panel.setFrame(target, display: false)
                self.island.layoutSubtreeIfNeeded()
                self.island.reveal(self.island.bounds, radius: radius, duration: 0) {}
            }
            self.endMove()
            completion()
        }
        if duration > 0 {
            arrival = arrive
            deadline = Date().addingTimeInterval(duration + 0.3)
        }
        island.reveal(target.offsetBy(dx: -window.minX, dy: -window.minY), radius: radius, duration: duration, timing: timing, from: from) { if duration > 0 { arrive() } }
        // With no animation the shape is there already: there is nothing to wait for (a completion block that has no animation to wait for comes a turn later).
        if duration <= 0 { arrive() }
        return panel.frame
    }

    /// Puts the window at `frame` without the shape moving on screen, for a window that is not the size the shape was drawn for. Answers where the shape is, in the
    /// window's new coordinates, for the move that comes next to start from (a layer's presentation only has what it was before until the change is committed); nil
    /// when the window was at `frame` already.
    @discardableResult
    func align(to frame: NSRect) -> CGPath? {
        let before = panel.frame
        guard frame != before else { return nil }
        token += 1
        arrival = nil
        endMove()
        let shown = island.shape.presentation()?.path ?? island.shape.path
        island.showsAll = false
        panel.setFrame(frame, display: false)
        island.layoutSubtreeIfNeeded()
        island.shape.removeAnimation(forKey: "reveal")
        guard let shown else { return nil }
        let there = Self.moved(shown, dx: before.minX - frame.minX, dy: before.minY - frame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        island.shape.path = there
        CATransaction.commit()
        return there
    }

    /// The island at rest is the frame it should have, with the shape all over it. For an island that should be at rest: a move that is overdue is finished by hand, a
    /// window that is not the frame it should be is put there and a shape that is not all of it is made so. Answers what it had to repair (nothing, when all was well).
    @discardableResult
    func reconcile(to wanted: NSRect, radius: CGFloat = 22, now: Date = Date()) -> [String] {
        var repairs: [String] = []
        if let arrival, now > deadline {
            repairs.append("a move of the island did not finish in time")
            arrival()
        }
        // A move on its way has not had its time yet: it is let be.
        guard !isMoving else { return repairs }
        if abs(panel.frame.width - wanted.width) > 0.5 || abs(panel.frame.height - wanted.height) > 0.5 || abs(panel.frame.minX - wanted.minX) > 0.5 || abs(panel.frame.maxY - wanted.maxY) > 0.5 {
            repairs.append("the window was \(Int(panel.frame.width))×\(Int(panel.frame.height)) at \(Int(panel.frame.minX)),\(Int(panel.frame.maxY)) and the island is \(Int(wanted.width))×\(Int(wanted.height))")
            token += 1
            island.showsAll = false
            panel.setFrame(wanted, display: false)
            island.layoutSubtreeIfNeeded()
            island.reveal(island.bounds, radius: radius, duration: 0) {}
            panel.invalidateShadow()
        } else {
            island.layoutSubtreeIfNeeded()
            if let box = island.shape.path?.boundingBox, abs(box.width - island.bounds.width) > 1 || abs(box.height - island.bounds.height) > 1 || abs(box.minX) > 1 {
                repairs.append("the shape was \(Int(box.width))×\(Int(box.height)) at \(Int(box.minX)) in a window of \(Int(island.bounds.width))×\(Int(island.bounds.height))")
                island.reveal(island.bounds, radius: radius, duration: 0) {}
                panel.invalidateShadow()
            }
        }
        if !repairs.isEmpty { islandLog.error("The island was not as it should be: \(repairs.joined(separator: "; "), privacy: .public)") }
        return repairs
    }

    private func endMove() {
        guard let shadow else { return }
        self.shadow = nil
        panel.hasShadow = shadow
        panel.invalidateShadow()
    }

    private static func moved(_ path: CGPath, dx: CGFloat, dy: CGFloat) -> CGPath {
        var shift = CGAffineTransform(translationX: dx, y: dy)
        return path.copy(using: &shift) ?? path
    }
}

// MARK: - The keeper

/// What the keeper needs of the island it keeps. `NotchController` is the real one; tests pass their own, so no test touches the real island.
protocol IslandRoomHost: AnyObject {
    /// The island's window and the view that holds its shape.
    var roomPanel: NSWindow { get }
    var roomIsland: IslandView { get }
    var roomScreen: IslandScreen { get }
    /// The island's size as the user's settings make it.
    var roomUserSize: CGSize { get }
    /// The island is open with its content on show and nobody is dragging its size: it may move.
    var roomMayMove: Bool { get }
    /// How long a move takes: none at all with Reduce Motion, or with the app's animations off.
    func roomDuration(_ base: Double) -> Double
    /// The island's size (what `AppModel.islandSize` answers) changed: the content is laid out again for it, and what hangs from the island follows.
    func roomChanged()
}

/// Keeps the island's size while a card asks for room: what it asked last, the size taken for it, and the moving between sizes. Once a move should be over, it looks
/// that the island is what it should be (the window the island's frame, the shape all of it) and puts right what is not (`verify`).
final class IslandRoomKeeper {
    private weak var host: IslandRoomHost?
    private let stage: IslandStage
    /// The card's last ask (nil: none is asking).
    private(set) var room: IslandRoom?
    /// The size the island has taken for it, when that is not the user's.
    private(set) var grown: CGSize?
    private var pending: DispatchWorkItem?
    private var checking: DispatchWorkItem?

    /// Asks arrive in bursts as the card lays itself out and Nook reads the rest of Claude's panel: the island moves once they have stopped for this long.
    static let delay: TimeInterval = 0.05
    /// How long after a move should have ended the island is looked at.
    static let checkAfter: TimeInterval = 0.4
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    init(host: IslandRoomHost) {
        self.host = host
        stage = IslandStage(panel: host.roomPanel, island: host.roomIsland)
    }

    /// The island's size right now: the one it took for a card, or the user's.
    var size: CGSize { grown ?? host?.roomUserSize ?? .zero }

    /// The frame the island has now, on the screen.
    var frame: NSRect? { host.map { $0.roomScreen.frame(of: size) } }

    var isMoving: Bool { stage.isMoving }

    /// A card says what it asks (nil: it is gone, or asks nothing). The island follows once the asks have settled.
    func ask(_ room: IslandRoom?, after delay: TimeInterval = IslandRoomKeeper.delay) {
        guard room != self.room else { return }
        self.room = room
        schedule(after: delay)
    }

    /// Looks at what is asked again: the island has just opened, or the screen or the settings it was sized for have changed.
    func reconsider() { schedule(after: Self.delay) }

    private func schedule(after delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        pending = work
        if delay <= 0 { DispatchQueue.main.async(execute: work) } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Takes the island to the size the card's ask gives, now. Nothing moves while the island is closed or not on show, or when it is already that size.
    func settle() {
        pending?.cancel(); pending = nil
        guard let host, host.roomMayMove else { return }
        let screen = host.roomScreen, user = host.roomUserSize, now = size
        let target = IslandGrowth.size(for: room, now: now, user: user, screen: screen)
        guard target != now else {
            // Nothing to move: the island is looked at all the same (a change the keeper was not told of would show here).
            scheduleCheck(after: Self.checkAfter)
            return
        }
        let growing = target.width > now.width || target.height > now.height
        grown = target == user ? nil : target
        islandLog.notice("The island goes from \(Int(now.width))×\(Int(now.height)) to \(Int(target.width))×\(Int(target.height)) (the user's is \(Int(user.width))×\(Int(user.height)); the card asks \(self.room.map { "\(Int($0.height)) at \(Int($0.width))" } ?? "nothing", privacy: .public))")
        // The content is laid out for the new size at once; the window gets there as the shape does.
        host.roomChanged()
        let duration = host.roomDuration(growing ? IslandGrowth.growDuration : IslandGrowth.shrinkDuration)
        let reached = stage.move(to: screen.frame(of: target), duration: duration, timing: Self.curve) { [weak self] in
            self?.host?.roomChanged()
            self?.scheduleCheck(after: 0.1)
        }
        // A window may not get all the size it was asked for: the island is what it got, and the content is laid out for that.
        let got = CGSize(width: min(target.width, reached.width), height: min(target.height, reached.height))
        if abs(got.width - target.width) > 1 || abs(got.height - target.height) > 1 {
            islandLog.error("The window took \(Int(reached.width))×\(Int(reached.height)) of the \(Int(target.width))×\(Int(target.height)) it was asked")
            grown = got == user ? nil : got
            host.roomChanged()
        }
        scheduleCheck(after: duration + Self.checkAfter)
    }

    private func scheduleCheck(after delay: TimeInterval) {
        checking?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.verify() }
        checking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The island at rest is its frame, with the shape all over it: a move that is overdue is finished, a window that is not the island's frame and a shape that is not
    /// all of it are put right. The content is laid out again for what the island turned out to be.
    @discardableResult
    func verify() -> [String] {
        checking?.cancel(); checking = nil
        guard let host, host.roomMayMove, pending == nil else { return [] }
        let repairs = stage.reconcile(to: host.roomScreen.frame(of: size))
        if !repairs.isEmpty { host.roomChanged() }
        return repairs
    }

    /// The island is no longer the size it took (it closed, or the screen or the settings changed): it takes the user's own at once, with no move, and is not asked again
    /// until `reconsider`. A move under way is given up.
    func release() {
        pending?.cancel(); pending = nil
        checking?.cancel(); checking = nil
        stage.cancel()
        grown = nil
    }

    /// For the island's own window after it was left at a size it no longer has (see `NotchController.expand`).
    @discardableResult
    func align(to frame: NSRect) -> CGPath? { stage.align(to: frame) }
}
