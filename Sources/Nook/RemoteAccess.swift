import AppKit
import Combine
import CryptoKit
import Network

// Nook Remote: a small web app Nook serves on the home Wi-Fi, so the user's phone can do what the island's conversation view does.
// The contract between this server and the page (Resources/remote/index.html) is docs/REMOTE_API.md.
//
// What the settings pane uses, and nothing more (everything else here is the server's own):
//
//   unlocked              the Remoto settings tab shows once unlocked (five taps on the version); kept across launches
//   unlock() / lock()     shows the tab for good / hides it again (and turns Nook Remote off)
//   status                .off · .starting · .on(url:port:) · .failed(Spanish sentence)
//   pairingURL            what the QR carries while on: http://<LAN IPv4>:<port>/pair?k=<key>. A key pairs one device: once it
//                         has, a new one takes its place here (the QR follows it live) and the old link pairs nothing
//   devices               the devices paired in this activation, most recently seen first ("iPhone · Safari", when last seen)
//   remove(_:)            forgets a device: its cookie opens nothing more and its open connections close at once
//   watching              a phone has the page open right now
//   start() / stop()      on: a new key every time, port 8765 (or the next free one up to 8775). Off: every connection closes and
//                         every device is forgotten
//
// The server is always off when Nook starts (nothing here is saved but `unlocked`), and it stops when Nook quits. It takes
// connections from the home network only and never from the Mac itself (`RemoteAddressPolicy`); a device pairs by opening the
// QR's link, which gives it its own cookie, and only that cookie opens the API (`RemoteRegistry`). What each call does is in
// RemoteRoutes.swift; the state and the conversation the phone reads are in RemoteState.swift and RemoteConversation.swift.

final class RemoteAccess: ObservableObject {
    // MARK: For the settings pane

    static let unlockedKey = "nook.remote.unlocked"
    /// The Remoto settings tab is there. Hidden until unlocked; once unlocked it stays.
    @Published private(set) var unlocked: Bool

    func unlock() {
        guard !unlocked else { return }
        unlocked = true
        defaults.set(true, forKey: Self.unlockedKey)
    }

    /// Hides the Remoto tab again, as before it was unlocked; Nook Remote goes off with it.
    func lock() {
        precondition(Thread.isMainThread)
        if status != .off { stop() }
        if unlocked { unlocked = false }
        defaults.set(false, forKey: Self.unlockedKey)
    }

    /// Forgets `device`: its cookie opens nothing from now on, and its connections (its event stream too) close at once. It can
    /// pair again with the QR.
    func remove(_ device: RemoteDevice) {
        precondition(Thread.isMainThread)
        registry.remove(id: device.id)
        uploads.forget(device: device.id)
        connectionLock.lock()
        let open = connectionsByDevice.removeValue(forKey: device.id) ?? []
        connectionLock.unlock()
        server?.close(connections: open)
    }

    enum Status: Equatable {
        case off
        /// Opening the port.
        case starting
        /// Listening: `url` is the page's address on the home network ("http://192.168.1.20:8765").
        case on(url: URL, port: Int)
        /// It could not start, or stopped working; the words say why, for the user.
        case failed(String)

        var isOn: Bool { if case .on = self { true } else { false } }
    }

    @Published private(set) var status: Status = .off
    /// The QR's link while on: the page's address, `/pair` and this activation's key. Nil while off.
    @Published private(set) var pairingURL: URL?
    @Published private(set) var devices: [RemoteDevice] = []
    /// At least one phone has the page open (its event stream). Nook then reads the tabs as fully as with the island open.
    @Published private(set) var watching = false

