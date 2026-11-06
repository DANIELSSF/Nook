import XCTest
@testable import Nook

/// Who may reach Nook Remote: the home network only, never the Mac itself; a Host that names this Mac; the right pairing key and
/// a paired device's own cookie (docs/REMOTE_API.md, "Lifecycle and access").
final class RemoteSecurityTests: XCTestCase {
    private let mac = [
        RemoteInterface(name: "lo0", address: RemoteIP("127.0.0.1")!, up: true, loopback: true),
        RemoteInterface(name: "lo0", address: RemoteIP("::1")!, up: true, loopback: true),
        RemoteInterface(name: "en0", address: RemoteIP("192.168.1.20")!, up: true, loopback: false),
        RemoteInterface(name: "en0", address: RemoteIP("fe80::aede:48ff:fe00:1122")!, up: true, loopback: false),
        RemoteInterface(name: "utun3", address: RemoteIP("10.8.0.2")!, up: true, loopback: false),
    ]
    private func policy(loopback: Bool = false) -> RemoteAddressPolicy { RemoteAddressPolicy(allowsLoopback: loopback, interfaces: { self.mac }) }

    // MARK: Addresses

    func testOnlyPrivateAndLinkLocalAddressesAreTheHomeNetwork() {
        for address in ["10.0.0.7", "172.16.4.2", "172.31.255.254", "192.168.1.34", "169.254.10.3", "fd12:3456:789a::1", "fc00::5", "fe80::1"] {
            XCTAssertTrue(RemoteIP(address)!.isPrivate, address)
            XCTAssertEqual(policy().verdict(for: RemoteIP(address)!), .allowed, address)
        }
        for address in ["8.8.8.8", "172.32.0.1", "172.15.255.1", "192.169.0.1", "11.0.0.1", "2001:4860:4860::8888", "100.64.0.1"] {
            XCTAssertFalse(RemoteIP(address)!.isPrivate, address)
            XCTAssertEqual(policy().verdict(for: RemoteIP(address)!), .outside, "\(address): closed unread")
        }
    }

    func testTheMacItselfIsRefusedByEveryOneOfItsAddresses() {
        for address in ["127.0.0.1", "127.0.0.53", "::1", "192.168.1.20", "fe80::aede:48ff:fe00:1122", "10.8.0.2"] {
            XCTAssertEqual(policy().verdict(for: RemoteIP(address)!), .thisMac, address)
        }
        XCTAssertEqual(policy().verdict(for: RemoteIP("::ffff:192.168.1.20")!), .thisMac, "An IPv4 address carried in IPv6 is the same address.")
        XCTAssertEqual(policy().verdict(for: RemoteIP("::ffff:192.168.1.34")!), .allowed)
    }

    func testOnlyATestRunMayLetTheLoopbackIn() {
        XCTAssertFalse(RemoteAddressPolicy.homeNetwork().allowsLoopback, "Nook's own policy never does.")
        XCTAssertEqual(RemoteAddressPolicy.homeNetwork().verdict(for: RemoteIP("127.0.0.1")!), .thisMac)
        XCTAssertTrue(RemoteAddressPolicy.runningTests)
        XCTAssertEqual(policy(loopback: true).verdict(for: RemoteIP("127.0.0.1")!), .allowed)
        XCTAssertEqual(policy(loopback: true).verdict(for: RemoteIP("192.168.1.20")!), .thisMac, "Only the loopback, never the Mac's own LAN address.")
    }

    func testTheMacsAddressesAreReadAgainWhenTheNetworkChanges() {
        var interfaces = mac
        let policy = RemoteAddressPolicy(interfaces: { interfaces })
        XCTAssertEqual(policy.verdict(for: RemoteIP("192.168.7.7")!), .allowed)
        interfaces.append(RemoteInterface(name: "en1", address: RemoteIP("192.168.7.7")!, up: true, loopback: false))
        policy.refresh()
        XCTAssertEqual(policy.verdict(for: RemoteIP("192.168.7.7")!), .thisMac, "A new address of the Mac is the Mac.")
    }

    // MARK: Host

