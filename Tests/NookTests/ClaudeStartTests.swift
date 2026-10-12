import XCTest
@testable import Nook

/// A Claude just started (`claude2`, Sample's function for his work account, in a Terminal tab or a Nook session) showed in Nook as
/// the shell line that started it and nothing after: "como si hubiera puesto el comando de claude y lo haya ignorado la interfaz".
/// What lies above Claude's newest banner belongs to whatever ran in the tab before; the conversation starts after it, and until it
/// has a message the tab says it waits for the first one (`awaitsFirstMessage`).
final class ClaudeStartTests: XCTestCase {
    private let rule = String(repeating: "─", count: 120)
    private let banner = [" ▐▛███▛█   Claude Code v2.1.293", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Examples/New project"]
    private let shell = ["Last login: Thu Oct  8 09:20:11 on ttys004", "developer@MacBook-Pro-Example New project % claude2"]
    private var box: [String] { [String(repeating: " ", count: 82) + "✔ Update installed · Restart to update", rule, "❯ Try \"write a test for <filepath>\"", rule,
                                 "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"] }

    /// Sample's Terminal tab at 9:22:46 (the screenshot): the shell above, Claude's banner, the empty box with its grey suggestion.
    private var fresh: String { (shell + banner + Array(repeating: "", count: 30) + box).joined(separator: "\n") }

    private func tab(_ text: String, processes: [String] = ["login", "-zsh", "claude"]) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: 1, windowTitle: "New project", index: 1, tty: "/dev/ttys004", customTitle: "", processes: processes, busy: false, selected: true, text: text)
    }

    /// Captured read-only from Nook's own tmux panes (8/10, Claude Code 2.1.289): a fresh session, and one whose settings file
    /// picked the model, which Claude notes under its banner.
    static let paneFresh = (["", " ▐▛███▛█   Claude Code v2.1.289", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Chamba"]
        + Array(repeating: "", count: 29) + ["                                         ✔ Update installed · Restart to update",
                                             String(repeating: "─", count: 81), "❯ Try \"how do I log an error?\"", String(repeating: "─", count: 81),
                                             "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]).joined(separator: "\n")
    static let paneNotice = (["", " ▐▛███▛█   Claude Code v2.1.289", "▝▜██████▀  Sonnet 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   /Users/developer", "",
                              "▎ Using Sonnet 5.5 (from .claude/settings.json) · /model"] + Array(repeating: "", count: 21)
        + ["                                 ✔ Update installed · Restart to update", String(repeating: "─", count: 73), "❯ Try \"refactor <filepath>\"",
           String(repeating: "─", count: 73), "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]).joined(separator: "\n")

    /// A Nook pane like `paneFresh`, with a conversation (and a status line) under the banner.
    private func pane(_ chat: [String], status: String? = nil) -> String {
        ([" ▐▛███▛█   Claude Code v2.1.289", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Chamba", ""] + chat
         + (status.map { ["", $0] } ?? []) + ["", String(repeating: "─", count: 81), "❯ ", String(repeating: "─", count: 81),
                                               "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"]).joined(separator: "\n")
    }

    func testANewClaudeShowsNothingOfTheShellThatStartedIt() throws {
        let screen = ClaudeComposer.split(fresh)
        XCTAssertEqual(screen.conversation, "")
        XCTAssertEqual(screen.banner?.version, "2.1.293")
        XCTAssertEqual(screen.input, "Try \"write a test for <filepath>\"")
        let session = TerminalSession(tab: tab(fresh), backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertEqual(session.displayText, "")
        XCTAssertEqual(session.banner?.model, "Opus 5.5")
        XCTAssertTrue(session.awaitsFirstMessage)
    }

    func testNooksOwnPanesJustStartedWaitForTheFirstMessage() {
        for capture in [Self.paneFresh, Self.paneNotice] {
            let session = paneSession()
            session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: capture)
            XCTAssertNotNil(session.banner)
            XCTAssertTrue(session.awaitsFirstMessage, "Claude's grey suggestion and its notes under the banner are no conversation.")
        }
        XCTAssertFalse(ClaudeExchange.begun("▎ Using Sonnet 5.5 (from .claude/settings.json) · /model"))
    }

    func testAResumedConversationIsPrintedAfterTheBannerAndStays() {
        let resumed = (shell.dropLast() + ["developer@MacBook-Pro-Example New project % claude2 --resume"] + banner
                       + ["", "> arregla el login", "", "⏺ Listo, el login ya valida el token.", ""] + box).joined(separator: "\n")
        let session = TerminalSession(tab: tab(resumed), backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertEqual(session.displayText, "> arregla el login\n\n⏺ Listo, el login ya valida el token.")
        XCTAssertFalse(session.awaitsFirstMessage)
    }

    func testClearStartsTheConversationAfresh() {
        let cleared = (shell + banner + ["", "> hola", "", "⏺ Hola, ¿en qué te ayudo?", "", "> /clear", ""] + banner + Array(repeating: "", count: 10) + box)
            .joined(separator: "\n")
        let session = TerminalSession(tab: tab(cleared), backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertEqual(session.displayText, "")
        XCTAssertTrue(session.awaitsFirstMessage)
    }

    /// A reply that quotes a banner indents it: it is no session starting, and the conversation above stays.
    func testABannerQuotedInAReplyKeepsTheConversation() {
        let quoted = (banner + ["", "> ¿qué muestra al arrancar?", "", "⏺ Esto:", ""] + banner.map { "  " + $0 } + ["", "⏺ Nada más."] + box).joined(separator: "\n")
        let conversation = ClaudeComposer.split(quoted).conversation
        XCTAssertTrue(conversation.hasPrefix("> ¿qué muestra al arrancar?"), conversation)
        XCTAssertTrue(conversation.hasSuffix("⏺ Nada más."), conversation)
        XCTAssertTrue(ClaudeStartup.sinceNewestBanner(quoted).hasPrefix(banner[0]), "The guess for Claude's record reads from the real banner.")
    }

    func testOnlyClaudeTabsLoseWhatCameBefore() {
        let text = (shell + banner + ["", "⏺ Hecho."] + ["developer@MacBook-Pro-Example New project % codex", "› hola"]).joined(separator: "\n")
        XCTAssertEqual(TerminalSession.screen(text, agent: .codex).conversation, text, "Codex's screen is shown as it is.")
        let shellTab = TerminalSession(tab: tab(fresh + "\n" + shell[1].replacingOccurrences(of: "claude2", with: ""), processes: ["login", "-zsh"]),
                                       backend: .bundled, bridge: TerminalAppBridge())
        XCTAssertTrue(shellTab.displayText.hasPrefix("Last login:"), "A shell shows the whole terminal.")
        XCTAssertFalse(shellTab.awaitsFirstMessage)
    }

    /// The record of an earlier Claude in the tab must not be taken for this one's: its last prompt shows above the new banner only.
    func testTheRecordIsGuessedFromWhatFollowsTheNewestBanner() {
        let text = (banner + ["", "❯ arregla el login", "", "⏺ Listo.", "", "developer@MacBook-Pro-Example New project % claude2"] + banner + box).joined(separator: "\n")
        XCTAssertTrue(TranscriptLocator.shows(prompt: "arregla el login", on: text))
        XCTAssertFalse(TranscriptLocator.shows(prompt: "arregla el login", on: String(ClaudeStartup.sinceNewestBanner(text))))
        XCTAssertEqual(ClaudeStartup.sinceNewestBanner("⏺ sin banner"), "⏺ sin banner")
    }

    // MARK: awaitsFirstMessage

    private func paneSession() -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-start-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-start-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        return TerminalSession(record: record, backend: backend, create: false)
    }

    func testAMessageSentFromNookEndsTheWaitAtOnceAndAFailureBringsItBack() {
        let session = paneSession()
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: Self.paneFresh)
        XCTAssertTrue(session.awaitsFirstMessage)
        // /model and /effort never show in the chat: the welcome stays while the chips change them.
        session.showPending("/model sonnet")
        XCTAssertTrue(session.awaitsFirstMessage)
        session.showPending("hola")
        XCTAssertFalse(session.awaitsFirstMessage, "Right after a send, before Claude shows anything.")
        // The delivery failed: the message is back in the field.
        session.pendingMessage = nil
        XCTAssertTrue(session.awaitsFirstMessage)
        session.showPending("hola")
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: pane(["❯ hola", "", "⏺ ¡Hola! ¿En qué te ayudo?"]))
        XCTAssertNil(session.pendingMessage)
        XCTAssertFalse(session.awaitsFirstMessage)
        // A screen caught mid-redraw (no box) says nothing either way.
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: "❯ hola\n\n⏺ ¡Hola! ¿En qué te ayudo?")
        XCTAssertFalse(session.awaitsFirstMessage)
        // Claude quits: no Claude, nothing to wait for.
        session.applyPane(tty: "/dev/ttys006", processes: ["/bin/zsh -l"], text: nil)
        XCTAssertFalse(session.awaitsFirstMessage)
    }

    func testAScreenCaughtMidRedrawDoesNotEndTheWait() {
        let session = paneSession()
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: Self.paneFresh)
        // The box's rules not drawn yet: its line "❯ Try …" would read as a message.
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: " ▐▛███▛█   Claude Code v2.1.289\n❯ Try \"how do I log an error?\"")
        XCTAssertTrue(session.awaitsFirstMessage)
    }

    func testClaudesRecordQueueAndTurnCount() {
        let session = paneSession()
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: Self.paneFresh)
        session.applyTranscript("", recap: nil, queued: [])
        XCTAssertTrue(session.awaitsFirstMessage, "A record with nothing in it yet.")
        session.applyTranscript(nil, recap: nil, queued: ["mira esto"])
        XCTAssertFalse(session.awaitsFirstMessage, "Typed in the terminal and held in Claude's queue.")
        session.applyTranscript(nil, recap: nil, queued: [])
        XCTAssertTrue(session.awaitsFirstMessage)
        session.applyTranscript("> mira esto\n\n⏺ Ya lo miro.\n\n", recap: nil, queued: [])
        XCTAssertFalse(session.awaitsFirstMessage)

        let working = paneSession()
        working.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: pane([], status: "✻ Churning… (2s · esc to interrupt)"))
        XCTAssertFalse(working.awaitsFirstMessage, "A turn under way.")
    }

    func testTheBubbleOfAnImageMessageSettlesOnClaudesRecord() {
        let session = paneSession()
        session.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: Self.paneFresh)
        session.applyTranscript("> antes\n\n⏺ Hola.\n\n", recap: nil, queued: [])
        let message = MessageAttachments.message(text: "mira esta captura", files: [MessageAttachments.folder + "pantalla-20261008-092246.png"])
        session.showPending(message)
        // Held in Claude's queue as its box showed it.
        session.applyTranscript(nil, recap: nil, queued: ["[Image #1]mira esta captura"])
        XCTAssertTrue(session.pendingQueued)
        session.applyTranscript("> antes\n\n⏺ Hola.\n\n> [Image #1]mira esta captura\n\n> [Imagen]\n\n", recap: nil, queued: [])
        XCTAssertNil(session.pendingMessage)

        let alone = MessageAttachments.folder + "imagen-08102026092924.png"
        session.showPending(alone)
        session.applyTranscript("> antes\n\n⏺ Hola.\n\n> [Image #1]mira esta captura\n\n> [Imagen]\n\n> [Image #2]\n\n> [Imagen]\n\n", recap: nil, queued: [])
        XCTAssertNil(session.pendingMessage, "An image alone shows as its placeholder.")

        // Without Claude's record, its echo on screen.
        let screenOnly = paneSession()
        screenOnly.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: pane(["❯ hola", "", "⏺ Hola."]))
        screenOnly.showPending(message)
        screenOnly.applyPane(tty: "/dev/ttys006", processes: ["claude"], text: pane(["❯ hola", "", "⏺ Hola.", "", "❯ [Image #1]mira esta captura"]))
        XCTAssertNil(screenOnly.pendingMessage)
    }
}