    /// Turns Nook Remote on: a new pairing key, the first free port of `ports`, and the address the QR names. Nothing happens
    /// while it is starting or on.
    func start() {
        precondition(Thread.isMainThread)
        switch status {
        case .starting, .on: return
        case .off, .failed: break
        }
        guard model != nil else { status = .failed("Nook se está cerrando."); return }
        guard let home = policy.currentHome() else {
            status = .failed("Este Mac no está conectado a una red local. Conéctalo a tu Wi-Fi y vuelve a intentarlo.")
            return
        }
        let address = home.address
        self.home = home
        generation += 1
        let generation = generation
        let key = RemoteToken.make()
        pairingKey = key
        registry.reset(key: key)
        status = .starting
        let server = RemoteServer(policy: policy, bodyPolicy: { [weak self] head, peer in
            self?.bodyDecision(for: head, from: peer) ?? .refuse(.error(503, "Nook Remoto está apagado."))
        }) { [weak self] request, peer, reply in
            guard let self else { return reply(.response(.error(503, "Nook Remoto está apagado."))) }
            self.handle(request, from: peer, reply: reply)
        }
        server.onBroken = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.shutDown(.failed("Nook Remoto dejó de funcionar: \(message) Vuelve a activarlo."))
            }
        }
        self.server = server
        server.start(ports: ports) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                switch result {
                case .success(let port):
                    self.port = port
                    self.announce(address: address, port: port)
                    self.watchNetwork(generation: generation)
                case .failure(.portsBusy):
                    let first = self.ports.first.map(String.init) ?? "", last = self.ports.last.map(String.init) ?? ""
                    self.shutDown(.failed("Los puertos \(first) a \(last) de este Mac están ocupados por otras apps. Ciérralas y vuelve a intentarlo."))
                case .failure(.failed(let reason)):
                    self.shutDown(.failed("No se pudo activar Nook Remoto: \(reason)"))
                }
            }
        }
    }

    /// Turns Nook Remote off: the port closes, every connection and event stream ends, and every device is forgotten (the next
    /// activation has a new key, so their cookies open nothing).
    func stop() {
        precondition(Thread.isMainThread)
        shutDown(.off)
    }

    /// The cookie a paired device carries.
    static let cookieName = "nook_remote"

    // MARK: Configuration

    /// Who may connect. Nook's own is the home network only; tests pass one that lets this Mac's loopback in, which only a test run
    /// can have (`RemoteAddressPolicy`). Set before `start`.
    var policy: RemoteAddressPolicy
    /// The ports tried in order.
    var ports: [UInt16] = Array(8765...8775)
    /// Where the page comes from.
    var page: RemotePageSource = .bundle
    /// Where the page's own errors are written (`POST /api/log`).
    var logURL = RemoteLog.url
    /// Where the phone's images are written: the folder of the island's pasted images and screenshots (`ScreenShotFile.folder`).
    var imagesFolder = ScreenShotFile.folder
    /// How long a change of network is given to settle before Nook Remote checks it is still on its home network.
    var networkSettle: TimeInterval = 3
    /// Whether macOS lets Nook record the screen: the system's preflight, which never asks (tests pass their own).
    var recordingGranted: () -> Bool = { ScreenRecordingAccess.granted }
    /// How many pictures of the model the phones get a second, at most.
    static let snapshotInterval: TimeInterval = 0.2

    // MARK: Inside

    weak var model: AppModel?
    private let defaults: UserDefaults
    let registry = RemoteRegistry()
    let broadcaster = RemoteBroadcaster()
    let logLimiter = RemoteLogLimiter()
    /// The images each device sent and has not attached to a message yet, and how many it sent lately (`POST /api/upload`).
    let uploads = RemoteUploads()
    let uploadGauge = RemoteUploadGauge()
    private(set) var server: RemoteServer?
    private(set) var port = 0
    private var pairingKey: String?
    /// The home network Nook Remote was turned on in (`networkChanged`).
    private var home: RemoteHome?
    private var generation = 0
    private var pathMonitor: NWPathMonitor?
    private var subscriptions: [AnyCancellable] = []
    private var sessionSubscriptions: [AnyCancellable] = []
    private var snapshotPending = false
    private var lastSnapshot = Date.distantPast
    private var quitObserver: NSObjectProtocol?
    /// Which connections each device's requests came on (`RemotePeer.connection`), so removing it closes them; from any thread.
    private let connectionLock = NSLock()
    private var connectionsByDevice: [String: Set<Int>] = [:]
    private var recordingAllowed: (value: Bool, at: Date)?
    /// The Mac's name, read once (`RemoteSnapshot.macName`).
    private(set) lazy var macName = RemoteSnapshot.macName()

    init(model: AppModel?, defaults: UserDefaults, policy: RemoteAddressPolicy = .homeNetwork()) {
        self.model = model
        self.defaults = defaults
        self.policy = policy
        unlocked = defaults.bool(forKey: Self.unlockedKey)
        registry.onChange = { [weak self] devices in
            DispatchQueue.main.async { self?.devices = devices }
        }
        // A key that paired a device is used up: the QR shows the next one at once.
        registry.onKey = { [weak self] key in
            DispatchQueue.main.async {
                guard let self, self.pairingKey != nil, self.registry.currentKey == key else { return }
                self.pairingKey = key
                if case .on(let url, _) = self.status { self.pairingURL = URL(string: url.absoluteString + "/pair?k=" + key) }
            }
        }
        broadcaster.onCount = { [weak self] count in
            DispatchQueue.main.async { self?.streamsChanged(count) }
        }
        // Nothing of it outlives Nook.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    deinit {
        server?.stop()
        pathMonitor?.cancel()
        broadcaster.closeAll()
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    private func shutDown(_ next: Status) {
        generation += 1
        server?.stop()
        server = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        broadcaster.closeAll()
        registry.reset(key: nil)
        logLimiter.reset()
        uploads.forget()
        uploadGauge.reset()
        connectionLock.lock(); connectionsByDevice = [:]; connectionLock.unlock()
        pairingKey = nil
        pairingURL = nil
        home = nil
        port = 0
        devices = []
        streamsChanged(0)
        if status != next { status = next }
    }

    /// The page's address and the QR's link, for `address`.
    private func announce(address: RemoteIP, port: Int) {
        let host = address.isV4 ? address.description : "[\(address.description)]"
        guard let url = URL(string: "http://\(host):\(port)"), let key = pairingKey else { return }
        let next = Status.on(url: url, port: port)
        if status != next { status = next }
        let link = URL(string: url.absoluteString + "/pair?k=" + key)
        if pairingURL != link { pairingURL = link }
    }

    /// The Mac's addresses are read again when its network changes (`networkChanged`).
    private func watchNetwork(generation: Int) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.networkChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.nook.remote.network", qos: .utility))
        pathMonitor = monitor
    }

    /// The network may have changed: once it settled (a Wi-Fi renewing its lease drops its address for a moment), Nook Remote stays
    /// on only on the home network it was turned on in, the same interface, address and router. Anywhere else (another Wi-Fi, a
    /// café's, no network) it goes off: its address, its QR and its devices belong to that network. Main thread.
    func networkChanged() {
        guard status.isOn else { return }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + networkSettle) { [weak self] in
            guard let self, self.generation == generation, self.status.isOn, let home = self.home else { return }
            self.policy.refresh()
            guard home.isSameNetwork(as: self.policy.currentHome()) else {
                return self.shutDown(.failed("La red de este Mac cambió y Nook Remoto se apagó. Vuelve a activarlo cuando estés en tu Wi-Fi de casa."))
            }
        }
    }

    // MARK: Following the model

    /// The phones' streams opened or closed: while any is open, every change of the model brings a new picture of it (at most
    /// `snapshotInterval` apart), and Nook reads the tabs as fully as with the island open (`AppModel.remoteWatching`).
    private func streamsChanged(_ count: Int) {
        let now = count > 0
        if watching != now { watching = now }
        if model?.remoteWatching != now { model?.remoteWatching = now }
        if now, subscriptions.isEmpty, let model {
            subscriptions = [
                model.objectWillChange.sink { [weak self] _ in self?.scheduleSnapshot() },
                model.screenVision.objectWillChange.sink { [weak self] _ in self?.scheduleSnapshot() },
                // Each tab announces its own changes; the list is followed as tabs come and go.
                model.$sessions.sink { [weak self] sessions in self?.follow(sessions) },
            ]
        } else if !now {
            subscriptions = []
            sessionSubscriptions = []
        }
        // A phone that just opened the stream gets everything with the next picture.
        if now { scheduleSnapshot() }
    }

    private func follow(_ sessions: [TerminalSession]) {
        sessionSubscriptions = sessions.map { $0.objectWillChange.sink { [weak self] _ in self?.scheduleSnapshot() } }
        scheduleSnapshot()
    }

    /// A picture of the model soon: right after the change being announced (objectWillChange comes before it), and never sooner
    /// than `snapshotInterval` after the last.
    func scheduleSnapshot() {
        guard server != nil, watching, !snapshotPending else { return }
        snapshotPending = true
        let wait = max(0, Self.snapshotInterval - Date().timeIntervalSince(lastSnapshot))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.snapshotPending = false
            guard self.server != nil, self.watching, let frame = self.frame() else { return }
            self.lastSnapshot = Date()
            self.broadcaster.publish(frame)
        }
    }

    /// A picture of the model now. Main thread.
    func frame() -> RemoteFrame? {
        guard let model else { return nil }
        return RemoteSnapshot.frame(of: model, screenAvailable: screenAvailable(model), macName: macName)
    }

    /// The screen can go with messages: screen vision is on (Ajustes → Pantalla) and macOS lets Nook record the screen. For the
    /// state the permission is read every few seconds at most; `fresh` reads it now (a message about to go). Only the system's
    /// preflight is asked: nothing the phone does ever brings up macOS's permission dialog.
    func screenAvailable(_ model: AppModel, fresh: Bool = false) -> Bool {
        guard model.screenVision.enabled else { return false }
        if !fresh, let known = recordingAllowed, Date().timeIntervalSince(known.at) < 5 { return known.value }
        let allowed = recordingGranted()
        recordingAllowed = (allowed, Date())
        return allowed
    }

    /// For tests: the key that pairs now.
    var currentPairingKey: String? { registry.currentKey }

    /// A request from `device` came on connection `connection` from `address` (server's queue): removing the device closes it, and
    /// the address gets a paired device's room on the server (`RemoteServer.trust`).
    func note(_ device: RemoteDevice, connection: Int, address: RemoteIP) {
        connectionLock.lock()
        var open = connectionsByDevice[device.id] ?? []
        open.insert(connection)
        // Numbers of connections long closed are of no use; a device never has this many open.
        if open.count > 64 { open = Set(open.sorted().suffix(32)) }
        connectionsByDevice[device.id] = open
        connectionLock.unlock()
        server?.trust(address)
    }
}