    func testHostMustNameThisMacOnTheHomeNetworkAndThePort() {
        let policy = policy()
        XCTAssertTrue(policy.acceptsHost("192.168.1.20:8765", port: 8765))
        XCTAssertTrue(policy.acceptsHost("[fe80::aede:48ff:fe00:1122]:8765", port: 8765))
        XCTAssertFalse(policy.acceptsHost("192.168.1.20:8766", port: 8765), "Another port.")
        XCTAssertFalse(policy.acceptsHost("192.168.1.20", port: 8765), "No port.")
        XCTAssertFalse(policy.acceptsHost("evil.example:8765", port: 8765), "A name (DNS rebinding).")
        XCTAssertFalse(policy.acceptsHost("MacBook-de-Daniel.local:8765", port: 8765), "Not even the Mac's own name.")
        XCTAssertFalse(policy.acceptsHost("192.168.1.21:8765", port: 8765), "Another device's address.")
        XCTAssertFalse(policy.acceptsHost("127.0.0.1:8765", port: 8765), "The loopback is the Mac itself.")
        XCTAssertFalse(policy.acceptsHost("8.8.8.8:8765", port: 8765))
        XCTAssertFalse(policy.acceptsHost(nil, port: 8765))
        XCTAssertFalse(policy.acceptsHost("192.168.1.20:8765:1", port: 8765))
        XCTAssertFalse(policy.acceptsHost("192.168.1.20:+8765", port: 8765))
        XCTAssertTrue(self.policy(loopback: true).acceptsHost("127.0.0.1:8765", port: 8765), "Tests reach the loopback.")
    }

    func testTheHomeNetworkIsTheWiFiOrEthernetOfThePrimaryRoute() {
        let candidates = [
            RemoteInterface(name: "utun3", address: RemoteIP("10.8.0.2")!, up: true, loopback: false, kind: .other),
            RemoteInterface(name: "bridge100", address: RemoteIP("192.168.64.1")!, up: true, loopback: false, kind: .other),
            RemoteInterface(name: "en0", address: RemoteIP("192.168.1.20")!, up: true, loopback: false, kind: .wifi),
            RemoteInterface(name: "en0", address: RemoteIP("fd00::20")!, up: true, loopback: false, kind: .wifi),
            RemoteInterface(name: "en7", address: RemoteIP("10.0.0.4")!, up: true, loopback: false, kind: .ethernet),
            RemoteInterface(name: "en8", address: RemoteIP("10.0.9.4")!, up: false, loopback: false, kind: .ethernet),
        ]
        let wifi = RemoteAddressPolicy(interfaces: { candidates }, route: { RemoteRoute(interface: "en0", router: "192.168.1.1") })
        XCTAssertEqual(wifi.currentHome(), RemoteHome(interface: "en0", address: RemoteIP("192.168.1.20")!, router: "192.168.1.1"))
        XCTAssertEqual(wifi.primaryLANAddress(), RemoteIP("192.168.1.20"))
        XCTAssertEqual(wifi.lanAddresses, [RemoteIP("192.168.1.20")!, RemoteIP("fd00::20")!], "Only the home interface's own addresses.")
        XCTAssertFalse(wifi.acceptsHost("10.0.0.4:8765", port: 8765), "The other Ethernet is not where the phone is.")
        XCTAssertFalse(wifi.acceptsHost("10.8.0.2:8765", port: 8765), "Nor the VPN's tunnel.")
        XCTAssertTrue(wifi.acceptsHost("[fd00::20]:8765", port: 8765))
        let wired = RemoteAddressPolicy(interfaces: { candidates }, route: { RemoteRoute(interface: "en7", router: "10.0.0.1") })
        XCTAssertEqual(wired.currentHome()?.interface, "en7", "The primary route's Ethernet wins over the Wi-Fi.")
        let tunnel = RemoteAddressPolicy(interfaces: { candidates }, route: { RemoteRoute(interface: "utun3", router: nil) })
        XCTAssertEqual(tunnel.currentHome(), RemoteHome(interface: "en0", address: RemoteIP("192.168.1.20")!, router: nil),
                       "A VPN as the primary route: the Wi-Fi is still home, its router unknown.")
        let noHome = candidates.filter { $0.kind == .other || !$0.up }
        XCTAssertNil(RemoteAddressPolicy(interfaces: { noHome }, route: { RemoteRoute() }).currentHome(), "A tunnel or a bridge is no home network.")
        XCTAssertNil(RemoteAddressPolicy(interfaces: { noHome }, route: { RemoteRoute() }).primaryLANAddress())
        XCTAssertFalse(RemoteInterface.current().isEmpty, "getifaddrs reads this Mac's own (the loopback at least).")
        XCTAssertTrue(RemoteInterface.current().contains { $0.kind == .loopback })
    }

