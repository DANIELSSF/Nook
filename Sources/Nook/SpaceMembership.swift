import AppKit
import Darwin

// Nook's panels are meant to be on every Space (`.canJoinAllSpaces`): the island at the notch has to be there on every desktop and over every
// full-screen app the user swipes to. WindowServer makes a sticky window a member of every Space when it is first ordered in, but it does not
// keep it there. After the Mac woke with its lid opened (2026-10-09 07:38, the display reconfigured under the running app), the collapsed
// island's window was a member of the desktop only, not of the full-screen app's Space beside it, so swiping to that app showed no island; the
// open island's window was a member of both, which is why the open island followed and the collapsed one did not. Nothing public brings the
// Space back: ordering the window out and in again, setting its collection behavior again (AppKit does not even send it once the window has
// been ordered out), its level or its frame all leave it where it was. So the window is added to the Spaces it is missing by WindowServer's
// own call (`SpaceBackend.add`), looked up by name at run time: on a macOS without it Nook simply cannot repair, and changes nothing.

/// What Nook asks WindowServer about a window's Spaces. The real one is `WindowServerSpaces`; tests pass their own.
protocol SpaceBackend: AnyObject {
    /// The calls were found; without them nothing is read or changed.
    var isAvailable: Bool { get }
    /// The Spaces the window is a member of (empty: none yet, or it cannot be told).
    func spaces(of windowNumber: Int) -> [UInt64]
    /// Each display's Spaces in Mission Control's order: its desktops and its full-screen apps.
    func displaySpaces() -> [[UInt64]]
    func add(_ windowNumber: Int, to spaces: [UInt64])
}

/// Keeps Nook's sticky panels members of every Space of their display (see above). All on the main thread, like the windows.
final class SpaceMembership {
    /// The one the panels use (`NotchPanel`) and the controller's checks (`NotchController.keepOnEverySpace`); tests put their own in its place.
    static var shared = SpaceMembership(backend: WindowServerSpaces())

    let backend: SpaceBackend
    /// Where repairs and the state after a wake are written (`SpacesJournal`). Nil writes nothing: the running app sets it, tests and quiet
    /// controllers leave it alone so nothing reaches the user's log.
    var journal: ((String) -> Void)?

    init(backend: SpaceBackend, journal: ((String) -> Void)? = nil) {
        self.backend = backend
        self.journal = journal
    }

    /// The Spaces of the window's display it is not a member of. The display is the one whose Spaces include one of the window's: a window in
    /// no Space yet (it is still being ordered in) is left to WindowServer, which makes a new sticky window a member of every Space itself.
    static func missing(current: [UInt64], displays: [[UInt64]]) -> [UInt64] {
        guard !current.isEmpty, let display = displays.first(where: { !Set($0).isDisjoint(with: current) }) else { return [] }
        let have = Set(current)
        return display.filter { !have.contains($0) }
    }

    /// Makes a sticky window a member of the Spaces of its display it is missing, and says which it really gained (empty: none was missing, it is
    /// not one of Nook's sticky windows, or WindowServer did not take it). `displays` saves asking again when several windows are looked at in a row.
    @discardableResult
    func rejoin(_ window: NSWindow, displays: [[UInt64]]? = nil, reason: String) -> [UInt64] {
        guard backend.isAvailable, window.collectionBehavior.contains(.canJoinAllSpaces), window.windowNumber > 0 else { return [] }
        let current = backend.spaces(of: window.windowNumber)
        guard !current.isEmpty else { return [] }
        let missing = Self.missing(current: current, displays: displays ?? backend.displaySpaces())
        guard !missing.isEmpty else { return [] }
        backend.add(window.windowNumber, to: missing)
        // The call answers nothing, so WindowServer is asked again (it takes the add at once): the log says what the window is really in now,
        // never a repair that did not happen. Only here, when a Space was missing, so a healthy window costs nothing more.
        let after = backend.spaces(of: window.windowNumber)
        let gained = missing.filter(after.contains), still = missing.filter { !after.contains($0) }
        let outcome = gained.isEmpty ? "no se pudo añadir (sigue en \(Self.list(after)))"
            : still.isEmpty ? "añadida, ahora en \(Self.list(after))"
            : "añadida a \(Self.list(gained)) pero sigue faltando en \(Self.list(still)), ahora en \(Self.list(after))"
        journal?("\(reason) · \(Self.role(of: window)): faltaba en \(Self.list(missing)) (estaba en \(Self.list(current))); \(outcome)")
        return gained
    }

    /// The Spaces Nook's visible sticky windows are missing are given back to them, asking for the displays' Spaces once. Returns how many
    /// windows were repaired.
    @discardableResult
    func rejoinVisible(_ windows: [NSWindow], reason: String) -> Int {
        let sticky = windows.filter { $0.isVisible && $0.collectionBehavior.contains(.canJoinAllSpaces) && $0.windowNumber > 0 }
        guard backend.isAvailable, !sticky.isEmpty else { return 0 }
        let displays = backend.displaySpaces()
        return sticky.filter { !rejoin($0, displays: displays, reason: reason).isEmpty }.count
    }

