import AppKit
import Combine
import ScreenCaptureKit
import UniformTypeIdentifiers

// Screen vision: Claude Code sees the user's screen. Two ways in, both off until the user turns the feature on in Nook's settings.
// The composer's toggle attaches a fresh screenshot to every message it sends (as a file path, like a pasted image), and an MCP
// tool, `capture_screen`, lets Claude take one by itself (`ScreenVisionMCP.swift`). Every capture leaves out Nook's own windows,
// the open island included, whatever the separate capture privacy setting says. Claude Code runs the tool in a helper process
// under Terminal's identity, which has no Screen Recording permission (and should not need it): the helper asks the running Nook
// over a private socket, and Nook, which holds the permission, takes the picture.

/// Which displays a capture takes.
enum ScreenDisplayChoice: String, Codable, CaseIterable {
    /// The display under the mouse pointer: where the user is looking, most of the time.
    case pointer
    /// The main display (the one with the menu bar).
    case main
    /// Every display, one picture each.
    case all
}

/// Who asked for a capture.
enum ScreenVisionOrigin: String, Codable {
    /// The composer's toggle, for a message being sent.
    case composer
    /// Claude, through the `capture_screen` tool.
    case claude
}

/// One saved screenshot.
struct ScreenShot: Codable, Equatable {
    var path: String
    var mimeType: String
    /// The display's name, as macOS gives it ("Pantalla integrada Retina").
    var display: String
    /// The saved image's size, in pixels.
    var width: Int
    var height: Int
    var date: Date
}

/// A capture that just happened, for the UI's brief cue.
struct ScreenVisionCapture: Equatable {
    var date: Date
    var origin: ScreenVisionOrigin
    var shots: [ScreenShot]
    /// The cue's words.
    var cue: String { origin == .claude ? "Claude miró tu pantalla" : "Pantalla adjunta al mensaje" }
}

/// Why a capture did not happen. Every description is a whole sentence in the user's words: it is shown as a notice in the island
/// and returned to Claude as the tool's error.
enum ScreenVisionError: LocalizedError, Equatable {
    case disabled
    case noPermission
    case noDisplay
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .disabled: "La visión de pantalla está desactivada en Nook. Actívala en los ajustes de Nook para que Claude pueda ver tu pantalla."
        // "Privacidad y seguridad" makes the island's notice offer the Permisos tab (`PermissionHelp`).
        case .noPermission: "Nook no tiene permiso para grabar la pantalla. Actívalo en Ajustes del Sistema → Privacidad y seguridad → \(NookPermission.screenRecordingPane)."
        case .noDisplay: "No se encontró ninguna pantalla que capturar."
        case .timedOut: "La captura de pantalla tardó demasiado."
        case .failed(let reason): "No se pudo capturar la pantalla: \(reason)"
        }
    }
}

// MARK: - Capturing

/// One display's picture, as the capturer took it.
struct CapturedDisplay {
    var image: CGImage
    var name: String
}

/// Takes pictures of displays without Nook's windows. The real one is ScreenCaptureKit (`SystemScreenCapturer`); tests pass a fake,
/// since no test process can hold the Screen Recording permission.
protocol ScreenCapturing {
    /// The chosen displays without any window of the process `pid`, each no larger than `maxLongEdge` pixels on its long side.
    /// Throws `ScreenVisionError`.
    func capture(_ choice: ScreenDisplayChoice, excluding pid: pid_t, maxLongEdge: Int) async throws -> [CapturedDisplay]
}

