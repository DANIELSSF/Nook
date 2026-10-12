import Foundation
import Darwin

// Claude Code's side of screen vision. Claude Code starts `nook-hook --mcp-screen` (the stable copy of Nook's executable) and
// speaks the Model Context Protocol with it: JSON-RPC 2.0, one message per line on stdin and stdout. Its one tool,
// `capture_screen`, does not capture anything itself (it runs as Terminal's child, under Terminal's permissions): it asks the
// running Nook over a private Unix socket, and turns the files Nook saved into the tool's image result.

// MARK: - The socket between the helper and Nook

/// One request line, one answer line, one connection each, in `/tmp/nook-<uid>/screen.sock`: the folder is the user's alone, the
/// socket too, and each side checks the other runs as the same user.
enum ScreenRelay {
    static var path: String { "/tmp/nook-\(getuid())/screen.sock" }
    /// The longest a line may be; anything longer is not one of these.
    static let maxLine = 1 << 20

    struct Request: Codable, Equatable {
        static let captureAction = "capture"
        var action = Request.captureAction
        var display: ScreenDisplayChoice?
    }

    /// The screenshots, or why there are none.
    struct Response: Codable, Equatable {
        var shots: [ScreenShot]?
        var error: String?
        init(shots: [ScreenShot]) { self.shots = shots }
        init(error: String) { self.error = error }
    }

    enum Failure: LocalizedError, Equatable {
        case notRunning
        case timedOut
        case untrusted
        case invalid
        /// Nook's own answer, in its words.
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "Nook no está abierto. Ábrelo y activa la visión de pantalla en sus ajustes para que Claude pueda ver tu pantalla."
            case .timedOut: "Nook no respondió a tiempo con la captura de pantalla."
            case .untrusted: "El canal de Nook no pertenece a tu usuario; no se pidió la captura."
            case .invalid: "Nook respondió algo que no se pudo leer."
            case .refused(let reason): reason
            }
        }
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// The helper's side: asks Nook for a capture and waits for the answer, up to `timeout`.
    static func request(_ request: Request, path: String = path, timeout: TimeInterval = 25) throws -> [ScreenShot] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.notRunning }
        defer { Darwin.close(fd) }
        setOptions(fd, timeout: timeout)
        var address = LocalSignalSocket.address(path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure.notRunning }
        guard peerIsUser(fd) else { throw Failure.untrusted }
        guard var line = encode(request) else { throw Failure.invalid }
        line.append(0x0A)
        guard writeAll(fd, line) else { throw Failure.notRunning }
        switch readLine(fd) {
        case .line(let data):
            guard let response = decode(Response.self, from: data) else { throw Failure.invalid }
            if let error = response.error { throw Failure.refused(error) }
            return response.shots ?? []
        case .timedOut: throw Failure.timedOut
        case .closed, .tooLong: throw Failure.invalid
        }
    }

    /// No SIGPIPE when the other side is gone, and no read or write that waits longer than `timeout`.
    static func setOptions(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    /// The process at the other end runs as this user.
    static func peerIsUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base + sent, raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    enum Read: Equatable { case line(Data), closed, timedOut, tooLong }

    /// Up to the first newline (left out).
    static func readLine(_ fd: Int32, limit: Int = maxLine) -> Read {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .closed
            }
            if count == 0 { return .closed }
            if let end = chunk[..<count].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[..<end])
                return .line(buffer)
            }
            buffer.append(contentsOf: chunk[..<count])
            if buffer.count > limit { return .tooLong }
        }
    }
}

/// Nook's side of the socket: accepts the helper's connections, reads its request and hands it to `handler`, which answers once,
/// from any thread. A connection from another user is closed unread; one whose answer never comes gets an error after `replyTimeout`.
final class ScreenRelayServer {
    typealias Handler = (ScreenRelay.Request, @escaping (ScreenRelay.Response) -> Void) -> Void

    private let path: String
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.nook.screen-relay", qos: .userInitiated)

