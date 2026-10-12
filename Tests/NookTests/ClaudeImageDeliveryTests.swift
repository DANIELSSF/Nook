import XCTest
@testable import Nook

/// Messages with images, as Sample sent them on 8/10 (deliveries.log 9:22:47, 9:23:28): Claude Code 2.1.293 attaches the images of a
/// pasted message ("[Image #1]" in its box, the path gone) and drops the Return that came with the paste, so the message waits in
/// its box. Nook used to read that changed box as "taken" and said "enviado"; a typed path stayed a plain path.
final class ClaudeImageDeliveryTests: XCTestCase {
    private static let rule = String(repeating: "─", count: 120)
    private let fast = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1, images: 5)

    /// Sample's words of 9:22:47, as Claude's record keeps them, and the screenshot Nook attached.
    static let words = "cuando ponga claude2 que se vea asi como la terminal, ademas la logica hasla ocn un sub agente en opus 5.5 en xhigh y la ui con sonnet en 5.5 al max, osea no que se vea igual pero si mas bonito porqque no se ve bien se ve como si hubiera puesto el comando de claude y lo haya ignoraod la interfaz"
    static let shot = MessageAttachments.folder + "pantalla-20261008-092246.png"
    static var message: String { MessageAttachments.message(text: words, files: [shot]) }
    /// Claude's box after the paste, as the 9:23:26 screenshot shows it: the image in front, the path gone, wrapped at 120 columns.
    static let pastedBox = ["[Image #1]cuando ponga claude2 que se vea asi como la terminal, ademas la logica hasla ocn un sub agente en opus 5.5",
                            "en xhigh y la ui con sonnet en 5.5 al max, osea no que se vea igual pero si mas bonito porqque no se ve bien se ve",
                            "como si hubiera puesto el comando de claude y lo haya ignoraod la interfaz"]

    /// Claude Code in Sample's Terminal tab (120 columns), driven by what Nook sends. A paste with images shows nothing in the box
    /// while Claude reads them (`reading` readings; its hint under the box changes meanwhile), then `pasted`; the paste's own Return
    /// is dropped unless `takesReturn`. An Enter sends whatever the box holds: its echo goes to the chat and Claude starts working.
    final class FakeClaude {
        var chat: [String] = []
        var box: [String]
        var footer = "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        var status: String?
        var reading = 3
        var pasted: [String]
        var takesReturn = false
        /// Nothing ever shows (another program had the keys).
        var deaf = false
        private(set) var actions: [String] = []
        private var pastes = 0

        init(box: [String] = ["Try \"write a test for <filepath>\""], pasted: [String]) { self.box = box; self.pasted = pasted }

        var enters: Int { actions.filter { $0 == TerminalAppBridge.returnAction }.count }

        func run(_ action: String) {
            actions.append(action)
            if action == TerminalAppBridge.returnAction { submit() } else { pastes += 1 }
        }

        func read() -> String {
            if pastes > 0, !deaf {
                if reading > 0 {
                    reading -= 1
                    // Claude is reading the images: its box is as it was, its hint under it isn't.
                    footer = "  ⏵⏵ auto mode on (shift+tab to cycle)"
                } else if pastes > 0 {
                    pastes = 0
                    box = pasted
                    if takesReturn { submit() }
                }
            }
            return screen
        }

        private func submit() {
            guard !box.joined().isEmpty, !box.joined().hasPrefix("Try \"") else { return }
            chat += ["", "❯ " + box[0]] + box.dropFirst().map { "  " + $0 }
            box = [""]
            status = "✻ Churning… (2s · esc to interrupt)"
        }

        var screen: String {
            let banner = [" ▐▛███▛█   Claude Code v2.1.293", "▝▜██████▀  Opus 5.5 with xhigh effort · Claude Team", " ▝▝   ▝▝   ~/Documents/Examples/New project"]
            let input = ["❯ " + box[0]] + box.dropFirst().map { "  " + $0 }
            return (banner + chat + [""] + (status.map { [$0, ""] } ?? []) + [String(repeating: " ", count: 82) + "✔ Update installed · Restart to update", rule]
                    + input + [rule, footer]).joined(separator: "\n")
        }
    }

    // MARK: Deliveries

    /// 8/10 9:22:47 replayed: the paste showed as "[Image #1]…" with Claude's grey suggestion gone, its Return dropped. Nook now
    /// waits for the box to hold the message in that form, presses Enter itself, and says "enviado" only once the box empties.
    func testSamplesMessageWithAScreenshotIsSentByNooksOwnEnter() throws {
        XCTAssertEqual(Self.message.utf8.count, 346 - 3 + String(getuid()).count, "The message of the log (Sample's user is 501).")
        let claude = FakeClaude(pasted: Self.pastedBox)
        var steps: [String] = []
        try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(claude.actions, [TerminalAppBridge.messageAction(Self.message, agent: .claude), TerminalAppBridge.returnAction],
                       "One paste, then one Enter of Nook's once the box held it.")
        XCTAssertTrue(claude.actions[0].contains("(character id 27) & \"[200~\""), "Pasted, so Claude attaches the image.")
        XCTAssertEqual(steps.first, "caja antes: «Try \"write a test for <filepath>\"»")
        XCTAssertEqual(steps[1], "pegado entre marcas con su Enter (346 bytes, 1 imagen)")
        XCTAssertFalse(steps.contains("Claude lo tomó: enviado"), "A changed screen while Claude read the image is not an arrival.")
        XCTAssertTrue(steps.contains { $0.hasPrefix("en la caja «[Image #1]cuando ponga") })
        XCTAssertEqual(steps.last, "caja vacía: enviado")
        XCTAssertTrue(claude.chat.contains { $0.hasPrefix("❯ [Image #1]cuando ponga") }, "Claude got it, image and words.")
    }

    /// The shorter messages of 9:23:28 went typed, and a typed path stays a path: one that ends with images is pasted now.
    func testAShortMessageEndingWithAnImageIsPastedNotTyped() {
        let short = MessageAttachments.message(text: "tambein pasa que cuando envio una imegn o algo mira el texto se quedo ahi en el input cuando en nook ya lo envie",
                                               files: [MessageAttachments.folder + "pantalla-20261008-092326.png"])
        XCTAssertLessThan(short.utf8.count, TerminalAppBridge.typedLimit, "Short enough to be typed before.")
        XCTAssertFalse(TerminalAppBridge.typesDirectly(short, agent: .claude))
        XCTAssertTrue(TerminalAppBridge.messageAction(short, agent: .claude).contains("[200~"))
        XCTAssertEqual(TerminalAppBridge.messageAction(short, agent: .codex), TerminalAppBridge.typeAction(short), "Codex keeps its way.")
        XCTAssertEqual(TerminalAppBridge.messageAction("revisa /tmp/a.png y dime"), TerminalAppBridge.typeAction("revisa /tmp/a.png y dime"))
        XCTAssertTrue(TerminalAppBridge.typesDirectly("revisa /tmp/a.png y dime", agent: .claude), "A path inside the words is no attachment.")
        XCTAssertTrue(TerminalAppBridge.typesDirectly("borra /Users/d/Desktop/vieja.png", agent: .claude), "A path the user typed or dropped stays text.")
        XCTAssertTrue(TerminalAppBridge.typesDirectly("hola", agent: .claude))
    }

    func testAnImageAloneIsSentAndRecognisedByItsPlaceholder() throws {
        let image = MessageAttachments.folder + "imagen-08102026092924.png"
        // Claude counts the session's images: this one is its third.
        let claude = FakeClaude(box: [""], pasted: ["[Image #3]"])
        var steps: [String] = []
        try TerminalAppBridge.deliver(image, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(claude.actions, [TerminalAppBridge.messageAction(image, agent: .claude), TerminalAppBridge.returnAction])
        XCTAssertEqual(steps.last, "caja vacía: enviado")
        XCTAssertTrue(MessageEcho.boxHolds("[Image #3]", image))
        XCTAssertFalse(MessageEcho.same("[Image #3]", image), "A placeholder alone doesn't say which image: never \"already in the box\".")
        XCTAssertNil(MessageEcho.joined(image, in: [Self.rule, "❯ [Image #3]", Self.rule].joined(separator: "\n")), "Its own image is no earlier text.")
        XCTAssertNotNil(MessageEcho.joined(image, in: [Self.rule, "❯ hola[Image #3]", Self.rule].joined(separator: "\n")))
        XCTAssertEqual(MessageEcho.echoKey(image), "[Image#")
        XCTAssertTrue(MessageEcho.appears(image, in: "> [Imagen]\n\n"), "Claude's record shows an image alone as [Imagen].")
    }

    /// An "[Image #2]" left in Claude's box (pasted there by hand, never sent) is not Nook's new image: Nook waits for the box to
    /// change, and then finds an image it didn't bring in front of its own.
    func testAnImageLeftInTheBoxIsNotTakenForTheNewOne() {
        let image = MessageAttachments.folder + "imagen-08102026092924.png"
        let claude = FakeClaude(box: ["[Image #2]"], pasted: ["[Image #2][Image #3]"])
        claude.reading = 20
        var steps: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver(image, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })) { error in
            guard case DeliveryError.joined = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(steps.contains("ya estaba en la caja: Enter"))
        XCTAssertEqual(claude.enters, 0, "The old image is never sent in place of the new one.")
    }

    func testTwoImagesAndTheirWords() throws {
        let files = [MessageAttachments.folder + "imagen-1.png", MessageAttachments.folder + "pantalla-2.png"]
        let message = MessageAttachments.message(text: "compara estas dos", files: files)
        XCTAssertEqual(ClaudeImagePaste.parts(message).images, files)
        let claude = FakeClaude(box: [""], pasted: ["[Image #4][Image #5]compara estas dos"])
        try TerminalAppBridge.deliver(message, agent: .claude, timing: fast, run: claude.run, read: claude.read)
        XCTAssertEqual(claude.enters, 1)
        XCTAssertTrue(claude.chat.contains("❯ [Image #4][Image #5]compara estas dos"))
        XCTAssertTrue(MessageEcho.partial("[Image #4]", of: message), "Images in, words not yet: not taken, not held.")
        XCTAssertTrue(MessageEcho.partial("[Image #4]compara", of: message))
        XCTAssertFalse(MessageEcho.partial("[Image #4][Image #5]compara estas dos", of: message))
        XCTAssertTrue(MessageEcho.same("compara estas dos [Image #4] [Image #5]", message), "Wherever Claude puts them.")
        XCTAssertFalse(MessageEcho.same("[Image #4]compara estas dos", message), "Exactly as many images.")
    }

    /// Terminal may hand a long paste over in pieces: its Return then reaches Claude after the images were read, and Claude sends
    /// the message itself. Its echo says so; Nook adds nothing.
    func testAnImageMessageClaudeTakesOnTheFirstReturnGetsNoEnter() throws {
        let claude = FakeClaude(pasted: Self.pastedBox)
        claude.takesReturn = true
        var steps: [String] = []
        try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })
        XCTAssertEqual(claude.actions, [TerminalAppBridge.messageAction(Self.message, agent: .claude)])
        XCTAssertEqual(steps.last, "Claude lo tomó: enviado")
    }

    func testAnImageMessageThatNeverShowsIsNotReportedSent() {
        let claude = FakeClaude(pasted: Self.pastedBox)
        claude.deaf = true
        var steps: [String] = []
        let quiet = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1, images: 0.3)
        XCTAssertThrowsError(try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: quiet, run: claude.run, read: claude.read, trace: { steps.append($0) })) { error in
            guard case DeliveryError.unseen = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(claude.enters, 0, "No Enter on a guess.")
        XCTAssertEqual(steps.last, "no apareció en la caja en 0 s; sin Enter, no enviado")
    }

    /// While Claude reads the images its spinner may go on (a turn under way) and its hint changes: none of it is an arrival.
    func testAChangingScreenBeforeThePasteShowsIsNotTaken() {
        var reads = 0
        let before = FakeClaude(box: [""], pasted: [""]).screen
        let arrival = TerminalAppBridge.arrival(of: Self.message, before: before, timing: fast, pasted: true, read: {
            reads += 1
            let claude = FakeClaude(box: reads < 20 ? [""] : Self.pastedBox, pasted: [])
            claude.status = "✻ Churning… (\(reads)s · esc to interrupt)"
            return claude.screen
        })
        XCTAssertEqual(arrival, .waiting)
        XCTAssertGreaterThanOrEqual(reads, 20)
    }

    func testTheBoxStillReadingItsImagesNeverGetsEnterTwice() throws {
        // The images take a while; Nook's Enter goes once, after the box held the whole message for `hold`.
        let claude = FakeClaude(pasted: Self.pastedBox)
        claude.reading = 40
        try TerminalAppBridge.deliver(Self.message, agent: .claude, timing: fast, run: claude.run, read: claude.read)
        XCTAssertEqual(claude.enters, 1)
        XCTAssertEqual(claude.actions.filter { $0 != TerminalAppBridge.returnAction }.count, 1, "Never pasted twice.")
    }

    /// 9:23:28 with today's paste: the first message (never sent) still sat in Claude's box. The second lands behind it: earlier text
    /// in front, so no Enter, and the field gets it back.
    func testEarlierTextInFrontOfAnImageMessageIsJoined() {
        let second = MessageAttachments.message(text: "tambein pasa que cuando envio una imegn o algo mira el texto se quedo ahi en el input cuando en nook ya lo envie",
                                                files: [MessageAttachments.folder + "pantalla-20261008-092326.png"])
        let claude = FakeClaude(box: Self.pastedBox, pasted: Self.pastedBox.dropLast() + [Self.pastedBox.last! + "[Image #2]tambein pasa que cuando envio una imegn o",
                                                                                         "algo mira el texto se quedo ahi en el input cuando en nook ya lo envie"])
        var steps: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver(second, agent: .claude, timing: fast, run: claude.run, read: claude.read, trace: { steps.append($0) })) { error in
            guard case DeliveryError.joined(let box) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(box.hasPrefix("[Image #1]cuando ponga"))
        }
        XCTAssertEqual(claude.enters, 0)
        XCTAssertEqual(steps.last, "unido a texto previo; sin Enter")
    }

    // MARK: Comparisons

    func testClaudesImageFormOfAMessage() {
        let message = Self.message, box = Self.pastedBox.joined(separator: "\n")
        XCTAssertTrue(MessageEcho.boxHolds(box, message))
        XCTAssertTrue(MessageEcho.same(box, message))
        XCTAssertFalse(MessageEcho.partial(box, of: message))
        XCTAssertTrue(MessageEcho.boxHolds(Self.words + " " + Self.shot, message), "The path left as text (Claude could not read it) holds it too.")
        XCTAssertFalse(MessageEcho.boxHolds("Try \"write a test for <filepath>\"", message))
        XCTAssertFalse(MessageEcho.boxHolds("[Image #1]otra cosa", message))
        XCTAssertTrue(MessageEcho.partial("[Image #1]", of: message))
        // Its own image is no earlier text; words or another image in front are.
        let screen = { (input: String) in [Self.rule, "❯ " + input, Self.rule].joined(separator: "\n") }
        XCTAssertNil(MessageEcho.joined(message, in: screen(box)))
        XCTAssertNil(MessageEcho.joined(message, in: screen(Self.words + "[Image #1]")), "After the words, as Claude may put it.")
        XCTAssertNotNil(MessageEcho.joined(message, in: screen("hola " + box)))
        XCTAssertNotNil(MessageEcho.joined(message, in: screen("[Image #1][Image #2]" + Self.words)), "An image the message didn't bring.")
        // Its echo in the chat, and in Claude's record (the words behind the placeholder, then the image).
        XCTAssertEqual(MessageEcho.echoes(of: message, inChatOf: screen("")), 0)
        XCTAssertEqual(MessageEcho.echoes(of: message, inChatOf: "❯ " + box + "\n" + screen("")), 1)
        XCTAssertTrue(MessageEcho.appears(message, in: "> [Image #1]" + Self.words + "\n\n> [Imagen]\n\n"))
        XCTAssertFalse(MessageEcho.appears(message, in: "> [Imagen]\n\n"))
        // A message without images is compared as before.
        XCTAssertEqual(MessageEcho.echoKey("hola gato"), MessageEcho.key("hola gato"))
        XCTAssertFalse(MessageEcho.same("[Image #1]hola", "hola"))
    }

    func testClaudesWayOfCuttingAPaste() {
        XCTAssertEqual(ClaudeImagePaste.parts("mira /tmp/a.png").images, ["/tmp/a.png"])
        XCTAssertEqual(ClaudeImagePaste.parts("mira /tmp/a.png").words, "mira")
        XCTAssertEqual(ClaudeImagePaste.parts("mira /tmp/a.PNG /tmp/b.jpeg").images, ["/tmp/a.PNG", "/tmp/b.jpeg"])
        XCTAssertEqual(ClaudeImagePaste.parts("dos\n/tmp/c.webp\nlíneas").words, "dos\nlíneas")
        XCTAssertEqual(ClaudeImagePaste.parts("'/Users/d/Captura de pantalla.png'").images, ["/Users/d/Captura de pantalla.png"])
        XCTAssertEqual(ClaudeImagePaste.parts("/Users/d/Captura\\ de\\ pantalla.png").images, ["/Users/d/Captura de pantalla.png"])
        XCTAssertTrue(ClaudeImagePaste.parts("revisa /tmp/a.png y dime").images.isEmpty, "A piece runs to the next \" /\": this one ends in words.")
        XCTAssertTrue(ClaudeImagePaste.parts("abre Notch.swift").images.isEmpty)
        XCTAssertTrue(ClaudeImagePaste.parts("renombra el icono a logo.png").images.isEmpty, "Claude can open an absolute path only: this one stays text.")
        let folder = MessageAttachments.folder
        XCTAssertTrue(MessageAttachments.endsWithAttachments("hola " + folder + "a.png"))
        XCTAssertTrue(MessageAttachments.endsWithAttachments(folder + "a.png"))
        XCTAssertFalse(MessageAttachments.endsWithAttachments(folder + "a.png y dime"))
        XCTAssertFalse(MessageAttachments.endsWithAttachments("hola /Users/d/a.png"), "Not one of Nook's attachments.")
        XCTAssertEqual(ClaudeImagePaste.placeholders(in: "[Image #4][Image #5]compara"), 2)
        XCTAssertEqual(ClaudeImagePaste.withoutPlaceholders("[Image #4] compara [Image #5]"), " compara ")
    }

    /// A message on its way or from the history, apart again: its words and the attached images, so they can show as pictures.
    func testAMessageComesApartIntoItsWordsAndAttachments() {
        let files = [MessageAttachments.folder + "imagen-1.png", MessageAttachments.folder + "pantalla-2.png"]
        XCTAssertEqual(MessageAttachments.parts(of: MessageAttachments.message(text: "mira\ncon dos líneas", files: files)).text, "mira\ncon dos líneas")
        XCTAssertEqual(MessageAttachments.parts(of: MessageAttachments.message(text: "mira", files: files)).files, files)
        XCTAssertEqual(MessageAttachments.parts(of: MessageAttachments.message(text: "", files: files)).files, files)
        XCTAssertEqual(MessageAttachments.parts(of: MessageAttachments.message(text: "", files: files)).text, "")
        XCTAssertEqual(MessageAttachments.parts(of: "revisa /tmp/a.png y dime").files, [], "Words that name a path keep it.")
        XCTAssertEqual(MessageAttachments.parts(of: "hola").text, "hola")
    }

    // MARK: Nook's own sessions

    private func claudeSession() -> TerminalSession {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-images-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-images-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        session.applyPane(tty: "/dev/ttys007", processes: ["claude"], text: FakeClaude(pasted: []).screen)
        session.paneJournal = { _ in }
        return session
    }

    /// A Nook session pasted and pressed Return 0.35 s later, whatever Claude did: with images the Return was lost while Claude read
    /// them. It now goes through the same checks as a Terminal tab, pasted by tmux (no Return of its own).
    func testANookSessionSendsAnImageMessageWithTheSameChecks() {
        let session = claudeSession(), claude = FakeClaude(pasted: Self.pastedBox)
        var steps: [TerminalAppBridge.DeliveryStep] = []
        session.paneSend = { step, text in
            steps.append(step)
            XCTAssertEqual(text, Self.message)
            claude.run(step == .enter ? TerminalAppBridge.returnAction : "paste")
        }
        session.paneScreen = { claude.read() }
        session.paneTiming = fast
        let done = expectation(description: "sent")
        session.send(Self.message) { success in
            XCTAssertTrue(success)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(steps, [.message, .enter])
        XCTAssertFalse(session.sending)
        XCTAssertTrue(claude.chat.contains { $0.hasPrefix("❯ [Image #1]cuando ponga") })
    }

    func testANookSessionGivesTheMessageBackWhenEarlierTextSitsInFront() {
        let session = claudeSession(), claude = FakeClaude(box: ["hola"], pasted: ["hola[Image #1]mira"])
        session.paneSend = { step, _ in claude.run(step == .enter ? TerminalAppBridge.returnAction : "paste") }
        session.paneScreen = { claude.read() }
        session.paneTiming = fast
        let done = expectation(description: "given back")
        session.send(MessageAttachments.message(text: "mira", files: [MessageAttachments.folder + "imagen-1.png"])) { success in
            XCTAssertFalse(success)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(claude.enters, 0)
        XCTAssertEqual(session.joinedBox, "hola[Image #1]mira", "The warning shows what sits in the box; it is never pasted again.")
    }

    /// tmux's own paste brackets the text when the program asked for it (Claude does) and keeps its line breaks; Enter is a key of its own.
    func testTmuxPastesBetweenBracketedPasteMarks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tmux = root.appendingPathComponent("Vendor/bin/tmux").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tmux), "No tmux to try it with.")
        let backend = TmuxBackend(executable: tmux, socket: "/tmp/nook-paste-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "paste", name: "paste", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        defer { _ = try? Shell.run(tmux, backend.arguments() + ["kill-server"]); try? FileManager.default.removeItem(atPath: backend.socket) }
        // A program that asks for bracketed paste and shows every byte it gets.
        XCTAssertEqual(try Shell.run(tmux, backend.arguments() + ["new-session", "-d", "-s", "paste", "-x", "120", "-y", "10",
                                                                  "printf '\\033[?2004h'; stty raw -echo; cat -v"]).0, 0)
        Thread.sleep(forTimeInterval: 0.5)
        // Its control characters never travel (an Escape would end the paste, ^U wipe Claude's box); the text goes on stdin.
        try backend.paste("hola\u{1b}\u{15} /tmp/nook-501/images/imagen-1.png", into: record)
        try backend.press("Enter", in: record)
        var shown = ""
        let deadline = Date().addingTimeInterval(3)
        repeat { Thread.sleep(forTimeInterval: 0.05); shown = backend.screen(record) ?? "" } while !shown.contains("^M") && Date() < deadline
        XCTAssertTrue(shown.contains("^[[200~hola /tmp/nook-501/images/imagen-1.png^[[201~^M"), shown)
        // A paste that fails leaves no buffer behind; one that worked neither.
        let elsewhere = SessionRecord(id: "no-such-session", name: "x", kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true)
        XCTAssertThrowsError(try backend.paste("secreto", into: elsewhere))
        XCTAssertEqual(try Shell.run(tmux, backend.arguments() + ["list-buffers"]).1, "")
    }
}