/// ScreenCaptureKit's screenshot of whole displays, with Nook's application filtered out: its windows are left out of the picture
/// even while the island is open, and what lies under them shows instead.
struct SystemScreenCapturer: ScreenCapturing {
    func capture(_ choice: ScreenDisplayChoice, excluding pid: pid_t, maxLongEdge: Int) async throws -> [CapturedDisplay] {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) } catch { throw Self.reason(error) }
        let pointer = CGEvent(source: nil)?.location
        let ids = ScreenShotFile.chooseDisplays(content.displays.map { ($0.displayID, CGDisplayBounds($0.displayID)) }, choice: choice,
                                                pointer: pointer, main: CGMainDisplayID())
        let displays = ids.compactMap { id in content.displays.first { $0.displayID == id } }
        guard !displays.isEmpty else { throw ScreenVisionError.noDisplay }
        // An application with no window on screen is not in the list; then there is nothing of Nook's to leave out.
        let nook = content.applications.filter { $0.processID == pid }
        let names = await MainActor.run { Self.screenNames() }
        var pictures: [CapturedDisplay] = []
        for display in displays {
            let filter = SCContentFilter(display: display, excludingApplications: nook, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            // The display's size in points (not its Retina pixels), smaller still past `maxLongEdge`: plenty to read, and a small file.
            let size = ScreenShotFile.outputSize(points: CGSize(width: display.width, height: display.height), maxLongEdge: maxLongEdge)
            configuration.width = size.width
            configuration.height = size.height
            configuration.captureResolution = .nominal
            // The pointer is not content, and for a message from the composer it always sits on Nook's (left out) send button.
            configuration.showsCursor = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                pictures.append(CapturedDisplay(image: image, name: names[display.displayID] ?? "Pantalla \(display.displayID)"))
            } catch { throw Self.reason(error) }
        }
        return pictures
    }

    /// The user's refusal (or a permission macOS no longer honours) reads as the missing permission; anything else as itself.
    static func reason(_ error: Error) -> ScreenVisionError {
        if let known = error as? ScreenVisionError { return known }
        let error = error as NSError
        if (error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue) || !CGPreflightScreenCaptureAccess() {
            ScreenRecordingAccess.markAsked()
            return .noPermission
        }
        return .failed(error.localizedDescription)
    }

    /// The displays' names by id, from AppKit (main thread).
    @MainActor static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber { names[number.uint32Value] = screen.localizedName }
        }
        return names
    }
}

/// The Screen Recording permission. macOS only tells whether it is granted; whether Nook has already asked (after which macOS
/// shows nothing more and only System Settings can turn it on) is remembered here.
enum ScreenRecordingAccess {
    static let askedKey = "nook.screenRecording.asked"
    static var granted: Bool { CGPreflightScreenCaptureAccess() }
    static func markAsked(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: askedKey) }
    static func state(_ defaults: UserDefaults = .standard) -> NookPermission.State {
        NookPermission.screenRecordingState(granted: granted, asked: defaults.bool(forKey: askedKey))
    }
    /// macOS's prompt, the first time; later calls show nothing. True when it is granted.
    @discardableResult static func request(_ defaults: UserDefaults = .standard) -> Bool {
        markAsked(defaults)
        return CGRequestScreenCaptureAccess()
    }
}

// MARK: - The files

/// Where screenshots go and how they are written: Nook's private temporary folder, like a pasted image, each file readable by the
/// user alone.
enum ScreenShotFile {
    static var folder: URL { URL(fileURLWithPath: "/tmp/nook-\(getuid())/images") }
    static let prefix = "pantalla-"
    /// A screenshot of text-heavy UI stays PNG (lossless, crisp letters, usually well under this). One that would be bigger (photos,
    /// video on screen) goes as JPEG instead, so it stays far below the 5 MB an image may weigh in Claude's API.
    static let pngLimit = 2_000_000
    static let jpegQuality = 0.85
    /// Screenshots older than this go when a new one is saved: with the toggle on, every message leaves one behind.
    static let keep: TimeInterval = 24 * 60 * 60

    /// The display's size in points, scaled down (never up) so its long side is at most `maxLongEdge`, in whole pixels.
    static func outputSize(points: CGSize, maxLongEdge: Int) -> (width: Int, height: Int) {
        let long = max(points.width, points.height)
        guard long > 0 else { return (1, 1) }
        let scale = min(1, CGFloat(maxLongEdge) / long)
        return (max(1, Int((points.width * scale).rounded())), max(1, Int((points.height * scale).rounded())))
    }

    /// The displays a choice takes, by id. "pointer" is the display the pointer is on (in global display coordinates, top left
    /// origin), else the main one; "main" the main one, else the first; "all" every one.
    static func chooseDisplays(_ displays: [(id: CGDirectDisplayID, bounds: CGRect)], choice: ScreenDisplayChoice, pointer: CGPoint?, main: CGDirectDisplayID) -> [CGDirectDisplayID] {
        let ids = displays.map(\.id)
        let primary = ids.contains(main) ? main : ids.first
        switch choice {
        case .all: return ids
        case .main: return primary.map { [$0] } ?? []
        case .pointer:
            if let pointer, let under = displays.first(where: { $0.bounds.contains(pointer) }) { return [under.id] }
            return primary.map { [$0] } ?? []
        }
    }

