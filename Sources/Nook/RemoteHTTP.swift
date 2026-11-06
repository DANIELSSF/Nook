import Foundation
import Network

// Nook Remote's server: plain HTTP/1.1 over TCP on the home network, on Network.framework, written by hand because it needs very
// little: a request line, headers, a body of known length (no chunked uploads), keep-alive, and Server-Sent Events. Everything it
// reads has a size cap and a time limit, and it holds a bounded number of connections; what a request may do is decided elsewhere
// (`RemoteAccess.handle`), and who may connect at all here, from the peer's address, before a byte is read
// (`RemoteAddressPolicy.verdict`).
//
//   RemoteRequest / RemoteResponse   one exchange
//   RemoteHTTPParser                 bytes → a request, or why not (pure, so it is tested without a socket)
//   RemoteServer                     the listener (ports 8765…8775, the first free one), its connections and their limits
//   RemoteConnection                 one connection: requests one after another, then perhaps an event stream

// MARK: - Exchange

struct RemoteRequest {
    var method: String
    /// The path, without the query ("/api/conversation").
    var path: String
    var query: [String: String] = [:]
    /// Lowercased names.
    var headers: [String: String] = [:]
    var body = Data()
    /// The client keeps the connection for another request.
    var keepAlive = true

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct RemoteResponse {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()
    /// The connection closes after this answer, whatever the client asked.
    var closes = false

    /// Every answer says this much: nothing is cached unless it says otherwise, nothing is sniffed, framed or sent as a referrer.
    static let commonHeaders: [(String, String)] = [
        ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
    ]

    static func json(_ status: Int, _ value: RemoteJSON) -> RemoteResponse {
        RemoteResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")], body: value.data)
    }

    /// `{"ok": true}` and the call's own fields.
    static func ok(_ fields: [(String, RemoteJSON)] = []) -> RemoteResponse { json(200, .object([("ok", .bool(true))] + fields)) }

    /// `{"error": "…"}`: a sentence in Spanish for the user, and any other field the call names.
    static func error(_ status: Int, _ message: String, _ fields: [(String, RemoteJSON)] = []) -> RemoteResponse {
        json(status, .object([("error", .string(message))] + fields))
    }

    /// A small page of its own, for what a browser opens directly (a wrong pairing link, the page opened on the Mac).
    static func page(_ status: Int, title: String, message: String) -> RemoteResponse {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let html = """
            <!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\
            <title>\(escaped(title))</title><style>body{font:17px -apple-system,system-ui,sans-serif;background:#000;color:#eee;margin:0;padding:48px 24px;}\
            h1{font-size:20px;margin:0 0 12px;}p{color:#bbb;line-height:1.45;margin:0;}</style></head>\
            <body><h1>\(escaped(title))</h1><p>\(escaped(message))</p></body></html>
            """
        return RemoteResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")], body: Data(html.utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"; case 303: "See Other"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 405: "Method Not Allowed"; case 408: "Request Timeout"; case 409: "Conflict"; case 413: "Content Too Large"; case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"; case 431: "Request Header Fields Too Large"; case 500: "Internal Server Error"; case 501: "Not Implemented"
        case 502: "Bad Gateway"; case 503: "Service Unavailable"; case 504: "Gateway Timeout"
        default: "Status"
        }
    }

    /// The bytes on the wire.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in Self.commonHeaders + headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Parsing

enum RemoteHTTPParser {
    /// The request line and headers together, at most.
    static let maxHead = 16 * 1024
    static let maxBody = 64 * 1024
    static let maxHeaders = 64
    static let maxTarget = 4096

    enum Outcome {
        /// More bytes are needed.
        case incomplete
        /// A whole request, and how many bytes of the buffer it took.
        case request(RemoteRequest, consumed: Int)
        /// Not a request this server takes: answer with this status (and close).
        case invalid(Int)
        /// A head whose body is longer than `maxBody` and than what was allowed: someone must decide whether to read it
        /// (`RemoteBodyDecision`) before a byte more is kept. `request` has no body yet.
        case large(RemoteRequest, length: Int)
    }