/// The security review of the delivery (8/10): what the log and the user get back, control characters, clipboard images on disk.
final class DeliverySafetyTests: XCTestCase {
    private let fast = TerminalAppBridge.DeliveryTiming(poll: 0.01, echo: 5, hold: 0.05, settle: 0.1, images: 5)
    private struct Broken: Error {}

    /// A failure after the message went, with no box on screen (a dialog's field had it): the user gets the message back, never the
    /// log's description of the screen ("— sin caja; pantalla: …"), which would show as their message and could be sent to Claude.
    func testWithoutABoxTheMessageItselfComesBack() {
        let question = ["⏺ Antes de empezar necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                        "  1. PostgreSQL", "     Relational, strong consistency", "  2. SQLite", "     Embedded, zero config",
                        "❯ 3. Type something.", String(repeating: "─", count: 40), "  4. Chat about this", "",
                        "Enter to select · ↑/↓ to navigate · Esc to cancel"]
        let answer = "Usa MongoDB con réplica"
        var actions: [String] = [], steps: [String] = []
        XCTAssertThrowsError(try TerminalAppBridge.deliver(answer, agent: .claude, timing: fast, run: { action in
            actions.append(action)
            if action == TerminalAppBridge.returnAction { throw Broken() }
        }, read: {
            (actions.isEmpty ? question : question.map { $0 == "❯ 3. Type something." ? "❯ 3. " + answer : $0 }).joined(separator: "\n")
        }, trace: { steps.append($0) })) { error in
            guard case DeliveryError.joined(let given) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(given, answer)
        }
        XCTAssertTrue(steps.contains { $0.hasPrefix("caja antes: «— sin caja; pantalla: ") }, "The log still says why.")

        // Codex has no box Nook reads either.
        XCTAssertThrowsError(try TerminalAppBridge.deliver("hola", agent: .codex, timing: fast, run: { if $0 == TerminalAppBridge.returnAction { throw Broken() } },
                                                           read: { "› hola" })) { error in
            guard case DeliveryError.joined(let given) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(given, "hola")
        }
    }

