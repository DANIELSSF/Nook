import AppKit
import SystemConfiguration

// Nook Remote's picture of the model: what `GET /api/state` and the `state` event carry (docs/REMOTE_API.md, "Reading"). It is
// taken on the main thread, where the model lives, as plain values (`RemoteFrame`); writing it out as JSON, and comparing it with
// the last one sent, happens on the remote's own queue.
//
//   RemoteJSON     a JSON value written by hand: keys in the contract's order, `null` written out, no line breaks (an SSE event
//                  is one line of data)
//   RemoteFrame    one picture of the model: the State without its conversation epoch, and what the conversation needs
//   RemoteSnapshot builds it from AppModel, field by field as the contract names them
//   SentShot       a screenshot that went with a message from one of Nook's composers, kept so the phone can show it

// MARK: - JSON

/// A JSON value. Objects keep their keys in the order given, and a missing value is written as `null`, as the contract's shapes
/// show them (JavaScript tells `null` from a missing key). Nothing it writes holds a line break: a string's are escaped.
indirect enum RemoteJSON: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([RemoteJSON])
    case object([(String, RemoteJSON)])
    /// JSON already written (a page of lines serialised once and sent to several clients).
    case raw([UInt8])

    static func == (lhs: RemoteJSON, rhs: RemoteJSON) -> Bool { lhs.bytes == rhs.bytes }

    static func string(_ value: String?) -> RemoteJSON { value.map(RemoteJSON.string) ?? .null }
    static func int(_ value: Int?) -> RemoteJSON { value.map(RemoteJSON.int) ?? .null }

    /// A UTF-16 range of a line as `[from, to]`, the end excluded.
    static func range(_ range: NSRange?, in line: NSRange) -> RemoteJSON {
        guard let range, range.location != NSNotFound else { return .null }
        let from = max(0, range.location - line.location)
        return .array([.int(from), .int(from + range.length)])
    }

    var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(into: &out)
        return out
    }

    var data: Data { Data(bytes) }
    var text: String { String(decoding: bytes, as: UTF8.self) }

    func write(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let value): out.append(contentsOf: (value ? "true" : "false").utf8)
        case .int(let value): out.append(contentsOf: String(value).utf8)
        case .number(let value): out.append(contentsOf: (value.isFinite ? String(value) : "0").utf8)
        case .string(let value): Self.write(value, into: &out)
        case .raw(let bytes): out.append(contentsOf: bytes)
        case .array(let items):
            out.append(0x5B)
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(0x2C) }
                item.write(into: &out)
            }
            out.append(0x5D)
        case .object(let fields):
            out.append(0x7B)
            for (index, field) in fields.enumerated() {
                if index > 0 { out.append(0x2C) }
                Self.write(field.0, into: &out)
                out.append(0x3A)
                field.1.write(into: &out)
            }
            out.append(0x7D)
        }
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    /// A string, quoted and escaped. Non-ASCII goes as UTF-8, which JSON allows; every control character is escaped, so no line
    /// break ever reaches the output.
    static func write(_ value: String, into out: inout [UInt8]) {
        out.append(0x22)
        for byte in value.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, 0x6E])
            case 0x0D: out.append(contentsOf: [0x5C, 0x72])
            case 0x09: out.append(contentsOf: [0x5C, 0x74])
            case 0..<0x20, 0x7F: out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            default: out.append(byte)
            }
        }
        out.append(0x22)
    }
}

// MARK: - Screenshots that went with messages

/// A screenshot attached to a message from one of Nook's composers (the island's or the phone's, `AppModel.sendMessage`), or an image
/// the phone sent with one (`POST /api/upload`). Claude's
/// record only says "[Image]" where it was, so Nook remembers which picture went with which words; the phone shows them
/// (`detail.shots`) and fetches each one by its exact name (`/api/shot/<name>`).
struct SentShot: Equatable {
    /// The file's name ("pantalla-20261105-083645.png"): the only thing the phone ever names.
    var name: String
    /// Where Nook wrote it (`ScreenShotFile`); never anything the phone sent.
    var path: String
    /// When it was taken (its name's stamp).
    var date: Date
    /// What was written with it, without the attached files' paths.
    var text: String
    /// When Nook noted it, the message having gone: it is kept a day from then, as its file is (`ScreenShotFile.keep`).
    var noted = Date()

    /// What a name must look like to be served: screen vision's own ("pantalla-20261105-083645.png", "-2" for a second display or a
    /// name already taken), or an image the phone sent ("imagen-movil-20261105-093012-k3f9a2.jpg"); no folder, no other characters.
    static func isShotName(_ name: String) -> Bool {
        name.range(of: #"^(pantalla-[0-9]{8}-[0-9]{6}(-[0-9]{1,3}){0,2}\.(png|jpg)|imagen-movil-[0-9]{8}-[0-9]{6}-[a-z0-9]{6}(-[0-9]{1,3})?\.(jpg|png|gif|webp))$"#,
                   options: .regularExpression) != nil
    }