    /// The image as PNG, or as JPEG when the PNG would weigh more than `pngLimit` (whichever is smaller then).
    static func encode(_ image: CGImage, pngLimit: Int = pngLimit) -> (data: Data, mimeType: String, ext: String)? {
        let png = data(image, type: .png, options: [:])
        if let png, png.count <= pngLimit { return (png, "image/png", "png") }
        let jpeg = data(image, type: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: jpegQuality])
        if let jpeg, jpeg.count < (png?.count ?? .max) { return (jpeg, "image/jpeg", "jpg") }
        return png.map { ($0, "image/png", "png") }
    }

    private static func data(_ image: CGImage, type: UTType, options: [CFString: Any]) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// "pantalla-20261007-140322": a fixed format, whatever the user's locale.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return prefix + formatter.string(from: date)
    }

    /// Saves each picture in `folder`, named after `date` (and a number when the name is taken), and returns them. Also clears out
    /// screenshots older than `keep`.
    static func save(_ pictures: [CapturedDisplay], in folder: URL = folder, date: Date) throws -> [ScreenShot] {
        try prepare(folder)
        let base = stamp(date)
        var shots: [ScreenShot] = []
        for (index, picture) in pictures.enumerated() {
            guard let encoded = encode(picture.image) else { throw ScreenVisionError.failed("no se pudo convertir la imagen.") }
            let name = pictures.count > 1 ? "\(base)-\(index + 1)" : base
            let url = try write(encoded.data, named: name, ext: encoded.ext, in: folder)
            shots.append(ScreenShot(path: url.path, mimeType: encoded.mimeType, display: picture.name, width: picture.image.width, height: picture.image.height, date: date))
        }
        prune(folder, now: date)
        return shots
    }

    /// The folder exists, belongs to the user and is theirs alone, and so does the one it is in (a shared /tmp would otherwise let
    /// someone else put a folder or a link there first).
    static func prepare(_ folder: URL) throws {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ScreenVisionError.failed("no se pudo crear \(folder.path).") }
        for directory in [folder.deletingLastPathComponent(), folder] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                throw ScreenVisionError.failed("la carpeta temporal de Nook (\(directory.path)) no es privada; no se guardó la captura.")
            }
            if info.st_mode & 0o077 != 0 { chmod(directory.path, 0o700) }
        }
    }

    /// Writes a new file, never over an existing one nor through a link, readable by the user alone.
    static func write(_ data: Data, named name: String, ext: String, in folder: URL) throws -> URL {
        for attempt in 0..<100 {
            let url = folder.appendingPathComponent((attempt == 0 ? name : "\(name)-\(attempt + 1)") + "." + ext)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw ScreenVisionError.failed("no se pudo guardar \(url.lastPathComponent) (\(String(cString: strerror(errno)))).")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do { try handle.write(contentsOf: data) } catch {
                unlink(url.path)
                throw ScreenVisionError.failed("no se pudo guardar \(url.lastPathComponent).")
            }
            return url
        }
        throw ScreenVisionError.failed("no se pudo elegir un nombre para la captura.")
    }

    /// Removes this feature's screenshots (and only them) older than `keep`.
    static func prune(_ folder: URL, now: Date, keep: TimeInterval = keep) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let path = folder.appendingPathComponent(name).path
            guard let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date, now.timeIntervalSince(modified) > keep else { continue }
            try? manager.removeItem(atPath: path)
        }
    }
}

// MARK: - The model

/// Screen vision's state and its two ways in: the composer's toggle and Claude's tool. Everything published changes on the main
/// thread. Nothing reaches outside the process (no socket, no change to Claude's configuration) until `start()`, which only the
/// app does at launch: a model made by a test or a preview stays inert.
final class ScreenVision: ObservableObject {
    static let enabledKey = "nook.screenVision.enabled"
    static let attachKey = "nook.screenVision.attach"
    /// The long side of a saved screenshot, at most.
    static let maxLongEdge = 1920
    /// How long a capture may take before it counts as failed.
    static let captureTimeout: TimeInterval = 10

    /// Where Claude Code stands with the tool.
    enum Registration: Equatable {
        /// Off, and nothing registered (or not started yet).
        case idle
        /// Registering or removing; the words say which.
        case working(String)
        /// Registered in these configuration folders ("~/.claude", "~/.claude-work").
        case ready([String])
        /// It could not be done; the words say why and what to do.
        case failed(String)
    }