    /// The log keeps what explains a delivery, about 100 characters of a box or a screen, as its header keeps 60 of the message.
    func testTheLogKeepsAnExcerptOfTheBoxAndScreen() throws {
        let long = String(repeating: "palabra ", count: 60) + "fin"
        let excerpt = TerminalAppBridge.excerpt(long)
        XCTAssertLessThanOrEqual(excerpt.count, TerminalAppBridge.excerptLimit)
        XCTAssertTrue(excerpt.hasPrefix("palabra palabra") && excerpt.hasSuffix("fin") && excerpt.contains(" … "))
        XCTAssertEqual(TerminalAppBridge.excerpt("corto"), "corto")
        let rule = String(repeating: "─", count: 100)
        var steps: [String] = [], actions: [String] = []
        let screen = { (box: String) in ["⏺ Hola", rule, "❯ " + box, rule].joined(separator: "\n") }
        try TerminalAppBridge.deliver("hola gato", agent: .claude, timing: fast, run: { actions.append($0) }, read: {
            // A long grey suggestion, replaced by the message, which Enter sends.
            actions.isEmpty ? screen(long) : actions.count == 1 ? screen("hola gato") : screen("")
        }, trace: { steps.append($0) })
        let before = try XCTUnwrap(steps.first)
        XCTAssertLessThanOrEqual(before.count, "caja antes: «»".count + TerminalAppBridge.excerptLimit)
        let noBox = String(repeating: "x", count: 500)
        XCTAssertThrowsError(try TerminalAppBridge.deliver("hola", agent: .codex, timing: fast, run: { if $0 == TerminalAppBridge.returnAction { throw Broken() } },
                                                           read: { noBox }, trace: { steps.append($0) }))
        XCTAssertTrue(steps.allSatisfy { $0.count < 200 }, steps.joined(separator: "\n"))
    }

