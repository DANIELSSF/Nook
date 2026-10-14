import XCTest
@testable import Nook

/// Claude's own copy of its latest usage reading (`cachedUsageUtilization` in its global file): the per-model weekly limits the
/// status line never sends, and Nook's own usage card made from both. The sample is the shape Claude Code 2.1.296 writes, trimmed.
final class ClaudeUsageSnapshotTests: XCTestCase {
    private static let account = "00000000-0000-4000-8000-000000000001"
    /// 2026-10-13 13:13:14 UTC.
    private static let fetched = Date(timeIntervalSince1970: 1_791_897_194.355)
    private let zone = TimeZone(identifier: "America/Bogota")!

    private func file(account: String = account, cachedAccount: String? = account, fable: Double = 41, fetchedAtMs: Double = 1_791_897_194_355) -> Data {
        var cached: [String: Any] = ["fetchedAtMs": fetchedAtMs, "utilization": [
            "five_hour": ["utilization": 3, "resets_at": "2026-10-13T18:00:00.233636+00:00"],
            "seven_day_sonnet": NSNull(),
            "limits": [
                ["kind": "session", "group": "session", "percent": 3, "severity": "normal", "resets_at": "2026-10-13T18:00:00.233636+00:00", "scope": NSNull(), "is_active": true],
                ["kind": "weekly_all", "group": "weekly", "percent": 12, "severity": "normal", "resets_at": "2026-10-20T11:00:00.233667+00:00", "scope": NSNull(), "is_active": false],
                ["kind": "weekly_scoped", "group": "weekly", "percent": fable, "severity": "normal", "resets_at": "2026-10-20T11:00:00+00:00",
                 "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()], "is_active": false],
                ["kind": "monthly_spend", "group": "spend", "percent": 5, "resets_at": NSNull()],
            ],
        ] as [String: Any]]
        if let cachedAccount { cached["accountUuid"] = cachedAccount }
        let json: [String: Any] = ["numStartups": 12, "oauthAccount": ["accountUuid": account, "emailAddress": "someone@example.com"], "cachedUsageUtilization": cached]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    // MARK: The snapshot

    func testClaudesReadingIsReadAsItIsWritten() throws {
        let snapshot = try XCTUnwrap(ClaudeUsageSnapshot.parse(file()))
        XCTAssertEqual(snapshot.fetchedAt.timeIntervalSince1970, Self.fetched.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.limits.map(\.title), ["Current session", "Current week (all models)", "Current week (Fable)"], "A kind Nook doesn't know is left out.")
        XCTAssertEqual(snapshot.limits.map(\.percent), [3, 12, 41])
        XCTAssertEqual(snapshot.limits.map(\.dated), [false, true, true])
        XCTAssertEqual(snapshot.limits[0].resetsAt, Date(timeIntervalSince1970: 1_791_914_400), "Microseconds and all.")
        XCTAssertEqual(snapshot.limits[2].resetsAt, Date(timeIntervalSince1970: 1_792_494_000))
    }

    func testAReadingOfAnotherAccountOrNoneIsIgnored() {
        XCTAssertNil(ClaudeUsageSnapshot.parse(file(account: "another-account")), "Signed in as someone else since.")
        XCTAssertNil(ClaudeUsageSnapshot.parse(file(cachedAccount: nil)))
        XCTAssertNil(ClaudeUsageSnapshot.parse(Data(#"{"numStartups":3}"#.utf8)))
        XCTAssertNil(ClaudeUsageSnapshot.parse(Data("{\"cachedUsageUtilization\":".utf8)), "Cut off while written.")
    }

    func testOnlyWhatStillDescribesThePresentIsKept() throws {
        let snapshot = try XCTUnwrap(ClaudeUsageSnapshot.parse(file()))
        XCTAssertEqual(snapshot.upToDate(at: Self.fetched.addingTimeInterval(60)), snapshot)
        // Past the session's reset (18:00 UTC): its window is over, the weeks stay.
        XCTAssertEqual(snapshot.upToDate(at: Date(timeIntervalSince1970: 1_791_914_401))?.limits.map(\.title), ["Current week (all models)", "Current week (Fable)"])
        XCTAssertNil(snapshot.upToDate(at: Self.fetched.addingTimeInterval(ClaudeUsageSnapshot.maxAge + 1)), "A day old says too little.")
    }

    func testTheGlobalFileIsWhereClaudeKeepsIt() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(ClaudeUsageSnapshot.files(config: home.appendingPathComponent(".claude"), home: home).map(\.path),
                       ["/Users/me/.claude/.config.json", "/Users/me/.claude.json"], "The default folder's file is in the home folder.")
        XCTAssertEqual(ClaudeUsageSnapshot.files(config: home.appendingPathComponent(".claude-work"), home: home).map(\.path),
                       ["/Users/me/.claude-work/.config.json", "/Users/me/.claude-work/.claude.json"], "A CLAUDE_CONFIG_DIR keeps its own.")
    }

    func testTheReaderReadsAgainOnlyWhenTheFileChanges() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-usage-snapshot-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let reader = ClaudeUsageSnapshotReader(home: home)
        XCTAssertNil(reader.snapshot(config: config.path), "No file yet.")
        let url = config.appendingPathComponent(".claude.json")
        let stamp = Date(timeIntervalSinceNow: -60)
        try file(fable: 41).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        XCTAssertEqual(reader.snapshot(config: config.path)?.limits.last?.percent, 41)
        try file(fable: 57).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(reader.snapshot(config: config.path)?.limits.last?.percent, 57, "Claude asked again: the new reading.")
        // The default folder's file lives in the home folder.
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try file(fable: 9).write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(reader.snapshot(config: home.appendingPathComponent(".claude").path)?.limits.last?.percent, 9)
    }

    func testALinkIsNeverFollowed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-usage-link-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("elsewhere.json")
        try file().write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: config.appendingPathComponent(".claude.json"), withDestinationURL: elsewhere)
        XCTAssertNil(ClaudeUsageSnapshotReader(home: home).snapshot(config: config.path))
    }

    // MARK: Nook's own card

    private func live(_ now: Date, five: Double = 7, week: Double = 15, limitsAt: Date, saved: ClaudeUsageSnapshot?) -> ClaudeLiveUsage {
        ClaudeLiveUsage(session: nil, sessionAt: nil,
                        limits: .init(fiveHour: .init(usedPercentage: five, resetsAt: now.addingTimeInterval(4 * 3600)),
                                      sevenDay: .init(usedPercentage: week, resetsAt: now.addingTimeInterval(5 * 86_400)), spendLimit: nil),
                        limitsAt: limitsAt, saved: saved)
    }

    func testTheCardHasTheModelsWeekFromClaudesReadingAndTheRestLive() throws {
        let now = Self.fetched.addingTimeInterval(25 * 60)
        let saved = try XCTUnwrap(ClaudeUsageSnapshot.parse(file()))
        // The status line answered after Claude's reading: its session and week are the newer.
        let usage = try XCTUnwrap(ClaudeUsage.nookCard(from: live(now, limitsAt: now.addingTimeInterval(-30), saved: saved), now: now, zone: zone))
        XCTAssertEqual(usage.meters.map(\.title), ["Current session", "Current week (all models)", "Current week (Fable)"], "Claude's order.")
        XCTAssertEqual(usage.meters.map(\.label), ["7% used", "15% used", "41% used"])
        XCTAssertEqual(usage.meters.map(\.source), [.live, .live, .snapshot])
        XCTAssertEqual(usage.meters[2].resets, "Resets Oct 20 at 6am (America/Bogota)")
        XCTAssertEqual(usage.savedAt, saved.fetchedAt, "The card can say how old the Fable figure is.")
    }

    func testClaudesReadingWinsWhenItIsTheNewer() throws {
        let now = Self.fetched.addingTimeInterval(60)
        let saved = try XCTUnwrap(ClaudeUsageSnapshot.parse(file()))
        // /usage was opened after the last answer: Claude's reading is the newer.
        let usage = try XCTUnwrap(ClaudeUsage.nookCard(from: live(now, limitsAt: Self.fetched.addingTimeInterval(-600), saved: saved), now: now, zone: zone))
        XCTAssertEqual(usage.meters.map(\.label), ["3% used", "12% used", "41% used"])
        XCTAssertEqual(usage.meters.map(\.source), [.snapshot, .snapshot, .snapshot])
    }

    func testWithoutClaudesReadingTheCardIsTheStatusLinesAlone() throws {
        let now = Self.fetched
        let usage = try XCTUnwrap(ClaudeUsage.nookCard(from: live(now, limitsAt: now, saved: nil), now: now, zone: zone))
        XCTAssertEqual(usage.meters.map(\.title), ["Current session", "Current week (all models)"])
        XCTAssertNil(usage.savedAt)
        XCTAssertNil(ClaudeUsage.nookCard(from: nil), "No status line: no card of Nook's own.")
    }

    func testThePanelsOwnRowsStillWin() throws {
        let now = Self.fetched.addingTimeInterval(60)
        let saved = try XCTUnwrap(ClaudeUsageSnapshot.parse(file()))
        let panel = ClaudeUsage(meters: [.init(title: "Current session", fraction: 0.05, label: "5% used", resets: nil),
                                         .init(title: "Current week (Fable)", fraction: 0.44, label: "44% used", resets: nil)])
        let usage = panel.filled(from: live(now, limitsAt: now, saved: saved), now: now, zone: zone)
        XCTAssertEqual(usage.meters.map(\.title), ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertEqual(usage.meters.map(\.label), ["5% used", "15% used", "44% used"], "What is on Claude's screen now is the newest of all.")
        XCTAssertEqual(usage.meters.map(\.source), [.panel, .live, .panel])
        XCTAssertNil(usage.savedAt, "No figure of the snapshot shown.")
    }

    func testTheButtonsTipHasTheModelsWeek() throws {
        let now = Self.fetched.addingTimeInterval(5 * 60)
        let saved = try XCTUnwrap(ClaudeUsageSnapshot.parse(file()))
        let tip = try XCTUnwrap(UsageGlance.tip(from: live(now, limitsAt: now, saved: saved), now: now, zone: zone))
        XCTAssertEqual(tip.value, "sesión 7 % · semana 15 % · Fable 41 %")
        XCTAssertEqual(tip.detail?.components(separatedBy: "\n").last, "Pulsa para ver el detalle")
        XCTAssertFalse(tip.detail?.contains("Fable: dato") ?? true, "Five minutes old needs no warning.")
        let later = Self.fetched.addingTimeInterval(40 * 60)
        let old = try XCTUnwrap(UsageGlance.tip(from: live(later, limitsAt: later, saved: saved), now: later, zone: zone))
        XCTAssertTrue(old.detail?.contains("Fable: dato de hace 40 min") ?? false, old.detail ?? "")
    }
}

/// The usage button with Claude's status line on: Nook's own card, nothing typed in the terminal; and closing it stays in Nook.
@MainActor
final class NookUsageCardTests: XCTestCase {
    func testTheButtonOpensNooksCardAndClosingItStaysInNook() throws {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-usagecard-" + UUID().uuidString)!)
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "app", index: 1, tty: "/dev/ttys943", customTitle: "", processes: ["claude"], busy: false, selected: true,
                                      text: "⏺ hola")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]
        session.agent = .claude
        let now = Date()
        session.liveUsage = ClaudeLiveUsage(session: nil, sessionAt: nil,
                                            limits: .init(fiveHour: .init(usedPercentage: 7, resetsAt: now.addingTimeInterval(3600)), sevenDay: nil, spendLimit: nil), limitsAt: now)
        model.openUsage(on: session)
        XCTAssertTrue(session.usageCardOpen)
        XCTAssertNil(session.pendingMessage, "Nothing typed in the terminal.")
        model.closeUsageCard(on: session)
        XCTAssertFalse(session.usageCardOpen)
    }
}