    /// How many each tab keeps, newest last; older ones go (their files go after a day anyway, `ScreenShotFile.prune`).
    static let perTab = 40
}

// MARK: - The picture

/// One picture of the model for the phone: the `State` of the contract except the selected tab's `conversationEpoch` (the
/// conversation's tracker knows it, on the remote's queue), and what the conversation needs to follow the selected tab.
struct RemoteFrame {
    /// `v`, `mac`, `screen`, `selected`, `tabs`.
    var head: [(String, RemoteJSON)]
    /// The selected tab's `TabDetail`, without `conversationEpoch`; nil without tabs.
    var detail: [(String, RemoteJSON)]?
    var notice: String?
    /// The text the island shows for the selected tab.
    var conversation: RemoteConversationSource?

    /// The whole `State`, with the epoch the conversation is at.
    func state(epoch: Int) -> RemoteJSON {
        var fields = head
        fields.append(("detail", detail.map { .object($0 + [("conversationEpoch", .int(epoch))]) } ?? .null))
        fields.append(("notice", .string(notice)))
        return .object(fields)
    }
}

/// What the conversation of the selected tab is made of: the island's text for it (`TerminalSession.displayText`), and how the
/// island shows it.
struct RemoteConversationSource {
    var tab: String
    var text: String
    /// Claude's transcript: lines are classified and dressed. Otherwise plain terminal text.
    var transcript: Bool
    /// The subagent whose own conversation is on show; "" for the tab's own.
    var view: String
    /// A question's card stands over the end of the text: its lines are left out, as the island leaves them out
    /// (`AgentPrompt.withoutPrompt`, done on the remote's queue).
    var stripPrompt: Bool

    /// Changes when the text shown is another one, not a newer version of the same: another tab, an agent's conversation, or
    /// another way of drawing it.
    var key: String { tab + "\u{1F}" + view + "\u{1F}" + (transcript ? "t" : "p") }
}

enum RemoteSnapshot {
    /// The picture of `model` now. Main thread only.
    static func frame(of model: AppModel, screenAvailable: Bool, macName: String) -> RemoteFrame {
        let selected = model.selected
        var head: [(String, RemoteJSON)] = [("v", .int(1)), ("mac", .string(macName))]
        // `attach` is whether the screen goes with a message: the eye, while screen vision is on (`ScreenVision.attaches`'s own rule).
        head.append(("screen", .object([("available", .bool(screenAvailable)), ("attach", .bool(model.screenVision.attachesToMessages))])))
        head.append(("selected", .string(selected?.id)))
        head.append(("tabs", .array(model.sessions.map(tab))))
        var frame = RemoteFrame(head: head, detail: nil, notice: model.notice, conversation: nil)
        if let selected {
            frame.detail = detail(selected, in: model)
            frame.conversation = RemoteConversationSource(tab: selected.id, text: selected.displayText, transcript: selected.agent == .claude,
                                                          view: selected.viewedAgent ?? "", stripPrompt: selected.mirrorsAgent && selected.prompt != nil)
        }
        return frame
    }

    // MARK: Tab

    static func tab(_ session: TerminalSession) -> RemoteJSON {
        let summary = SubagentSummary(session.subagents)
        let question = session.mirrorsAgent && session.prompt.map { $0.kind != .selector } == true
        return .object([
            ("id", .string(session.id)),
            ("title", .string(session.displayTitle)),
            ("tint", .string(hex(session.tint.shades.pastel))),
            ("icon", .string(session.icon.rawValue)),
            ("agent", .string(session.agent?.rawValue)),
            ("kind", .string(session.record.kind.rawValue)),
            ("state", .string(state(session.taskState))),
            ("unread", .bool(session.unreadNotice != nil)),
            ("question", .bool(question)),
            ("agents", .object([("running", .int(summary.running)), ("done", .int(summary.done)), ("failed", .int(summary.failed))])),
        ])
    }

