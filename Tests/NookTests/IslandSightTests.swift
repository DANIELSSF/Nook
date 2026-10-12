import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Nook

/// The open island's moving pictures (a tab's icon, the working dots, the agents' spinners) cost nothing while nobody can see them: the
/// screens asleep or locked, or the island's window away or covered. SwiftUI does not stop a `TimelineView` for a covered window (measured:
/// one behind the desktop keeps its twenty frames a second), so the island says so itself (`\.islandSeen`).
@MainActor
final class IslandSightTests: XCTestCase {
    override func tearDown() {
        PetSight.windowOverride = nil; PetSight.screensDarkOverride = nil
        super.tearDown()
    }

    private func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// A model with one tab at work, its icon one that moves: Claude's (whose spinner symbol the island shows), or with `dots` a shell's
    /// (whose work the island shows as the three waving dots).
    private func workingModel(defaults: UserDefaults, dots: Bool = false) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.animations = true
        let rule = String(repeating: "─", count: 72)
        let screen = dots ? "$ npm run build\n> building…" : ["⏺ Revisando el código del notch.", "", "✶ Churning… (1m 2s · ↓ 3.4k tokens · esc to interrupt)", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"].joined(separator: "\n")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: dots ? "build" : "Claude Code",
                                      processes: dots ? ["login", "-zsh", "npm"] : ["login", "-zsh", "claude"], busy: dots, selected: true, text: screen)
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.icon = .orbit
        model.sessions = [session]; model.selectedID = session.id
        model.expanded = true; model.islandContentVisible = true
        model.updateActivity()
        return model
    }

    // MARK: What it costs (a benchmark: runs only with NOOK_ENERGY_BENCH set)

    /// The open island at work, in a window on screen at 1% opacity that lets the pointer through (nobody sees it or bumps into it, and it
    /// never takes the keyboard): the process's CPU while the island can be seen, and while the screens are dark. By default a Claude tab
    /// whose icon moves; NOOK_ENERGY_DOTS a shell's tab (the working dots), NOOK_ENERGY_AGENTS two of Claude's agents at work (their
    /// spinners and pulses), NOOK_ENERGY_STILL the animations off. A display link only runs for a window the system counts as seen, which a
    /// faint one may not be: the AppKit views that move by one (a tab's icon) can measure as still here.
    func testTheOpenIslandCostsNothingWhileNobodyCanSeeIt() throws {
        guard let seconds = ProcessInfo.processInfo.environment["NOOK_ENERGY_BENCH"].flatMap(Double.init) else { throw XCTSkip("Set NOOK_ENERGY_BENCH=<seconds> to measure the open island.") }
        let suite = "nook-island-bench-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = workingModel(defaults: defaults, dots: ProcessInfo.processInfo.environment["NOOK_ENERGY_DOTS"] != nil)
        if ProcessInfo.processInfo.environment["NOOK_ENERGY_STILL"] != nil { model.animations = false }
        // Two of Claude's agents at work, and the tab's icon the still dot: what moves is the agents' spinners and pulses.
        if ProcessInfo.processInfo.environment["NOOK_ENERGY_AGENTS"] != nil, let session = model.selected {
            session.icon = .dot
            session.subagents = [SubagentActivity(id: "a1", name: "Explore", state: .running), SubagentActivity(id: "a2", name: "Plan", state: .running)]
            model.updateActivity()
        }
        print("bench: working \(model.working), Claude's symbol \(model.activityGlyph ?? "none") (none: the dots wave), agents at work \(model.runningSubagents)")
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let host = NSHostingView(rootView: NookPanel(model: model).environment(\.colorScheme, .dark))
        // As the island's own (`NotchController`): the window is sized by the controller, never by the content.
        host.sizingOptions = []
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1500, height: 900)
        let panel = NSPanel(contentRect: NSRect(x: screen.maxX - size.width - 8, y: screen.minY + 40, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0.01; panel.ignoresMouseEvents = true; panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        // The window server is not asked whether the window is seen: a faint window counts as covered for it, and the Mac may be locked.
        PetSight.windowOverride = { _ in true }
        PetSight.screensDarkOverride = false
        NotificationCenter.default.post(name: PetPowerMonitor.didChange, object: nil)
        pump(3)
        func measure() -> Double {
            let cpu = Self.cpuSeconds(), start = Date()
            pump(seconds)
            return 100 * (Self.cpuSeconds() - cpu) / Date().timeIntervalSince(start)
        }
        let seen = measure()
        PetSight.screensDarkOverride = true
        NotificationCenter.default.post(name: PetPowerMonitor.didChange, object: nil)
        pump(1)
        let dark = measure()
        print(String(format: "open island at work: %.2f%% of one core while seen, %.2f%% while the screens are dark (%.0f s each)", seen, dark, seconds))
    }

    // MARK: The working dots

    /// The three working dots are drawn by an AppKit view of their own (`WorkingDotsView`): at any moment, the picture the `HStack` of
    /// circles they replace drew then.
    func testTheWorkingDotsPaintWhatTheirSwiftUIFormPaintedAtTheSameMoment() throws {
        let side = WorkingDotsView.side, scale: CGFloat = 4, px = Int(side * scale)
        // The dots' colour is the island's mint on black, defined once (`WorkingDotsView.tint`): the picture SwiftUI would paint is painted with that same colour, so the
        // two cannot drift apart (a literal copy of it here did when the palette became more vivid).
        let accent = Color(nsColor: WorkingDotsView.tint)
        func canvas() -> CGContext {
            CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        func bytes(_ cg: CGContext) -> [UInt8] { Array(UnsafeBufferPointer(start: cg.data!.bindMemory(to: UInt8.self, capacity: px * px * 4), count: px * px * 4)) }
        for time in [nil, 0.0, 0.21, 0.5, 1.37, 4000.9] as [Double?] {
            // What `ActivityGlyph` drew before.
            let dots = HStack(spacing: 2) {
                ForEach(0..<3) { i in Circle().fill(accent).frame(width: 3, height: 3).offset(y: time.map { sin($0 * 6 + Double(i)) * 2 } ?? 0) }
            }.frame(width: side, height: side)
            let renderer = ImageRenderer(content: dots)
            renderer.scale = scale
            let swiftUI = canvas()
            swiftUI.draw(try XCTUnwrap(renderer.cgImage), in: CGRect(x: 0, y: 0, width: px, height: px))
            let appKit = canvas()
            appKit.translateBy(x: 0, y: CGFloat(px)); appKit.scaleBy(x: scale, y: -scale)
            WorkingDotsView.paint(at: time, in: appKit)
            let a = bytes(swiftUI), b = bytes(appKit)
            // Two rasterizers soften a dot this small differently at its rim, so it is the dots' places and sizes that are compared: each
            // dot's centre of ink and how much ink it has (to a few percent), and the colour of their middles. SwiftUI sets each dot on the
            // pixel grid and the AppKit view draws it where the wave has it, so their centres may differ by up to a quarter of a 2x pixel.
            func places(_ v: [UInt8]) -> [(x: Double, y: Double, ink: Double)] {
                (0..<3).map { d in
                    var ink = 0.0, x = 0.0, y = 0.0
                    for k in stride(from: 0, to: v.count, by: 4) {
                        let i = k / 4, column = i % px
                        guard column >= d * px / 3, column < (d + 1) * px / 3 else { continue }
                        let w = Double(v[k + 3]); ink += w; x += w * Double(column); y += w * Double(i / px)
                    }
                    return (x / max(ink, 1) / Double(scale), y / max(ink, 1) / Double(scale), ink)
                }
            }
            for (old, new) in zip(places(a), places(b)) {
                XCTAssertEqual(new.x, old.x, accuracy: 0.13, "at \(String(describing: time))"); XCTAssertEqual(new.y, old.y, accuracy: 0.13, "at \(String(describing: time))")
                XCTAssertEqual(new.ink, old.ink, accuracy: old.ink * 0.04, "at \(String(describing: time))")
            }
            // The middle of the first dot: the accent, fully opaque, in both.
            let middle = { (v: [UInt8]) -> [UInt8] in
                let d = places(v)[0], k = (Int(d.y * Double(scale)) * px + Int(d.x * Double(scale))) * 4
                return Array(v[k..<k + 4])
            }
            XCTAssertEqual(middle(a).map(Int.init), middle(b).map(Int.init), "the dots' colour")
        }
    }

    func testTheWorkingDotsRunOnlyWhileTheyWaveAndCanBeSeen() {
        let view = WorkingDotsView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        XCTAssertEqual(view.frameInterval, 0, "not running until told")
        view.show(waving: true, running: true)
        XCTAssertEqual(view.frameInterval, WorkingDotsView.interval, accuracy: 1e-9)
        view.show(waving: true, running: false)
        XCTAssertEqual(view.frameInterval, 0, "the other copy is on show, or nobody can see the island")
        view.show(waving: false, running: true)
        XCTAssertEqual(view.frameInterval, 0, "level dots (Reduce Motion, animations off) need no clock")
        view.show(waving: true, running: true)
        window.contentView = nil
        XCTAssertEqual(view.frameInterval, 0, "and nothing out of a window")
    }

    // MARK: The probe

    func testTheProbeSaysWhenTheIslandCanBeSeenAndOnlyWhenThatChanges() {
        var seen = true
        PetSight.windowOverride = { _ in seen }
        PetSight.screensDarkOverride = false
        let probe = IslandSightView(frame: .zero)
        var heard: [Bool] = []
        probe.onChange = { heard.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        pump(0.05)
        XCTAssertEqual(heard, [true])
        seen = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        pump(0.05)
        XCTAssertEqual(heard, [true, false], "covered")
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        pump(0.05)
        XCTAssertEqual(heard, [true, false], "the same news twice is news once")
        seen = true
        NotificationCenter.default.post(name: PetSight.cameOnScreen, object: window)
        pump(0.05)
        XCTAssertEqual(heard, [true, false, true], "back on screen")
        PetSight.screensDarkOverride = true
        NotificationCenter.default.post(name: PetPowerMonitor.didChange, object: nil)
        pump(0.05)
        XCTAssertEqual(heard, [true, false, true, false], "the screens sleep or lock")
        window.contentView = nil
    }

    // MARK: The agents' spinners and pulses

    /// `view` drawn as the island draws it: in a hosting view in an off-screen window of the screen's scale, dark, on black. Its pixels, in
    /// the representation AppKit caches a view's drawing in.
    private func pixels<V: View>(_ view: V, size: NSSize) throws -> [UInt8] {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.black).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        var bytes: [UInt8] = []
        // The first render of a run can come out empty: draw again until something shows.
        for _ in 0..<5 {
            pump(0.05)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            bytes = Array(UnsafeBufferPointer(start: rep.bitmapData, count: rep.bytesPerRow * rep.pixelsHigh))
            if bytes.enumerated().contains(where: { $0.offset % 4 != 3 && $0.element > 40 }) { break }
        }
        return bytes
    }

    /// How many pixels of two drawings differ by more than `tolerance` in any channel.
    private func differing(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 2) -> Int {
        guard a.count == b.count else { return Int.max }
        var count = 0
        for k in stride(from: 0, to: a.count, by: 4) where (0..<4).contains(where: { abs(Int(a[k + $0]) - Int(b[k + $0])) > tolerance }) { count += 1 }
        return count
    }

    /// Claude's spinner in a tab's badge (10 pt, 9 wide) and in an agent's row (13 pt, 13 wide) is an AppKit view now (`SpinnerGlyphView`): for
    /// every symbol it turns through, it paints the very pixels the `Text` it replaced painted.
    func testTheAgentsSpinnerPaintsWhatItsTextPaintedForEverySymbol() throws {
        defer { IslandClock.now = Date.init }
        var compared = 0
        for (size, width) in [(CGFloat(10), CGFloat(9)), (13, 13)] {
            // Several places in the window, so the spinner's position falls between pixels in every way it can.
            for (k, symbol) in SubagentStateGlyph.frames.enumerated() where k < 6 {
                let box = [NSSize(width: 31, height: 24), NSSize(width: 31.5, height: 24.5), NSSize(width: 32, height: 25.5)][k % 3]
                IslandClock.now = { Date(timeIntervalSinceReferenceDate: SubagentStateGlyph.interval * (Double(k) + 10_000) + 0.05) }
                XCTAssertEqual(SubagentStateGlyph.symbol(at: IslandClock.now(), still: false), symbol)
                let before = try pixels(Text(symbol).font(.system(size: size, weight: .bold)).foregroundStyle(AgentPalette.running).frame(width: width), size: box)
                let after = try pixels(SpinnerGlyph(size: size, color: AgentPalette.running, still: false, seen: false).frame(width: width), size: box)
                XCTAssertGreaterThan(before.enumerated().filter { $0.offset % 4 == 0 && $0.element > 60 }.count, 4, "\(symbol) at \(size) pt drew something")
                XCTAssertEqual(differing(before, after), 0, "\(symbol) at \(size) pt")
                compared += 1
            }
        }
        XCTAssertEqual(compared, 12)
        let box = NSSize(width: 31, height: 24)
        // Still (Reduce Motion, the animations off), it shows the resting symbol, as before.
        IslandClock.now = { Date(timeIntervalSinceReferenceDate: 1234.5) }
        let still = try pixels(SpinnerGlyph(size: 13, color: AgentPalette.running, still: true, seen: true).frame(width: 13), size: box)
        let resting = try pixels(Text(SubagentStateGlyph.symbol(at: Date(), still: true)).font(.system(size: 13, weight: .bold)).foregroundStyle(AgentPalette.running).frame(width: 13), size: box)
        XCTAssertEqual(differing(still, resting), 0)
    }

    /// The capsule's marks are AppKit views now, one per mark in the row (`AgentMarkView`): at any moment they paint what the row of shapes at
    /// their opacities painted.
    func testTheCapsulesMarksPaintWhatTheirRowPaintedAtTheSameMoment() throws {
        defer { IslandClock.now = Date.init }
        typealias Mark = SubagentDots.Mark
        let marks = [Mark(id: "a:1", kind: .agent, color: AgentPalette.running, running: true),
                     Mark(id: "a:2", kind: .agent, color: AgentPalette.done, running: false, dim: true),
                     Mark(id: "s:1", kind: .shell, color: ShellPalette.color(.running), running: true),
                     Mark(id: "s:2", kind: .shell, color: ShellPalette.color(.stopped), running: false, dim: true),
                     Mark(id: "u:0", kind: .unnamedShell, color: AgentPalette.running, running: false)]
        // Several places in the window, so the row's position falls between pixels in every way it can.
        for (box, time) in [(NSSize(width: 48, height: 14), 0.0), (NSSize(width: 48.5, height: 14.5), 0.31), (NSSize(width: 49, height: 15), 1.0),
                            (NSSize(width: 49.5, height: 13.5), 2.2), (NSSize(width: 47, height: 14), 9_999.7)] {
            IslandClock.now = { Date(timeIntervalSinceReferenceDate: time) }
            let before = try pixels(HStack(spacing: 3) {
                ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                    SubagentDots.shape(mark).opacity(SubagentDots.opacity(of: mark, at: index, time: time, pulsing: true))
                }
            }, size: box)
            let after = try pixels(SubagentDots.markRow(marks, pulsing: true, seen: false), size: box)
            // A shape drawn at an opacity, against the same shape drawn whole and then made that opaque: a unit or two apart at most.
            // The shapes are SwiftUI's own pictures (`ImageRenderer`) in the places SwiftUI gives them: same pixels but along one edge, where
            // the two renderers' antialiasing parts by a few levels. Nothing is moved, missing or another colour.
            let inked = before.enumerated().filter { $0.offset % 4 == 0 && ($0.element > 0 || after[$0.offset] > 0) }.count
            XCTAssertLessThanOrEqual(differing(before, after, tolerance: 16), 0, "at \(time) in \(box): nothing more than an edge's shade apart")
            XCTAssertLessThanOrEqual(Double(differing(before, after, tolerance: 3)) / Double(max(inked, 1)), 0.4, "at \(time) in \(box): \(differing(before, after, tolerance: 3)) of \(inked) inked pixels a few levels apart")
        }
    }

    func testTheSpinnerAndTheMarksRunOnlyWhileTheyMoveAndCanBeSeen() {
        let spinner = SpinnerGlyphView(frame: NSRect(x: 0, y: 0, width: 13, height: 16))
        let marks = AgentMarkView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(spinner); window.contentView?.addSubview(marks)
        spinner.show(size: 13, color: AgentPalette.running, scheme: .dark, still: false, running: true)
        XCTAssertTrue(spinner.onClock)
        XCTAssertEqual(SpinnerGlyphView.clock.frameInterval, SubagentStateGlyph.interval, accuracy: 1e-9)
        spinner.show(size: 13, color: AgentPalette.running, scheme: .dark, still: true, running: true)
        XCTAssertFalse(spinner.onClock, "still: no clock")
        XCTAssertEqual(SpinnerGlyphView.clock.frameInterval, 0, "and the clock stops with nothing on it")
        spinner.show(size: 13, color: AgentPalette.running, scheme: .dark, still: false, running: false)
        XCTAssertFalse(spinner.onClock, "nobody can see the island: paused")
        let working = SubagentDots.Mark(id: "a", kind: .agent, color: AgentPalette.running, running: true)
        let finished = SubagentDots.Mark(id: "a", kind: .agent, color: AgentPalette.done, running: false, dim: true)
        marks.show(working, index: 0, scheme: .dark, pulsing: true, running: true)
        XCTAssertTrue(marks.onClock)
        XCTAssertEqual(AgentMarkView.clock.frameInterval, AgentMarkView.interval, accuracy: 1e-9)
        marks.show(finished, index: 0, scheme: .dark, pulsing: true, running: true)
        XCTAssertFalse(marks.onClock, "nothing works: nothing pulses")
        XCTAssertEqual(AgentMarkView.clock.frameInterval, 0, "and the clock stops with nothing on it")
        marks.show(working, index: 0, scheme: .dark, pulsing: false, running: true)
        XCTAssertFalse(marks.onClock, "Reduce Motion or the animations off")
        marks.show(working, index: 0, scheme: .dark, pulsing: true, running: false)
        XCTAssertFalse(marks.onClock, "nobody can see the island")
        marks.show(working, index: 0, scheme: .dark, pulsing: true, running: true)
        spinner.show(size: 13, color: AgentPalette.running, scheme: .dark, still: false, running: true)
        window.contentView = nil
        XCTAssertFalse(marks.onClock); XCTAssertFalse(spinner.onClock, "and nothing out of a window")
        XCTAssertNil(spinner.hitTest(NSPoint(x: 5, y: 5))); XCTAssertNil(marks.hitTest(NSPoint(x: 5, y: 3)))
    }

    // MARK: No redraw on a timer

    /// Terminal is read twice a second while the island is open. A reading that finds the same tabs used to announce a change of the whole
    /// model all the same (a `removeAll` that removed nothing), and the open island was rendered again each time; now it announces nothing.
    func testAReadingOfTerminalThatFindsNothingNewDoesNotRedrawTheIsland() {
        let suite = "nook-island-heartbeat-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(receivesSignals: false, defaults: defaults)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys097", customTitle: "Claude Code", processes: ["login", "-zsh", "claude"],
                                      busy: false, selected: true, text: "⏺ Listo.")
        model.updateExternalTabs([tab], ttys: [tab.tty])
        model.updateExternalTabs([tab], ttys: [tab.tty])
        var announced = 0
        let watch = model.objectWillChange.sink { announced += 1 }
        defer { watch.cancel() }
        for _ in 0..<5 { model.updateExternalTabs([tab], ttys: [tab.tty]) }
        XCTAssertEqual(announced, 0, "the same tabs, read again, are no change of the model")
        // A tab that went is one.
        model.updateExternalTabs([], ttys: [tab.tty])
        model.updateExternalTabs([], ttys: [tab.tty])
        model.updateExternalTabs([], ttys: [tab.tty])
        XCTAssertGreaterThan(announced, 0, "a tab that went away still redraws the island")
    }
}