    /// Control characters act on the agent instead of being read: they never travel, typed or pasted, to a tab or a Nook session.
    func testControlCharactersNeverTravel() {
        XCTAssertEqual(TerminalText.sendable("a\u{03}b\u{04}c\u{15}d\u{17}e\u{7F}f\u{1b}[201~g\u{9B}h\u{00}"), "abcdef[201~gh")
        XCTAssertEqual(TerminalText.sendable("uno\tdos\ntres\r\ncuatro ñ 😀"), "uno\tdos\ntres\r\ncuatro ñ 😀", "Tabs, line breaks and text stay.")
        XCTAssertEqual(TerminalAppBridge.messageAction("hola\u{15} gato"), TerminalAppBridge.typeAction("hola gato"), "Typed.")
        XCTAssertFalse(TerminalAppBridge.messageAction(String(repeating: "x", count: 250) + "\u{03}\u{17}").contains("\u{03}"), "Pasted.")
        XCTAssertFalse(TerminalAppBridge.messageAction(String(repeating: "x", count: 250) + "\u{03}\u{17}").contains("\u{17}"))
        // Delivered: what reaches the box is compared with the message as it went.
        var actions: [String] = []
        let rule = String(repeating: "─", count: 100)
        XCTAssertNoThrow(try TerminalAppBridge.deliver("hola\u{15} gato", agent: .claude, timing: fast, run: { actions.append($0) }, read: {
            [rule, actions.isEmpty ? "❯ " : actions.count == 1 ? "❯ hola gato" : "❯ ", rule].joined(separator: "\n")
        }))
        XCTAssertEqual(actions, [TerminalAppBridge.typeAction("hola gato"), TerminalAppBridge.returnAction])
    }

