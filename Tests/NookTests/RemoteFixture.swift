import Foundation
import ImageIO
import XCTest
@testable import Nook

/// What Nook Remote's tests share: a quiet model with a Claude tab of Terminal (its scripts and keys recorded, never run), a server
/// started on this Mac's loopback with a policy only a test run may have, requests made by hand, a client that speaks raw HTTP over
/// a socket, and a stream reader that records its events.
@MainActor
enum RemoteFixture {
    nonisolated static let rule = String(repeating: "─", count: 72)

    /// The addresses the tests' Mac has: Wi-Fi on the home network, and the loopback.
    nonisolated static let interfaces = [
        RemoteInterface(name: "lo0", address: RemoteIP("127.0.0.1")!, up: true, loopback: true),
        RemoteInterface(name: "en0", address: RemoteIP("192.168.1.20")!, up: true, loopback: false),
        RemoteInterface(name: "en0", address: RemoteIP("fe80::1c2b:3a4d:5e6f:7081")!, up: true, loopback: false),
    ]

    static func defaults() -> UserDefaults {
        let name = "nook-remote-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Claude Code's screen: a little conversation, its box and its mode line.
    static func claudeScreen(_ conversation: [String] = ["> Revisa por qué falla el build.", "", "⏺ Voy a mirar el log del último build."],
                             mode: String = "  ⏵⏵ auto mode on (shift+tab to cycle)") -> String {
        (conversation + ["", rule, "❯ ", rule, mode]).joined(separator: "\n")
    }

    /// A permission question at the end of Claude's screen.
    static func questionScreen() -> String {
        ["> Borra la carpeta build", "", "⏺ Bash(rm -rf build)", " Bash command", "   rm -rf build", "   Delete the build folder", "",
         " Do you want to proceed?", " ❯ 1. Yes", "   2. Yes, and don't ask again for rm commands in this project",
         "   3. No, and tell Claude what to do differently (esc)"].joined(separator: "\n")
    }

    static func tab(_ text: String, tty: String = "/dev/ttys041", processes: [String] = ["login", "-zsh", "claude"], window: Int = 7) -> TerminalTabSnapshot {
        TerminalTabSnapshot(windowID: window, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: processes, busy: false, selected: true, text: text)
    }

    /// A model whose Terminal transport records what it would do, with one Claude tab selected. `keys`: Accessibility is granted.
    static func model(screen: String? = nil, keys: Bool = true, vision: ScreenVision? = nil) -> (AppModel, TerminalSession, Recorder) {
        let model = AppModel(receivesSignals: false, defaults: defaults(), screenVision: vision)
        let recorder = Recorder()
        model.terminalBridge.directKeysAllowed = { keys }
        model.terminalBridge.terminalProcess = { 4242 }
        model.terminalBridge.runScript = { recorder.note("script", $0) }
        model.terminalBridge.postKey = { key, _ in recorder.note("key", key.rawValue) }
        model.terminalBridge.queryScript = { recorder.note("query", $0); throw TerminalBridgeError.failed("Terminal no está abierto en la prueba.") }
        model.commandSender = { text, _ in recorder.note("command", text) }
        model.messageSender = { text, _, done in recorder.note("message", text); done(true) }
        let session = TerminalSession(tab: tab(screen ?? claudeScreen()), backend: .bundled, bridge: model.terminalBridge)
        model.sessions = [session]
        model.selectedID = session.id
        return (model, session, recorder)
    }

    /// The model's remote, listening on this Mac's loopback (tests only) at a port of its own.
    /// The tests' Mac goes out to the internet over Wi-Fi, through the home router.
    nonisolated static let route = RemoteRoute(interface: "en0", router: "192.168.1.1")

    static func started(_ model: AppModel, loopback: Bool = true, interfaces: [RemoteInterface] = interfaces, page: RemotePageSource? = nil) throws -> RemoteAccess {
        try started(model, loopback: loopback, network: { (interfaces, route) }, page: page)
    }

    /// `network`: the Mac's interfaces and primary route, asked again whenever the policy reads them (a test may change them).
    static func started(_ model: AppModel, loopback: Bool = true, network: @escaping () -> ([RemoteInterface], RemoteRoute), page: RemotePageSource? = nil) throws -> RemoteAccess {
        let remote = model.remote
        remote.policy = RemoteAddressPolicy(allowsLoopback: loopback, interfaces: { network().0 }, route: { network().1 })
        // Never the Mac's own permission or network timing: each test says what it needs.
        remote.recordingGranted = { true }
        remote.networkSettle = 0
        // The phone's images go to a folder of the test's own, never Nook's.
        remote.imagesFolder = try ScreenVisionFixture.folder()
        let base = UInt16.random(in: 40_000...59_000)
        remote.ports = Array(base...(base + 6))
        remote.page = page ?? .files(["index.html": Data("<!doctype html><title>Nook</title>".utf8), "app.js": Data("console.log(1)".utf8)])
        // The page's log goes to a file of the test's own, never the user's.
        remote.logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nook-remote-\(UUID().uuidString.prefix(8))/remote.log")
        remote.start()
        waitUntil { remote.status.isOn || { if case .failed = remote.status { true } else { false } }() }
        guard remote.status.isOn else { throw XCTSkip("Nook Remote could not listen: \(remote.status)") }
        return remote
    }

    /// Lets the main queue run until `condition` holds.
    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: Requests by hand

    static func peer(_ remote: RemoteAccess, _ address: String = "127.0.0.1") -> RemotePeer {
        let ip = RemoteIP(address)!
        return RemotePeer(address: ip, verdict: remote.policy.verdict(for: ip), port: remote.port)
    }

    static func request(_ method: String, _ target: String, remote: RemoteAccess, cookie: String? = nil, json: Any? = nil, headers: [String: String] = [:]) -> RemoteRequest {
        let (path, query) = RemoteHTTPParser.split(target)
        var all = ["host": "127.0.0.1:\(remote.port)", "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"]
        if let cookie { all["cookie"] = "\(RemoteAccess.cookieName)=\(cookie)" }
        var body = Data()
        if let json {
            body = try! JSONSerialization.data(withJSONObject: json)
            all["content-type"] = "application/json"
            all["x-nook-remote"] = "1"
            all["origin"] = "http://127.0.0.1:\(remote.port)"
        }
        for (name, value) in headers { all[name.lowercased()] = value }
        all = all.filter { !$0.value.isEmpty }
        return RemoteRequest(method: method, path: path, query: query, headers: all, body: body)
    }

    /// An image upload as the page sends it: raw bytes of `type`, with the page's header, its origin and the cookie.
    static func upload(_ data: Data, type: String = "image/png", remote: RemoteAccess, cookie: String?, headers: [String: String] = [:]) -> RemoteRequest {
        var request = Self.request("POST", "/api/upload", remote: remote, cookie: cookie,
                                   headers: ["content-type": type, "x-nook-remote": "1", "origin": "http://127.0.0.1:\(remote.port)"].merging(headers) { $1 })
        request.body = data
        request.headers = request.headers.filter { !$0.value.isEmpty }
        return request
    }

    /// A picture as a file of `kind`'s format: a two-tone one (small), or noise (large as PNG, as a photo would be).
    static func image(_ type: CFString = "public.png" as CFString, width: Int = 40, height: Int = 30, noise: Bool = false) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type, 1, nil)!
        CGImageDestinationAddImage(destination, ScreenVisionFixture.image(width: width, height: height, noise: noise), nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    /// The answer `remote` gives `request`, waited for on the main queue (the calls run there).
    static func call(_ remote: RemoteAccess, _ request: RemoteRequest, from address: String = "127.0.0.1", timeout: TimeInterval = 5) -> RemoteResponse? {
        var result: RemoteReply?
        let lock = NSLock()
        remote.handle(request, from: peer(remote, address)) { reply in lock.lock(); result = reply; lock.unlock() }
        waitUntil(timeout) { lock.lock(); defer { lock.unlock() }; return result != nil }
        lock.lock(); defer { lock.unlock() }
        if case .response(let response)? = result { return response }
        return nil
    }

    /// The cookie a device gets by pairing.
    static func pair(_ remote: RemoteAccess) -> String? {
        guard let response = call(remote, request("GET", "/pair?k=" + (remote.currentPairingKey ?? ""), remote: remote)),
              let header = response.headers.first(where: { $0.0 == "Set-Cookie" })?.1 else { return nil }
        return RemoteToken.cookies(named: RemoteAccess.cookieName, in: header).first
    }

    static func json(_ response: RemoteResponse?) -> [String: Any] {
        guard let body = response?.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return object
    }
}

/// What a model's transport was asked to do, in order, from any thread.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, String)] = []
    func note(_ kind: String, _ value: String) { lock.lock(); entries.append((kind, value)); lock.unlock() }
    func all(_ kind: String) -> [String] { lock.lock(); defer { lock.unlock() }; return entries.filter { $0.0 == kind }.map(\.1) }
}