    init?(path: String = ScreenRelay.path, replyTimeout: TimeInterval = 20, handler: @escaping Handler) {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Remove only a previous socket owned by this user in the private directory.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSocket,
           (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() { unlink(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = LocalSignalSocket.address(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { Darwin.close(fd); return nil }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                Self.serve(client, timeout: replyTimeout, handler: handler)
            }
        }
        reader.setCancelHandler { Darwin.close(fd) }
        source = reader
        reader.resume()
    }

    deinit { stop() }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        unlink(path)
    }

    private static func serve(_ client: Int32, timeout: TimeInterval, handler: @escaping Handler) {
        guard ScreenRelay.peerIsUser(client) else { Darwin.close(client); return }
        // The accepted socket may inherit the listener's non-blocking mode; its reads wait, up to the timeout.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        ScreenRelay.setOptions(client, timeout: 5)
        DispatchQueue.global(qos: .userInitiated).async {
            guard case .line(let data) = ScreenRelay.readLine(client, limit: 64 * 1024),
                  let request = ScreenRelay.decode(ScreenRelay.Request.self, from: data) else { Darwin.close(client); return }
            let once = OnceFlag()
            let reply: (ScreenRelay.Response) -> Void = { response in
                guard once.claim() else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    if var line = ScreenRelay.encode(response) { line.append(0x0A); _ = ScreenRelay.writeAll(client, line) }
                    Darwin.close(client)
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { reply(ScreenRelay.Response(error: ScreenRelay.Failure.timedOut.localizedDescription)) }
            handler(request, reply)
        }
    }
}

// MARK: - The MCP server

/// The protocol, without its pipes: one incoming message in, the reply out (nil for a notification). `capture` asks Nook (the
/// socket, in the helper); tests pass a fake.
final class ScreenVisionMCPServer {
    static let serverName = "nook-screen"
    static let toolName = "capture_screen"
    /// Newest first; a client asking for another gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let version = "1.0.0"
    /// The largest screenshot file the tool returns.
    static let maxImageBytes = 20 << 20

    typealias Capture = (ScreenDisplayChoice) throws -> [ScreenShot]

    private let capture: Capture
    private let folder: String
    private let read: (String) -> Data?

    init(capture: @escaping Capture = { try ScreenRelay.request(ScreenRelay.Request(display: $0)) },
         folder: String = ScreenShotFile.folder.path, read: @escaping (String) -> Data? = ScreenVisionMCPServer.readFile) {
        self.capture = capture
        self.folder = folder
        self.read = read
    }

    static let toolDescription = """
        Takes a screenshot of the user's Mac screen through the Nook app and returns it as an image, with a short text line naming \
        the display, the time and the saved file's path. Nook's own windows (its notch island and panels) are always left out of \
        the picture, so you see what is behind them. Use it when the user asks you to look at their screen, or when seeing what is \
        on it (an app, an error dialog, a design, a web page) would help. By default it captures the display under the mouse \
        pointer; pass display "main" for the main display or "all" for every display (one image each). It fails with an \
        explanation when Nook is not running, screen vision is turned off in Nook's settings, or Nook lacks the macOS Screen \
        Recording permission.
        """

    static var tool: [String: Any] {
        [
            "name": toolName,
            "title": "Capture screen",
            "description": toolDescription,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "display": [
                        "type": "string",
                        "enum": ScreenDisplayChoice.allCases.map(\.rawValue),
                        "description": "Which display to capture: \"pointer\" (the one under the mouse pointer, default), \"main\", or \"all\".",
                    ] as [String: Any],
                ] as [String: Any],
                "additionalProperties": false,
            ] as [String: Any],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ]
    }

