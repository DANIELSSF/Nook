import Foundation
import Network
import Security
import SystemConfiguration

// Who may talk to Nook Remote (docs/REMOTE_API.md, "Lifecycle and access"). Nothing here trusts what a request says about itself
// beyond what it proves: the address it comes from, the Host it names, and the cookie only a paired device holds.
//
//   RemoteIP               an IPv4 or IPv6 address as bytes, with the ranges the rules name (private, link-local, loopback)
//   RemoteInterface        one address of this Mac, read with getifaddrs
//   RemoteAddressPolicy    the home network only, never the Mac itself; which Host a request may name; the address for the QR
//   RemoteToken            random keys and tokens, and their constant-time comparison
//   RemoteRegistry         the pairing key of this activation and the devices paired with it, from any thread
//   RemoteDevice           what the settings pane shows of a paired device

// MARK: - Addresses

/// An IP address as its bytes: 4 for IPv4, 16 for IPv6. An IPv4 address carried in IPv6 (`::ffff:192.168.1.20`, how a dual-stack
/// listener may report an IPv4 peer) is kept as the IPv4 address it is, so the same device is always the same address.
struct RemoteIP: Hashable, CustomStringConvertible {
    let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            self.bytes = Array(bytes[12..<16])
        } else if bytes.count == 4 || bytes.count == 16 {
            self.bytes = bytes
        } else { return nil }
    }

    /// A literal ("192.168.1.20", "fe80::1", "fe80::1%en0": the zone is not part of the address).
    init?(_ text: String) {
        let literal = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 { self.init(bytes: withUnsafeBytes(of: &v4) { Array($0) }) }
        else if inet_pton(AF_INET6, literal, &v6) == 1 { self.init(bytes: withUnsafeBytes(of: &v6) { Array($0) }) }
        else { return nil }
    }

    /// The peer of a connection, as Network.framework reports it.
    init?(endpoint: NWEndpoint) {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): self.init(bytes: Array(address.rawValue))
        case .ipv6(let address): self.init(bytes: Array(address.rawValue))
        case .name(let name, _): self.init(name)
        @unknown default: return nil
        }
    }

    var isV4: Bool { bytes.count == 4 }
    var isLoopback: Bool { isV4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1] }
    var isLinkLocal: Bool { isV4 ? bytes[0] == 169 && bytes[1] == 254 : bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 }
    /// The ranges a home network uses: 10/8, 172.16/12, 192.168/16 and 169.254/16; fc00::/7 and fe80::/10.
    var isPrivate: Bool {
        if isLinkLocal { return true }
        if isV4 { return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16) || (bytes[0] == 192 && bytes[1] == 168) }
        return bytes[0] & 0xFE == 0xFC
    }

    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isV4 ? AF_INET : AF_INET6
        return bytes.withUnsafeBytes { raw in inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) }.map { _ in String(cString: buffer) } ?? "?"
    }
}

/// One address of one of this Mac's interfaces.
struct RemoteInterface: Equatable {
    /// What carries it. Nook Remote takes the phone over Wi-Fi or wired Ethernet only: never a VPN's tunnel, a bridge for virtual
    /// machines, the cellular radio or AWDL ("other").
    enum Kind: Equatable { case wifi, ethernet, loopback, other }

    var name: String
    var address: RemoteIP
    var up: Bool
    var loopback: Bool
    var kind: Kind

    /// `kind`: what the system says the interface is; without it (tests), the loopback flag, else "en…" is Wi-Fi, else other.
    init(name: String, address: RemoteIP, up: Bool, loopback: Bool, kind: Kind? = nil) {
        self.name = name; self.address = address; self.up = up; self.loopback = loopback
        self.kind = kind ?? (loopback ? .loopback : name.hasPrefix("en") ? .wifi : .other)
    }

    /// Wi-Fi or wired Ethernet: where the phone can be.
    var isHome: Bool { kind == .wifi || kind == .ethernet }