    /// "#6fd4b3": the tab's colour as the dark island draws it.
    static func hex(_ color: TabRGB) -> String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(color.red), byte(color.green), byte(color.blue))
    }

    static func state(_ state: TaskState) -> String {
        switch state {
        case .idle: "idle"
        case .working: "working"
        case .finished: "finished"
        case .attention: "attention"
        }
    }

    // MARK: Detail

    /// The selected tab's `TabDetail`, as the island's conversation view shows it, without `conversationEpoch`.
    static func detail(_ session: TerminalSession, in model: AppModel) -> [(String, RemoteJSON)] {
        let prompt = session.mirrorsAgent ? session.prompt : nil
        let claude = session.agent == .claude
        // Claude's panel stands where its box was; a question's card wins over it, as on the island.
        let panel = session.mirrorsAgent && prompt == nil ? session.panel.map(ClaudePanel.init) : nil
        var fields: [(String, RemoteJSON)] = [
            ("id", .string(session.id)),
            ("running", .bool(session.isRunning)),
            ("sending", .bool(session.sending)),
            ("answering", .bool(session.answering)),
            ("status", session.agentStatus.map(status) ?? .null),
        ]
        if claude {
            fields.append(("model", .object([
                ("current", .string(session.currentModel)),
                ("choices", .array(model.availableModels(for: session).map { choice in
                    .object([("id", .string(choice.id)), ("label", .string(choice.label)), ("detail", .string(choice.detail)), ("current", .bool(choice.isCurrent))])
                })),
                ("blocked", .string(model.modelSwitchBlocked(on: session))),
            ])))
        } else {
            fields.append(("model", .null))
        }
        if claude, let mode = session.agentMode {
            let style = ClaudeModeStyle(mode)
            let blocked = ClaudeModeStyle.block(running: session.isRunning, questionOpen: prompt != nil, panelOpen: panel != nil)
            fields.append(("mode", .object([("kind", .string(modeKind(mode))), ("title", .string(style.title)), ("blocked", .string(blocked))])))
        } else {
            fields.append(("mode", .null))
        }
        fields.append(("prompt", prompt.map { self.prompt($0, filled: { session.isFilledField($0, of: $1) }) } ?? .null))
        if prompt != nil, let target = model.fieldAnswer(for: session) {
            fields.append(("field", .object([
                ("signature", .string(target.prompt.signature)), ("option", .int(target.option)),
                ("question", .string(target.prompt.question)), ("title", .string(target.prompt.options[target.option].title)),
            ])))
        } else {
            fields.append(("field", .null))
        }
        fields.append(("panel", panel.map(self.panel) ?? .null))
        fields.append(("subagents", .array(session.subagents.filter { $0.role == .agent }.map(subagent))))
        fields.append(("viewedAgent", .string(session.viewedAgent)))
        fields.append(("pending", .array(pending(of: session).map { .object([("text", .string($0.text)), ("state", .string($0.state))]) })))
        fields.append(("suggestion", .string(session.suggestion)))
        fields.append(("shots", .array(model.sentShots(for: session).map(shot))))
        return fields
    }

    static func status(_ status: ClaudeStatus) -> RemoteJSON {
        .object([("glyph", .string(status.glyph)), ("text", .string(SessionPane.statusText(status.text))), ("working", .bool(status.working)),
                 ("background", .int(status.background))])
    }

    /// The contract's kind: Claude's own name for a mode Nook knows, "default" for its default mode, "other" for a mode Nook
    /// doesn't know by name (its title is Claude's own words).
    static func modeKind(_ mode: ClaudeMode) -> String {
        if mode.isDefault { return "default" }
        return mode.kind?.rawValue ?? "other"
    }

    /// What follows the conversation until Claude's record has it, as the island's `mirrorMessages`: what Claude holds in its queue,
    /// and the message Nook just sent while it isn't queued. Another agent's message on its way shows the same way (the island
    /// writes it into its plain mirror instead). An agent's own conversation has none.
    static func pending(of session: TerminalSession) -> [(text: String, state: String)] {
        guard session.viewedAgent == nil, session.mirrorsAgent else { return [] }
        var messages: [(text: String, state: String)] = []
        if session.agent == .claude { messages = session.claudeQueue.map { (SessionPane.displayedMessage($0), "queued") } }
        if let message = session.pendingMessage, !(session.agent == .claude && session.pendingQueued) {
            messages.append((SessionPane.displayedMessage(message), session.sending ? "sending" : "waiting"))
        }
        return messages
    }

    static func subagent(_ agent: SubagentActivity) -> RemoteJSON {
        .object([
            ("id", .string(agent.id)), ("name", .string(agent.name)), ("kind", .string(agent.kind ?? agent.alias)),
            ("model", .string(agent.model.map { $0.prefix(1).uppercased() + $0.dropFirst() })), ("state", .string(agent.state.rawValue)),
            ("activity", .string(agent.activity)), ("duration", .string(agent.duration)), ("tokens", .string(agent.tokens)),
            ("background", .bool(agent.background)), ("detail", .string(agent.detail)),
        ])
    }

    static func shot(_ shot: SentShot) -> RemoteJSON {
        .object([("url", .string("/api/shot/" + shot.name)), ("at", .string(iso8601(shot.date))), ("text", .string(shot.text))])
    }

    static func iso8601(_ date: Date) -> String { isoFormatter.string(from: date) }
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: Prompt

    /// An `AgentPrompt` as the contract's `Prompt`. `filled` says whether Nook already wrote an answer into a text field that stays
    /// on screen (`TerminalSession.isFilledField`): choosing it again toggles its box, so it is no field to write into.
    static func prompt(_ prompt: AgentPrompt, filled: (Int, AgentPrompt) -> Bool = { _, _ in false }) -> RemoteJSON {
        let kind: String
        switch prompt.kind {
        case .approval: kind = "approval"
        case .question: kind = "question"
        case .selector: kind = "selector"
        }
        let options: [RemoteJSON] = prompt.options.map { option in
            // A field Nook already wrote into, still on screen, is chosen like any option (Enter toggles its box): it takes no text.
            let isFilled = option.input == .inline && filled(option.index, prompt)
            let input: String
            switch option.input {
            case .none: input = "none"
            case .inline: input = isFilled ? "none" : "inline"
            case .followUp: input = "followUp"
            }
            return .object([
                ("index", .int(option.index)), ("number", .int(option.number)), ("title", .string(option.title)), ("detail", .string(option.detail)),
                ("input", .string(input)), ("checked", option.checked.map(RemoteJSON.bool) ?? .null), ("current", .bool(option.current)),
                ("shortcut", .string(option.shortcut)), ("filled", .bool(isFilled)),
            ])
        }
        return .object([
            ("signature", .string(prompt.signature)),
            ("kind", .string(kind)),
            ("header", .string(prompt.header)),
            ("question", .string(prompt.question)),
            ("note", .string(prompt.note)),
            ("context", .string(prompt.context)),
            ("tabs", .array(prompt.tabs.map { .object([("title", .string($0.title)), ("answered", .bool($0.answered)), ("isSubmit", .bool($0.isSubmit))]) })),
            ("options", .array(options)),
            ("highlighted", .int(prompt.highlighted)),
            ("multiSelect", .bool(prompt.multiSelect)),
            ("review", .array(prompt.review.map { .object([("question", .string($0.question)), ("answer", .string($0.answer))]) })),
            ("reviewTitle", .string(prompt.reviewTitle)),
            ("warning", .string(prompt.warning)),
            ("takesNotes", .bool(prompt.takesNotes)),
            ("notes", .string(prompt.notes)),
            ("notesOpen", .bool(prompt.takesNotes && (prompt.notesOpen || prompt.notesFocused))),
            ("preview", .string(prompt.preview)),
            ("moreAbove", .int(prompt.moreAbove)),
            ("moreBelow", .int(prompt.moreBelow)),
        ])
    }

    // MARK: Panel

    static func panel(_ panel: ClaudePanel) -> RemoteJSON {
        .object([("name", .string(panel.name)), ("rows", .array(panel.rows.map(row))), ("moreAbove", .bool(panel.moreAbove)), ("moreBelow", .bool(panel.moreBelow))])
    }

    static func row(_ row: ClaudePanel.Row) -> RemoteJSON {
        switch row {
        case .blank: return .object([("kind", .string("blank"))])
        case .rule: return .object([("kind", .string("rule"))])
        case .tabs(let title, let names, let active):
            return .object([("kind", .string("tabs")), ("title", .string(title)), ("names", .array(names.map(RemoteJSON.string))), ("active", .int(active))])
        case .heading(let indent, let text): return .object([("kind", .string("heading")), ("indent", .int(indent)), ("text", .string(text))])
        case .text(let indent, let label, let body):
            return .object([("kind", .string("text")), ("indent", .int(indent)), ("label", .string(label)), ("body", .string(body))])
        case .caption(let indent, let text): return .object([("kind", .string("caption")), ("indent", .int(indent)), ("text", .string(text))])
        case .cursor(let indent, let text): return .object([("kind", .string("cursor")), ("indent", .int(indent)), ("text", .string(text))])
        case .bar(let indent, let lead, let fraction, let trailing):
            return .object([("kind", .string("bar")), ("indent", .int(indent)), ("lead", .string(lead)), ("fraction", .number(fraction)), ("trailing", .string(trailing))])
        case .hint(let text): return .object([("kind", .string("hint")), ("text", .string(text))])
        }
    }

    // MARK: The Mac

    /// The Mac's name as the user set it ("MacBook de Daniel"), read from the system's configuration: `Host.current()` asks the
    /// network and can take seconds.
    static func macName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
