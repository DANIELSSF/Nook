import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// What Claude's status line adds to the island, as the island shows it: the "Límites en vivo" row of the Permisos tab (what each state of the folders reads and does, and
/// how it is read), the usage card's "en vivo" marks and extra figures, and the glance the usage button's tip gives at the limits. Nothing here installs the status line:
/// the folders are temporary ones, and the system's side is a recorder.
@MainActor
final class ClaudeLiveUITests: XCTestCase {
    private func folder(_ name: String, _ state: NookStatusLine.State) -> NookStatusLine.Folder {
        NookStatusLine.Folder(url: URL(fileURLWithPath: "/tmp/nook-test-home/" + name), state: state)
    }

    // MARK: The row

    func testTheRowReadsEachStateOfTheFoldersAndOffersTheRightButton() throws {
        let chained = NookStatusLine.State.chained(original: "ccstatusline")
        let foreign = NookStatusLine.State.foreign(command: "ccstatusline")
        func make(_ states: NookStatusLine.State...) -> ClaudeLimitsPresentation {
            ClaudeLimitsPresentation.make(folders: states.enumerated().map { folder(".claude\($0.offset == 0 ? "" : "-\($0.offset)")", $0.element) })
        }
        // Not read yet: it says so and offers nothing.
        let unread = ClaudeLimitsPresentation.make(folders: nil)
        XCTAssertEqual(unread.chip, "Leyendo…"); XCTAssertNil(unread.action); XCTAssertEqual(unread.tone, .neutral)
        // No folder to put it in.
        let none = ClaudeLimitsPresentation.make(folders: [])
        XCTAssertEqual(none.chip, "Sin carpetas de Claude"); XCTAssertNil(none.action); XCTAssertNotNil(none.note)
        // Off everywhere: the quiet state, with «Activar…».
        let off = make(.off, .off)
        XCTAssertEqual(off.chip, "Sin activar"); XCTAssertEqual(off.tone, .neutral); XCTAssertEqual(off.action, .enable); XCTAssertNil(off.note)
        // A line of the user's own is kept, and the row says so before they turn it on.
        let keeps = make(.off, foreign)
        XCTAssertEqual(keeps.chip, "Sin activar"); XCTAssertEqual(keeps.action, .enable)
        XCTAssertEqual(keeps.note, ClaudeLimitsPresentation.chaining)
        // On everywhere: «Quitar…».
        let on = make(.on)
        XCTAssertEqual(on.chip, "Activado"); XCTAssertEqual(on.tone, .good); XCTAssertEqual(on.action, .disable)
        XCTAssertEqual(make(.on, .on).chip, "Activado")
        // Chained to the user's own everywhere: it says so.
        let both = make(chained, chained)
        XCTAssertEqual(both.chip, "Encadenada con la tuya"); XCTAssertEqual(both.tone, .good); XCTAssertEqual(both.action, .disable); XCTAssertNotNil(both.note)
        XCTAssertEqual(make(.on, chained).chip, "Activado", "Chained in only one of them is simply on.")
        // On in some: the rest is what is left to do, and the chip counts them.
        let some = make(.on, .off)
        XCTAssertEqual(some.chip, "1 de 2 carpetas"); XCTAssertEqual(some.tone, .attention); XCTAssertEqual(some.action, .enable)
        XCTAssertEqual(make(chained, foreign, .off).chip, "1 de 3 carpetas")
        XCTAssertEqual(make(.on, .on, .off).chip, "2 de 3 carpetas")
        // Settings Nook cannot read stop any change in any folder: nothing is offered, and the row says which.
        let broken = make(.on, .unreadable)
        XCTAssertEqual(broken.chip, "Ajustes ilegibles"); XCTAssertEqual(broken.tone, .attention); XCTAssertNil(broken.action)
        XCTAssertTrue(try XCTUnwrap(broken.note).contains("~/.claude-1"), "It names the folder.")
        XCTAssertEqual(make(.unreadable, .off).chip, "Ajustes ilegibles", "Whatever the other folders are.")
    }

    func testEachFoldersLineSaysWhatItHas() {
        XCTAssertEqual(ClaudeLimitsPresentation.line(for: .on).words, "activada")
        XCTAssertEqual(ClaudeLimitsPresentation.line(for: .on).tone, .good)
        XCTAssertEqual(ClaudeLimitsPresentation.line(for: .chained(original: "x")).words, "activada, con la tuya después")
        XCTAssertEqual(ClaudeLimitsPresentation.line(for: .foreign(command: "x")).words, "tiene su línea de estado (se mantiene)")
        XCTAssertEqual(ClaudeLimitsPresentation.line(for: .off).words, "sin línea de estado")
        XCTAssertEqual(ClaudeLimitsPresentation.line(for: .unreadable).tone, .attention)
        // Every one has a symbol the system has.
        for state in [NookStatusLine.State.on, .chained(original: "x"), .foreign(command: "x"), .off, .unreadable] {
            XCTAssertNotNil(NSImage(systemSymbolName: ClaudeLimitsPresentation.line(for: state).symbol, accessibilityDescription: nil), "\(state)")
        }
    }

