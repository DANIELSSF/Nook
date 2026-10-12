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
        return "Después de actualizar Nook, macOS puede mostrar el permiso activado y aun así negárselo a la versión nueva. «Abrir Ajustes» borra ese registro y vuelve a añadir Nook a la lista: solo tienes que activarlo una vez."
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

// MARK: - Claude's live limits

/// What the "Límites en vivo" row's button does. Both go through `AppModel.toggleClaudeStatusLine`, which asks first.
enum ClaudeLimitsAction: Equatable {
    case enable, disable

    var title: String { self == .enable ? "Activar…" : "Quitar…" }
    var symbol: String { self == .enable ? "gauge.with.dots.needle.67percent" : "xmark.circle" }
}

/// The "Límites en vivo" row: Nook's status line in Claude's settings, which is how a Terminal tab gets its limits, cost and context without a key or a scroll. Like the
/// hooks it is not a macOS permission, and it says so.
struct ClaudeLimitsPresentation: Equatable {
    var chip: String
    var tone: PermissionTone
    var symbol: String
    /// nil when there is nothing to do: it is not read yet, there is no folder to put it in, or a settings file Nook cannot read stops any change.
    var action: ClaudeLimitsAction?
    /// A line of its own for this state, when there is something to say about it.
    var note: String?

    static let subtitle = "Claude le pasa a Nook tus límites, el costo y el contexto de cada sesión, sin teclas ni desplazarte."
    /// What is kept, where, who can read it and for how long, in the row's own words before the user turns it on and while it is on.
    static let keeps = "Lo último que Claude envía de cada sesión, tal como lo manda: nombre, carpeta, ruta de su conversación, modelo, costo, contexto, límites y más. Solo en este Mac, en una carpeta privada que únicamente lee tu usuario; nada sale por la red. Cada archivo se borra una hora después de su última actualización, y al quitar la función, toda la carpeta."
    /// The same in full, for the row's guide: everything that is kept (Claude's payload, whole), where it is, and that it never leaves this Mac.
    static func keepsInDetail(folder: String) -> String {
        "Qué se guarda, en detalle: el nombre y el id de la sesión; su carpeta (y el repositorio o la PR de git, si los hay); la ruta de su conversación; el modelo y la versión; el costo, los tiempos y las líneas cambiadas; el contexto y el esfuerzo; los límites con sus reinicios; y los datos de la caché. Está en \(folder), una carpeta que solo lee tu usuario, y no sale de este Mac."
    }
    /// What changes in Claude when it is on, which the row says before the user turns it on and again while it is on (the confirmation says it too).
    static let effects = "Claude deja una fila en blanco bajo su caja de escritura (en las sesiones a pantalla completa) y quita las pistas del pie («?\u{00A0}for shortcuts»), como con cualquier línea de estado."
    /// A status line of the user's own stays on screen: Nook runs it after its own, and keeps what it prints along with the rest.
    static let chaining = "Tu línea de estado actual sigue viéndose igual: Nook la ejecuta después y guarda también lo que imprime."
    /// The copies Nook leaves of Claude's settings each time it changes them.
    static let backups = "Cada cambio en los ajustes de Claude deja una copia de seguridad privada junto al archivo (hasta cinco)."
    /// When the sessions that were open take it.
    static let pickup = "Las sesiones que ya estaban abiertas la toman en su próxima respuesta."

    /// The words of the confirmation that comes before any change: a few short paragraphs with what is kept (and where, and for how long), what changes in Claude and
    /// the backups; the details are in the row. `files` names the folders ("~/.claude y ~/.claude-work"), and `chains` is a status line of the user's own in one of them.
    static func confirmation(installed: Bool, files: String, chains: Bool) -> (title: String, text: String) {
        if installed {
            return ("Quitar los límites en vivo",
                    "Se quita la línea de estado de Nook de \(files) y se deja como estaba antes: sin línea de estado, o la tuya. Se borra también la carpeta con lo que Nook guardó de las sesiones.\n\n" + backups)
        }
        let changes = "En Claude aparece una fila en blanco bajo su caja en las sesiones a pantalla completa, y desaparecen las pistas «?\u{00A0}for shortcuts»." + (chains ? " " + chaining : "")
        return ("Ver los límites de Claude en vivo",
                ["Añade a \(files) una línea de estado: Claude le pasa a Nook, al responder, lo último de cada sesión (nombre, carpeta, ruta de su conversación, modelo, costo, contexto y límites, entre otros datos; el detalle, en Ajustes → Permisos).",
                 "Se guarda solo en este Mac, en una carpeta privada que únicamente lee tu usuario; nada sale por la red. Cada archivo se borra una hora después de su última actualización, y al quitar la función, toda la carpeta.",
                 changes,
                 backups + " " + pickup].joined(separator: "\n\n"))
    }

    /// Whether the row lists the folders: when it is open, and when they are not all alike (a list of two identical lines says nothing the chip does not) or one has
    /// something the user should know (a line of their own, settings Nook cannot read, one chained).
    static func listsFolders(_ folders: [NookStatusLine.Folder], open: Bool) -> Bool {
        guard !folders.isEmpty else { return false }
        if open { return true }
        let alike = folders.dropFirst().allSatisfy { $0.state == folders[0].state }
        let notable = folders.contains { if case .off = $0.state { false } else if case .on = $0.state { false } else { true } }
        return !alike || notable
    }