// MARK: - The page

/// Where the page's files come from. Only files of that one folder, by a plain name, are ever served: never a path.
enum RemotePageSource {
    /// The app's `Contents/Resources/remote/`; in a debug build run from the package (`swift run`), also `Resources/remote/` of the
    /// working copy.
    case bundle
    case directory(URL)
    /// Files in memory (tests).
    case files([String: Data])

    static let maxSize = 5 * 1024 * 1024

    /// The file `name` (index.html, app.js…), or nil when there is none or the name is not a plain file name.
    func file(_ name: String) -> Data? {
        guard Self.isPlainName(name) else { return nil }
        switch self {
        case .files(let files): return files[name]
        case .directory(let folder): return Self.read(folder.appendingPathComponent(name))
        case .bundle:
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("remote")
            #if DEBUG
            // Run from the package (`swift run`), the working copy's page. A release build serves the app's own copy only.
            let folders = [bundled, URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/remote")].compactMap { $0 }
            #else
            let folders = [bundled].compactMap { $0 }
            #endif
            for folder in folders { if let data = Self.read(folder.appendingPathComponent(name)) { return data } }
            return nil
        }
    }

    static func isPlainName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$"#, options: .regularExpression) != nil && !name.contains("..")
    }

    /// A regular file, never through a link, not too big.
    static func read(_ url: URL, limit: Int = maxSize) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= limit else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// The hashes of a page's inline scripts as a Content-Security-Policy names them ("sha256-<base64>"), in order: the text
    /// between each `<script>` without a `src` and its `</script>`, with its line breaks as the browser reads them (CR LF and CR
    /// become LF).
    static func scriptHashes(in html: Data) -> [String] {
        let text = String(decoding: html, as: UTF8.self)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return inlineScript.matches(in: text, range: whole).compactMap { match in
            let attributes = (text as NSString).substring(with: match.range(at: 1))
            guard attributes.range(of: #"\bsrc\s*="#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            let body = (text as NSString).substring(with: match.range(at: 2)).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            return "sha256-" + Data(SHA256.hash(data: Data(body.utf8))).base64EncodedString()
        }
    }
    private static let inlineScript = try! NSRegularExpression(pattern: #"<script\b([^>]*)>([\s\S]*?)</script\s*>"#, options: [.caseInsensitive])

    /// The type a file is served as, by its extension; nil for any other kind of file (not served).
    static func contentType(_ name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json; charset=utf-8"
        case "webmanifest": "application/manifest+json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        default: nil
        }
    }
}