    func testTheRowListsTheFoldersOnlyWhenThatSaysSomething() {
        let off = [folder("a", .off), folder("b", .off)], on = [folder("a", .on), folder("b", .on)]
        XCTAssertFalse(ClaudeLimitsPresentation.listsFolders(off, open: false), "Two lines that say the same as the chip.")
        XCTAssertFalse(ClaudeLimitsPresentation.listsFolders(on, open: false))
        XCTAssertTrue(ClaudeLimitsPresentation.listsFolders(on, open: true), "Opened, it says everything.")
        XCTAssertTrue(ClaudeLimitsPresentation.listsFolders([folder("a", .on), folder("b", .off)], open: false), "Some have it: which.")
        XCTAssertTrue(ClaudeLimitsPresentation.listsFolders([folder("a", .off), folder("b", .foreign(command: "x"))], open: false), "One has a line of the user's own.")
        XCTAssertTrue(ClaudeLimitsPresentation.listsFolders([folder("a", .unreadable)], open: false))
        XCTAssertTrue(ClaudeLimitsPresentation.listsFolders([folder("a", .chained(original: "x"))], open: false))
        XCTAssertFalse(ClaudeLimitsPresentation.listsFolders([], open: true), "No folders, no list.")
        XCTAssertFalse(ClaudeLimitsPresentation.listsFolders([folder("a", .off)], open: false))
    }

    // MARK: What is said of what is kept

    /// The consent says what is kept, where, who can read it, for how long, what changes in Claude and the backups, and each of those is true of the mechanics it names.
    func testTheRowSaysWhatIsKeptWhereWhoReadsItAndForHowLong() {
        let keeps = ClaudeLimitsPresentation.keeps.lowercased()
        for words in ["lo último que claude envía de cada sesión", "tal como lo manda", "nombre", "carpeta", "ruta de su conversación", "modelo", "costo", "contexto", "límites",
                      "solo en este mac", "carpeta privada", "únicamente lee tu usuario", "nada sale por la red", "una hora después de su última actualización", "al quitar la función, toda la carpeta"] {
            XCTAssertTrue(keeps.contains(words), "«\(words)» is missing from: \(keeps)")
        }
        // The hour is the watcher's, the five are the settings' backups, the folder is the script's.
        XCTAssertEqual(ClaudeStatusWatcher().keep, 3600, "«una hora»")
        XCTAssertEqual(ClaudeSettingsFile.backupsKept, 5, "«hasta cinco»")
        XCTAssertTrue(ClaudeLimitsPresentation.backups.contains("copia de seguridad privada junto al archivo (hasta cinco)"))
        let folder = NookStatusLine.statusFolder.path
        XCTAssertTrue(folder.hasPrefix("/tmp/nook-") && folder.hasSuffix("/status"), folder)
        XCTAssertTrue(NookStatusLine.scriptSource(statusFolder: NookStatusLine.statusFolder).contains(folder), "The script writes where the row says.")
    }

    func testTheGuideNamesEverythingThatIsKept() {
        let folder = NookStatusLine.statusFolder.path
        let detail = ClaudeLimitsPresentation.keepsInDetail(folder: folder)
        XCTAssertTrue(detail.contains(folder), "It says where, with the real path.")
        // Everything Claude's status line gets, so the consent can never say less than what is on disk.
        for item in ["nombre y el id de la sesión", "su carpeta", "repositorio", "PR de git", "ruta de su conversación", "modelo y la versión", "costo", "tiempos", "líneas cambiadas",
                     "contexto", "esfuerzo", "límites con sus reinicios", "datos de la caché", "solo lee tu usuario", "no sale de este Mac"] {
            XCTAssertTrue(detail.contains(item), "«\(item)» is missing from: \(detail)")
        }
    }