    /// The reply line to one line from Claude Code, or nil when none is due (a notification, a blank line).
    func reply(to line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
            return Self.line(Self.error(NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = message as? [Any] {
            guard !batch.isEmpty else { return Self.line(Self.error(NSNull(), code: -32600, message: "Invalid Request")) }
            let replies = batch.compactMap { handle($0) }
            return replies.isEmpty ? nil : Self.line(replies)
        }
        return handle(message).flatMap(Self.line)
    }

    /// One message's reply. A message without an id is a notification and gets none, whatever it is.
    func handle(_ message: Any) -> [String: Any]? {
        guard let message = message as? [String: Any] else { return Self.error(NSNull(), code: -32600, message: "Invalid Request") }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response to a request of ours (this server sends none), or nothing at all.
            return id == nil || message["result"] != nil || message["error"] != nil ? nil : Self.error(id!, code: -32600, message: "Invalid Request")
        }
        guard let id, !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.result(id, [
                "protocolVersion": Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "title": "Nook", "version": Self.version],
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": [Self.tool]])
        case "tools/call":
            guard let name = params["name"] as? String, name == Self.toolName else {
                return Self.error(id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "")")
            }
            return Self.result(id, call(arguments: params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.error(id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// The tool's result: each screenshot as a line of text and its image. Anything that goes wrong is a result too, marked as an
    /// error, so Claude reads why.
    func call(arguments: [String: Any]) -> [String: Any] {
        var choice = ScreenDisplayChoice.pointer
        if let raw = arguments["display"] {
            guard let text = raw as? String, let chosen = ScreenDisplayChoice(rawValue: text) else {
                return Self.failure("El parámetro display debe ser \"pointer\", \"main\" o \"all\".")
            }
            choice = chosen
        }
        let shots: [ScreenShot]
        do { shots = try capture(choice) } catch { return Self.failure(error.localizedDescription) }
        guard !shots.isEmpty else { return Self.failure(ScreenVisionError.noDisplay.localizedDescription) }
        var content: [[String: Any]] = []
        for shot in shots {
            // Only Nook's own screenshots: an answer naming any other file is not read.
            guard isScreenshot(shot.path), let data = read(shot.path), !data.isEmpty, data.count <= Self.maxImageBytes else {
                return Self.failure("No se pudo leer la captura que guardó Nook (\(shot.path)).")
            }
            content.append(["type": "text", "text": Self.caption(shot)])
            content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": shot.mimeType])
        }
        return ["content": content, "isError": false]
    }

    /// "Pantalla «Pantalla integrada Retina», 14:03:22, 1512×982 px, sin las ventanas de Nook. Archivo: /tmp/…/pantalla-….png"
    static func caption(_ shot: ScreenShot) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "Pantalla «\(shot.display)», \(formatter.string(from: shot.date)), \(shot.width)×\(shot.height) px, sin las ventanas de Nook. Archivo: \(shot.path)"
    }

    func isScreenshot(_ path: String) -> Bool {
        let file = (path as NSString).standardizingPath, root = (folder as NSString).standardizingPath
        return file.hasPrefix(root + "/") && (file as NSString).deletingLastPathComponent == root
            && (file as NSString).lastPathComponent.hasPrefix(ScreenShotFile.prefix)
    }

    /// The file's bytes, never through a link.
    static func readFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd()
    }

    static func failure(_ text: String) -> [String: Any] { ["content": [["type": "text", "text": text]], "isError": true] }
    static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    static func error(_ id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// One line of JSON (no newline inside: JSON escapes those in strings).
    static func line(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

enum ScreenVisionMCP {
    /// `--mcp-screen`: the server on stdin and stdout until Claude Code closes them. Nothing but protocol messages ever goes to
    /// stdout (diagnostics would go to stderr).
    static func serveFromCLI() {
        // Claude gone mid-answer is a failed write, not the end of the process by signal.
        signal(SIGPIPE, SIG_IGN)
        let server = ScreenVisionMCPServer()
        while let line = readLine(strippingNewline: true) {
            let reply = autoreleasepool { server.reply(to: line) }
            guard let reply else { continue }
            guard (try? FileHandle.standardOutput.write(contentsOf: Data((reply + "\n").utf8))) != nil else { return }
        }
    }
}
