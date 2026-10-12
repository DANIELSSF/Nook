import Foundation

/// The order of Nook's tab strip, by tab id (`TerminalSession.id`), which the user sets by dragging a tab to another place
/// (`AppModel.moveSession`). It is Nook's alone: Terminal's own tabs never move for it.
///
/// Tabs that are not in the strip right now keep their place in the order: the ones still to arrive at launch (Terminal's tabs
/// come with its first readings, after Nook's own sessions) and closed ones, which go back where they were if they are reopened.
/// A tab the order has never seen goes at the end. What is kept is pruned like a tab's name and colour (`AppModel.forgetOtherTabs`):
/// a later tab that takes a closed tab's TTY is another tab, with an id of its own, and never inherits its place.
struct TabOrder: Equatable {
    private(set) var ids: [String]

    init(_ ids: [String] = []) {
        var seen = Set<String>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    func rank(of id: String) -> Int? { ids.firstIndex(of: id) }

    /// Where a tab arriving in the strip goes among the tabs already there (`present`, in the strip's order), noting it in the
    /// order: before the first tab that comes after it in the order, so tabs arriving one by one (a launch, a reopen) take their
    /// saved places whatever order they come in. A tab the order lacks goes at the end, and so does a tab in the strip it lacks
    /// (one put there by hand): those are added to the order first, in the strip's order.
    mutating func place(_ id: String, among present: [String]) -> Int {
        for other in present where other != id && rank(of: other) == nil { ids.append(other) }
        guard let rank = rank(of: id) else {
            ids.append(id)
            return present.count
        }
        return present.firstIndex { other in (self.rank(of: other) ?? .max) > rank } ?? present.count
    }

    /// The strip now shows `present`, in this order, after the user moved `moved`. Tabs not in the strip keep their place: each
    /// stays after the tab it followed, and those before every tab stay first. The ones that followed the moved tab stay where it
    /// was (after the tab that came before it): only the dragged tab moves.
    mutating func follow(_ present: [String], moved: String? = nil) {
        let shown = Set(present)
        var leading: [String] = [], trailing: [String: [String]] = [:]
        var anchor: String?
        for id in ids {
            if shown.contains(id) {
                if id != moved { anchor = id }
            } else if let anchor {
                trailing[anchor, default: []].append(id)
            } else {
                leading.append(id)
            }
        }
        var result = leading
        for id in present {
            result.append(id)
            result += trailing[id] ?? []
        }
        self = TabOrder(result)
    }

    /// `items` in this order; the ones it lacks go after, as they were.
    func arranged<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        items.enumerated()
            .sorted { a, b in
                let ra = rank(of: id(a.element)) ?? .max, rb = rank(of: id(b.element)) ?? .max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// At launch: the places of Terminal tabs follow their names and colours (`TerminalTabIdentity.migrated`): a place saved by
    /// the bare TTY moves to the tab restored on it when that tab is provably the same (`keep`), and the places of tabs whose TTY
    /// now holds another login, or none, go. Of Nook's own tmux sessions, only the ones restored (`nookTabs`) keep theirs.
    mutating func migrate(keep: [String: String], logins: [String: String], nookTabs: Set<String>) {
        let ranks = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let kept = TerminalTabIdentity.migrated(ranks, keep: keep, logins: logins, nookTabs: nookTabs)
        self = TabOrder(kept.sorted { $0.value < $1.value }.map(\.key))
    }

    // MARK: Persistence

    static let key = "tabOrder"

    static func load(from defaults: UserDefaults) -> TabOrder { TabOrder(defaults.stringArray(forKey: key) ?? []) }
    func save(to defaults: UserDefaults) { defaults.set(ids, forKey: Self.key) }
}