/// A stream's reader that keeps every event it is sent.
final class RecordingSink: RemoteEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var _events: [(name: String, data: [String: Any])] = []
    private var _closed = false
    var onClose: (() -> Void)?

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        while let end = buffer.range(of: "\n\n") {
            let block = String(buffer[..<end.lowerBound])
            buffer = String(buffer[end.upperBound...])
            var name = "message", payload = ""
            for line in block.components(separatedBy: "\n") {
                if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
                if line.hasPrefix("data: ") { payload += String(line.dropFirst(6)) }
            }
            let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
            _events.append((name, object))
        }
    }

    func close() {
        lock.lock(); _closed = true; let done = onClose; onClose = nil; lock.unlock()
        done?()
    }

    var events: [(name: String, data: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _events }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func named(_ name: String) -> [[String: Any]] { events.filter { $0.name == name }.map(\.data) }
}

/// Raw HTTP over a socket to this Mac's loopback, blocking: run it off the main thread.
enum RawHTTP {
    struct Answer {
        var status: Int
        var head: String
        var body: Data
        func header(_ name: String) -> String? {
            head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }.map { String($0.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
    }

    static func connect(port: Int, timeout: TimeInterval = 5) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    static func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads one answer: its head, and its body by Content-Length. Nil when the server closed or said nothing.
    static func read(_ fd: Int32) -> Answer? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if data.count >= end.upperBound + length {
                    let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
                    return Answer(status: status, head: head, body: data.subdata(in: end.upperBound..<(end.upperBound + length)))
                }
            }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            data.append(contentsOf: chunk[..<count])
        }
    }

    /// Reads whatever comes until `done` says it is enough, or the time runs out.
    static func stream(_ fd: Int32, until done: (String) -> Bool) -> String {
        var text = ""
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !done(text) {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            text += String(decoding: chunk[..<count], as: UTF8.self)
        }
        return text
    }

    /// Runs blocking socket work on a thread of its own: GCD's shared pool may be busy with other suites' work, and a socket test
    /// must not wait on it.
    static func background(_ work: @escaping () -> Void) {
        let thread = Thread(block: work)
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// One request on its own connection, answered on a background thread; the main queue keeps running meanwhile.
    static func exchange(port: Int, _ request: String, timeout: TimeInterval = 5) -> Answer? {
        var answer: Answer?
        let done = DispatchSemaphore(value: 0)
        background {
            defer { done.signal() }
            guard let fd = connect(port: port, timeout: timeout) else { return }
            defer { Darwin.close(fd) }
            write(fd, request)
            answer = read(fd)
        }
        let deadline = Date().addingTimeInterval(timeout + 1)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return answer
    }
}