    func testTheSameNetworkIsTheSameInterfaceAddressAndRouter() {
        let home = RemoteHome(interface: "en0", address: RemoteIP("192.168.1.20")!, router: "192.168.1.1")
        XCTAssertTrue(home.isSameNetwork(as: home))
        XCTAssertTrue(home.isSameNetwork(as: RemoteHome(interface: "en0", address: RemoteIP("192.168.1.20")!, router: nil)), "A router not known yet is no change.")
        XCTAssertFalse(home.isSameNetwork(as: RemoteHome(interface: "en0", address: RemoteIP("192.168.1.20")!, router: "192.168.1.254")), "Another Wi-Fi on the same addresses.")
        XCTAssertFalse(home.isSameNetwork(as: RemoteHome(interface: "en0", address: RemoteIP("10.0.0.5")!, router: "192.168.1.1")))
        XCTAssertFalse(home.isSameNetwork(as: RemoteHome(interface: "en7", address: RemoteIP("192.168.1.20")!, router: "192.168.1.1")))
        XCTAssertFalse(home.isSameNetwork(as: nil), "No network at all.")
    }

    // MARK: Keys and cookies

    func testKeysAreLongRandomAndURLSafe() {
        let keys = (0..<50).map { _ in RemoteToken.make() }
        XCTAssertEqual(Set(keys).count, 50)
        for key in keys {
            XCTAssertEqual(key.count, 43, "32 bytes, base64url without padding.")
            XCTAssertNil(key.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        }
    }

    func testComparisonIsExact() {
        let key = RemoteToken.make()
        XCTAssertTrue(RemoteToken.same(key, key))
        XCTAssertFalse(RemoteToken.same(key, String(key.dropLast()) + (key.last == "A" ? "B" : "A")))
        XCTAssertFalse(RemoteToken.same(key, String(key.dropLast())))
        XCTAssertFalse(RemoteToken.same(key, ""))
        XCTAssertFalse(RemoteToken.same(key, key + "x"))
    }

    func testAKeyPairsOneDeviceAndTheNextKeyTakesItsPlace() throws {
        let registry = RemoteRegistry()
        var keys: [String] = []
        registry.onKey = { keys.append($0) }
        XCTAssertEqual(registry.pair(key: "anything", userAgent: nil), .wrongKey, "Off: nothing pairs.")
        let key = RemoteToken.make()
        registry.reset(key: key)
        XCTAssertEqual(registry.pair(key: nil, userAgent: nil), .wrongKey)
        XCTAssertEqual(registry.pair(key: RemoteToken.make(), userAgent: nil), .wrongKey, "Another key.")
        guard case .paired(let phone) = registry.pair(key: key, userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1") else {
            return XCTFail()
        }
        XCTAssertNotEqual(phone, key, "The key pairs; it never opens the API itself.")
        let next = try XCTUnwrap(registry.currentKey)
        XCTAssertNotEqual(next, key, "Used up: a new key takes its place.")
        XCTAssertEqual(keys, [next], "And the QR hears it.")
        XCTAssertEqual(registry.pair(key: key, userAgent: nil), .wrongKey, "The old QR pairs nothing more.")
        guard case .paired(let pad) = registry.pair(key: next, userAgent: "Mozilla/5.0 (iPad; CPU OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/140.0 Mobile/15E148 Safari/604.1") else {
            return XCTFail()
        }
        XCTAssertNotEqual(phone, pad)
        XCTAssertEqual(registry.device(cookie: "theme=dark; nook_remote=\(phone)")?.label, "iPhone · Safari")
        XCTAssertEqual(registry.device(cookie: "nook_remote=\(pad)")?.label, "iPad · Chrome")
        XCTAssertNil(registry.device(cookie: "nook_remote=\(key)"), "The pairing key is no cookie.")
        XCTAssertNil(registry.device(cookie: "nook_remote="))
        XCTAssertNil(registry.device(cookie: nil))
        XCTAssertNil(registry.device(cookie: "other=\(phone)"))
        XCTAssertEqual(registry.devices.count, 2)
        registry.reset(key: RemoteToken.make())
        XCTAssertNil(registry.device(cookie: "nook_remote=\(phone)"), "A new activation forgets every device.")
        XCTAssertTrue(registry.devices.isEmpty)
    }

    func testAFullListRefusesNewDevicesAndEvictsNobody() throws {
        let registry = RemoteRegistry()
        registry.reset(key: RemoteToken.make())
        var tokens: [String] = []
        for _ in 0..<RemoteRegistry.maxDevices {
            guard case .paired(let token) = registry.pair(key: registry.currentKey, userAgent: "Android") else { return XCTFail() }
            tokens.append(token)
        }
        let key = registry.currentKey
        XCTAssertEqual(registry.pair(key: key, userAgent: "iPhone"), .full)
        XCTAssertEqual(registry.currentKey, key, "A refusal uses no key up.")
        XCTAssertTrue(tokens.allSatisfy { registry.device(cookie: "nook_remote=\($0)") != nil }, "Every paired device stays.")
        let removed = try XCTUnwrap(registry.device(cookie: "nook_remote=\(tokens[3])"))
        XCTAssertTrue(registry.remove(id: removed.id))
        XCTAssertFalse(registry.remove(id: removed.id))
        XCTAssertNil(registry.device(cookie: "nook_remote=\(tokens[3])"), "A removed device's cookie opens nothing.")
        guard case .paired = registry.pair(key: key, userAgent: "iPhone") else { return XCTFail("Room again.") }
    }

    func testDeviceLabelsComeFromTheUserAgent() {
        XCTAssertEqual(RemoteDevice.label(userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/140.0 Mobile/15E148 Safari/605.1.15"), "iPhone · Firefox")
        XCTAssertEqual(RemoteDevice.label(userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1"), "iPad · Safari",
                       "An iPad asks for the desktop site as a Mac, but says Mobile.")
        XCTAssertEqual(RemoteDevice.label(userAgent: "Mozilla/5.0 (Linux; Android 16; Pixel 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Mobile Safari/537.36"), "Android · Chrome")
        XCTAssertEqual(RemoteDevice.label(userAgent: nil), "Navegador")
    }

    func testCookiesAreReadByName() {
        XCTAssertEqual(RemoteToken.cookies(named: "nook_remote", in: "a=1; nook_remote=abc; nook_remote=def;b=2"), ["abc", "def"])
        XCTAssertEqual(RemoteToken.cookies(named: "nook_remote", in: "xnook_remote=abc"), [])
    }
}

/// Bytes into requests: what is taken, and what is refused before anything else looks at it.
final class RemoteHTTPParserTests: XCTestCase {
    private func parse(_ text: String) -> RemoteHTTPParser.Outcome { RemoteHTTPParser.parse(Data(text.utf8)) }

    private func request(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (RemoteRequest, Int)? {
        guard case .request(let request, let consumed) = parse(text) else { XCTFail("Not a request: \(parse(text))", file: file, line: line); return nil }
        return (request, consumed)
    }

    private func status(_ text: String) -> Int? {
        if case .invalid(let status) = parse(text) { return status }
        return nil
    }

    func testAGetFromSafari() throws {
        let raw = "GET /api/conversation?tab=terminal.app%3A%3A%2Fdev%2Fttys004&before=1830&limit=400 HTTP/1.1\r\nHost: 192.168.1.20:8765\r\n"
            + "Accept: */*\r\nCookie: nook_remote=abc\r\nUser-Agent: Mozilla/5.0 (iPhone)\r\n\r\n"
        let (request, consumed) = try XCTUnwrap(request(raw))
        XCTAssertEqual(consumed, raw.utf8.count)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/conversation")
        XCTAssertEqual(request.query["tab"], "terminal.app::/dev/ttys004")
        XCTAssertEqual(request.query["before"], "1830")
        XCTAssertEqual(request.header("Host"), "192.168.1.20:8765")
        XCTAssertEqual(request.header("cookie"), "nook_remote=abc")
        XCTAssertTrue(request.keepAlive)
    }

    func testAPostWithItsBodyAndTheNextRequestBehindIt() throws {
        let body = #"{"tab":"t","text":"hola ñ"}"#
        let first = "POST /api/send HTTP/1.1\r\nHost: 192.168.1.20:8765\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        let (request, consumed) = try XCTUnwrap(request(first + "GET / HTTP/1.1\r\n"))
        XCTAssertEqual(consumed, first.utf8.count, "Only its own bytes.")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), body)
        XCTAssertFalse(request.keepAlive)
    }

    func testIncompleteRequestsWait() {
        guard case .incomplete = parse("GET / HTTP/1.1\r\nHost: a") else { return XCTFail() }
        guard case .incomplete = parse("POST /api/send HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\n{\"a\"") else { return XCTFail("The body is not all there.") }
    }

    func testOversizedHeadsAndBodiesAreRefused() {
        XCTAssertEqual(status("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 17_000)), 431, "No end of the head in 16 KB.")
        XCTAssertEqual(status("GET / HTTP/1.1\r\n" + (0..<70).map { "X-\($0): 1\r\n" }.joined() + "\r\n"), 431)
        guard case .large(let head, let length) = parse("POST /api/upload HTTP/1.1\r\nHost: a\r\nContent-Length: 65537\r\n\r\nxx") else {
            return XCTFail("A body over 64 KB waits for a decision, read no further.")
        }
        XCTAssertEqual(length, 65537)
        XCTAssertEqual(head.path, "/api/upload")
        XCTAssertTrue(head.body.isEmpty, "Nothing of the body is taken before it is allowed.")
        guard case .incomplete = RemoteHTTPParser.parse(Data("POST /api/upload HTTP/1.1\r\nHost: a\r\nContent-Length: 65537\r\n\r\nxx".utf8), allowance: 65537) else {
            return XCTFail("Allowed, it is read to its end.")
        }
        guard case .large = RemoteHTTPParser.parse(Data("POST /api/upload HTTP/1.1\r\nHost: a\r\nContent-Length: 70000\r\n\r\n".utf8), allowance: 65537) else {
            return XCTFail("An allowance is for that length only.")
        }
        guard case .incomplete = parse("POST /api/send HTTP/1.1\r\nHost: a\r\nContent-Length: 65536\r\n\r\n") else { return XCTFail("64 KB exactly is fine.") }
    }

    func testRequestsThatSmuggleOrBendTheRulesAreRefused() {
        XCTAssertEqual(status("POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"), 501)
        XCTAssertEqual(status("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"), 400, "Two Hosts.")
        XCTAssertEqual(status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx"), 400, "Two lengths.")
        XCTAssertEqual(status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n"), 400)
        XCTAssertEqual(status("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1e3\r\n\r\n"), 400)
        XCTAssertEqual(status("GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n"), 400, "Obsolete line folding.")
        XCTAssertEqual(status("GET / HTTP/1.1\r\nHo st: a\r\n\r\n"), 400)
        XCTAssertEqual(status("GET  / HTTP/1.1\r\nHost: a\r\n\r\n"), 400)
        XCTAssertEqual(status("GET http://evil/ HTTP/1.1\r\nHost: a\r\n\r\n"), 400, "Only a path.")
        XCTAssertEqual(status("GET / HTTP/2\r\nHost: a\r\n\r\n"), 400)
        XCTAssertEqual(status("get / HTTP/1.1\r\nHost: a\r\n\r\n"), 400)
    }

    func testResponsesSayWhatTheyAreAndNeverLeakTheReferrer() {
        let text = String(decoding: RemoteResponse.error(401, "Empareja este dispositivo escaneando el QR en Nook.").serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Referrer-Policy: no-referrer\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"error\":\"Empareja este dispositivo escaneando el QR en Nook.\"}"))
    }

    func testJSONIsWrittenWithNullsAndWithoutLineBreaks() {
        let value = RemoteJSON.object([("a", .null), ("b", .string("dos\nlíneas \"y\" \\ \u{1}")), ("c", .array([.int(1), .bool(false), .number(0.25)]))])
        XCTAssertEqual(value.text, #"{"a":null,"b":"dos\nlíneas \"y\" \\ \u0001","c":[1,false,0.25]}"#)
        XCTAssertFalse(value.text.contains("\n"))
        let decoded = try? JSONSerialization.jsonObject(with: value.data) as? [String: Any]
        XCTAssertEqual(decoded?["b"] as? String, "dos\nlíneas \"y\" \\ \u{1}")
        XCTAssertTrue(decoded?["a"] is NSNull)
    }
}