    func testANookSessionSendsNoControlCharacters() {
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-controls-\(getpid()).sock", configuration: "/dev/null")
        let record = SessionRecord(id: "nook-controls-" + UUID().uuidString.prefix(6), name: "Claude Code", kind: .claude, directory: NSTemporaryDirectory(),
                                   socket: backend.socket, ownsSession: true)
        let session = TerminalSession(record: record, backend: backend, create: false)
        let claude = ClaudeImageDeliveryTests.FakeClaude(pasted: ["[Image #1]mira"])
        session.applyPane(tty: "/dev/ttys007", processes: ["claude"], text: claude.screen)
        session.paneJournal = { _ in }
        session.paneTiming = fast
        var sent: [String] = []
        session.paneSend = { step, text in sent.append(text); claude.run(step == .enter ? TerminalAppBridge.returnAction : "paste") }
        session.paneScreen = { claude.read() }
        let done = expectation(description: "sent")
        session.send("mira\u{03}\u{1b} " + MessageAttachments.folder + "imagen-1.png") { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(Set(sent), ["mira " + MessageAttachments.folder + "imagen-1.png"])
    }

    // MARK: Clipboard images on disk

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-clip-" + UUID().uuidString.prefix(8))
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try ScreenShotFile.prepare(folder)
        return folder
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("nook-clip-test-" + UUID().uuidString))
        addTeardownBlock { board.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.systemMint.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.clearContents(); board.writeObjects([image])
        return board
    }