    /// Every address of every interface now, up or not (getifaddrs), each with its kind as the system's configuration names it.
    static func current() -> [RemoteInterface] {
        let kinds = systemKinds()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [RemoteInterface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let socketAddress = entry.ifa_addr else { continue }
            var address: RemoteIP?
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                address = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    var raw = pointer.pointee.sin_addr
                    return RemoteIP(bytes: withUnsafeBytes(of: &raw) { Array($0) })
                }
            case AF_INET6:
                address = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    var raw = pointer.pointee.sin6_addr
                    return RemoteIP(bytes: withUnsafeBytes(of: &raw) { Array($0) })
                }
            default: continue
            }
            guard let address else { continue }
            let flags = Int32(entry.ifa_flags), name = String(cString: entry.ifa_name)
            let loopback = flags & IFF_LOOPBACK != 0
            found.append(RemoteInterface(name: name, address: address, up: flags & IFF_UP != 0, loopback: loopback,
                                         kind: loopback ? .loopback : kinds[name] ?? .other))
        }
        return found
    }

    /// The Wi-Fi and Ethernet interfaces the system knows, by BSD name ("en0" → Wi-Fi). A tunnel, a bridge or anything else is not
    /// among them.
    static func systemKinds() -> [String: Kind] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var kinds: [String: Kind] = [:]
        for interface in all {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?, let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
            if type == kSCNetworkInterfaceTypeIEEE80211 { kinds[name] = .wifi } else if type == kSCNetworkInterfaceTypeEthernet { kinds[name] = .ethernet }
        }
        return kinds
    }
}

/// The system's primary IPv4 route: the interface it goes out of and its router (the home Wi-Fi's gateway).
struct RemoteRoute: Equatable {
    var interface: String?
    var router: String?

    static func current() -> RemoteRoute {
        guard let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return RemoteRoute() }
        return RemoteRoute(interface: global["PrimaryInterface"] as? String, router: global["Router"] as? String)
    }
}

/// The home network Nook Remote is on: the Wi-Fi or Ethernet interface, its IPv4 address there, and the router when the system says.
struct RemoteHome: Equatable {
    var interface: String
    var address: RemoteIP
    var router: String?

    /// Still the network it was: the same interface with the same address, and the same router when both are known.
    func isSameNetwork(as other: RemoteHome?) -> Bool {
        guard let other, other.interface == interface, other.address == address else { return false }
        guard let router, let otherRouter = other.router else { return true }
        return router == otherRouter
    }
}

// MARK: - Policy

/// The rules on addresses. A connection is taken only from the home network: a private or link-local address that is not this Mac's
/// own. The Mac itself is refused on purpose, by every one of its addresses (loopback included): the page is for the phone, and a
/// page any local program could open would make the pairing cookie the only thing between that program and the terminals. A
/// request must also name this Mac by one of its home-network addresses and the port in its Host, so a web page that rebinds its
/// own name to this Mac's address (DNS rebinding) is refused too.
///
/// The home network is one interface: the primary route's when it is Wi-Fi or Ethernet, else the Wi-Fi (en0) or another Ethernet
/// one with a private IPv4 address. Its addresses are the only ones a Host may name and the one the QR carries.
///
/// The Mac's addresses are read again when the network changes (`refresh`, from the server's path monitor) and at least every few
/// seconds; reading them costs a few microseconds.
final class RemoteAddressPolicy: @unchecked Sendable {
    enum Verdict: Equatable {
        /// From the home network: served.
        case allowed
        /// From this Mac (loopback, or one of its own addresses): told the page is for the phone, and nothing else.
        case thisMac
        /// From anywhere else: the connection is closed unread.
        case outside
    }

    /// Lets this Mac's loopback in, for tests only: a policy asking for it outside a test run never gets it.
    let allowsLoopback: Bool
    private let interfaces: () -> [RemoteInterface]
    private let route: () -> RemoteRoute
    private let lock = NSLock()
    private var known: (all: [RemoteInterface], route: RemoteRoute, at: Date)?
    static let staleAfter: TimeInterval = 3

    /// The only policy Nook itself uses: the home network, never this Mac.
    static func homeNetwork() -> RemoteAddressPolicy { RemoteAddressPolicy() }

    /// `interfaces`: this Mac's addresses, and `route` its primary route (tests pass their own). `allowsLoopback` is honoured only
    /// inside a test run.
    init(allowsLoopback: Bool = false, interfaces: @escaping () -> [RemoteInterface] = RemoteInterface.current, route: @escaping () -> RemoteRoute = RemoteRoute.current) {
        self.allowsLoopback = allowsLoopback && Self.runningTests
        self.interfaces = interfaces
        self.route = route
    }

    /// XCTest is loaded: only a test run has it.
    static var runningTests: Bool { NSClassFromString("XCTestCase") != nil }

    /// Forgets the addresses read so far: the network changed.
    func refresh() {
        lock.lock(); known = nil; lock.unlock()
    }

    private func current(now: Date = Date()) -> (all: [RemoteInterface], route: RemoteRoute) {
        lock.lock(); defer { lock.unlock() }
        if let known, now.timeIntervalSince(known.at) < Self.staleAfter { return (known.all, known.route) }
        let all = interfaces(), primary = route()
        known = (all, primary, now)
        return (all, primary)
    }