    private static let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    /// `allowance`: a body this long may be read (`RemoteBodyDecision.large`); without it, `maxBody` at most.
    static func parse(_ buffer: Data, allowance: Int? = nil) -> Outcome {
        let bytes = [UInt8](buffer.prefix(maxHead + terminator.count))
        guard let headEnd = find(terminator, in: bytes) else { return buffer.count > maxHead ? .invalid(431) : .incomplete }
        guard headEnd <= maxHead else { return .invalid(431) }
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, requestLine.utf8.count <= maxTarget + 32 else { return .invalid(400) }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return .invalid(400) }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return .invalid(400) }
        guard target.hasPrefix("/"), target.utf8.count <= maxTarget, !target.contains(where: { $0.isWhitespace || !$0.isASCII }) else { return .invalid(400) }
        guard lines.count <= maxHeaders else { return .invalid(431) }
        var headers: [String: String] = [:]
        for line in lines {
            // A folded header (a line starting with a space) is obsolete and has fooled parsers before: refused.
            guard let colon = line.firstIndex(of: ":"), let first = line.first, first != " ", first != "\t", !line.contains("\n"), !line.contains("\r") else { return .invalid(400) }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.!#$%&'*+^`|~".contains($0)) }) else { return .invalid(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let existing = headers[name] {
                // Two Hosts or two lengths are how a request smuggles another past a proxy; nothing legitimate sends them.
                if name == "host" || name == "content-length" { return .invalid(400) }
                headers[name] = existing + (name == "cookie" ? "; " : ", ") + value
            } else { headers[name] = value }
        }
        guard headers["transfer-encoding"] == nil else { return .invalid(501) }
        var length = 0
        if let declared = headers["content-length"] {
            guard !declared.isEmpty, declared.count <= 9, declared.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(declared) else { return .invalid(400) }
            length = value
        }
        let (path, query) = split(target)
        let connection = headers["connection"]?.lowercased() ?? ""
        let keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
        var request = RemoteRequest(method: method, path: path, query: query, headers: headers, keepAlive: keepAlive)
        // A body longer than the usual is read only once it was allowed, and never beyond what was.
        if length > maxBody, length != allowance { return .large(request, length: length) }
        let bodyStart = headEnd + terminator.count
        guard buffer.count >= bodyStart + length else { return .incomplete }
        let start = buffer.startIndex
        request.body = buffer.subdata(in: (start + bodyStart)..<(start + bodyStart + length))
        return .request(request, consumed: bodyStart + length)
    }

    /// "/api/conversation?tab=a%20b&before=10" → ("/api/conversation", ["tab": "a b", "before": "10"]).
    static func split(_ target: String) -> (String, [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ text: Substring) -> String? { String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
            guard let name = decode(parts[0]), !name.isEmpty else { continue }
            query[name] = parts.count == 2 ? decode(parts[1]) ?? "" : ""
        }
        return (String(target[..<mark]), query)
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        outer: for index in 0...(bytes.count - needle.count) {
            for offset in needle.indices where bytes[index + offset] != needle[offset] { continue outer }
            return index
        }
        return nil
    }
}

// MARK: - Server

/// How a request is answered: once, with a response, or by turning its connection into an event stream.
enum RemoteReply {
    case response(RemoteResponse)
    /// Server-Sent Events: the connection sends the stream's headers and is handed over, as an `RemoteEventSink`, to whoever
    /// writes the events.
    case stream((RemoteEventSink) -> Void)
}

/// Where a stream's events go: a connection, or a test's recorder. Callable from any thread.
protocol RemoteEventSink: AnyObject {
    func write(_ data: Data)
    func close()
    /// Called once, from any thread, when the stream is over (the phone left, a write failed, or `close`).
    var onClose: (() -> Void)? { get set }
}

/// What to do with a request whose body is longer than the usual 64 KB, decided from its head alone, before the body is read.
enum RemoteBodyDecision {
    /// Read it: up to `limit` bytes, the whole request within `timeout`. `release` runs once, when the request was answered or the
    /// connection ended.
    case large(limit: Int, timeout: TimeInterval, release: () -> Void)
    /// Answer this at once and close; the body is never read.
    case refuse(RemoteResponse)
}

/// Where a request comes from, as the server saw it when the connection opened.
struct RemotePeer {
    var address: RemoteIP
    var verdict: RemoteAddressPolicy.Verdict
    /// The port the server listens on (a request's Host must name it).
    var port: Int
    /// The connection's number on its server (`RemoteServer.close(connections:)`).
    var connection = 0
}

