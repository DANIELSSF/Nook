import AppKit
import Combine

// The settings card's "Permisos" tab, without its views: what Nook needs from macOS, the state each permission is in, and the
// one button that does the right thing for that state. Every mapping is plain data so it is unit-tested; `PermissionsPane.swift`
// only draws it. Nothing here asks macOS for anything by itself: the system's side is behind `PermissionsModel.Services`, which
// tests replace.

// MARK: - A permission's row

/// What a permission's button does.
enum PermissionAction: Equatable {
    /// macOS's own prompt, possible only while it has never been asked.
    case request
    /// The exact pane of System Settings, where the switch is.
    case openSettings
    /// Terminal has to be running before macOS can say whether Nook may control it.
    case openTerminal

    var title: String {
        switch self {
        case .request: "Pedir permiso"
        case .openSettings: "Abrir Ajustes"
        case .openTerminal: "Abrir Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .request: "hand.raised"
        case .openSettings: "arrow.up.forward.app"
        case .openTerminal: "terminal"
        }
    }
}

/// How loud a state is. The view maps each to a colour.
enum PermissionTone: Equatable {
    case good, attention, bad, neutral
}

/// A permission's row for one state: the chip, and the button.
struct PermissionPresentation: Equatable {
    var chip: String
    var tone: PermissionTone
    /// The chip's SF Symbol.
    var symbol: String
    /// nil when there is nothing to do (it is on, or it has not been read yet).
    var action: PermissionAction?
}

extension NookPermission {
    /// How the row reads for `state`; nil is "not read yet". The needed permission speaks louder than the optional ones: only
    /// it turns amber when it is off and red when it is refused.
    func presentation(for state: State?) -> PermissionPresentation {
        guard let state else { return PermissionPresentation(chip: "Leyendo…", tone: .neutral, symbol: "ellipsis.circle", action: nil) }
        switch state {
        case .granted:
            return PermissionPresentation(chip: "Activado", tone: .good, symbol: "checkmark.circle.fill", action: nil)
        case .notAsked:
            // Accessibility has no answer to wait for (macOS only opens the pane), so it always goes straight there.
            return PermissionPresentation(chip: "Sin activar", tone: essential ? .attention : .neutral, symbol: "circle.dashed",
                                          action: self == .accessibility ? .openSettings : .request)
        case .denied:
            return PermissionPresentation(chip: "Denegado", tone: essential ? .bad : .attention, symbol: "xmark.circle.fill", action: .openSettings)
        case .unknown:
            // Only Terminal's permission can't be read, and only while Terminal is closed.
            if self == .automation {
                return PermissionPresentation(chip: "Abre Terminal para comprobarlo", tone: .neutral, symbol: "questionmark.circle", action: .openTerminal)
            }
            return PermissionPresentation(chip: "No se pudo comprobar", tone: .neutral, symbol: "questionmark.circle", action: .openSettings)
        }
    }

    /// An aside under the steps, for what the steps do not say.
    var note: String? {
        guard self == .accessibility else { return nil }
        return "Después de actualizar Nook: la app va firmada con un identificador estable, así que macOS debería conservar este permiso entre versiones. Si deja de funcionar, quita Nook de la lista con «−» y vuelve a añadirlo."
    }
}

// MARK: - Claude's signals

/// One of Claude's configuration folders and whether Nook's hooks are in it.
struct ClaudeFolder: Equatable {
    /// How it reads: "~/.claude".
    var name: String
    var enabled: Bool

    /// Every configuration folder, read off the main thread (it opens each `settings.json`).
    static func read(folders: [URL] = ClaudeHooks.folders(), isEnabled: (URL) -> Bool = { ClaudeHooks.isEnabled(in: $0) }) -> [ClaudeFolder] {
        folders.map { ClaudeFolder(name: "~/" + $0.lastPathComponent, enabled: isEnabled($0)) }
    }
}

enum ClaudeSignalsAction: Equatable {
    case enable, disable

    var title: String { self == .enable ? "Activar avisos…" : "Desactivar…" }
    var symbol: String { self == .enable ? "bell.badge" : "bell.slash" }
}

/// The "Avisos de Claude" row. It is not a macOS permission (it writes hooks into Claude's own settings), so it sits beside them.
struct ClaudeSignalsPresentation: Equatable {
    var chip: String
    var tone: PermissionTone
    var symbol: String
    var action: ClaudeSignalsAction