    /// Like screen vision's pictures: the user's alone, a new file each time (two in the same second don't overwrite each other), a
    /// name that doesn't depend on the locale or a 12-hour clock.
    func testAClipboardImageIsWrittenPrivatelyAndNeverOverAnother() throws {
        let folder = try folder(), board = pasteboard()
        let now = Date(timeIntervalSince1970: 1_791_465_000)
        let first = try XCTUnwrap(AppModel.saveImage(from: board, folder: folder, now: now))
        let second = try XCTUnwrap(AppModel.saveImage(from: board, folder: folder, now: now))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual((first as NSString).lastPathComponent, "imagen-" + ScreenShotFile.stamp(now) + ".png")
        for path in [first, second] {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
            XCTAssertEqual(mode & 0o777, 0o600, path)
        }
        XCTAssertNotNil(NSImage(contentsOfFile: first))
    }

    /// Clipboard images go after a day, like screen vision's, except one still attached to a message; nothing else is touched.
    func testOldClipboardImagesArePrunedButNotOnesStillAttached() throws {
        let folder = try folder(), manager = FileManager.default
        let now = Date()
        func file(_ name: String, age: TimeInterval) -> String {
            let path = folder.appendingPathComponent(name).path
            manager.createFile(atPath: path, contents: Data("x".utf8))
            try? manager.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
            return path
        }
        let day: TimeInterval = 24 * 60 * 60
        let old = file("imagen-20261005-080523.png", age: 3 * day), attached = file("imagen-20261006-130504.png", age: 2 * day)
        let fresh = file("imagen-20261008-092924.png", age: 60), screen = file("pantalla-20261005-080000.png", age: 3 * day)
        let other = file("notas.txt", age: 3 * day)
        // As the app passes it: the paths attached to the tabs' messages, written the way `/tmp` paths are.
        MessageAttachments.prune(folder, now: now, keeping: [attached])
        XCTAssertFalse(manager.fileExists(atPath: old))
        for kept in [attached, fresh, screen, other] { XCTAssertTrue(manager.fileExists(atPath: kept), kept) }

        // Through `saveImage`: the new picture and the attached one stay, the old one goes.
        let another = file("imagen-20261004-100000.png", age: 4 * day)
        let saved = try XCTUnwrap(AppModel.saveImage(from: pasteboard(), folder: folder, now: now, keeping: [attached]))
        XCTAssertFalse(manager.fileExists(atPath: another))
        XCTAssertTrue(manager.fileExists(atPath: saved) && manager.fileExists(atPath: attached))
    }

    @MainActor func testTheAttachedPathsAreEveryTabsAttachments() {
        let store = MessageAttachments.shared, tabs = ["prune-a-" + UUID().uuidString, "prune-b-" + UUID().uuidString]
        defer { tabs.forEach { store.set([], for: $0) } }
        store.set(["/tmp/a.png"], for: tabs[0]); store.set(["/tmp/b.png", "/tmp/c.png"], for: tabs[1])
        XCTAssertTrue(store.attachedPaths.isSuperset(of: ["/tmp/a.png", "/tmp/b.png", "/tmp/c.png"]))
    }
}