    private static func installed(_ state: NookStatusLine.State) -> Bool {
        switch state {
        case .on, .chained: true
        case .off, .foreign, .unreadable: false
        }
    }

    /// Every folder, as the row reads it: nil is "not read yet".
    static func make(folders: [NookStatusLine.Folder]?) -> ClaudeLimitsPresentation {
        guard let folders else { return ClaudeLimitsPresentation(chip: "Leyendo…", tone: .neutral, symbol: "ellipsis.circle", action: nil, note: nil) }
        guard !folders.isEmpty else {
            return ClaudeLimitsPresentation(chip: "Sin carpetas de Claude", tone: .neutral, symbol: "questionmark.circle", action: nil,
                                            note: "Nook no encuentra una carpeta de ajustes de Claude (~/.claude) donde ponerla.")
        }
        // A settings file that is not readable stops any change in any folder (nothing is written anywhere): the row says so and does not offer one.
        let unreadable = folders.filter { $0.state == .unreadable }
        if !unreadable.isEmpty {
            let names = unreadable.map(\.name).joined(separator: ", ")
            return ClaudeLimitsPresentation(chip: "Ajustes ilegibles", tone: .attention, symbol: "exclamationmark.triangle.fill", action: nil,
                                            note: "Nook no puede leer los ajustes de \(names) (no son un JSON válido) y no cambia nada hasta que se arreglen.")
        }
        let on = folders.filter { installed($0.state) }
        if on.count == folders.count {
            let chained = on.allSatisfy { if case .chained = $0.state { true } else { false } }
            return ClaudeLimitsPresentation(chip: chained ? "Encadenada con la tuya" : "Activado", tone: .good, symbol: chained ? "link" : "checkmark.circle.fill", action: .disable,
                                            note: chained ? chaining : nil)
        }
        if !on.isEmpty {
            // Some folders have it and some don't: a Claude in the others would never report.
            return ClaudeLimitsPresentation(chip: "\(on.count) de \(folders.count) carpetas", tone: .attention, symbol: "circle.lefthalf.filled", action: .enable, note: nil)
        }
        let keeps = folders.contains { if case .foreign = $0.state { true } else { false } }
        return ClaudeLimitsPresentation(chip: "Sin activar", tone: .neutral, symbol: "circle.dashed", action: .enable,
                                        note: keeps ? chaining : nil)
    }

    /// One folder of the row's list: its mark, how loud it is and what it says.
    static func line(for state: NookStatusLine.State) -> (symbol: String, tone: PermissionTone, words: String) {
        switch state {
        case .on: ("checkmark", .good, "activada")
        case .chained: ("checkmark", .good, "activada, con la tuya después")
        case .foreign: ("minus", .neutral, "tiene su línea de estado (se mantiene)")
        case .off: ("minus", .neutral, "sin línea de estado")
        case .unreadable: ("exclamationmark", .attention, "ajustes ilegibles")
        }
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
        /// Each Claude folder's status line (`NookStatusLine.states`), delivered on the main thread. Nothing, for a test that does not look at it.
        var readStatusLine: (@escaping ([NookStatusLine.Folder]) -> Void) -> Void = { $0([]) }
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
            // It opens each folder's `settings.json`, so it is read off the main thread, like the hooks.
            readStatusLine: { done in
                DispatchQueue.global(qos: .utility).async {
                    let folders = NookStatusLine.states()
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
    /// Each Claude folder's status line, for the "Límites en vivo" row; nil until the first read.
    @Published private(set) var statusLineFolders: [NookStatusLine.Folder]?
    /// The guides that are open, by permission (`NookPermission.id`) or `claudeKey`.
    @Published private(set) var openGuides: Set<String>
    static let claudeKey = "claude"
    /// The guide of the "Límites en vivo" row, among the guides that are open.
    static let limitsKey = "limits"

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

    init(services: Services = .live, states: [NookPermission: NookPermission.State] = [:], claudeFolders: [ClaudeFolder]? = nil, statusLineFolders: [NookStatusLine.Folder]? = nil,
         openGuides: Set<String> = [], center: NotificationCenter = .default, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         bundleOf: @escaping (Notification) -> String? = PermissionsModel.bundle(of:), settle: TimeInterval = PermissionsModel.terminalSettle) {
        self.services = services
        self.settle = settle
        self.states = states
        self.claudeFolders = claudeFolders
        self.statusLineFolders = statusLineFolders
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
        var waiting = 3
        let finish = { [weak self] in
            waiting -= 1
            guard waiting == 0, let self else { return }
            self.reading = false
            if self.readAgain { self.readAgain = false; self.refresh() }
        }
        services.readStates { [weak self] states in self?.states = states; finish() }
        services.readClaude { [weak self] folders in self?.claudeFolders = folders; finish() }
        services.readStatusLine { [weak self] folders in self?.statusLineFolders = folders; finish() }
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