    func testTheConfirmationIsFourShortParagraphsWithTheEssentials() throws {
        let files = "~/.claude y ~/.claude-work"
        let install = ClaudeLimitsPresentation.confirmation(installed: false, files: files, chains: false)
        XCTAssertEqual(install.title, "Ver los límites de Claude en vivo")
        let paragraphs = install.text.components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, 4, install.text)
        XCTAssertTrue(paragraphs.allSatisfy { $0.count < 330 }, "Short: \(paragraphs.map(\.count))")
        XCTAssertTrue(paragraphs[0].contains(files), "It names the folders it changes.")
        for words in ["nombre", "carpeta", "ruta de su conversación", "modelo", "costo", "contexto", "límites"] { XCTAssertTrue(paragraphs[0].contains(words), words) }
        XCTAssertTrue(paragraphs[0].contains("Ajustes → Permisos"), "…and where the rest is told.")
        for words in ["solo en este Mac", "carpeta privada", "únicamente lee tu usuario", "nada sale por la red", "una hora después de su última actualización", "al quitar la función, toda la carpeta"] {
            XCTAssertTrue(paragraphs[1].contains(words), "«\(words)» is missing from: \(paragraphs[1])")
        }
        XCTAssertTrue(paragraphs[2].contains("fila en blanco") && paragraphs[2].contains("pantalla completa") && paragraphs[2].contains("for shortcuts"))
        XCTAssertFalse(paragraphs[2].contains("línea de estado actual"), "A line of the user's own is mentioned only when there is one.")
        XCTAssertTrue(paragraphs[3].contains("copia de seguridad privada") && paragraphs[3].contains("hasta cinco") && paragraphs[3].contains("próxima respuesta"))
        // With a line of the user's own it says it stays and that what it prints is kept too.
        let chained = ClaudeLimitsPresentation.confirmation(installed: false, files: files, chains: true).text.components(separatedBy: "\n\n")
        XCTAssertTrue(chained[2].contains(ClaudeLimitsPresentation.chaining))
        XCTAssertTrue(ClaudeLimitsPresentation.chaining.contains("sigue viéndose igual") && ClaudeLimitsPresentation.chaining.contains("guarda también lo que imprime"))
        // Taking it out: back as it was, the data goes, and the backups.
        let remove = ClaudeLimitsPresentation.confirmation(installed: true, files: files, chains: false)
        XCTAssertEqual(remove.title, "Quitar los límites en vivo")
        XCTAssertTrue(remove.text.contains(files) && remove.text.contains("como estaba antes") && remove.text.contains("Se borra también la carpeta"))
        XCTAssertTrue(remove.text.contains("hasta cinco"))
        XCTAssertEqual(remove.text.components(separatedBy: "\n\n").count, 2)
        // No English but the hint Claude's footer shows, and no emoji.
        for text in [install.text, remove.text, ClaudeLimitsPresentation.keeps, ClaudeLimitsPresentation.effects, ClaudeLimitsPresentation.chaining, ClaudeLimitsPresentation.backups, detail(for: "x")] {
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, text)
            let plain = text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "? for shortcuts", with: "")
            XCTAssertFalse(plain.contains(" the ") || plain.contains(" your ") || plain.contains(" and "), plain)
        }
    }

    private func detail(for folder: String) -> String { ClaudeLimitsPresentation.keepsInDetail(folder: folder) }

    func testTheRowSaysWhatItChangesInClaudeAndTheCopyIsSpanish() {
        let effects = ClaudeLimitsPresentation.effects
        XCTAssertTrue(effects.contains("fila en blanco") && effects.contains("pantalla completa"), "The blank row, in fullscreen sessions.")
        XCTAssertTrue(effects.replacingOccurrences(of: "\u{00A0}", with: " ").contains("? for shortcuts"), "The footer's hints go (and the question mark does not end a line alone).")
        XCTAssertTrue(ClaudeLimitsPresentation.pickup.contains("próxima respuesta"), "Open sessions pick it up on their next reply.")
        XCTAssertEqual(ClaudeLimitsPresentation.subtitle, "Claude le pasa a Nook tus límites, el costo y el contexto de cada sesión, sin teclas ni desplazarte.")
        // Buttons and chips are Spanish, and there is a symbol the system has for each.
        for action in [ClaudeLimitsAction.enable, .disable] {
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), action.symbol)
            XCTAssertTrue(action.title.hasSuffix("…"), "It asks first, so it ends in an ellipsis.")
        }
        XCTAssertEqual(ClaudeLimitsAction.enable.title, "Activar…"); XCTAssertEqual(ClaudeLimitsAction.disable.title, "Quitar…")
        var chips = Set<String>()
        for folders in [nil, [], [folder("a", .off)], [folder("a", .on)], [folder("a", .on), folder("b", .off)], [folder("a", .chained(original: "x"))], [folder("a", .unreadable)]] as [[NookStatusLine.Folder]?] {
            let shown = ClaudeLimitsPresentation.make(folders: folders)
            chips.insert(shown.chip)
            XCTAssertNotNil(NSImage(systemSymbolName: shown.symbol, accessibilityDescription: nil), shown.symbol)
        }
        XCTAssertEqual(chips, ["Leyendo…", "Sin carpetas de Claude", "Sin activar", "Activado", "1 de 2 carpetas", "Encadenada con la tuya", "Ajustes ilegibles"])
        XCTAssertNotNil(NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil), "The row's icon.")
    }

    // MARK: How it is read

    private final class Recorder {
        var folders: [NookStatusLine.Folder] = []
        var reads = 0
        var held: [([NookStatusLine.Folder]) -> Void] = []
        var hold = false

        var services: PermissionsModel.Services {
            PermissionsModel.Services(readStates: { $0([:]) }, readClaude: { $0([]) },
                                      readStatusLine: { [self] done in
                                          reads += 1
                                          if hold { held.append(done) } else { done(folders) }
                                      },
                                      request: { _, done in done(.granted) }, openSettings: { _ in }, openTerminal: { $0() })
        }
    }

    func testTheFoldersAreReadWithTheRestAndTheTabWaitsForThem() {
        let recorder = Recorder()
        recorder.folders = [folder(".claude", .on), folder(".claude-work", .off)]
        let model = PermissionsModel(services: recorder.services, center: NotificationCenter(), workspace: NotificationCenter())
        XCTAssertNil(model.statusLineFolders, "Nothing is read until the tab asks.")
        XCTAssertEqual(ClaudeLimitsPresentation.make(folders: model.statusLineFolders).chip, "Leyendo…")
        model.refresh()
        XCTAssertEqual(model.statusLineFolders, recorder.folders)
        XCTAssertEqual(recorder.reads, 1)
        XCTAssertEqual(ClaudeLimitsPresentation.make(folders: model.statusLineFolders).chip, "1 de 2 carpetas")
        // A read that is held back keeps the others from starting again, and one more follows it, as with every other read.
        recorder.hold = true
        model.refresh(); model.refresh()
        XCTAssertEqual(recorder.reads, 2, "One read at a time.")
        recorder.hold = false
        recorder.folders = [folder(".claude", .on), folder(".claude-work", .on)]
        let held = recorder.held; recorder.held = []
        held.forEach { $0(recorder.folders) }
        XCTAssertEqual(recorder.reads, 3, "The refresh asked for meanwhile became one more read.")
        XCTAssertEqual(model.statusLineFolders, recorder.folders)
    }

    /// The row is a paragraph and a button while it is off and one line once it is on: the card's window is told, or it would stay the height it had.
    func testTheCardTellsItsWindowWhenTheLimitsRowChangesHeight() {
        let recorder = Recorder()
        recorder.folders = [folder(".claude", .off), folder(".claude-work", .off)]
        let permissions = PermissionsModel(services: recorder.services, claudeFolders: [], center: NotificationCenter(), workspace: NotificationCenter())
        permissions.refresh()
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-limits-height-" + UUID().uuidString)!)
        model.settingsTab = .permissions
        var changes = 0
        let card = SettingsCard(model: model, screen: CGSize(width: 1512, height: 982), topInset: 32, permissions: permissions, onContentChange: { changes += 1 })
        let host = NSHostingView(rootView: card.environment(\.nookTintedGlass, false))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 460, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let before = changes
        recorder.folders = [folder(".claude", .on), folder(".claude-work", .on)]
        permissions.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertGreaterThan(changes, before, "Its window is told the content changed.")
        // Nothing changed: nothing is said.
        let after = changes
        permissions.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(changes, after)
    }

    /// The real read, on temporary folders (never on the user's own): each file of settings as the row will see it.
    func testTheRealReadOfTemporaryFoldersGivesEachState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-limits-row-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("nook-statusline.sh")
        func settings(_ folder: String, _ json: String?) throws -> URL {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let json { try json.write(to: ClaudeHooks.settingsURL(in: url), atomically: true, encoding: .utf8) }
            return url
        }
        let own = NookStatusLine.command(script: script)
        let urls = [try settings("off", nil),
                    try settings("on", "{\"statusLine\":{\"type\":\"command\",\"command\":\(String(data: try JSONEncoder().encode(own), encoding: .utf8)!)}}"),
                    try settings("chained", "{\"statusLine\":{\"type\":\"command\",\"command\":\(String(data: try JSONEncoder().encode(NookStatusLine.command(script: script, chaining: "ccstatusline")), encoding: .utf8)!)}}"),
                    try settings("foreign", "{\"statusLine\":{\"type\":\"command\",\"command\":\"ccstatusline\"}}"),
                    try settings("broken", "{ not json")]
        let read = NookStatusLine.states(folders: urls, script: script)
        XCTAssertEqual(read.map(\.name), ["~/off", "~/on", "~/chained", "~/foreign", "~/broken"])
        XCTAssertEqual(read.map(\.state), [.off, .on, .chained(original: "ccstatusline"), .foreign(command: "ccstatusline"), .unreadable])
        XCTAssertEqual(ClaudeLimitsPresentation.make(folders: Array(read[0..<2])).chip, "1 de 2 carpetas")
        XCTAssertEqual(ClaudeLimitsPresentation.make(folders: read).chip, "Ajustes ilegibles")
        XCTAssertEqual(ClaudeLimitsPresentation.make(folders: [read[2]]).chip, "Encadenada con la tuya")
    }

    // MARK: The figures

    private func payload(cost: Bool = true, context: Bool = true, model: Bool = true) -> ClaudeStatusPayload {
        var json: [String: Any] = ["session_id": "abc123", "transcript_path": "/Users/x/.claude/projects/p/abc123.jsonl"]
        if cost { json["cost"] = ["total_cost_usd": 1.75, "total_duration_ms": 496_000.0, "total_api_duration_ms": 254_000.0, "total_lines_added": 12, "total_lines_removed": 3] }
        if context { json["context_window"] = ["used_percentage": 38.0, "remaining_percentage": 62.0, "context_window_size": 200_000, "total_input_tokens": 76_000] }
        if model { json["model"] = ["id": "claude-opus-5-5", "display_name": "Opus 5.5"]; json["effort"] = ["level": "xhigh"] }
        json["prompt_cache"] = ["warm": true, "ttl": "1h", "requests": 22, "misses": 0, "hit_ratio": 0.95, "expires_at": Date().addingTimeInterval(3000).timeIntervalSince1970]
        return ClaudeStatusPayload(json: json)!
    }

    private func limits(_ now: Date, five: Double? = 28, week: Double? = 74, spend: Bool = false, fiveResets: TimeInterval = 4 * 3600) -> ClaudeStatusPayload.RateLimits {
        ClaudeStatusPayload.RateLimits(
            fiveHour: five.map { .init(usedPercentage: $0, resetsAt: now.addingTimeInterval(fiveResets)) },
            sevenDay: week.map { .init(usedPercentage: $0, resetsAt: now.addingTimeInterval(5 * 86_400)) },
            spendLimit: spend ? .init(usedPercentage: 24.6, resetsAt: now.addingTimeInterval(12 * 86_400), usedUSD: 12.3, limitUSD: 50, period: "monthly") : nil)
    }

    private func live(_ now: Date, read ago: TimeInterval = 120, spend: Bool = false, five: Double? = 28, week: Double? = 74, session: ClaudeStatusPayload? = nil) -> ClaudeLiveUsage {
        ClaudeLiveUsage(session: session ?? payload(), sessionAt: now.addingTimeInterval(-ago), limits: limits(now, five: five, week: week, spend: spend), limitsAt: now.addingTimeInterval(-ago))
    }

    func testReadingsThatDescribeThePresentAreTheOnesKept() {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let fresh = live(now, spend: true)
        XCTAssertEqual(fresh.upToDate(at: now), fresh, "Nothing has passed: nothing goes.")
        // The five hours' window is over: its percent is of a window that is gone.
        var stale = fresh
        stale.limits?.fiveHour = .init(usedPercentage: 90, resetsAt: now.addingTimeInterval(-60))
        let kept = try? XCTUnwrap(stale.upToDate(at: now))
        XCTAssertNil(kept?.limits?.fiveHour); XCTAssertNotNil(kept?.limits?.sevenDay); XCTAssertNotNil(kept?.limits?.spendLimit)
        XCTAssertNotNil(kept?.session, "The session's figures stay.")
        // Nothing of the limits left: their reading goes too; and with no session either, nothing is.
        var over = stale
        over.limits?.sevenDay = .init(usedPercentage: 10, resetsAt: now.addingTimeInterval(-1)); over.limits?.spendLimit = nil
        XCTAssertNil(over.upToDate(at: now)?.limits); XCTAssertNil(over.upToDate(at: now)?.limitsAt)
        over.session = nil
        XCTAssertNil(over.upToDate(at: now))
        // A limit that says no reset time is kept (there is nothing to say it is over).
        var open = fresh
        open.limits?.fiveHour = .init(usedPercentage: 5, resetsAt: nil)
        XCTAssertNotNil(open.upToDate(at: now)?.limits?.fiveHour)
    }

    func testTheWordsAndFiguresOfTheLiveMarks() {
        XCTAssertEqual(UsageLive.ago(5), "hace unos segundos")
        XCTAssertEqual(UsageLive.ago(60), "hace 1 min")
        XCTAssertEqual(UsageLive.ago(8 * 60), "hace 8 min")
        XCTAssertEqual(UsageLive.ago(2 * 3600), "hace 2 h")
        XCTAssertEqual(UsageLive.ago(3 * 86_400), "hace 3 d")
        XCTAssertEqual(UsageLive.ago(-30), "hace unos segundos", "A clock that is a little behind is not a negative time.")
        XCTAssertEqual(UsageLive.tokens(200_000), "200k"); XCTAssertEqual(UsageLive.tokens(1_000_000), "1M"); XCTAssertEqual(UsageLive.tokens(1_500_000), "1,5M"); XCTAssertEqual(UsageLive.tokens(850), "850")
        XCTAssertEqual(UsageLive.money(50), "$50"); XCTAssertEqual(UsageLive.money(12.3), "$12.30")
        XCTAssertEqual(UsageLive.spend(.init(usedPercentage: 24.6, resetsAt: nil, usedUSD: 12.3, limitUSD: 50, period: "monthly")), "$12.30 de $50 · mensual")
        XCTAssertEqual(UsageLive.spend(.init(usedPercentage: 24.6, resetsAt: nil, usedUSD: 12.3, limitUSD: nil, period: nil)), "$12.30 gastados")
        XCTAssertEqual(UsageLive.spend(.init(usedPercentage: 24.6, resetsAt: nil, usedUSD: 12.3, limitUSD: 50, period: "fortnightly")), "$12.30 de $50", "A period it does not know is left out, not guessed.")
        XCTAssertNil(UsageLive.spend(.init(usedPercentage: 24.6, resetsAt: nil)), "No dollars, no line.")
        XCTAssertNil(UsageLive.spend(nil))
        XCTAssertEqual(UsageLive.effort("xhigh"), "muy alto"); XCTAssertEqual(UsageLive.effort("High"), "alto"); XCTAssertNil(UsageLive.effort("turbo")); XCTAssertNil(UsageLive.effort(nil))
    }

    func testTheContextCellsTipSaysTheWindowTheModelAndTheEffort() {
        let tip = UsageLive.contextTip(payload())
        XCTAssertEqual(tip?.title, "Contexto"); XCTAssertEqual(tip?.value, "38 % usado")
        XCTAssertEqual(tip?.detail, "Ventana de 200k tokens · Opus 5.5 · esfuerzo muy alto")
        XCTAssertNil(UsageLive.contextTip(payload(context: false)), "No context, no cell.")
        XCTAssertEqual(UsageLive.contextTip(payload(model: false))?.detail, "Ventana de 200k tokens", "Without a model or effort it says what it has.")
        // The model by its id when Claude gave no name.
        var named = payload()
        named.modelName = nil
        XCTAssertEqual(UsageLive.contextTip(named)?.detail, "Ventana de 200k tokens · Opus 5.5 · esfuerzo muy alto")
    }

    // MARK: The glance

    func testTheUsageButtonsTipSaysWhereTheLimitsStand() throws {
        let now = Date(timeIntervalSince1970: 1_791_500_000)
        let zone = TimeZone(identifier: "America/Bogota")!
        let tip = try XCTUnwrap(UsageGlance.tip(from: live(now, read: 30), now: now, zone: zone))
        XCTAssertEqual(tip.title, "Uso y límites")
        XCTAssertEqual(tip.value, "sesión 28 % · semana 74 %")
        let detail = try XCTUnwrap(tip.detail)
        let lines = detail.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, detail)
        XCTAssertTrue(lines[0].hasPrefix("Sesión: reinicia"), detail)
        XCTAssertTrue(lines[1].hasPrefix("Semana: reinicia"), detail)
        XCTAssertEqual(lines[2], "Pulsa para ver el detalle")
        XCTAssertFalse(detail.contains("Dato de"), "A reading of half a minute needs no warning.")
        XCTAssertTrue(lines[1].contains("\u{00A0}"), "A time is not split by the line's end.")
        // An old reading says how old.
        let old = try XCTUnwrap(UsageGlance.tip(from: live(now, read: 2 * 3600), now: now, zone: zone))
        XCTAssertEqual(try XCTUnwrap(old.detail).components(separatedBy: "\n").dropLast().last, "Dato de hace 2 h")
        // Only what is current: a window that is over is not said, and with no window left there is no glance (the button's own tip stays).
        XCTAssertEqual(UsageGlance.tip(from: live(now, fiveResets: -10), now: now, zone: zone)?.value, "semana 74 %")
        XCTAssertNil(UsageGlance.tip(from: live(now, five: nil, week: nil), now: now, zone: zone))
        XCTAssertNil(UsageGlance.tip(from: nil, now: now, zone: zone))
        XCTAssertNil(UsageGlance.tip(from: ClaudeLiveUsage(session: payload(), sessionAt: now, limits: nil, limitsAt: nil), now: now, zone: zone), "A tab with a session's figures and no limits.")
        // Floored like the panel's own «% used».
        XCTAssertEqual(UsageGlance.tip(from: live(now, five: 28.9, week: 74.9), now: now, zone: zone)?.value, "sesión 28 % · semana 74 %")
    }

    private func live(_ now: Date, fiveResets: TimeInterval) -> ClaudeLiveUsage {
        ClaudeLiveUsage(session: payload(), sessionAt: now, limits: limits(now, fiveResets: fiveResets), limitsAt: now)
    }

    // MARK: The card

    /// Every labelled element of the window with its spoken value: how a test reads what the card says, dots included, without guessing where a layout put it.
    private func spoken(in window: NSWindow) -> [(label: String, value: String)] {
        // SwiftUI builds its accessibility nodes only when assistive technology is on: the app is told it is (the setter `AccessibilityLookup` uses, called by its selector so the build has no warning for it).
        _ = NSApp.perform(Selector(("accessibilitySetValue:forAttribute:")), with: true as NSNumber, with: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [(String, String)] = []
        func walk(_ element: AnyObject) {
            guard let node = element as? NSObject else { return }
            if let label = node.value(forKey: "accessibilityLabel") as? String, !label.isEmpty {
                // SwiftUI says a value either as the element's value or as its description.
                let value = (node.value(forKey: "accessibilityValue") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (node.value(forKey: "accessibilityValueDescription") as? String) ?? ""
                found.append((label, value))
            }
            for child in (node.value(forKey: "accessibilityChildren") as? [Any]) ?? [] { walk(child as AnyObject) }
        }
        for child in window.contentView?.accessibilityChildren() ?? [] { walk(child as AnyObject) }
        return found
    }

    private func card(text: String, live: ClaudeLiveUsage?, now: Date, width: CGFloat = 690, height: CGFloat = 1700) -> (NSWindow, NSHostingView<AnyView>) {
        let view = ClaudePanelCard(text: text, growsIsland: true, live: live, now: now).frame(width: width, height: height).padding(15).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width + 30, height: height + 30)
        let window = NSWindow(contentRect: host.frame.offsetBy(dx: -30000, dy: -30000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        return (window, host)
    }

    /// A Terminal tab's screen scrolled past the session and the limits: Claude's panel shows from what spends them down.
    private var cut: String { ClaudeUsageFixtures.screen(top: ClaudeUsageFixtures.body.firstIndex { $0.contains("What's contributing") }!, height: 40) }

    /// A morning in Bogotá, when the panel's "Resets 1pm" is still to come (the card replaces a reset that has passed with the status line's next one, and marks it).
    private var morning: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Bogota")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 8, minute: 0))!
    }

    func testTheCardMarksWhatCameFromTheStatusLineAndOnlyThat() throws {
        let now = Date()
        // The screen has no limits and no session: the status line gives them, and they are marked.
        let (window, _) = card(text: cut, live: live(now, spend: true), now: now)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let said = spoken(in: window)
        func value(_ label: String) -> String? { said.first { $0.label == label }?.value }
        XCTAssertTrue(try XCTUnwrap(value("Sesión actual"), "\(said.map(\.label))").contains("en vivo"), "The session's limit came from the status line.")
        XCTAssertTrue(try XCTUnwrap(value("Semana actual (todos los modelos)")).contains("en vivo"))
        XCTAssertTrue(try XCTUnwrap(value("Límite de gasto")).contains("$12.30 de $50 · mensual"), "The spend limit says its dollars.")
        XCTAssertTrue(try XCTUnwrap(value(UsageWords.stat("Total cost"))).hasSuffix("En vivo"), "The session's cost too.")
        XCTAssertTrue(try XCTUnwrap(value("Contexto")).hasPrefix("38 %"), "The context window, which only the status line knows.")
        XCTAssertTrue(try XCTUnwrap(value("Contexto")).hasSuffix("En vivo"))
    }

    func testWhereThePanelHasTheFigureItIsNotMarked() throws {
        let now = morning
        // The whole panel is on the screen: its figures are its own, and nothing is marked live but what only the status line has.
        let (window, _) = card(text: ClaudeUsageFixtures.terminal, live: live(now), now: now)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let said = spoken(in: window)
        func value(_ label: String) -> String? { said.first { $0.label == label }?.value }
        XCTAssertFalse(try XCTUnwrap(value("Sesión actual")).contains("en vivo"), "The panel's own bar wins.")
        XCTAssertFalse(try XCTUnwrap(value(UsageWords.stat("Total cost"))).contains("En vivo"))
        XCTAssertTrue(try XCTUnwrap(value("Contexto")).hasSuffix("En vivo"), "The context is only ever the status line's.")
        // Without the status line the card is as it was: no context cell, no dots.
        let (plain, _) = card(text: ClaudeUsageFixtures.terminal, live: nil, now: now)
        defer { plain.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let without = spoken(in: plain)
        XCTAssertNil(without.first { $0.label == "Contexto" })
        XCTAssertFalse(without.contains { $0.value.contains("en vivo") || $0.value.contains("En vivo") })
    }

    func testALimitThatHasResetIsNotTakenFromTheStatusLine() throws {
        let now = Date()
        // The five hours' window ended a minute ago: the card does not show the percent of a window that is over.
        let stale = ClaudeLiveUsage(session: nil, sessionAt: nil, limits: limits(now, fiveResets: -60), limitsAt: now.addingTimeInterval(-3600))
        let (window, _) = card(text: cut, live: stale, now: now)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let said = spoken(in: window)
        XCTAssertNil(said.first { $0.label == "Sesión actual" }, "\(said.map(\.label))")
        XCTAssertNotNil(said.first { $0.label == "Semana actual (todos los modelos)" }, "The week's is still current.")
    }

    // MARK: Renders

    private func renderDirectory() throws -> String {
        guard let directory = ProcessInfo.processInfo.environment["NOOK_RENDER_DIR"] else { throw XCTSkip("Set NOOK_RENDER_DIR to render the live limits.") }
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.cacheDisplay(in: host.bounds, to: rep)
            if (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.5 { break }
            rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    /// The Permisos tab with the "Límites en vivo" row in each state of the folders (the others as in a normal day), opened and closed.
    func testRenderTheLimitsRowInEachState() throws {
        let directory = try renderDirectory()
        let chained = NookStatusLine.State.chained(original: "ccstatusline")
        let granted: [NookPermission: NookPermission.State] = [.automation: .granted, .accessibility: .granted, .microphone: .granted, .speech: .granted]
        let hooks = [ClaudeFolder(name: "~/.claude", enabled: true), ClaudeFolder(name: "~/.claude-work", enabled: true)]
        // The open ones on a screen tall enough for the whole list, to see all of the guide; the others at the height a 982 pt screen gives the card.
        let tall: Set<String> = ["on-open", "off-open", "off-whole"]
        let cases: [(String, [NookStatusLine.Folder]?, Bool)] = [
            ("off", [folder(".claude", .off), folder(".claude-work", .off)], false),
            ("foreign", [folder(".claude", .foreign(command: "ccstatusline")), folder(".claude-work", .off)], false),
            ("partial", [folder(".claude", .on), folder(".claude-work", .off)], false),
            ("on", [folder(".claude", .on), folder(".claude-work", .on)], false),
            ("on-open", [folder(".claude", .on), folder(".claude-work", .on)], true),
            ("chained", [folder(".claude", chained), folder(".claude-work", chained)], false),
            ("unreadable", [folder(".claude", .on), folder(".claude-work", .unreadable)], false),
            ("reading", nil, false),
            ("off-open", [folder(".claude", .off), folder(".claude-work", .off)], true),
            ("off-whole", [folder(".claude", .off), folder(".claude-work", .off)], false),
        ]
        for (name, folders, open) in cases {
            let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-render-\(UUID().uuidString)")!)
            model.settingsTab = .permissions
            model.claudeSignalsEnabled = true
            let permissions = PermissionsModel(states: granted, claudeFolders: hooks, statusLineFolders: folders, openGuides: open ? [PermissionsModel.limitsKey] : [])
            let view = SettingsCard(model: model, screen: CGSize(width: 1512, height: tall.contains(name) ? 2200 : 982), topInset: 32, permissions: permissions).padding(30).background(Color(white: 0.3))
            let host = NSHostingView(rootView: view.environment(\.nookTintedGlass, false))
            try write(host, size: host.fittingSize, to: URL(fileURLWithPath: directory).appendingPathComponent("limits-row-\(name).png").path)
        }
    }

    /// The usage card of a Terminal tab scrolled to the middle of Claude's panel, with and without the status line: the dots, the context cell and the spend limit's dollars.
    func testRenderTheUsageCardWithTheStatusLine() throws {
        let directory = try renderDirectory()
        let now = Date()
        for (name, text, status) in [("cut-live", cut, live(now, read: 95, spend: true)), ("cut-plain", cut, nil), ("whole-live", ClaudeUsageFixtures.terminal, live(now, read: 95)),
                                     ("cut-stale", cut, live(now, read: 3 * 3600, spend: true))] as [(String, String, ClaudeLiveUsage?)] {
            let view = ClaudePanelCard(text: text, growsIsland: true, live: status, now: now).frame(width: 690, height: 1000).padding(15).background(Color.black)
                .environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
            try write(NSHostingView(rootView: view), size: NSSize(width: 720, height: 1030), to: URL(fileURLWithPath: directory).appendingPathComponent("usage-live-\(name).png").path)
        }
    }
    /// What the tips say: the usage button's own, its glance at the limits (fresh and old), a dot's and the context cell's.
    func testRenderTheTips() throws {
        let directory = try renderDirectory()
        let now = Date()
        let tips: [NookTip] = [
            NookTip("Uso y límites", detail: "Lo que llevas gastado y cuándo se reinicia (/usage)"),
            try XCTUnwrap(UsageGlance.tip(from: live(now, read: 30), now: now)),
            try XCTUnwrap(UsageGlance.tip(from: live(now, read: 2 * 3600), now: now)),
            NookTip("En vivo", value: "hace 3 min", detail: UsageLive.words),
            try XCTUnwrap(UsageLive.contextTip(payload())),
        ]
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in NookTipBubble(tip: tip).frame(maxWidth: 300, alignment: .leading) }
        }.padding(24).frame(width: 350, alignment: .leading).background(Color(white: 0.06)).environment(\.colorScheme, .dark).environment(\.nookTintedGlass, false)
        let host = NSHostingView(rootView: view)
        try write(host, size: host.fittingSize, to: URL(fileURLWithPath: directory).appendingPathComponent("tips-live.png").path)
    }
}
