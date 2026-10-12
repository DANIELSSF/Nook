import Foundation
import os

/// Keys sent to Terminal tabs: whether one sent with Terminal left behind arrived (`TerminalAppBridge.press`).
let keyLog = Logger(subsystem: "dev.nook.mac", category: "keys")

/// What a key visibly does to an agent's screen, so a key sent to a Terminal tab with Terminal left behind can be told to have
/// arrived (`TerminalAppBridge.press`). A check compares a reading of the tab's visible screen after the key with the one taken
/// right before it, and only counts a whole screen: Claude's box drawn (a reading caught mid-redraw lacks it) or a whole dialog.
/// It is nil when nothing on that screen would show the key for sure; the key then goes the sure way, with Terminal in front.
enum KeyEffect {
    /// The keys a check can exist for. Tab, ← → (Claude's panels), "s" and ⌃V do things no reading tells apart for sure.
    static func checkable(_ key: TerminalKey) -> Bool { [.up, .down, .escape, .backtab].contains(key) }

    static func check(_ key: TerminalKey, agent: TerminalAgent, before: String) -> ((String) -> Bool)? {
        let was = Reading(before, agent: agent)
        switch key {
        case .up, .down:
            // The highlight of the dialog moves to another option, or the list scrolls under it. Only a whole dialog answers;
            // a highlight at the end of a list that doesn't wrap never moves, and goes the sure way after the wait.
            guard let prompt = was.prompt else { return nil }
            let mark = highlight(prompt)
            return { after in Reading(after, agent: agent).prompt.map { highlight($0) != mark } ?? false }
        case .escape:
            if let prompt = was.prompt {
                // The dialog is cancelled: none on screen, or another one, on a whole screen.
                return { after in
                    let now = Reading(after, agent: agent)
                    return now.whole && now.prompt?.signature != prompt.signature
                }
            }
            if agent == .claude {
                // One of Claude's panels closes, or its command menu, or its turn stops: the box is back without them.
                if was.screen.panel != nil { return { after in let now = Reading(after, agent: agent); return now.box && now.screen.panel == nil } }
                if was.box, !was.screen.menu.isEmpty { return { after in let now = Reading(after, agent: agent); return now.box && now.screen.menu.isEmpty } }
                if was.screen.status?.working == true {
                    return { after in let now = Reading(after, agent: agent); return now.box && now.screen.status?.working != true }
                }
                return nil
            }
            // Codex says how to stop its turn while it works ("Working (12s • esc to interrupt)") and stops saying it once stopped.
            guard was.interruptible else { return nil }
            return { after in let now = Reading(after, agent: agent); return now.whole && !now.interruptible }
        case .backtab:
            // Claude's permission mode moves on: the mode line under the box names another one (the default one names none).
            guard agent == .claude, was.box, was.prompt == nil, was.screen.panel == nil else { return nil }
            let mode = was.mode
            return { after in let now = Reading(after, agent: agent); return now.box && now.mode != mode }
        default:
            return nil
        }
    }

    /// Where the highlight is: the option's place, number and words, so a list that scrolls under it counts as moving too.
    private static func highlight(_ prompt: AgentPrompt) -> String {
        let option = prompt.options.indices.contains(prompt.highlighted) ? prompt.options[prompt.highlighted] : nil
        return "\(prompt.highlighted)|\(option?.number ?? -1)|\(option?.title ?? "")"
    }

    /// One reading of the visible screen, split as the mirror splits it (`TerminalSession.screen`).
    private struct Reading {
        let screen: ClaudeScreen
        let prompt: AgentPrompt?
        let agent: TerminalAgent
        let text: String

        init(_ raw: String, agent: TerminalAgent) {
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            self.agent = agent
            screen = agent == .claude ? ClaudeComposer.split(text) : ClaudeScreen(conversation: text)
            prompt = AgentPrompt.parse(screen.conversation)
        }
        /// Claude's box is drawn.
        var box: Bool { screen.input != nil }
        /// A reading to trust: with Claude, its box or a whole dialog; Codex's screen isn't split, so anything on it.
        var whole: Bool { agent == .claude ? box || prompt != nil : !text.isEmpty }
        /// The mode line's mode ("" for the default one, which Claude doesn't name); its hints change on their own.
        var mode: String { screen.mode?.label.lowercased() ?? "" }
        /// The end of the screen offers to stop the turn.
        var interruptible: Bool {
            text.split(separator: "\n").suffix(12).contains { $0.lowercased().contains("esc to interrupt") }
        }
    }
}

/// How a key sent with Terminal left behind went (`TerminalAppBridge.press`): the log says whether this Mac's Terminal takes them.
struct KeyAttempt: Equatable {
    enum Outcome: String {
        /// The screen showed it: Terminal never came forward.
        case verified
        /// Sent without a check, right after one that showed (a burst on the same tab).
        case trusted
        /// The screen didn't show it in time: pressed again with Terminal in front.
        case unverified = "not verified"
        /// It showed once Terminal was in front, before being pressed again: not pressed twice.
        case late = "arrived late"
        /// The tab's window isn't Terminal's front one (or the script failed): Terminal in front, as before.
        case behind
        /// Nothing on that screen would show the key: Terminal in front, as before.
        case unchecked
    }
    var key: TerminalKey
    var outcome: Outcome
    var milliseconds: Int
    var detail = ""

    func log() {
        keyLog.notice("background \(key.rawValue, privacy: .public): \(outcome.rawValue, privacy: .public) after \(milliseconds, privacy: .public) ms \(detail, privacy: .public)")
    }
}