    /// One window as the Spaces log tells it: shown or not, on the Space in front, seen, and the Spaces it is in out of its display's.
    func describe(_ window: NSWindow, displays: [[UInt64]]) -> String {
        let current = backend.isAvailable && window.windowNumber > 0 ? backend.spaces(of: window.windowNumber) : []
        let display = displays.first { !Set($0).isDisjoint(with: current) } ?? []
        let seen = window.occlusionState.contains(.visible)
        return "\(Self.role(of: window)): \(window.isVisible ? "visible" : "oculta"), \(window.isOnActiveSpace ? "en este espacio" : "fuera de este espacio"), "
            + "\(seen ? "a la vista" : "tapada"), espacios \(Self.list(current)) de \(Self.list(display))"
    }

    static func role(of window: NSWindow) -> String {
        if let role = (window as? NotchPanel)?.spaceRole { return role }
        return "ventana \(Int(window.frame.width))×\(Int(window.frame.height))"
    }
    static func list(_ spaces: [UInt64]) -> String { spaces.isEmpty ? "ninguno" : spaces.map(String.init).joined(separator: "·") }
}

/// WindowServer's own calls for a window's Spaces. They are not public API (SkyLight's, re-exported by CoreGraphics), so each is looked up
/// by name: when one is missing the backend says it is unavailable and Nook leaves the windows as they are.
final class WindowServerSpaces: SpaceBackend {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias AddWindowsToSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

    /// Current, other and user Spaces: every Space a window can be a member of.
    private static let allSpacesMask: Int32 = 0x7
    private let mainConnection: MainConnection?
    private let copySpaces: CopySpacesForWindows?
    private let copyDisplays: CopyManagedDisplaySpaces?
    private let addToSpaces: AddWindowsToSpaces?

    init() {
        let handle = dlopen(nil, RTLD_NOW)
        func load<Function>(_ name: String, as _: Function.Type) -> Function? { dlsym(handle, name).map { unsafeBitCast($0, to: Function.self) } }
        mainConnection = load("CGSMainConnectionID", as: MainConnection.self)
        copySpaces = load("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
        copyDisplays = load("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        addToSpaces = load("CGSAddWindowsToSpaces", as: AddWindowsToSpaces.self)
    }

    var isAvailable: Bool { mainConnection != nil && copySpaces != nil && copyDisplays != nil && addToSpaces != nil }

    func spaces(of windowNumber: Int) -> [UInt64] {
        guard let mainConnection, let copySpaces, windowNumber > 0 else { return [] }
        let windows = [NSNumber(value: UInt32(windowNumber))] as CFArray
        let spaces = copySpaces(mainConnection(), Self.allSpacesMask, windows)?.takeRetainedValue() as? [NSNumber] ?? []
        return spaces.map(\.uint64Value).sorted()
    }

    func displaySpaces() -> [[UInt64]] {
        guard let mainConnection, let copyDisplays else { return [] }
        return Self.parse(copyDisplays(mainConnection())?.takeRetainedValue() as? [[String: Any]] ?? [])
    }

    func add(_ windowNumber: Int, to spaces: [UInt64]) {
        guard let mainConnection, let addToSpaces, windowNumber > 0, !spaces.isEmpty else { return }
        addToSpaces(mainConnection(), [NSNumber(value: UInt32(windowNumber))] as CFArray, spaces.map { NSNumber(value: $0) } as CFArray)
    }

    /// Each display's Spaces from WindowServer's description of them: a "Spaces" list per display, each Space with its "ManagedSpaceID"
    /// ("id64" on systems that only give that).
    static func parse(_ displays: [[String: Any]]) -> [[UInt64]] {
        displays.map { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
                ((space["ManagedSpaceID"] ?? space["id64"]) as? NSNumber)?.uint64Value
            }
        }.filter { !$0.isEmpty }
    }
}

/// A short local record of what happened to the panels' Spaces after a wake and whenever one had to be given back, so the next time the island
/// goes missing there is something to read. Capped in size; written off the main thread.
enum SpacesJournal {
    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook/spaces.log") }
    private static let queue = DispatchQueue(label: "nook.spaces-journal", qos: .utility)
    /// Past this size only the newest half is kept.
    static let limit = 64_000

    static func append(_ entry: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(entry)\n"
        queue.async { write(line, to: url) }
    }

    /// Only the user reads and writes the log.
    static let mode = 0o600

    static func write(_ line: String, to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Made private from the start, and a log an earlier build left readable by others is made private the first time it is written to.
        // The writes below go into the file itself rather than a replacement, so they keep its mode.
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: mode])
        } else if (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) != mode {
            try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if text.utf8.count > limit { text = String(text.suffix(limit / 2)) }
        text += line
        try? text.write(to: url, atomically: false, encoding: .utf8)
    }
}
