import AppKit
import XCTest
@testable import Nook

/// Renders the collapsed island at several moments of an alert's peek to PNG for visual review: the peek's own
/// surface behind, the collapsed island's cat and badge on top, as the two windows stack on screen. Runs only
/// when NOOK_RENDER_DIR is set.
@MainActor
final class AlertPeekRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the peek.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ host: NSView, size: NSSize, to path: String) throws {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// A strip of desktop with the menu bar along its top and the collapsed island, with the peek around it, on top.
    private final class Stage: NSView {
        let layout: AlertPeekLayout
        let peek: AlertPeekView
        let pet: PetView
        let label: NSTextField
        let light: Bool
        static let margin = NSEdgeInsets(top: 0, left: 36, bottom: 16, right: 36)

        init(compact: CGSize, light: Bool, model: AppModel) {
            layout = AlertPeekLayout(compact: compact)
            self.light = light
            peek = AlertPeekView(layout: layout)
            pet = PetView(frame: .zero)
            label = NSTextField(labelWithString: "")
            let m = Self.margin
            super.init(frame: NSRect(x: 0, y: 0, width: layout.windowSize.width + m.left + m.right, height: layout.windowSize.height + m.bottom))
            peek.frame = NSRect(origin: CGPoint(x: m.left, y: m.bottom), size: layout.windowSize)
            pet.injectedModel = model
            pet.frame = NSRect(x: m.left + layout.compactRect.minX, y: m.bottom + layout.compactRect.minY, width: compact.width, height: compact.height)
            label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            label.textColor = light ? .black.withAlphaComponent(0.6) : .white.withAlphaComponent(0.7)
            label.frame = NSRect(x: 4, y: 3, width: 140, height: 12)
            [peek, pet, label].forEach(addSubview)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            // Wallpaper with a menu bar along the top, as behind the real island.
            (light ? NSColor(white: 0.86, alpha: 1) : NSColor(red: 0.16, green: 0.2, blue: 0.3, alpha: 1)).setFill()
            bounds.fill()
            (light ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.22, alpha: 1)).setFill()
            NSRect(x: 0, y: bounds.height - layout.compact.height, width: bounds.width, height: layout.compact.height).fill()
        }
    }

    private func model(withUnread unread: Bool) -> AppModel {
        let model = AppModel(receivesSignals: false)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: "/dev/ttys099", customTitle: "api", processes: ["login", "-zsh", "claude"], busy: false, selected: true, text: "⏺ Listo.")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        if unread { session.unreadNotice = "Claude terminó." }
        model.sessions = [session]; model.selectedID = session.id
        model.updateActivity()
        return model
    }

    /// One image per scenario: the same alert at each of `moments`, one under the other.
    private func film(_ name: String, alert: NookAlert, compact: CGSize, moments: [Double], motion: Bool = true, light: Bool = false, in directory: String) throws {
        let model = model(withUnread: true)
        var timeline = AlertPeekTimeline()
        timeline.begin(alert, now: 0, motion: motion)
        let stages = moments.map { t -> Stage in
            let stage = Stage(compact: compact, light: light, model: model)
            let frame = timeline.frame(at: t)
            stage.peek.show(frame)
            stage.pet.pose = PetAnimation.perked(from: PetAnimation.sit(time: 3), time: 3, amount: timeline.perk(at: t), age: t)
            stage.label.stringValue = String(format: "t=%.2fs", t)
            return stage
        }
        let width = stages.map(\.frame.width).max() ?? 0, height = stages.reduce(0) { $0 + $1.frame.height }
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height
        for stage in stages {
            y -= stage.frame.height
            stage.frame.origin = CGPoint(x: 0, y: y)
            sheet.addSubview(stage)
        }
        try write(sheet, size: sheet.frame.size, to: URL(fileURLWithPath: directory).appendingPathComponent("alert-\(name).png").path)
    }

    private let notched = CGSize(width: 246, height: 32), flat = CGSize(width: 240, height: 28)
    private let moments = [0.0, 0.1, 0.2, 0.3, 0.45, 0.7, 1.0, 3.5, 3.7, 3.85]

    func testRenderPeekForEachKind() throws {
        let directory = try renderDirectory()
        let finished = NookAlert(id: 1, sessionID: "a", kind: .finished, title: "api", message: "Claude terminó.")
        let question = NookAlert(id: 2, sessionID: "a", kind: .question, title: "api", message: "Do you want to proceed?")
        let failed = NookAlert(id: 3, sessionID: "a", kind: .failed, title: "web", message: "Claude terminó con un error.")
        try film("finished", alert: finished, compact: notched, moments: moments, in: directory)
        try film("question", alert: question, compact: notched, moments: moments, in: directory)
        try film("failed", alert: failed, compact: notched, moments: moments, in: directory)
    }

    func testRenderPeekVariants() throws {
        let directory = try renderDirectory()
        let question = NookAlert(id: 2, sessionID: "a", kind: .question, title: "api", message: "Do you want to proceed?")
        let long = NookAlert(id: 4, sessionID: "a", kind: .question, title: "Claude Code · nook-notch-island", message: "Do you want to make this edit to PanelView.swift?\nThe change touches the composer, the slash menu and the tests.")
        let titleOnly = NookAlert(id: 5, sessionID: "a", kind: .finished, title: "build", message: "")
        let short = NookAlert(id: 6, sessionID: "a", kind: .failed, title: "x", message: "Error.")
        try film("flat-screen", alert: question, compact: flat, moments: [0.2, 0.45, 1.0, 3.5], in: directory)
        try film("light-desktop", alert: question, compact: notched, moments: [0.2, 0.45, 1.0, 3.5], light: true, in: directory)
        try film("long-text", alert: long, compact: notched, moments: [1.0], in: directory)
        try film("title-only", alert: titleOnly, compact: notched, moments: [1.0], in: directory)
        try film("short-text", alert: short, compact: notched, moments: [1.0], in: directory)
        try film("reduced-motion", alert: question, compact: notched, moments: [0.0, 0.1, 0.2, 0.3, 1.0, 3.45, 3.55, 3.65], motion: false, in: directory)
    }

    /// A replacement mid-peek: the old text fading out as the new one fades in, with the island staying out.
    func testRenderReplacement() throws {
        let directory = try renderDirectory()
        let model = model(withUnread: true)
        var timeline = AlertPeekTimeline()
        timeline.begin(NookAlert(id: 1, sessionID: "a", kind: .finished, title: "api", message: "Claude terminó."), now: 0, motion: true)
        timeline.begin(NookAlert(id: 2, sessionID: "b", kind: .question, title: "web", message: "Do you want to proceed?"), now: 2, motion: true)
        let stages = [1.9, 2.05, 2.1, 2.15, 2.3, 2.5].map { t -> Stage in
            let stage = Stage(compact: notched, light: false, model: model)
            stage.peek.show(timeline.frame(at: t))
            stage.pet.pose = PetAnimation.perked(from: PetAnimation.sit(time: 3), time: 3, amount: timeline.perk(at: t), age: t)
            stage.label.stringValue = String(format: "t=%.2fs", t)
            return stage
        }
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: stages[0].frame.width, height: stages.reduce(0) { $0 + $1.frame.height }))
        var y = sheet.frame.height
        for stage in stages { y -= stage.frame.height; stage.frame.origin = CGPoint(x: 0, y: y); sheet.addSubview(stage) }
        try write(sheet, size: sheet.frame.size, to: URL(fileURLWithPath: directory).appendingPathComponent("alert-replacement.png").path)
    }
}