    /// `enabled` is `AppModel.claudeSignalsEnabled` (every folder has the hooks); `folders` is nil until they have been read.
    static func make(enabled: Bool, folders: [ClaudeFolder]?) -> ClaudeSignalsPresentation {
        if enabled { return ClaudeSignalsPresentation(chip: "Activado", tone: .good, symbol: "checkmark.circle.fill", action: .disable) }
        let on = folders?.filter(\.enabled).count ?? 0
        if let folders, on > 0 {
            // Some folders have them and some don't: a Claude in the others would never signal.
            return ClaudeSignalsPresentation(chip: "\(on) de \(folders.count) carpetas", tone: .attention, symbol: "circle.lefthalf.filled", action: .enable)
        }
        return ClaudeSignalsPresentation(chip: "Sin activar", tone: .neutral, symbol: "circle.dashed", action: .enable)
    }
}

// MARK: - Proactive help

/// Whether one of Nook's own notices is about a missing permission, so its banner can offer to open the Permisos tab. It matches
/// the wording of those notices (the tests hold it to the real ones), not Claude's own messages.
enum PermissionHelp {
    static let phrases = ["Privacidad y seguridad", "Accesibilidad", "permiso de Terminal", "permiso para Nook", "macOS no permitió"]

    static func opensPermissions(_ notice: String) -> Bool {
        phrases.contains { notice.localizedCaseInsensitiveContains($0) }
    }
}

extension AppModel {
    /// "Ver permisos": the settings card, on its Permisos tab.
    func showPermissions() { controller?.openSettings(tab: .permissions) }
}

// MARK: - Coming back from System Settings

/// The card's way back from System Settings. The island puts itself away at the user's first click in the pane (so it does not
/// cover it); this remembers that they were on the Permisos tab, so that opening the island within a few minutes shows that tab
/// again, already reading the permissions they just changed. It is used once.
struct SettingsResume {
    static let window: TimeInterval = 10 * 60
    private var until: Date?

    mutating func arm(now: Date) { until = now.addingTimeInterval(Self.window) }
    mutating func clear() { until = nil }
    /// Whether the tab should come back now. Asking spends it.
    mutating func due(now: Date) -> Bool {
        defer { until = nil }
        guard let until else { return false }
        return until > now
    }
}

// MARK: - The tab's state

/// The Permisos tab's state: what each permission is, which guides are open, and when to look again. Reads happen off the main
/// thread; everything it publishes is changed on it.
final class PermissionsModel: ObservableObject {
    /// What the tab does to the system. The real ones read the permissions, ask macOS and open System Settings; tests pass
    /// recorders, so no test ever prompts or opens anything.
    struct Services {
        /// Every permission's state, delivered on the main thread.
        var readStates: (@escaping ([NookPermission: NookPermission.State]) -> Void) -> Void
        /// The Claude folders and whether they have Nook's hooks, delivered on the main thread.
        var readClaude: (@escaping ([ClaudeFolder]) -> Void) -> Void
        /// macOS's prompt (or its pane); the state afterwards arrives on the main thread.
        var request: (NookPermission, @escaping (NookPermission.State) -> Void) -> Void
        var openSettings: (NookPermission) -> Void
        /// Starts Terminal without bringing it forward; the completion is on the main thread.
        var openTerminal: (@escaping () -> Void) -> Void