final class RemoteServer: @unchecked Sendable {
    typealias Handler = (RemoteRequest, RemotePeer, @escaping (RemoteReply) -> Void) -> Void
    /// Decides on a body longer than the usual (`RemoteBodyDecision`), on the server's queue.
    typealias BodyPolicy = (RemoteRequest, RemotePeer) -> RemoteBodyDecision

    enum StartError: Error, Equatable {
        /// Every port asked for is taken.
        case portsBusy
        case failed(String)
    }

    /// Connections open at once, from everyone together and from one address. An address no paired device has used lately gets
    /// fewer, and may open only a few a second: a couple of devices on the network can't take every connection from the phone.
    static let maxConnections = 32
    static let maxPerPeer = 12
    static let maxPerStranger = 4
    /// New connections an address may open in `acceptWindow`: a paired device, and any other.
    static let acceptsPerWindow = 60, strangerAcceptsPerWindow = 12
    static let acceptWindow: TimeInterval = 10
    /// How long an address stays trusted after a request with a paired device's cookie.
    static let trustFor: TimeInterval = 10 * 60

    let queue = DispatchQueue(label: "dev.nook.remote.server", qos: .userInitiated)
    private let policy: RemoteAddressPolicy
    private let handler: Handler
    private let bodyPolicy: BodyPolicy
    private var listener: NWListener?
    /// The listener being opened, not yet listening.
    private var opening: NWListener?
    private var connections: [ObjectIdentifier: RemoteConnection] = [:]
    private(set) var port: Int = 0
    private var stopped = false
    private var serial = 0
    /// Addresses a paired device used, and when they last did.
    private var trusted: [RemoteIP: Date] = [:]
    /// When each address opened its latest connections.
    private var accepted: [RemoteIP: [Date]] = [:]
    /// The listener broke after it was listening (on the server's queue): Nook Remote is off from then on.
    var onBroken: ((String) -> Void)?

    /// `bodyPolicy`: what to do with a body longer than 64 KB; without one, it is refused (413).
    init(policy: RemoteAddressPolicy, bodyPolicy: @escaping BodyPolicy = { _, _ in .refuse(.error(413, "La petición es demasiado grande.")) }, handler: @escaping Handler) {
        self.policy = policy
        self.bodyPolicy = bodyPolicy
        self.handler = handler
    }

    /// Listens on the first of `ports` that is free. `completion` runs on the server's queue, once.
    func start(ports: [UInt16], completion: @escaping (Result<Int, StartError>) -> Void) {
        queue.async { self.listen(ports, at: 0, completion: completion) }
    }

