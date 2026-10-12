import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// Renders the background shells' parts of the island to PNG for visual review: the capsule's marks and words, the lists (over the composer and under a
/// tab), and the shell's output in the mirror's place, in each of its states. Runs only when NOOK_RENDER_DIR is set.
@MainActor
final class ShellRenderTests: XCTestCase {
    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the island.") }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }

    private func path(_ directory: String, _ name: String) -> String { URL(fileURLWithPath: directory).appendingPathComponent(name).path }

    /// Mounts `view` in an offscreen window, lets `steps` change the data between run loop turns, and writes the final image over the island's black.
    private func render<V: View>(_ view: V, size: NSSize, settle: Double = 0.3, steps: [() -> Void] = [], to path: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        for step in steps {
            step()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        clearScrollBackgrounds(host)
        var rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            clearScrollBackgrounds(host)
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(blackBacked(rep).representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        withExtendedLifetime(window) {}
    }

    private func blackBacked(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    private func clearScrollBackgrounds(_ view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.drawsBackground = false; scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false; scroll.contentView.backgroundColor = .clear
        }
        view.subviews.forEach(clearScrollBackgrounds)
    }

    // MARK: Data

    private let start = Date()

    private func shell(_ id: String, _ name: String, command: String = "", state: ShellActivity.State = .running, exit: Int? = nil, note: String? = nil, ran: TimeInterval = 192,
                       moved: Bool = false, output: String? = "/private/tmp/claude-501/-Users-me-nook/s/tasks/x.output") -> ShellActivity {
        var shown = ShellActivity(id: id, name: name, command: command, state: state, exitCode: exit, note: note, movedToBackground: moved,
                                  started: Date().addingTimeInterval(-ran), outputPath: output)
        if state != .running { shown.ended = Date().addingTimeInterval(-ran + 70 > 0 ? -5 : -ran / 2) }
        return shown
    }

    private func agent(_ id: String, _ name: String, state: SubagentActivity.State = .running, model: String? = "sonnet", activity: String? = nil) -> SubagentActivity {
        var shown = SubagentActivity(id: id, name: name, kind: "general-purpose", state: state, background: true, toolUses: 23, tokens: "41.2k", duration: "3m 12s")
        shown.model = model
        shown.activity = activity
        return shown
    }

    private let build = "gcloud builds submit --tag \"gcr.io/sampleapp/web:cfcefc7\" ."
    private let buildOutput = """
    Creating temporary archive of 214 file(s) totalling 3.1 MiB before compression.
    Uploading tarball of [.] to [gs://sampleapp-cloudbuild/source/1790000000.1-ab12cd.tgz]
    Created [https://cloudbuild.googleapis.com/v1/projects/sampleapp/locations/global/builds/9f1c2e3a].
    Logs are available at [ https://console.cloud.google.com/cloud-build/builds/9f1c2e3a?project=sampleapp ].
    ----------------------------- REMOTE BUILD OUTPUT ------------------------------
    starting build "9f1c2e3a-6b0e-4d5c-9f0a-1a2b3c4d5e6f"

    FETCHSOURCE
    Fetching storage object: gs://sampleapp-cloudbuild/source/1790000000.1-ab12cd.tgz#1790000000123456
    BUILD
    Already have image (with digest): gcr.io/cloud-builders/docker
    Sending build context to Docker daemon  3.307MB
    Step 1/12 : FROM node:20-alpine AS deps
     ---> 7a8f2c4e1b3d
    Step 2/12 : WORKDIR /app
     ---> Using cache
     ---> 0b6c1d9e2f4a
    Step 3/12 : COPY package.json pnpm-lock.yaml ./
     ---> 3c5d7e9f1a2b
    Step 4/12 : RUN corepack enable && pnpm install --frozen-lockfile
     ---> Running in 4d6e8f0a2b3c
    Lockfile is up to date, resolution step is skipped
    Progress: resolved 1, reused 0, downloaded 0, added 0
    Packages: +1184
    """
    private let devOutput = """
    > sampleapp-web@0.1.0 dev /Users/me/sampleapp-web
    > next dev -p 3000

       ▲ Next.js 15.1.0
       - Local:        http://localhost:3000

     ✓ Starting...
     ✓ Ready in 1.8s
     ○ Compiling / ...
     ✓ Compiled / in 2.3s (812 modules)
     GET / 200 in 2490ms
     GET /api/session 200 in 41ms
     GET /_next/static/chunks/main.js 200 in 8ms
    """

    private var chat: String { "> Lanza el build en segundo plano y avísame cuando termine.\n\n⏺ Listo, el build corre en segundo plano.\n\n" }

    private func claude(_ model: AppModel, title: String = "nook", tty: String = "/dev/ttys190", agents: [SubagentActivity] = [], shells: [ShellActivity], modeHint: Int? = nil,
                        tint: TabTint = .mint) -> TerminalSession {
        let rule = String(repeating: "─", count: 60)
        let hints = [modeHint.map { $0 == 1 ? "1 shell" : "\($0) shells" }, "↓ to manage"].compactMap { $0 }.joined(separator: " · ")
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh", "claude"], busy: false, selected: true,
                                      text: ["⏺ en pantalla", "", rule, "❯ ", rule, "  ⏵⏵ auto mode on (shift+tab to cycle) · \(hints)"].joined(separator: "\n"))
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        session.tint = tint
        // Nothing here may go looking for Claude's record on disk.
        session.transcriptLocated = Date()
        session.applyTranscript(chat, recap: nil, agents: agents, shells: shells)
        return session
    }

    private func island() -> (AppModel, NSSize) {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-shellrender-" + UUID().uuidString)!)
        model.expanded = true; model.islandContentVisible = true
        // Still glyphs: the renders must come out the same each time.
        model.animations = false
        return (model, NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28)))
    }

    // MARK: The capsule

    private struct CapsuleSheet: View {
        struct Row: Identifiable { var id: String; var caption: String; var agents: [SubagentActivity]; var shells: [ShellActivity]; var screen: Int? }
        var rows: [Row]
        var body: some View {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text(row.caption).font(.system(size: 10)).foregroundStyle(.secondary)
                        SubagentCapsule(agents: row.agents, shells: row.shells, screenShellCount: row.screen, animated: false, alwaysVisible: true)
                    }
                }
            }.padding(16).frame(width: 520, alignment: .trailing).background(Color.black).environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
        }
    }

    func testRenderCapsuleStates() throws {
        let directory = try renderDirectory()
        let running = shell("b1", "Build and push the image", command: build)
        let rows: [CapsuleSheet.Row] = [
            .init(id: "agents", caption: "solo agentes (como siempre)", agents: [agent("a", "Diseñar"), agent("b", "Revisar", state: .done), agent("c", "Probar")], shells: [], screen: nil),
            .init(id: "one", caption: "1 shell en curso", agents: [], shells: [running], screen: 1),
            .init(id: "two", caption: "2 shells en curso", agents: [], shells: [running, shell("b2", "Dev server", command: "pnpm dev")], screen: 2),
            .init(id: "both", caption: "2 agentes y 1 shell", agents: [agent("a", "Diseñar"), agent("b", "Revisar")], shells: [running], screen: 1),
            .init(id: "failed", caption: "1 shell con error (nada en curso)", agents: [], shells: [shell("b3", "Run the gate", state: .failed, exit: 1, ran: 12)], screen: nil),
            .init(id: "done", caption: "1 shell listo", agents: [], shells: [shell("b4", "Build", state: .completed, exit: 0)], screen: nil),
            .init(id: "mixed-done", caption: "agentes y shell listos", agents: [agent("a", "Diseñar", state: .done)], shells: [shell("b4", "Build", state: .completed, exit: 0)], screen: nil),
            .init(id: "hint", caption: "Claude cuenta 1 shell que Nook no nombra", agents: [], shells: [], screen: 1),
            .init(id: "hint-with", caption: "agentes + 2 shells sin nombre", agents: [agent("a", "Diseñar")], shells: [], screen: 2),
            .init(id: "stopped", caption: "1 shell detenido", agents: [], shells: [shell("b5", "Watch", state: .stopped, note: "sin memoria")], screen: nil),
        ]
        try render(CapsuleSheet(rows: rows), size: NSSize(width: 520, height: CGFloat(rows.count) * 32 + 32), settle: 0.1, to: path(directory, "shell-capsules.png"))
    }

    // MARK: The lists

    /// The capsule's list, open over the composer's text row, in a Normal island's pane.
    private func listView(agents: [SubagentActivity], shells: [ShellActivity], unseen: Int = 0, maxHeight: CGFloat = 170) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            HStack { Spacer(); SubagentCapsule(agents: agents, shells: shells, screenShellCount: shells.filter(\.isRunning).count + unseen, animated: false, alwaysVisible: true,
                                               initiallyOpen: true, listMaxHeight: maxHeight, onManage: {}, onOpen: { _ in }, onOpenShell: { _ in }) }
                .padding(.trailing, 25).padding(.top, 187 + 9)
        }.frame(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
            .environment(\.colorScheme, .dark).environment(\.nookDarkBackdrop, true)
    }

    func testRenderShellLists() throws {
        let directory = try renderDirectory()
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 32))
        let dev = shell("b2", "Dev server", command: "pnpm dev", ran: 1_820)
        let buildShell = shell("b1", "Build and push the cfcefc7 image via Cloud Build", command: build, ran: 192)
        let failed = shell("b3", "Run lint, typecheck and test gate", command: "pnpm gate", state: .failed, exit: 1, ran: 74)
        let stopped = shell("b5", "caffeinate -dims", command: "caffeinate -dims", state: .stopped, note: "sin memoria", ran: 540)
        let done = shell("b4", "Deploy to staging", command: "pnpm deploy:staging", state: .completed, exit: 0, ran: 331)
        let moved = shell("b6", "cd /Users/me/VIBE && pnpm turbo run test", command: "cd /Users/me/VIBE && pnpm turbo run test\npnpm lint", ran: 305, moved: true)

        try render(listView(agents: [agent("a", "Cat pet animation improvements", activity: "Read(Sources/Nook/Pet.swift)"), agent("b", "Review the notch layout", state: .done)],
                            shells: [buildShell, dev, done], maxHeight: 220), size: size, settle: 0.1, to: path(directory, "shell-list-with-agents.png"))
        try render(listView(agents: [], shells: [buildShell, dev, failed, done, stopped]), size: size, settle: 0.1, to: path(directory, "shell-list-only.png"))
        try render(listView(agents: [], shells: [moved, failed], maxHeight: 220), size: size, settle: 0.1, to: path(directory, "shell-list-moved-failed.png"))
        // As tall as the Normal island lets the capsule's list be (130 pt): it scrolls under its fade, like the agents' does.
        try render(listView(agents: [], shells: [buildShell, dev, failed, done], maxHeight: SubagentCapsule.listMaxHeight), size: size, settle: 0.1, to: path(directory, "shell-list-normal-height.png"))
        try render(listView(agents: [agent("a", "Cat pet animation improvements", activity: "Read(Sources/Nook/Pet.swift)")], shells: [dev, done], maxHeight: SubagentCapsule.listMaxHeight),
                   size: size, settle: 0.1, to: path(directory, "shell-list-normal-height-agents.png"))
        try render(listView(agents: [], shells: [], unseen: 1), size: size, settle: 0.1, to: path(directory, "shell-list-hint-only.png"))
        try render(listView(agents: [agent("a", "Cat pet animation improvements")], shells: [dev], unseen: 2, maxHeight: 220), size: size, settle: 0.1,
                   to: path(directory, "shell-list-hint-alongside.png"))
    }

    func testRenderTabListWithShells() throws {
        let directory = try renderDirectory()
        let (model, size) = island()
        let nook = claude(model, title: "nook", tty: "/dev/ttys191", agents: [agent("a", "Cat pet animation improvements", activity: "Read(Sources/Nook/Pet.swift)")],
                          shells: [shell("b1", "Build and push the image", command: build), shell("b2", "Dev server", command: "pnpm dev", ran: 1_820)], modeHint: 2)
        let api = claude(model, title: "api", tty: "/dev/ttys192", shells: [shell("b3", "Run migrations", command: "pnpm migrate")], modeHint: 1, tint: .blue)
        let docs = claude(model, title: "docs", tty: "/dev/ttys193", shells: [], tint: .lavender)
        model.sessions = [nook, api, docs]; model.selectedID = nook.id
        let presenter = TabAgentListPresenter()
        presenter.toggle(nook.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        try render(NookPanel(model: model, agentList: presenter).environment(\.nookTintedGlass, false), size: size, to: path(directory, "shell-tabs-list.png"))

        // Only a shell: the list's own title says so.
        let (second, _) = island()
        let only = claude(second, title: "api", tty: "/dev/ttys194", shells: [shell("b3", "Run migrations", command: "pnpm migrate")], modeHint: 1, tint: .blue)
        second.sessions = [only]; second.selectedID = only.id
        let alone = TabAgentListPresenter()
        alone.toggle(only.id, frame: CGRect(x: 60, y: 4, width: 28, height: 22))
        try render(NookPanel(model: second, agentList: alone).environment(\.nookTintedGlass, false), size: size, to: path(directory, "shell-tabs-list-only.png"))
    }

    /// The widest the capsule gets (agents and shells together) in the narrowest island: the field keeps the room its placeholder needs.
    func testRenderTheWidestCapsuleInTheCompactIsland() throws {
        let directory = try renderDirectory()
        for (name, widthExtra) in [("compact", CGFloat(-72)), ("normal", 0)] {
            let (model, _) = island()
            model.display.widthExtra = widthExtra
            let session = claude(model, title: "nook", tty: "/dev/ttys195", agents: [agent("a", "Diseñar"), agent("b", "Revisar"), agent("c", "Probar", state: .done)],
                                 shells: [shell("b1", "Build", command: build), shell("b2", "Dev server", command: "pnpm dev"), shell("b3", "Gate", state: .failed, exit: 1)], modeHint: 2)
            model.sessions = [session]; model.selectedID = session.id
            try render(NookPanel(model: model).environment(\.nookTintedGlass, false), size: model.islandSize, settle: 0.8, to: path(directory, "shell-capsule-widest-\(name).png"))
        }
    }

    // MARK: The output

    private func viewing(_ shell: ShellActivity?, id: String? = nil, output: ShellOutput?, shells: [ShellActivity]? = nil, modeHint: Int? = 1, title: String = "nook",
                         notice: String? = nil, draft: String = "") -> (AppModel, TerminalSession) {
        let (model, _) = island()
        let session = claude(model, title: title, shells: shells ?? shell.map { [$0] } ?? [], modeHint: modeHint)
        model.sessions = [session]; model.selectedID = session.id
        model.view(shell: id ?? shell?.id, in: session)
        if let output { session.applyShellOutput(output, id: id ?? shell?.id ?? "") }
        model.notice = notice
        return (model, session)
    }

    func testRenderShellOutputStates() throws {
        let directory = try renderDirectory()
        let size = NSSize(width: NotchGeometry.expandedWidth, height: NotchGeometry.expandedHeight(topInset: 28))
        let running = shell("b1", "Build and push the cfcefc7 image via Cloud Build", command: build)
        let dev = shell("b2", "Dev server", command: "pnpm dev", ran: 1_820)

        func png(_ name: String, _ scenario: (AppModel, TerminalSession)) throws {
            try render(NookPanel(model: scenario.0).environment(\.nookTintedGlass, false), size: size, settle: 1.0, to: path(directory, "shell-view-\(name).png"))
        }
        try png("running", viewing(running, output: ShellOutput(text: buildOutput + "\n")))
        try png("dev", viewing(dev, output: ShellOutput(text: devOutput + "\n")))
        try png("done", viewing(shell("b4", "Deploy to staging", command: "pnpm deploy:staging", state: .completed, exit: 0, ran: 331),
                                output: ShellOutput(text: "Deploying…\nUploaded 214 files\nDone in 12.4s\n"), modeHint: nil))
        try png("failed", viewing(shell("b3", "Run lint, typecheck and test gate", command: "pnpm gate", state: .failed, exit: 1, ran: 74),
                                  output: ShellOutput(text: "src/Pet.swift:41: error: cannot find 'foo' in scope\n  41 |     foo()\n     |     `- error: cannot find 'foo' in scope\n\nError: command failed with exit code 1\n"), modeHint: nil))
        try png("reading", viewing(running, output: nil))
        try png("silent", viewing(running, output: ShellOutput(text: "")))
        try png("silent-ended", viewing(shell("b4", "Deploy to staging", state: .completed, exit: 0), output: ShellOutput(text: ""), modeHint: nil))
        try png("unavailable", viewing(running, output: ShellOutput(available: false)))
        try png("unnamed-file", viewing(shell("b7", "Watch the logs", command: "tail -f app.log", output: nil), output: ShellOutput(available: false)))
        try png("clipped", viewing(running, output: ShellOutput(text: buildOutput + "\n", clipped: true)))
        try png("missing-row", viewing(nil, id: "bgone0001", output: ShellOutput(text: "Deploying…\nDone in 12.4s\n"), shells: [], modeHint: nil))
        try png("long-name", viewing(shell("b8", "Investigate why the collapsed island keeps redrawing the tab row every half second while nothing visible changes",
                                           command: "pnpm turbo run test --filter=@sampleapp/web --concurrency=4"), output: ShellOutput(text: devOutput + "\n")))
        try png("toast", viewing(running, output: ShellOutput(text: buildOutput + "\n"), notice: "Copiado: el aviso queda en el centro de la conversación, también con un shell abierto."))
    }

    func testRenderShellOutputAtOtherSizes() throws {
        let directory = try renderDirectory()
        let running = shell("b1", "Build and push the cfcefc7 image via Cloud Build", command: build)
        func sized(_ name: String, widthExtra: CGFloat, heightExtra: CGFloat) throws {
            let scenario = viewing(running, output: ShellOutput(text: buildOutput + "\n"))
            scenario.0.display.widthExtra = widthExtra; scenario.0.display.heightExtra = heightExtra
            let size = scenario.0.islandSize
            try render(NookPanel(model: scenario.0).environment(\.nookTintedGlass, false), size: size, settle: 1.0, to: path(directory, "shell-view-\(name).png"))
        }
        try sized("compact", widthExtra: -72, heightExtra: -44)
        try sized("tall", widthExtra: 0, heightExtra: 220)
    }
}