    /// The setting. On, the composer's toggle can attach the screen and Claude Code gets the `capture_screen` tool; off, neither,
    /// and the tool is taken out of Claude Code again.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            // Off also disarms the composer's toggle: turning the setting on again must not send the screen with the next message unasked.
            if !enabled { attachToMessages = false }
            scheduleRegistration()
        }
    }
    /// The composer's toggle: each message sent from Nook carries a fresh screenshot. Only counts while `enabled`.
    @Published var attachToMessages: Bool {
        didSet { if attachToMessages != oldValue { defaults.set(attachToMessages, forKey: Self.attachKey) } }
    }
    @Published private(set) var registration: Registration = .idle
    /// The tool was just added to some folder: Claude sessions already open there only see it after being restarted.
    @Published private(set) var needsClaudeRestart = false
    /// A message is waiting for its screenshot (the composer can show it, and sending again waits).
    @Published private(set) var capturing = false
    /// The latest capture, by either way in.
    @Published private(set) var lastCapture: ScreenVisionCapture?

    /// Both the setting and the toggle are on.
    var attachesToMessages: Bool { enabled && attachToMessages }

    private let defaults: UserDefaults
    private let capturer: ScreenCapturing
    private let registrar: ScreenVisionRegistering
    private let folder: URL
    private let relayPath: String
    private let ownPID: pid_t
    private let now: () -> Date
    private let timeout: TimeInterval
    private var live = false
    private var server: ScreenRelayServer?
    private var generation = 0
    private let registrationQueue = DispatchQueue(label: "dev.nook.screen-vision.registration", qos: .utility)

    init(defaults: UserDefaults = .standard, capturer: ScreenCapturing = SystemScreenCapturer(), registrar: ScreenVisionRegistering = ClaudeMCPRegistrar(),
         folder: URL = ScreenShotFile.folder, relayPath: String = ScreenRelay.path, ownPID: pid_t = getpid(), timeout: TimeInterval = ScreenVision.captureTimeout,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.capturer = capturer
        self.registrar = registrar
        self.folder = folder
        self.relayPath = relayPath
        self.ownPID = ownPID
        self.timeout = timeout
        self.now = now
        enabled = defaults.bool(forKey: Self.enabledKey)
        attachToMessages = defaults.bool(forKey: Self.attachKey)
    }

    deinit { server?.stop() }

    /// At launch: answers the tool's helper on the private socket (when `serving`), and makes sure the tool is still registered in
    /// every folder while the feature is on (a folder added since, or a helper that moved). Once.
    func start(serving: Bool = true) {
        precondition(Thread.isMainThread)
        guard !live else { return }
        live = true
        if serving {
            server = ScreenRelayServer(path: relayPath) { [weak self] request, reply in
                guard let self else { return reply(ScreenRelay.Response(error: "Nook se está cerrando.")) }
                self.answer(request, reply: reply)
            }
            if server == nil { NSLog("Nook: screen vision socket unavailable at \(relayPath)") }
        }
        if enabled { scheduleRegistration() }
    }

    /// Tries again what failed: registering while on, removing while off.
    func retryRegistration() {
        precondition(Thread.isMainThread)
        scheduleRegistration()
    }

    /// The restart notice was read.
    func dismissRestartNotice() { needsClaudeRestart = false }

    // MARK: Capturing

    /// Screenshots of the chosen displays without Nook's windows, saved in Nook's private folder. Throws `ScreenVisionError`
    /// (`.disabled` while the setting is off).
    @MainActor func capture(_ choice: ScreenDisplayChoice = .pointer, origin: ScreenVisionOrigin) async throws -> [ScreenShot] {
        guard enabled else { throw ScreenVisionError.disabled }
        let capturer = capturer, pid = ownPID
        let pictures = try await Self.within(timeout) {
            do { return try await capturer.capture(choice, excluding: pid, maxLongEdge: Self.maxLongEdge) }
            catch let error as ScreenVisionError { throw error }
            catch { throw ScreenVisionError.failed(error.localizedDescription) }
        }
        guard !pictures.isEmpty else { throw ScreenVisionError.noDisplay }
        let folder = folder, date = now()
        // Encoding and writing a large picture takes a moment: off the main thread.
        let shots = try await Task.detached(priority: .userInitiated) { try ScreenShotFile.save(pictures, in: folder, date: date) }.value
        lastCapture = ScreenVisionCapture(date: date, origin: origin, shots: shots)
        return shots
    }

    /// Whether the composer offers the toggle in a tab: the setting is on and an agent that opens images (Claude, Codex) runs there.
    func offersToggle(for agent: TerminalAgent?) -> Bool { enabled && agent != nil }

    /// Whether a message goes out with the screen: the setting and the toggle are on, an agent runs in the tab (Claude and Codex
    /// open an image they are given by path; a shell would run it as an argument), and the text is not one of the agent's commands
    /// ("/model", "!ls"), which a path at the end would change.
    func attaches(text: String, agent: TerminalAgent?) -> Bool {
        guard attachesToMessages, agent != nil else { return false }
        let first = text.first { !$0.isWhitespace }
        return first != "/" && first != "!"
    }

    /// The composer's send. Without the screen, `deliver` gets `files` at once (nothing changes). With it, the screen is captured
    /// first and `deliver` gets `files` and then the screenshot's path. A capture that fails sends nothing: `failed` gets the
    /// notice to show, and the composer gives the message back to the field, since Claude would not have seen the screen.
    func prepareMessage(files: [String], withScreen: Bool, deliver: @escaping ([String]) -> Void, failed: @escaping (String) -> Void) {
        guard withScreen else { return deliver(files) }
        capturing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let shots = try await self.capture(.pointer, origin: .composer)
                self.capturing = false
                deliver(files + shots.map(\.path))
            } catch {
                self.capturing = false
                failed(Self.notSent(because: error))
            }
        }
    }

    /// The notice for a message the composer kept because its screenshot failed.
    static func notSent(because error: Error) -> String {
        "No se envió el mensaje porque no se pudo adjuntar tu pantalla: \(error.localizedDescription) Tu mensaje sigue en el campo."
    }

    /// One request from the tool's helper: a capture for Claude, or the reason there is none.
    private func answer(_ request: ScreenRelay.Request, reply: @escaping (ScreenRelay.Response) -> Void) {
        guard request.action == ScreenRelay.Request.captureAction else { return reply(ScreenRelay.Response(error: "Nook no reconoce esa petición.")) }
        Task { @MainActor [weak self] in
            guard let self else { return reply(ScreenRelay.Response(error: "Nook se está cerrando.")) }
            do { reply(ScreenRelay.Response(shots: try await self.capture(request.display ?? .pointer, origin: .claude))) }
            catch { reply(ScreenRelay.Response(error: error.localizedDescription)) }
        }
    }

    /// `work`'s result, or `.timedOut` after `seconds`. A capture that never answers does not hold its caller: it is left behind.
    static func within<T>(_ seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let task = Task {
                do { let value = try await work(); if once.claim() { continuation.resume(returning: value) } }
                catch { if once.claim() { continuation.resume(throwing: error) } }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                if once.claim() { task.cancel(); continuation.resume(throwing: ScreenVisionError.timedOut) }
            }
        }
    }

    // MARK: Registration

    /// Registers or removes the tool to match `enabled`, off the main thread, one job after another. Only the latest job's outcome
    /// is shown: quick on, off, on ends registered and says so.
    private func scheduleRegistration() {
        guard live else { return }
        generation += 1
        let job = generation, wanted = enabled, registrar = registrar
        registration = .working(wanted ? "Añadiendo la herramienta a Claude Code…" : "Quitando la herramienta de Claude Code…")
        registrationQueue.async { [weak self] in
            let outcome = Result { wanted ? try registrar.register() : try registrar.unregister() }
            DispatchQueue.main.async {
                guard let self, self.generation == job else { return }
                switch outcome {
                case .success(let result) where wanted:
                    self.registration = .ready(result.folders)
                    if !result.added.isEmpty { self.needsClaudeRestart = true }
                case .success:
                    self.registration = .idle
                    self.needsClaudeRestart = false
                case .failure(let error):
                    self.registration = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// For a settings pane: what the registration state says, in a sentence.
    static func describe(_ registration: Registration) -> String {
        switch registration {
        case .idle: "Claude no tiene la herramienta para ver tu pantalla."
        case .working(let words): words
        case .ready(let folders):
            "Claude puede pedir una captura con la herramienta capture_screen (\(folders.joined(separator: " y ")))."
        case .failed(let reason): reason
        }
    }

    /// Claude Code reads its tools when a session starts.
    static let restartNote = "Las sesiones de Claude que ya estaban abiertas verán la herramienta al reiniciarlas (sal de claude y vuelve a abrirlo)."
}

/// True for the first caller only, from any thread (its lock makes it safe to share).
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