    private func listen(_ ports: [UInt16], at index: Int, completion: @escaping (Result<Int, StartError>) -> Void) {
        guard !stopped else { return }
        guard index < ports.count, let port = NWEndpoint.Port(rawValue: ports[index]) else { return completion(.failure(.portsBusy)) }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // A phone that went away without closing (out of the Wi-Fi, asleep) is noticed within a minute, not after TCP's own hours.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Wi-Fi and wired Ethernet only: never AWDL, the cellular radio, a VPN's tunnel (Tailscale, a company's: "other"), nor this
        // Mac's loopback (which tests alone may use, `RemoteAddressPolicy.allowsLoopback`).
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = policy.allowsLoopback ? [.cellular, .other] : [.cellular, .other, .loopback]
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: port) } catch {
            return listen(ports, at: index + 1, completion: completion)
        }
        opening = listener
        var reported = false
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            if reported {
                if case .failed(let error) = state, self.listener === listener, !self.stopped { self.onBroken?(error.localizedDescription) }
                return
            }
            switch state {
            case .ready:
                reported = true
                self.opening = nil
                // Turned off while it was opening: it closes again at once.
                guard !self.stopped else { listener?.cancel(); return }
                self.listener = listener
                self.port = Int(ports[index])
                completion(.success(Int(ports[index])))
            case .failed(let error), .waiting(let error):
                let taken: Bool
                if case .posix(let code) = error { taken = code == .EADDRINUSE || code == .EACCES } else { taken = false }
                // Waiting for the network to come back is not failing: the listener is ready once it does.
                if case .waiting = state, !taken { return }
                reported = true
                self.opening = nil
                listener?.cancel()
                if taken { self.listen(ports, at: index + 1, completion: completion) } else { completion(.failure(.failed(error.localizedDescription))) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    /// Closes the listener and every connection, streams included. For good: a server is never started again.
    func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.opening?.cancel()
            self.opening = nil
            let open = Array(self.connections.values)
            self.connections = [:]
            open.forEach { $0.close() }
        }
    }

    private func accept(_ connection: NWConnection) {
        // Who it is decides before anything is read: from outside the home network, nothing at all.
        guard !stopped, let address = RemoteIP(endpoint: connection.endpoint) else { connection.cancel(); return }
        let verdict = policy.verdict(for: address)
        guard verdict != .outside, connections.count < Self.maxConnections, admits(address) else { connection.cancel(); return }
        serial += 1
        let peer = RemotePeer(address: address, verdict: verdict, port: port, connection: serial)
        let served = RemoteConnection(connection, peer: peer, queue: queue, bodyPolicy: bodyPolicy, handler: handler)
        let id = ObjectIdentifier(served)
        connections[id] = served
        served.onEnd = { [weak self] in self?.connections[id] = nil }
        served.start()
    }

    /// Whether `address` may open one more connection now (and counts it): fewer at once and fewer a second for an address no paired
    /// device used lately.
    private func admits(_ address: RemoteIP, now: Date = Date()) -> Bool {
        if let since = trusted[address], now.timeIntervalSince(since) > Self.trustFor { trusted[address] = nil }
        let known = trusted[address] != nil
        let open = connections.values.filter { $0.peer.address == address }.count
        guard open < (known ? Self.maxPerPeer : Self.maxPerStranger) else { return false }
        var recent = (accepted[address] ?? []).filter { now.timeIntervalSince($0) < Self.acceptWindow }
        guard recent.count < (known ? Self.acceptsPerWindow : Self.strangerAcceptsPerWindow) else { accepted[address] = recent; return false }
        recent.append(now)
        accepted[address] = recent
        // The table of addresses never outgrows what a home network has.
        if accepted.count > 256 { accepted = accepted.filter { _, times in times.contains { now.timeIntervalSince($0) < Self.acceptWindow } } }
        return true
    }

    /// A paired device's cookie came from `address`: it gets a paired device's room for a while. From any thread.
    func trust(_ address: RemoteIP) {
        queue.async {
            if self.trusted[address] == nil, self.trusted.count > 64 { self.trusted = self.trusted.filter { Date().timeIntervalSince($0.value) < Self.trustFor } }
            self.trusted[address] = Date()
        }
    }

    /// Closes the connections with these numbers (`RemotePeer.connection`), event streams included. From any thread.
    func close(connections ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        queue.async {
            for connection in self.connections.values where ids.contains(connection.peer.connection) { connection.close() }
        }
    }
}

// MARK: - Connection

/// One client connection, on the server's queue. Requests are read and answered one at a time (nothing more is read while one is
/// answered); a request must arrive whole within `requestTimeout`, and a connection kept alive closes after `idleTimeout` without
/// one. An event stream has no timeout of its own: TCP's keepalive and the stream's pings find a phone that is gone.
final class RemoteConnection: RemoteEventSink, @unchecked Sendable {
    static let requestTimeout: TimeInterval = 10
    static let idleTimeout: TimeInterval = 30
    /// Requests on one connection, at most.
    static let maxRequests = 200
    /// Bytes a stream may have waiting to be written before the phone is taken for gone.
    static let maxQueued = 8 * 1024 * 1024

    let peer: RemotePeer
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: RemoteServer.Handler
    private let bodyPolicy: RemoteServer.BodyPolicy
    private var buffer = Data()
    /// The body the request being read may have beyond the usual, once allowed, and what to run when it is done with.
    private var allowance: Int?
    private var releaseBody: (() -> Void)?
    private var handling = false
    private var streaming = false
    private var closed = false
    private var served = 0
    private var queued = 0
    private var timer: DispatchWorkItem?
    /// The server's: the connection is over (on the server's queue).
    var onEnd: (() -> Void)?
    /// The stream's reader's (`RemoteEventSink`), set from its own queue: one set after the connection ended is called at once, so a
    /// phone that left before its stream was taken in is never counted as watching.
    var onClose: (() -> Void)? {
        get { closeLock.lock(); defer { closeLock.unlock() }; return closeHandler }
        set {
            closeLock.lock()
            guard !ended else { closeLock.unlock(); newValue?(); return }
            closeHandler = newValue
            closeLock.unlock()
        }
    }
    private let closeLock = NSLock()
    private var closeHandler: (() -> Void)?
    private var ended = false