        static let live = Services(
            readStates: { NookPermission.states(completion: $0) },
            readClaude: { done in
                DispatchQueue.global(qos: .utility).async {
                    let folders = ClaudeFolder.read()
                    DispatchQueue.main.async { done(folders) }
                }
            },
            // `request` looks at the state first, which talks to the system, so it starts off the main thread; its answer comes back on it.
            request: { permission, done in DispatchQueue.global(qos: .userInitiated).async { permission.request(completion: done) } },
            openSettings: { $0.openSettings() },
            openTerminal: { done in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PermissionsModel.terminalBundle) else { return done() }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in DispatchQueue.main.async(execute: done) }
            })
    }

    static let systemSettingsBundle = "com.apple.systempreferences"
    static let terminalBundle = "com.apple.Terminal"
    /// Terminal takes a moment after launching before macOS can say whether Nook may control it.
    static let terminalSettle: TimeInterval = 0.8

    /// Each permission's state; empty until the first read.
    @Published private(set) var states: [NookPermission: NookPermission.State]
    /// The Claude folders; nil until the first read.
    @Published private(set) var claudeFolders: [ClaudeFolder]?
    /// The guides that are open, by permission (`NookPermission.id`) or `claudeKey`.
    @Published private(set) var openGuides: Set<String>
    static let claudeKey = "claude"

    /// Called when the user was sent to System Settings, so the island can bring this tab back when they return.
    var onOpenedSettings: () -> Void = {}

    /// macOS's own prompt is up, waiting for the user's answer. The island does not put itself away at the click that answers it.
    private(set) var isRequesting = false

    private let services: Services
    private let settle: TimeInterval
    private var active = false
    private var reading = false
    private var readAgain = false
    private var listeners: [AnyCancellable] = []

    /// The bundle of the app a workspace notification is about.
    static func bundle(of notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    init(services: Services = .live, states: [NookPermission: NookPermission.State] = [:], claudeFolders: [ClaudeFolder]? = nil, openGuides: Set<String> = [],
         center: NotificationCenter = .default, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         bundleOf: @escaping (Notification) -> String? = PermissionsModel.bundle(of:), settle: TimeInterval = PermissionsModel.terminalSettle) {
        self.services = services
        self.settle = settle
        self.states = states
        self.claudeFolders = claudeFolders
        self.openGuides = openGuides
        // Where the user comes back from System Settings, or Terminal opens or quits (which is what makes its permission readable):
        // no timer, only the events that can change the answer. They count only while the tab is on screen.
        listeners = [
            center.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in self?.changed() },
            center.publisher(for: NSWindow.didBecomeKeyNotification).sink { [weak self] note in if note.object is NotchPanel { self?.changed() } },
            workspace.publisher(for: NSWorkspace.didDeactivateApplicationNotification).sink { [weak self] note in
                if bundleOf(note) == Self.systemSettingsBundle { self?.changed() }
            },
            workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification).sink { [weak self] note in
                if bundleOf(note) == Self.terminalBundle { self?.changed(after: settle) }
            },
            workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification).sink { [weak self] note in
                if bundleOf(note) == Self.terminalBundle { self?.changed() }
            },
        ]
    }

    /// The tab is on screen (or not). Showing it reads everything.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on { refresh() }
    }
    var isActive: Bool { active }

    private func changed(after delay: TimeInterval = 0) {
        guard active else { return }
        if delay > 0 { refresh(after: delay) } else { refresh() }
    }

    /// Reads every state again. A read already under way is not doubled: one more follows it.
    func refresh() {
        guard !reading else { readAgain = true; return }
        reading = true
        var waiting = 2
        let finish = { [weak self] in
            waiting -= 1
            guard waiting == 0, let self else { return }
            self.reading = false
            if self.readAgain { self.readAgain = false; self.refresh() }
        }
        services.readStates { [weak self] states in self?.states = states; finish() }
        services.readClaude { [weak self] folders in self?.claudeFolders = folders; finish() }
    }

    func refresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
    }

    /// What the permission's button does (`NookPermission.presentation(for:)` says which).
    func perform(_ action: PermissionAction, for permission: NookPermission) {
        switch action {
        case .request:
            isRequesting = true
            services.request(permission) { [weak self] state in
                self?.isRequesting = false
                self?.states[permission] = state
                // Another permission may have moved with it (Terminal opened, a pane toggled meanwhile).
                self?.refresh()
            }
        case .openSettings:
            services.openSettings(permission)
            onOpenedSettings()
        case .openTerminal:
            services.openTerminal { [weak self] in if let self { self.refresh(after: self.settle) } }
        }
    }

    func presentation(for permission: NookPermission) -> PermissionPresentation { permission.presentation(for: states[permission]) }

    /// The needed permission is missing or refused: the tab says so even when it is not the one on screen.
    var needsAttention: Bool {
        NookPermission.allCases.contains { $0.essential && [.notAsked, .denied].contains(states[$0]) }
    }

    func isOpen(_ key: String) -> Bool { openGuides.contains(key) }
    func toggleGuide(_ key: String) {
        if openGuides.contains(key) { openGuides.remove(key) } else { openGuides.insert(key) }
    }
}