    /// Every address of this Mac.
    var ownAddresses: Set<RemoteIP> { Set(current().all.map(\.address)) }

    /// The home network now: the primary route's interface when it is Wi-Fi or Ethernet with a private IPv4 address, else en0, else
    /// another such interface (a link-local address only when there is nothing better). Nil off any home network.
    func currentHome() -> RemoteHome? {
        let (all, primary) = current()
        let candidates = all.filter { $0.up && $0.isHome && $0.address.isV4 && $0.address.isPrivate }
        func rank(_ interface: RemoteInterface) -> Int {
            var rank = interface.name == primary.interface ? 0 : interface.name == "en0" ? 1 : 2
            if interface.address.isLinkLocal { rank += 10 }
            return rank
        }
        guard let chosen = candidates.min(by: { rank($0) < rank($1) }) else { return nil }
        return RemoteHome(interface: chosen.name, address: chosen.address, router: chosen.name == primary.interface ? primary.router : nil)
    }

    /// This Mac's addresses on the home network's interface: the ones a request's Host may name.
    var lanAddresses: Set<RemoteIP> {
        guard let home = currentHome() else { return [] }
        return Set(current().all.filter { $0.name == home.interface && !$0.address.isLoopback && $0.address.isPrivate }.map(\.address))
    }

    func verdict(for peer: RemoteIP) -> Verdict {
        if peer.isLoopback { return allowsLoopback ? .allowed : .thisMac }
        if ownAddresses.contains(peer) { return .thisMac }
        return peer.isPrivate ? .allowed : .outside
    }

    /// Whether a request's Host header names this Mac as the phone reaches it: one of its home-network addresses (an IPv6 one in
    /// brackets) and the server's port. A name, another port or no port at all is refused.
    func acceptsHost(_ host: String?, port: Int) -> Bool {
        guard let host, let (literal, named) = Self.split(host), named == port, let address = RemoteIP(literal) else { return false }
        if address.isLoopback { return allowsLoopback }
        return lanAddresses.contains(address)
    }

    /// "192.168.1.20:8765" → ("192.168.1.20", 8765); "[fe80::1]:8765" → ("fe80::1", 8765).
    static func split(_ host: String) -> (String, Int)? {
        let text = host.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let literal = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), rest.dropFirst().allSatisfy(\.isASCII) else { return nil }
            return (literal, port)
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(parts[1]) else { return nil }
        return (String(parts[0]), port)
    }

    /// The address the QR carries: this Mac's IPv4 on the home network (`currentHome`). Nil off any network.
    func primaryLANAddress() -> RemoteIP? { currentHome()?.address }
}

// MARK: - Keys and tokens

enum RemoteToken {
    /// 32 random bytes, base64url without padding (43 characters): a pairing key or a device's token.
    static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // The system's generator does not fail in practice; this one is as unpredictable, only slower to reach.
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Whether two secrets are the same, in a time that does not depend on where they first differ.
    static func same(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        var difference: UInt8 = left.count == right.count ? 0 : 1
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }

    /// The `nook_remote` values in a Cookie header ("a=1; nook_remote=…; b=2"); a browser may send more than one.
    static func cookies(named name: String, in header: String?) -> [String] {
        guard let header else { return [] }
        return header.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Devices

/// A paired device, as the settings pane lists it.
struct RemoteDevice: Identifiable, Equatable {
    /// Random, and never the device's token.
    var id: String
    /// "iPhone · Safari", from its User-Agent.
    var label: String
    var pairedAt: Date
    var lastSeen: Date

    /// A short name for a browser from its User-Agent: the device, and the browser when it says.
    static func label(userAgent: String?) -> String {
        let agent = userAgent ?? ""
        let device: String
        if agent.contains("iPhone") { device = "iPhone" }
        else if agent.contains("iPad") || (agent.contains("Macintosh") && agent.contains("Mobile")) { device = "iPad" }
        else if agent.contains("Android") { device = "Android" }
        else if agent.contains("Macintosh") { device = "Mac" }
        else if agent.contains("Windows") { device = "Windows" }
        else if agent.contains("Linux") { device = "Linux" }
        else { device = "Navegador" }
        let browser: String?
        if agent.contains("EdgiOS") || agent.contains("Edg/") { browser = "Edge" }
        else if agent.contains("CriOS") || agent.contains("Chrome/") { browser = "Chrome" }
        else if agent.contains("FxiOS") || agent.contains("Firefox/") { browser = "Firefox" }
        else if agent.contains("Safari/") { browser = "Safari" }
        else { browser = nil }
        return browser.map { device + " · " + $0 } ?? device
    }
}

/// The pairing key of the current activation and the devices it paired, read and changed from the server's queue and the main
/// thread alike. Nothing here is saved: turning Nook Remote off forgets it all, and every device has to scan the QR again.
///
/// A key pairs one device only: once it has, the next key takes its place (`onKey`, so the QR shows it at once), and a second scan
/// of the old QR finds no key. A full list refuses new devices; one goes only when the user removes it (`remove`).
final class RemoteRegistry: @unchecked Sendable {
    private struct Entry {
        var token: String
        var device: RemoteDevice
    }

    /// How a pairing went.
    enum Pairing: Equatable {
        /// This device's new token.
        case paired(String)
        /// Not this activation's current key (or none): an old QR, a guess, or Nook Remote off.
        case wrongKey
        /// `maxDevices` are paired already; nothing was used up.
        case full
    }

    private let lock = NSLock()
    private var key: String?
    private var entries: [Entry] = []
    /// Paired devices kept at once; beyond them, pairing is refused until the user removes one.
    static let maxDevices = 8
    /// How stale `lastSeen` may get before the settings pane hears of it again.
    static let seenGranularity: TimeInterval = 10
    /// Hears the devices whenever the list or someone's `lastSeen` changes; called from whichever thread changed it.
    var onChange: (([RemoteDevice]) -> Void)?
    /// Hears the key that pairs now, once the last one paired a device; called from whichever thread paired it.
    var onKey: ((String) -> Void)?

    /// A new activation: this key pairs, and no device is paired yet. Nil: off, nothing pairs.
    func reset(key: String?) {
        lock.lock()
        self.key = key
        entries = []
        lock.unlock()
        onChange?([])
    }

    /// The key that pairs right now.
    var currentKey: String? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    var devices: [RemoteDevice] {
        lock.lock(); defer { lock.unlock() }
        return entries.map(\.device).sorted { $0.lastSeen > $1.lastSeen }
    }

    /// A device offering `candidate` as the pairing key: it gets a token of its own when the key is this activation's current one and
    /// there is room, and the key is used up (a new one takes its place).
    func pair(key candidate: String?, userAgent: String?, now: Date = Date()) -> Pairing {
        lock.lock()
        guard let key, let candidate, RemoteToken.same(candidate, key) else { lock.unlock(); return .wrongKey }
        guard entries.count < Self.maxDevices else { lock.unlock(); return .full }
        let token = RemoteToken.make(), next = RemoteToken.make()
        let device = RemoteDevice(id: String(RemoteToken.make().prefix(12)), label: RemoteDevice.label(userAgent: userAgent), pairedAt: now, lastSeen: now)
        entries.append(Entry(token: token, device: device))
        self.key = next
        let list = entries.map(\.device).sorted { $0.lastSeen > $1.lastSeen }
        lock.unlock()
        onKey?(next)
        onChange?(list)
        return .paired(token)
    }

    /// Forgets the device with that id: its token opens nothing from now on. False when there was none.
    @discardableResult func remove(id: String) -> Bool {
        lock.lock()
        let before = entries.count
        entries.removeAll { $0.device.id == id }
        let removed = entries.count != before
        let list = entries.map(\.device).sorted { $0.lastSeen > $1.lastSeen }
        lock.unlock()
        if removed { onChange?(list) }
        return removed
    }

    /// The paired device whose token a request's Cookie header carries (its `lastSeen` moves to `now`), or nil. Every token is
    /// compared in constant time, and every one of them is compared.
    func device(cookie header: String?, now: Date = Date()) -> RemoteDevice? {
        let offered = RemoteToken.cookies(named: RemoteAccess.cookieName, in: header)
        guard !offered.isEmpty else { return nil }
        lock.lock()
        var found: Int?
        for candidate in offered {
            for index in entries.indices where RemoteToken.same(candidate, entries[index].token) { found = index }
        }
        guard let index = found else { lock.unlock(); return nil }
        let announce = now.timeIntervalSince(entries[index].device.lastSeen) >= Self.seenGranularity
        entries[index].device.lastSeen = now
        let device = entries[index].device
        let list = announce ? entries.map(\.device).sorted { $0.lastSeen > $1.lastSeen } : nil
        lock.unlock()
        if let list { onChange?(list) }
        return device
    }
}