    init(_ connection: NWConnection, peer: RemotePeer, queue: DispatchQueue, bodyPolicy: @escaping RemoteServer.BodyPolicy, handler: @escaping RemoteServer.Handler) {
        self.connection = connection
        self.peer = peer
        self.queue = queue
        self.bodyPolicy = bodyPolicy
        self.handler = handler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        arm(Self.requestTimeout)
        receive()
    }

    private func arm(_ seconds: TimeInterval) {
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.handling, !self.streaming else { return }
            self.finish()
        }
        timer = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if self.streaming {
                // The phone has nothing to say on a stream; it closing (or talking) ends it.
                self.finish()
                return
            }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if complete || error != nil {
                // Half-closed after a whole request: it is still answered (its answer closes the connection).
                if !self.handling { self.process(lastBytes: true) }
                return
            }
            self.process(lastBytes: false)
        }
    }

    private func process(lastBytes: Bool) {
        guard !handling, !closed else { return }
        switch RemoteHTTPParser.parse(buffer, allowance: allowance) {
        case .incomplete:
            if lastBytes || buffer.count > RemoteHTTPParser.maxHead + max(RemoteHTTPParser.maxBody, allowance ?? 0) { return finish() }
            receive()
        case .invalid(let status):
            respond(RemoteResponse.error(status, "La petición no es válida."), keepAlive: false)
        case .large(let head, let length):
            // Decided once, from the head: refused, nothing more is read; allowed, the whole request has the route's own time.
            switch bodyPolicy(head, peer) {
            case .refuse(var response):
                response.closes = true
                respond(response, keepAlive: false)
            case .large(let limit, let timeout, let release):
                guard length <= limit else {
                    release()
                    return respond(RemoteResponse.error(413, "La petición es demasiado grande."), keepAlive: false)
                }
                allowance = length
                releaseBody = release
                arm(timeout)
                process(lastBytes: lastBytes)
            }
        case .request(var request, let consumed):
            buffer.removeFirst(consumed)
            allowance = nil
            if lastBytes { request.keepAlive = false }
            handling = true
            timer?.cancel()
            let once = OnceFlag()
            handler(request, peer) { [weak self] reply in
                guard once.claim() else { return }
                self?.queue.async { self?.answer(reply, to: request) }
            }
        }
    }

    private func answer(_ reply: RemoteReply, to request: RemoteRequest) {
        guard !closed else { return }
        handling = false
        releaseBody?(); releaseBody = nil
        served += 1
        switch reply {
        case .response(let response):
            let keepAlive = request.keepAlive && !response.closes && served < Self.maxRequests
            respond(response, keepAlive: keepAlive)
            guard keepAlive else { return }
            arm(Self.idleTimeout)
            if buffer.isEmpty { receive() } else { process(lastBytes: false) }
        case .stream(let open):
            streaming = true
            timer?.cancel()
            let head = "HTTP/1.1 200 OK\r\n" + RemoteResponse.commonHeaders.map { "\($0.0): \($0.1)\r\n" }.joined()
                + "Content-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\nretry: 2000\n\n"
            send(Data(head.utf8))
            open(self)
            receive()
        }
    }

    private func respond(_ response: RemoteResponse, keepAlive: Bool) {
        let data = response.serialized(keepAlive: keepAlive)
        if keepAlive { send(data); return }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func send(_ data: Data) {
        queued += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queued -= data.count
            if error != nil { self.finish() }
        })
    }

    // MARK: Stream

    func write(_ data: Data) {
        queue.async {
            guard !self.closed, self.streaming else { return }
            // A phone that reads nothing must not make Nook hold the conversation for it, again and again.
            guard self.queued + data.count <= Self.maxQueued else { return self.finish() }
            self.send(data)
        }
    }

    func close() { queue.async { self.finish() } }

    /// Ends the connection, once.
    private func finish() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        connection.cancel()
        releaseBody?(); releaseBody = nil
        let server = onEnd
        onEnd = nil
        closeLock.lock()
        ended = true
        let reader = closeHandler
        closeHandler = nil
        closeLock.unlock()
        server?()
        reader?()
    }
}
