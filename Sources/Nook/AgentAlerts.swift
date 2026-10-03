import Foundation

/// Something a collapsed island calls attention to, the way the terminal rings its bell: an agent
/// finished its turn, asks for something, or stopped with an error.
struct NookAlert: Equatable, Identifiable {
    enum Kind: Equatable { case finished, question, failed }
    /// Grows with every alert, so the same kind twice in a row is still a new one.
    let id: Int
    let sessionID: String
    let kind: Kind
    /// The tab's name in Nook.
    let title: String
    let message: String
}

/// Tells when an agent's turn ended from its screen alone: Claude's spinner line was there and has
/// been gone (or became "Churned for …") for a few seconds, with no question in its place. Claude's
/// hooks say the same instantly, but only for the configuration folder they were installed in.
struct TurnWatch {
    /// How long the spinner must stay away; a redraw can hide it for a moment.
    var quiet: TimeInterval = 3
    private var lastWorking: Date?
    private var readings = 0

    /// True once, when a turn that was seen working has ended.
    mutating func observe(working: Bool, asking: Bool, now: Date = Date()) -> Bool {
        if working { lastWorking = now; readings = 0; return false }
        guard let since = lastWorking else { return false }
        // A question in the spinner's place is not the end: it raises its own alert.
        if asking { lastWorking = nil; readings = 0; return false }
        readings += 1
        guard readings >= 2, now.timeIntervalSince(since) >= quiet else { return false }
        lastWorking = nil; readings = 0
        return true
    }
}
