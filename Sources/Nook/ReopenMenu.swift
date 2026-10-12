import Foundation

// The "+" menu takes back what left the tab row: `AppModel.recentlyClosed` (the tabs a ✕ closed and the Terminal tabs Nook lost), newest
// first, each one pick from being reopened with its name and colour. A close that was a slip costs one menu choice.

/// A closed tab as the "+" menu lists it.
struct ReopenEntry: Equatable, Identifiable {
    /// Its place in the list: titles repeat, and a tab can be closed, reopened and closed again.
    var id: Int
    var label: String
    var tab: AppModel.ClosedTab
}

enum ReopenMenu {
    /// The longest title the menu shows whole: a Terminal tab's title can run to a sentence.
    static let titleLimit = 36

    static func entries(_ closed: [AppModel.ClosedTab]) -> [ReopenEntry] {
        closed.enumerated().map { ReopenEntry(id: $0.offset, label: label(for: $0.element.title, newest: $0.offset == 0), tab: $0.element) }
    }

    /// "Reabrir pestaña cerrada: «ui»" for the tab that closed last (the slip), "Reabrir «ui»" for those before it.
    static func label(for title: String, newest: Bool) -> String {
        let flat = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let name = flat.count > titleLimit ? String(flat.prefix(titleLimit)).trimmingCharacters(in: .whitespaces) + "…" : flat
        switch (newest, name.isEmpty) {
        case (true, true): return "Reabrir pestaña cerrada"
        case (true, false): return "Reabrir pestaña cerrada: «\(name)»"
        case (false, true): return "Reabrir otra pestaña sin nombre"
        case (false, false): return "Reabrir «\(name)»"
        }
    }
}
