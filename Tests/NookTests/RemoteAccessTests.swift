import CryptoKit
import XCTest
@testable import Nook

/// Nook Remote end to end inside Nook: the switch, pairing, every check a request passes, the state the phone reads, and each
/// action reaching the island's own function on the model (docs/REMOTE_API.md). The model's transports are recorders; the server
/// listens on this Mac's loopback, which only a test run may let in.
@MainActor
final class RemoteAccessTests: XCTestCase {
    private var remotes: [RemoteAccess] = []

    override func tearDown() {
        remotes.forEach { $0.stop() }
        remotes = []
        super.tearDown()
    }

    private func started(_ model: AppModel, loopback: Bool = true) throws -> RemoteAccess {
        let remote = try RemoteFixture.started(model, loopback: loopback)
        remotes.append(remote)
        return remote
    }

    private func call(_ remote: RemoteAccess, _ method: String, _ target: String, cookie: String? = nil, json: Any? = nil, headers: [String: String] = [:]) -> RemoteResponse? {
        RemoteFixture.call(remote, RemoteFixture.request(method, target, remote: remote, cookie: cookie, json: json, headers: headers))
    }

    private func paired(_ model: AppModel) throws -> (RemoteAccess, String) {
        let remote = try started(model)
        return (remote, try XCTUnwrap(RemoteFixture.pair(remote)))
    }

    // MARK: The switch

    func testOffAtLaunchAndUnlockedForGood() {
        let defaults = RemoteFixture.defaults()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        XCTAssertEqual(model.remote.status, .off, "Never on when Nook starts.")
        XCTAssertNil(model.remote.pairingURL)
        XCTAssertFalse(model.remote.unlocked)
        model.remote.unlock()
        XCTAssertTrue(model.remote.unlocked)
        XCTAssertTrue(defaults.bool(forKey: RemoteAccess.unlockedKey))
        XCTAssertTrue(AppModel(receivesSignals: false, defaults: defaults).remote.unlocked, "Unlocked stays unlocked.")
        XCTAssertEqual(AppModel(receivesSignals: false, defaults: defaults).remote.status, .off)
    }

    func testOnItNamesTheMacsWiFiAddressAndANewKeyEachTime() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        guard case .on(let url, let port) = remote.status else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "http://192.168.1.20:\(port)")
        let key = try XCTUnwrap(remote.currentPairingKey)
        XCTAssertEqual(remote.pairingURL?.absoluteString, "http://192.168.1.20:\(port)/pair?k=\(key)")
        remote.stop()
        XCTAssertEqual(remote.status, .off)
        XCTAssertNil(remote.pairingURL)
        remote.start()
        RemoteFixture.waitUntil { remote.status.isOn }
        XCTAssertNotEqual(remote.currentPairingKey, key, "Every activation has its own key.")
    }

    func testWithoutAHomeNetworkItSaysSo() {
        let (model, _, _) = RemoteFixture.model()
        model.remote.policy = RemoteAddressPolicy(allowsLoopback: true, interfaces: { [RemoteInterface(name: "lo0", address: RemoteIP("127.0.0.1")!, up: true, loopback: true)] })
        model.remote.start()
        guard case .failed(let message) = model.remote.status else { return XCTFail("\(model.remote.status)") }
        XCTAssertTrue(message.contains("red local"), message)
    }

    func testABusyPortGivesWayToTheNextOne() throws {
        let (model, _, _) = RemoteFixture.model()
        let base = UInt16.random(in: 40_000...59_000)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(base.bigEndian)
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try XCTSkipUnless(bound == 0 && Darwin.listen(fd, 1) == 0, "Port \(base) was not free for the test.")
        let remote = model.remote
        remotes.append(remote)
        remote.policy = RemoteAddressPolicy(allowsLoopback: true, interfaces: { RemoteFixture.interfaces })
        remote.ports = [base, base + 1, base + 2]
        remote.start()
        RemoteFixture.waitUntil { remote.status != .starting }
        guard case .on(_, let port) = remote.status else { return XCTFail("\(remote.status)") }
        XCTAssertNotEqual(port, Int(base), "The busy port is skipped.")
    }

    // MARK: Pairing and the cookie

    func testTheRightKeyPairsThisDeviceWithACookieOfItsOwn() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let wrong = call(remote, "GET", "/pair?k=" + RemoteToken.make())
        XCTAssertEqual(wrong?.status, 403)
        XCTAssertTrue(String(decoding: wrong?.body ?? Data(), as: UTF8.self).contains("Escanea el código QR en Nook → Ajustes → Remoto."))
        XCTAssertNil(wrong?.headers.first { $0.0 == "Set-Cookie" })
        XCTAssertEqual(call(remote, "GET", "/pair")?.status, 403, "No key.")
        let right = try XCTUnwrap(call(remote, "GET", "/pair?k=" + remote.currentPairingKey!))
        XCTAssertEqual(right.status, 303)
        XCTAssertEqual(right.headers.first { $0.0 == "Location" }?.1, "/")
        let cookie = try XCTUnwrap(right.headers.first { $0.0 == "Set-Cookie" }?.1)
        XCTAssertTrue(cookie.hasSuffix("; HttpOnly; SameSite=Strict; Path=/"), cookie)
        XCTAssertTrue(cookie.hasPrefix("nook_remote="))
        XCTAssertFalse(cookie.contains(remote.currentPairingKey!), "The device's token is not the pairing key.")
        RemoteFixture.waitUntil { !remote.devices.isEmpty }
        XCTAssertEqual(remote.devices.map(\.label), ["iPhone · Safari"])
    }

    func testTheAPIWantsAPairedDevicesCookie() throws {
        let (model, _, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let refused = call(remote, "GET", "/api/state")
        XCTAssertEqual(refused?.status, 401)
        XCTAssertEqual(RemoteFixture.json(refused)["error"] as? String, "Empareja este dispositivo escaneando el QR en Nook.")
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: RemoteToken.make())?.status, 401, "A token nobody was given.")
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: remote.currentPairingKey)?.status, 401, "The pairing key only pairs.")
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: cookie)?.status, 200)
        XCTAssertEqual(call(remote, "POST", "/api/select", json: ["tab": model.sessions[0].id])?.status, 401)
    }

    func testTurningItOffForgetsEveryDevice() throws {
        let (model, _, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let key = try XCTUnwrap(remote.currentPairingKey)
        remote.stop()
        XCTAssertTrue(remote.devices.isEmpty)
        remote.start()
        RemoteFixture.waitUntil { remote.status.isOn }
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: cookie)?.status, 401, "The old cookie opens nothing.")
        XCTAssertEqual(call(remote, "GET", "/pair?k=" + key)?.status, 403, "Nor does the old key.")
        XCTAssertNotNil(RemoteFixture.pair(remote), "The new key pairs.")
    }

    // MARK: Checks on every request

    func testAHostThatIsNotThisMacIsRefused() throws {
        let (model, _, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        for host in ["evil.example:\(remote.port)", "127.0.0.1:1", "192.168.1.99:\(remote.port)", ""] {
            XCTAssertEqual(call(remote, "GET", "/api/state", cookie: cookie, headers: ["host": host])?.status, 403, host)
            XCTAssertEqual(call(remote, "GET", "/", headers: ["host": host])?.status, 403, "Even the page: \(host)")
        }
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: cookie, headers: ["host": "192.168.1.20:\(remote.port)"])?.status, 200, "The Mac's LAN address.")
    }

    func testPostsNeedTheirHeaderJSONAndTheirOwnOrigin() throws {
        let (model, session, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let body = ["tab": session.id]
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body)?.status, 200)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["x-nook-remote": ""])?.status, 403)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["x-nook-remote": "0"])?.status, 403)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["content-type": "text/plain"])?.status, 415)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["content-type": "application/json; charset=utf-8"])?.status, 200)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["origin": "http://evil.example"])?.status, 403)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["origin": "http://192.168.1.20:\(remote.port)"])?.status, 403,
                       "An origin other than the Host the page was opened with.")
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["origin": ""])?.status, 200, "No Origin at all is fine.")
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: body, headers: ["sec-fetch-site": "cross-site"])?.status, 403)
        var broken = RemoteFixture.request("POST", "/api/select", remote: remote, cookie: cookie, json: body)
        broken.body = Data("{tab:".utf8)
        XCTAssertEqual(RemoteFixture.call(remote, broken)?.status, 400)
        XCTAssertEqual(call(remote, "DELETE", "/api/select", cookie: cookie)?.status, 405)
        XCTAssertEqual(call(remote, "POST", "/api/nada", cookie: cookie, json: body)?.status, 404)
    }

    func testTheMacItselfIsToldThePageIsForThePhone() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model, loopback: false)
        let response = call(remote, "GET", "/")
        XCTAssertEqual(response?.status, 403)
        XCTAssertTrue(String(decoding: response?.body ?? Data(), as: UTF8.self).contains("Nook Remoto es para tu teléfono"))
        XCTAssertTrue(response?.closes == true)
        let fromLAN = RemoteFixture.call(remote, RemoteFixture.request("GET", "/", remote: remote), from: "192.168.1.20")
        XCTAssertEqual(fromLAN?.status, 403, "Nor from the Mac's own address on the network.")
    }

    // MARK: Reading

    func testTheStateIsWhatTheIslandShows() throws {
        let (model, session, _) = RemoteFixture.model()
        session.customTitle = "API"
        session.tint = .blue
        let (remote, cookie) = try paired(model)
        let state = RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))
        XCTAssertEqual(state["v"] as? Int, 1)
        XCTAssertFalse((state["mac"] as? String ?? "").isEmpty)
        XCTAssertEqual(state["selected"] as? String, session.id)
        XCTAssertTrue(state["notice"] is NSNull)
        XCTAssertEqual((state["screen"] as? [String: Any])?["attach"] as? Bool, false)
        let tab = try XCTUnwrap((state["tabs"] as? [[String: Any]])?.first)
        XCTAssertEqual(tab["id"] as? String, session.id)
        XCTAssertEqual(tab["title"] as? String, "API")
        XCTAssertEqual(tab["tint"] as? String, RemoteSnapshot.hex(TabTint.blue.shades.pastel))
        XCTAssertEqual(tab["icon"] as? String, "dot")
        XCTAssertEqual(tab["agent"] as? String, "claude")
        XCTAssertEqual(tab["kind"] as? String, "shell")
        XCTAssertEqual(tab["state"] as? String, "idle")
        XCTAssertEqual(tab["question"] as? Bool, false)
        let detail = try XCTUnwrap(state["detail"] as? [String: Any])
        XCTAssertEqual(detail["id"] as? String, session.id)
        XCTAssertEqual(detail["running"] as? Bool, true)
        XCTAssertEqual((detail["mode"] as? [String: Any])?["kind"] as? String, "auto")
        XCTAssertEqual((detail["mode"] as? [String: Any])?["title"] as? String, "Auto")
        XCTAssertTrue((detail["mode"] as? [String: Any])?["blocked"] is NSNull)
        XCTAssertNotNil((detail["model"] as? [String: Any])?["choices"] as? [[String: Any]])
        XCTAssertTrue(detail["prompt"] is NSNull)
        XCTAssertTrue(detail["field"] is NSNull)
        XCTAssertEqual((detail["pending"] as? [Any])?.count, 0)
        XCTAssertNotNil(detail["conversationEpoch"] as? Int)
        XCTAssertEqual(RemoteSnapshot.hex(TabRGB(0.433, 0.833, 0.702)), "#6ed4b3")
    }

    func testAQuestionIsSentAsItsCardAndLeavesTheConversation() throws {
        let (model, session, _) = RemoteFixture.model(screen: RemoteFixture.questionScreen())
        let (remote, cookie) = try paired(model)
        let state = RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))
        XCTAssertEqual((state["tabs"] as? [[String: Any]])?.first?["question"] as? Bool, true)
        let prompt = try XCTUnwrap((state["detail"] as? [String: Any])?["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["signature"] as? String, session.prompt?.signature)
        XCTAssertEqual(prompt["kind"] as? String, "approval")
        XCTAssertEqual(prompt["question"] as? String, "Do you want to proceed?")
        XCTAssertEqual(prompt["context"] as? String, "Bash(rm -rf build)")
        let options = try XCTUnwrap(prompt["options"] as? [[String: Any]])
        XCTAssertEqual(options.map { $0["number"] as? Int }, [1, 2, 3])
        XCTAssertEqual(options.last?["input"] as? String, "followUp")
        XCTAssertEqual(prompt["highlighted"] as? Int, 0)
        XCTAssertTrue((state["detail"] as? [String: Any])?["mode"] is NSNull, "The mode chip needs Claude's box, which the question took.")
        let page = RemoteFixture.json(call(remote, "GET", "/api/conversation?tab=\(session.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&before=100", cookie: cookie))
        let texts = (page["lines"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        XCTAssertTrue(texts.contains("⏺ Bash(rm -rf build)"))
        XCTAssertFalse(texts.contains { $0.contains("Do you want to proceed?") }, "The card shows the question, as on the island.")
    }

    func testPagingAStaleEpochIsRefusedWithTheCurrentOne() throws {
        let (model, session, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let tab = session.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let page = RemoteFixture.json(call(remote, "GET", "/api/conversation?tab=\(tab)&before=10&limit=400", cookie: cookie))
        let epoch = try XCTUnwrap(page["epoch"] as? Int)
        let stale = call(remote, "GET", "/api/conversation?tab=\(tab)&before=10&epoch=\(epoch + 1)", cookie: cookie)
        XCTAssertEqual(stale?.status, 409)
        XCTAssertEqual(RemoteFixture.json(stale)["epoch"] as? Int, epoch)
        XCTAssertEqual(call(remote, "GET", "/api/conversation?tab=\(tab)", cookie: cookie)?.status, 400)
    }

    func testThePageIsServedWithoutDataAndOnlyByPlainNames() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let page = try XCTUnwrap(call(remote, "GET", "/"))
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.headers.first { $0.0 == "Content-Type" }?.1, "text/html; charset=utf-8")
        XCTAssertTrue(page.headers.contains { $0.0 == "Content-Security-Policy" && $0.1.contains("frame-ancestors 'none'") })
        XCTAssertEqual(call(remote, "GET", "/app.js")?.status, 200)
        for path in ["/../index.html", "/.hidden", "/a/b.js", "/index.html%00", "/nada.html", "/app.exe"] {
            XCTAssertEqual(call(remote, "GET", path)?.status, 404, path)
        }
    }

    // MARK: Acting

    func testSelectingATabSelectsItInNook() throws {
        let (model, first, recorder) = RemoteFixture.model()
        let second = TerminalSession(tab: RemoteFixture.tab(RemoteFixture.claudeScreen(), tty: "/dev/ttys042", window: 8), backend: .bundled, bridge: model.terminalBridge)
        model.sessions.append(second)
        let (remote, cookie) = try paired(model)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(call(remote, "POST", "/api/select", cookie: cookie, json: ["tab": second.id])?.status, 200)
        XCTAssertEqual(model.selectedID, second.id, "The phone switching tabs switches Nook's.")
        RemoteFixture.waitUntil { !recorder.all("script").isEmpty }
        XCTAssertTrue(recorder.all("script").contains { $0.contains("set selected of t to true") }, "And Terminal's, as a click in the island does.")
        let gone = call(remote, "POST", "/api/select", cookie: cookie, json: ["tab": "terminal.app::/dev/ttys999"])
        XCTAssertEqual(gone?.status, 404)
        XCTAssertEqual(RemoteFixture.json(gone)["error"] as? String, "Esa pestaña ya no está abierta en Nook.")
    }

    func testAMessageGoesTheIslandsWay() throws {
        let (model, session, recorder) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let sent = call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": "Revisa el build\n"])
        XCTAssertEqual(sent?.status, 200)
        XCTAssertEqual(recorder.all("message"), ["Revisa el build"], "Line breaks at its ends are not part of it, as on the island.")
        XCTAssertEqual(session.sentHistory.last, "Revisa el build", "It joins the tab's history, as the island's do.")
        XCTAssertEqual(session.pendingMessage, "Revisa el build", "It shows in the conversation until Claude's record has it.")
        XCTAssertEqual(call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": " \n "])?.status, 400)
        model.messageSender = { _, _, done in done(false) }
        let failed = call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": "otra"])
        XCTAssertEqual(failed?.status, 502)
        XCTAssertEqual(RemoteFixture.json(failed)["error"] as? String, "No pude entregar el mensaje a la terminal. Revisa la pestaña en el Mac.")
        XCTAssertNil(session.pendingMessage, "A message that didn't go leaves no placeholder; the phone keeps its text.")
        XCTAssertEqual(session.draft, "", "Nothing lands in the Mac's own field.")
        session.joinedBox = "texto previo Revisa"
        XCTAssertEqual(call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": "otra"])?.status, 409, "Claude's box holds the last one.")
    }

    func testAKeyReachesTheTabAndAMissingPermissionIsToldToThePhoneNotAskedOnTheMac() throws {
        let (model, session, recorder) = RemoteFixture.model(keys: false)
        let (remote, cookie) = try paired(model)
        // Asking on the Mac would be an NSAlert run modally: this test would never finish.
        let refused = call(remote, "POST", "/api/key", cookie: cookie, json: ["tab": session.id, "key": "up"])
        XCTAssertEqual(refused?.status, 403)
        XCTAssertEqual(RemoteFixture.json(refused)["error"] as? String, AppModel.remoteKeysNotice)
        XCTAssertEqual(model.notice, AppModel.remoteKeysNotice, "The phone reads it in the state's notice too.")
        XCTAssertTrue(recorder.all("key").isEmpty)
        model.terminalBridge.directKeysAllowed = { true }
        XCTAssertEqual(call(remote, "POST", "/api/key", cookie: cookie, json: ["tab": session.id, "key": "down"])?.status, 200)
        XCTAssertEqual(recorder.all("key"), ["down"])
        XCTAssertEqual(call(remote, "POST", "/api/key", cookie: cookie, json: ["tab": session.id, "key": "pasteImage"])?.status, 400, "Only the contract's keys.")
        XCTAssertEqual(call(remote, "POST", "/api/key", cookie: cookie, json: ["tab": session.id, "key": "keyS"])?.status, 400)
    }

    func testInterruptIsTheIslandsEscape() throws {
        let (model, session, recorder) = RemoteFixture.model(keys: false)
        let (remote, cookie) = try paired(model)
        XCTAssertEqual(call(remote, "POST", "/api/interrupt", cookie: cookie, json: ["tab": session.id])?.status, 403)
        model.terminalBridge.directKeysAllowed = { true }
        XCTAssertEqual(call(remote, "POST", "/api/interrupt", cookie: cookie, json: ["tab": session.id])?.status, 200)
        XCTAssertEqual(recorder.all("key"), ["escape"])
    }

    func testTheModeOnlyCyclesAndWaitsForAnOpenQuestion() throws {
        let (model, session, recorder) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        XCTAssertEqual(call(remote, "POST", "/api/mode/cycle", cookie: cookie, json: ["tab": session.id])?.status, 200)
        XCTAssertEqual(recorder.all("key"), ["backtab"], "⇧⇥, Claude's own key.")
        session.update(RemoteFixture.tab(RemoteFixture.questionScreen()))
        let blocked = call(remote, "POST", "/api/mode/cycle", cookie: cookie, json: ["tab": session.id])
        XCTAssertEqual(blocked?.status, 409)
        XCTAssertEqual(RemoteFixture.json(blocked)["error"] as? String, ClaudeModeStyle.block(running: true, questionOpen: true, panelOpen: false))
        XCTAssertEqual(recorder.all("key"), ["backtab"], "Nothing more pressed.")
    }

    func testAModelIsChosenFromTheTabsList() throws {
        let (model, session, recorder) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let choice = try XCTUnwrap(model.availableModels(for: session).first { $0.argument == "default" })
        XCTAssertEqual(call(remote, "POST", "/api/model", cookie: cookie, json: ["tab": session.id, "id": choice.id])?.status, 200)
        XCTAssertEqual(recorder.all("command"), ["/model default"], "As the model button does.")
        XCTAssertEqual(call(remote, "POST", "/api/model", cookie: cookie, json: ["tab": session.id, "id": "model:nada"])?.status, 404)
        session.update(RemoteFixture.tab(RemoteFixture.claudeScreen(["> hola", "", "✻ Churning… (3s · esc to interrupt)"])))
        let busy = call(remote, "POST", "/api/model", cookie: cookie, json: ["tab": session.id, "id": choice.id])
        XCTAssertEqual(busy?.status, 409)
        XCTAssertEqual(RemoteFixture.json(busy)["error"] as? String, model.modelSwitchBlocked(on: session))
    }

    func testAnOptionIsChosenOnTheLiveQuestionOnly() throws {
        let (model, session, recorder) = RemoteFixture.model(screen: RemoteFixture.questionScreen())
        let (remote, cookie) = try paired(model)
        let signature = try XCTUnwrap(session.prompt?.signature)
        let stale = call(remote, "POST", "/api/prompt/choose", cookie: cookie, json: ["tab": session.id, "signature": "otra", "option": 0])
        XCTAssertEqual(stale?.status, 409)
        XCTAssertEqual(call(remote, "POST", "/api/prompt/choose", cookie: cookie, json: ["tab": session.id, "signature": signature, "option": 9])?.status, 400)
        XCTAssertEqual(call(remote, "POST", "/api/prompt/choose", cookie: cookie, json: ["tab": session.id, "signature": signature, "option": true])?.status, 400, "A bool is no option.")
        XCTAssertEqual(call(remote, "POST", "/api/prompt/choose", cookie: cookie, json: ["tab": session.id, "signature": signature, "option": 1])?.status, 200)
        XCTAssertTrue(recorder.all("script").contains { $0.contains("[B") }, "One write with the arrow and Terminal's Return, as the card does: \(recorder.all("script"))")
    }

    func testChoosingATextFieldMakesTheComposerItsAnswer() throws {
        let question = ["⏺ Antes de seguir necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                        "❯ 1. PostgreSQL", "     Relational, strong consistency", "  2. SQLite", "     Embedded, zero config",
                        "  3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "",
                        "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        let (model, session, recorder) = RemoteFixture.model(screen: question)
        let (remote, cookie) = try paired(model)
        let signature = try XCTUnwrap(session.prompt?.signature)
        let chosen = call(remote, "POST", "/api/prompt/choose", cookie: cookie, json: ["tab": session.id, "signature": signature, "option": 2])
        XCTAssertEqual(chosen?.status, 200)
        XCTAssertEqual(RemoteFixture.json(chosen)["field"] as? Bool, true)
        XCTAssertTrue(recorder.all("script").isEmpty, "A text field takes no key until its answer goes.")
        let field = try XCTUnwrap((RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))["detail"] as? [String: Any])?["field"] as? [String: Any])
        XCTAssertEqual(field["option"] as? Int, 2)
        XCTAssertEqual(field["signature"] as? String, signature)
        XCTAssertEqual(field["question"] as? String, "Which database should we use?")
        XCTAssertEqual(call(remote, "POST", "/api/prompt/field", cookie: cookie, json: ["tab": session.id, "signature": signature, "option": 0, "text": "x"])?.status, 400,
                       "Only a text field takes text.")
        XCTAssertEqual(call(remote, "POST", "/api/prompt/field", cookie: cookie, json: ["tab": session.id, "signature": signature, "option": 2, "text": "  "])?.status, 400,
                       "An empty answer would cancel Claude's question.")
    }

    func testCancellingAQuestionIsEscapeAndNeedsOne() throws {
        let (model, session, recorder) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        XCTAssertEqual(call(remote, "POST", "/api/prompt/cancel", cookie: cookie, json: ["tab": session.id])?.status, 409, "No question, no Escape.")
        session.update(RemoteFixture.tab(RemoteFixture.questionScreen()))
        XCTAssertEqual(call(remote, "POST", "/api/prompt/cancel", cookie: cookie, json: ["tab": session.id])?.status, 200)
        XCTAssertEqual(recorder.all("key"), ["escape"])
    }

    func testAnAgentsConversationOpensAndCloses() throws {
        let screen = RemoteFixture.claudeScreen(["> Diseña las animaciones", "", "⏺ Agent(Design cat pet animations)", "  ⎿  Initializing…"])
        let (model, session, _) = RemoteFixture.model(screen: screen)
        let agent = try XCTUnwrap(session.subagents.first { $0.role == .agent })
        let (remote, cookie) = try paired(model)
        let state = RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))
        let listed = try XCTUnwrap(((state["detail"] as? [String: Any])?["subagents"] as? [[String: Any]])?.first)
        XCTAssertEqual(listed["id"] as? String, agent.id)
        XCTAssertEqual(listed["state"] as? String, "running")
        XCTAssertEqual(call(remote, "POST", "/api/agent/open", cookie: cookie, json: ["tab": session.id, "id": agent.id])?.status, 200)
        XCTAssertEqual(session.viewedAgent, agent.id)
        XCTAssertEqual(call(remote, "POST", "/api/agent/open", cookie: cookie, json: ["tab": session.id, "id": NSNull()])?.status, 200)
        XCTAssertNil(session.viewedAgent, "Back to Claude's conversation.")
        XCTAssertEqual(call(remote, "POST", "/api/agent/open", cookie: cookie, json: ["tab": session.id, "id": "nadie"])?.status, 404)
    }

    func testANewTabOpensInTerminalWithoutTouchingTheIsland() throws {
        let (model, _, recorder) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        XCTAssertEqual(call(remote, "POST", "/api/tabs/new", cookie: cookie, json: ["kind": "codex"])?.status, 200)
        RemoteFixture.waitUntil { model.notice != nil }
        XCTAssertFalse(recorder.all("query").isEmpty, "AppModel.create asked Terminal for its front window.")
        XCTAssertTrue(model.notice?.hasPrefix("No se pudo abrir Codex en Terminal.") == true, model.notice ?? "")
        XCTAssertFalse(model.expanded)
        XCTAssertEqual(call(remote, "POST", "/api/tabs/new", cookie: cookie, json: ["kind": "python"])?.status, 400)
    }

    func testTheScreenToggleIsTheComposersEye() throws {
        let off = try ScreenVisionUIFixture.vision(enabled: false)
        let (model, _, _) = RemoteFixture.model(vision: off)
        let (remote, cookie) = try paired(model)
        XCTAssertEqual(call(remote, "POST", "/api/screen", cookie: cookie, json: ["attach": true])?.status, 409, "Screen vision is off on the Mac.")
        XCTAssertFalse(model.screenVision.attachToMessages)
        model.screenVision.enabled = true
        XCTAssertEqual(call(remote, "POST", "/api/screen", cookie: cookie, json: ["attach": true])?.status, 200)
        XCTAssertTrue(model.screenVision.attachToMessages, "The same eye as the Mac's composer.")
        XCTAssertEqual(call(remote, "POST", "/api/screen", cookie: cookie, json: ["attach": 1])?.status, 400)
        XCTAssertEqual(call(remote, "POST", "/api/screen", cookie: cookie, json: ["attach": false])?.status, 200)
        XCTAssertFalse(model.screenVision.attachToMessages)
        remote.recordingGranted = { false }
        let refused = call(remote, "POST", "/api/screen", cookie: cookie, json: ["attach": true])
        XCTAssertEqual(refused?.status, 409, "On only when the screen can really go (`screen.available`).")
        XCTAssertEqual(RemoteFixture.json(refused)["error"] as? String, RemoteAccess.noRecording)
        XCTAssertFalse(model.screenVision.attachToMessages)
        XCTAssertEqual(call(remote, "POST", "/api/screen", cookie: cookie, json: ["attach": false])?.status, 200, "Off always works.")
        let state = RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))
        XCTAssertEqual((state["screen"] as? [String: Any])?["available"] as? Bool, false)
    }

    func testThePhoneNeverSetsOffACaptureWithoutThePermission() throws {
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        let (remote, cookie) = try paired(model)
        var asked = 0
        remote.recordingGranted = { asked += 1; return false }
        let refused = call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": "mira esto"])
        XCTAssertEqual(refused?.status, 409)
        XCTAssertTrue((RemoteFixture.json(refused)["error"] as? String ?? "").hasPrefix(RemoteAccess.noRecording), RemoteFixture.json(refused).description)
        XCTAssertGreaterThan(asked, 0, "The system's preflight, read right then.")
        XCTAssertTrue(capturer.calls.isEmpty, "No capture, so no permission dialog on the Mac.")
        XCTAssertTrue(recorder.all("message").isEmpty)
        XCTAssertTrue(session.sentHistory.isEmpty, "Nothing went, nothing was remembered: the phone keeps the text.")
        XCTAssertEqual(call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": "/model"])?.status, 200, "A command never carries the screen.")
        // The island is not the phone: its composer captures as it always did (macOS asks there, where the user is).
        var outcome: AppModel.MessageOutcome?
        model.sendMessage("desde la isla", to: session) { outcome = $0 }
        RemoteFixture.waitUntil(10) { outcome != nil }
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(capturer.calls.count, 1)
    }

    // MARK: Screenshots

    func testOnlyAScreenshotThatWentWithAMessageIsServed() throws {
        // The capture itself, and its picture joining the message, are `SharedSendPathTests`'; here the file is written by hand.
        let (model, session, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let folder = try ScreenVisionFixture.folder()
        try ScreenShotFile.prepare(folder)
        let shot = try ScreenShotFile.save([CapturedDisplay(image: ScreenVisionFixture.image(width: 64, height: 40), name: "Pantalla")], in: folder, date: ScreenVisionFixture.date)[0]
        let path = shot.path, name = (path as NSString).lastPathComponent
        XCTAssertTrue(SentShot.isShotName(name), name)
        model.noteSentShots([path], text: "mira esto", for: session)
        let shots = try XCTUnwrap((RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))["detail"] as? [String: Any])?["shots"] as? [[String: Any]])
        XCTAssertEqual(shots.first?["url"] as? String, "/api/shot/" + name)
        XCTAssertEqual(shots.first?["text"] as? String, "mira esto", "The words that went with it, without the path.")
        let image = try XCTUnwrap(call(remote, "GET", "/api/shot/" + name, cookie: cookie))
        XCTAssertEqual(image.status, 200)
        XCTAssertEqual(image.body, try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(image.headers.first { $0.0 == "Content-Type" }?.1, "image/png")
        XCTAssertEqual(image.headers.first { $0.0 == "Cache-Control" }?.1, "private, max-age=86400")
        XCTAssertEqual(call(remote, "GET", "/api/shot/" + name)?.status, 401, "With the cookie only.")
        // A picture of the same kind in the same folder that went with no message is not served, nor is anything named by a path.
        let other = (path as NSString).deletingLastPathComponent + "/pantalla-20261007-140323.png"
        try Data(contentsOf: URL(fileURLWithPath: path)).write(to: URL(fileURLWithPath: other))
        for target in ["/api/shot/pantalla-20261007-140323.png", "/api/shot/../../../../etc/passwd", "/api/shot/%2e%2e%2fetc%2fpasswd", "/api/shot/" + path,
                       "/api/shot/imagen-20261007-140322.png", "/api/shot/"] {
            XCTAssertEqual(call(remote, "GET", target, cookie: cookie)?.status, 404, target)
        }
        // A file that went is served only while it is the one Nook wrote: one swapped for a link is not followed.
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: other)
        XCTAssertEqual(call(remote, "GET", "/api/shot/" + name, cookie: cookie)?.status, 404)
    }

    // MARK: The screenshot alone

    func testWithTheEyeOnAnEmptySendIsTheScreenshotAlone() throws {
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        let (remote, cookie) = try paired(model)
        let state = RemoteFixture.json(call(remote, "GET", "/api/state", cookie: cookie))
        XCTAssertEqual((state["screen"] as? [String: Any])?["attach"] as? Bool, true, "What the page reads: the eye is on…")
        XCTAssertEqual((state["tabs"] as? [[String: Any]])?.first?["agent"] as? String, "claude", "…in an agent's tab.")
        let sent = RemoteFixture.call(remote, RemoteFixture.request("POST", "/api/send", remote: remote, cookie: cookie, json: ["tab": session.id, "text": " \n "]), timeout: 20)
        XCTAssertEqual(sent?.status, 200, String(decoding: sent?.body ?? Data(), as: UTF8.self))
        let message = try XCTUnwrap(recorder.all("message").first)
        let parts = MessageAttachments.parts(of: message)
        XCTAssertEqual(parts.text, "", "Nothing written: not even the spaces.")
        XCTAssertEqual(parts.files.count, 1)
        XCTAssertTrue((parts.files[0] as NSString).lastPathComponent.hasPrefix("pantalla-"))
        XCTAssertEqual(message, parts.files[0], "Exactly the screenshot's path.")
        XCTAssertEqual(capturer.calls.count, 1)
        XCTAssertTrue(session.sentHistory.isEmpty, "Nothing empty in the history ↑ walks.")
        XCTAssertEqual(model.sentShots(for: session).map(\.text), [""])
        XCTAssertEqual(RemoteFixture.call(remote, RemoteFixture.request("POST", "/api/send", remote: remote, cookie: cookie, json: ["tab": session.id]), timeout: 20)?.status, 200,
                       "No text at all is the same.")
        XCTAssertEqual(recorder.all("message").count, 2)
        XCTAssertTrue(session.sentHistory.isEmpty)
    }

    func testWithTheEyeOffOrInAShellAnEmptySendIsRefused() throws {
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: false, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        let shell = TerminalSession(tab: RemoteFixture.tab("$ ls", tty: "/dev/ttys044", processes: ["login", "-zsh"], window: 9), backend: .bundled, bridge: model.terminalBridge)
        model.sessions.append(shell)
        let (remote, cookie) = try paired(model)
        let off = call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": ""])
        XCTAssertEqual(off?.status, 400)
        XCTAssertEqual(RemoteFixture.json(off)["error"] as? String, "Escribe un mensaje o activa la captura de pantalla para enviar solo la captura.")
        model.screenVision.attachToMessages = true
        XCTAssertEqual(call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": shell.id, "text": ""])?.status, 400,
                       "A shell would run the screenshot's path as a command: the screen never goes there.")
        model.screenVision.enabled = false
        XCTAssertEqual(call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": ""])?.status, 400, "Screen vision off: the eye counts for nothing.")
        XCTAssertTrue(recorder.all("message").isEmpty)
        XCTAssertTrue(capturer.calls.isEmpty)
    }

    func testAnOpenTextFieldNeverGetsAnEmptySend() throws {
        let question = ["⏺ Antes de seguir necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                        "  1. PostgreSQL", "  2. SQLite", "❯ 3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "",
                        "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        let capturer = FakeScreenCapturer()
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true, capturer: capturer)
        let (model, session, recorder) = RemoteFixture.model(screen: question, vision: vision)
        XCTAssertNotNil(model.fieldAnswer(for: session))
        let (remote, cookie) = try paired(model)
        let refused = call(remote, "POST", "/api/send", cookie: cookie, json: ["tab": session.id, "text": "  "])
        XCTAssertEqual(refused?.status, 400)
        XCTAssertEqual(RemoteFixture.json(refused)["error"] as? String, "Escribe tu respuesta antes de enviarla.")
        RemoteFixture.waitUntil(0.3) { false }
        XCTAssertTrue(recorder.all("message").isEmpty, "Nothing went to the agent's box instead.")
        XCTAssertTrue(recorder.all("script").isEmpty, "Nothing was written into the field.")
        XCTAssertTrue(capturer.calls.isEmpty, "No screenshot was taken for it.")
        XCTAssertTrue(session.sentHistory.isEmpty)
    }

    // MARK: Settings

    func testLockingHidesTheTabAgainAndTurnsItOff() throws {
        let defaults = RemoteFixture.defaults()
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.remote.unlock()
        let remote = try started(model)
        remote.lock()
        XCTAssertEqual(remote.status, .off)
        XCTAssertFalse(remote.unlocked)
        XCTAssertFalse(defaults.bool(forKey: RemoteAccess.unlockedKey))
        XCTAssertTrue(defaults.object(forKey: RemoteAccess.unlockedKey) != nil, "Saved as locked.")
        XCTAssertFalse(AppModel(receivesSignals: false, defaults: defaults).remote.unlocked)
    }

    func testRemovingADeviceClosesItsStreamAndItsCookieOpensNothing() throws {
        let (model, _, _) = RemoteFixture.model()
        let (remote, cookie) = try paired(model)
        let other = try XCTUnwrap(RemoteFixture.pair(remote))
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        var events = "", ended = false
        let lock = NSLock()
        let opened = expectation(description: "stream"), closed = expectation(description: "closed")
        RawHTTP.background {
            guard let fd = RawHTTP.connect(port: port, timeout: 10) else { return }
            defer { Darwin.close(fd) }
            RawHTTP.write(fd, "GET /api/events HTTP/1.1\r\nHost: \(host)\r\nCookie: nook_remote=\(cookie)\r\n\r\n")
            let text = RawHTTP.stream(fd) { $0.contains("event: state") }
            lock.lock(); events = text; lock.unlock()
            opened.fulfill()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while Darwin.read(fd, &chunk, chunk.count) > 0 {}
            lock.lock(); ended = true; lock.unlock()
            closed.fulfill()
        }
        wait(for: [opened], timeout: 8)
        lock.lock(); XCTAssertTrue(events.contains("event: state")); lock.unlock()
        RemoteFixture.waitUntil { remote.devices.count == 2 }
        // The stream's device is the one paired first.
        let first = try XCTUnwrap(remote.devices.min { $0.pairedAt < $1.pairedAt })
        remote.remove(first)
        wait(for: [closed], timeout: 5)
        lock.lock(); XCTAssertTrue(ended, "Its open stream closed at once."); lock.unlock()
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: cookie)?.status, 401)
        XCTAssertEqual(call(remote, "GET", "/api/state", cookie: other)?.status, 200, "The other device is untouched.")
        RemoteFixture.waitUntil { remote.devices.count == 1 }
        XCTAssertEqual(remote.devices.count, 1)
    }

    func testTheKeyPairsOnceAndTheQRFollowsTheNextOne() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let first = try XCTUnwrap(remote.pairingURL)
        let key = try XCTUnwrap(remote.currentPairingKey)
        XCTAssertEqual(call(remote, "GET", "/pair?k=" + key)?.status, 303)
        RemoteFixture.waitUntil { remote.pairingURL != first }
        let next = try XCTUnwrap(remote.pairingURL)
        XCTAssertNotEqual(next, first, "The QR shows the next key at once.")
        XCTAssertTrue(next.absoluteString.hasSuffix("/pair?k=" + (remote.currentPairingKey ?? "-")))
        let again = call(remote, "GET", "/pair?k=" + key)
        XCTAssertEqual(again?.status, 403, "The same link a second time pairs nothing.")
        XCTAssertTrue(String(decoding: again?.body ?? Data(), as: UTF8.self).contains("Escanea el código QR en Nook → Ajustes → Remoto."))
        XCTAssertEqual(call(remote, "GET", "/pair?k=" + remote.currentPairingKey!)?.status, 303)
    }

    func testANinthDeviceIsRefusedUntilOneIsRemoved() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let cookies = (0..<RemoteRegistry.maxDevices).compactMap { _ in RemoteFixture.pair(remote) }
        XCTAssertEqual(cookies.count, RemoteRegistry.maxDevices)
        let refused = call(remote, "GET", "/pair?k=" + remote.currentPairingKey!)
        XCTAssertEqual(refused?.status, 403)
        XCTAssertTrue(String(decoding: refused?.body ?? Data(), as: UTF8.self).contains("Ya hay 8 dispositivos emparejados. Quita uno en Nook → Ajustes → Remoto."))
        XCTAssertTrue(cookies.allSatisfy { call(remote, "GET", "/api/state", cookie: $0)?.status == 200 }, "Nobody was evicted.")
        RemoteFixture.waitUntil { remote.devices.count == RemoteRegistry.maxDevices }
        remote.remove(remote.devices[0])
        XCTAssertNotNil(RemoteFixture.pair(remote), "Room again.")
    }

    // MARK: The network

    /// The tests' Mac's network, which a test may change while Nook Remote is on.
    private final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var state = (RemoteFixture.interfaces, RemoteFixture.route)
        var value: ([RemoteInterface], RemoteRoute) {
            get { lock.lock(); defer { lock.unlock() }; return state }
            set { lock.lock(); state = newValue; lock.unlock() }
        }
    }

    private func startedOn(_ network: Network, _ model: AppModel) throws -> RemoteAccess {
        let remote = try RemoteFixture.started(model, network: { network.value })
        remotes.append(remote)
        return remote
    }

    func testAnotherNetworkTurnsItOff() throws {
        let network = Network()
        let (model, _, _) = RemoteFixture.model()
        let remote = try startedOn(network, model)
        remote.networkChanged()
        RemoteFixture.waitUntil(0.3) { false }
        XCTAssertTrue(remote.status.isOn, "The same network: it stays on.")
        // Another Wi-Fi: the same interface, another address.
        network.value = (RemoteFixture.interfaces.map { $0.name == "en0" && $0.address.isV4 ? RemoteInterface(name: "en0", address: RemoteIP("10.20.0.7")!, up: true, loopback: false) : $0 },
                         RemoteRoute(interface: "en0", router: "10.20.0.1"))
        remote.networkChanged()
        RemoteFixture.waitUntil { !remote.status.isOn }
        XCTAssertEqual(remote.status, .failed("La red de este Mac cambió y Nook Remoto se apagó. Vuelve a activarlo cuando estés en tu Wi-Fi de casa."))
        XCTAssertNil(remote.pairingURL)
        XCTAssertTrue(remote.devices.isEmpty)
    }

    func testTheSameAddressBehindAnotherRouterIsAnotherNetwork() throws {
        let network = Network()
        let (model, _, _) = RemoteFixture.model()
        let remote = try startedOn(network, model)
        network.value = (RemoteFixture.interfaces, RemoteRoute(interface: "en0", router: "192.168.1.254"))
        remote.networkChanged()
        RemoteFixture.waitUntil { !remote.status.isOn }
        guard case .failed = remote.status else { return XCTFail("\(remote.status)") }
    }

    func testLosingTheNetworkTurnsItOff() throws {
        let network = Network()
        let (model, _, _) = RemoteFixture.model()
        let remote = try startedOn(network, model)
        network.value = (RemoteFixture.interfaces.filter { $0.loopback }, RemoteRoute())
        remote.networkChanged()
        RemoteFixture.waitUntil { !remote.status.isOn }
        guard case .failed = remote.status else { return XCTFail("\(remote.status)") }
    }

    // MARK: The page's scripts

    func testOnlyThePagesOwnScriptsMayRun() throws {
        let script = "document.title = 'Nook';\nconsole.log(\"<b>\");"
        let html = "<!doctype html><title>Nook</title><script>\(script)</script><script src=\"app.js\"></script><script type=\"module\">\r\nlet a = 1\r\n</script>"
        let (model, _, _) = RemoteFixture.model()
        let remote = try RemoteFixture.started(model, page: .files(["index.html": Data(html.utf8)]))
        remotes.append(remote)
        let page = try XCTUnwrap(call(remote, "GET", "/"))
        let policy = try XCTUnwrap(page.headers.first { $0.0 == "Content-Security-Policy" }?.1)
        func hash(_ text: String) -> String { "'sha256-" + Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString() + "'" }
        let scriptSource = try XCTUnwrap(policy.components(separatedBy: "; ").first { $0.hasPrefix("script-src ") })
        XCTAssertEqual(scriptSource, "script-src 'self' \(hash(script)) \(hash("\nlet a = 1\n"))", "Each inline block by its hash (CR LF read as LF); one with src= is a file.")
        XCTAssertFalse(scriptSource.contains("unsafe-inline"))
        XCTAssertTrue(policy.contains("style-src 'self' 'unsafe-inline'"))
    }

    func testTheShippedPagesScriptIsTheOneTheHeaderAllows() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/remote")
        let html = try String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8)
        let (model, _, _) = RemoteFixture.model()
        let remote = try RemoteFixture.started(model, page: .directory(folder))
        remotes.append(remote)
        let policy = try XCTUnwrap(call(remote, "GET", "/")?.headers.first { $0.0 == "Content-Security-Policy" }?.1)
        // The blocks as a browser reads them, found here without the server's code: every "<script…>" with no src, to its "</script>".
        var blocks: [String] = [], rest = html[...]
        while let open = rest.range(of: "<script"), let close = rest[open.upperBound...].range(of: ">"), let end = rest[close.upperBound...].range(of: "</script>") {
            if !rest[open.upperBound..<close.lowerBound].contains("src=") { blocks.append(String(rest[close.upperBound..<end.lowerBound])) }
            rest = rest[end.upperBound...]
        }
        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            let hash = "'sha256-" + Data(SHA256.hash(data: Data(block.replacingOccurrences(of: "\r\n", with: "\n").utf8))).base64EncodedString() + "'"
            XCTAssertTrue(policy.contains(hash), "The shipped script runs under the policy it is served with.")
        }
        XCTAssertFalse(policy.contains("script-src 'self' 'unsafe-inline'"))
        // What the hashes don't allow would break the page: no handler in an attribute, no javascript: link, outside its scripts.
        var markup = html
        for block in blocks { markup = markup.replacingOccurrences(of: block, with: "") }
        markup = markup.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        XCTAssertNil(markup.range(of: #"<[A-Za-z][^>]*\son[a-z]+\s*="#, options: .regularExpression), "An inline event handler would never run.")
        XCTAssertNil(markup.range(of: #"\b(href|src|action|formaction)\s*=\s*["']?\s*javascript:"#, options: [.regularExpression, .caseInsensitive]),
                     "Nor a javascript: link.")
    }

    // MARK: Connections

    func testAStrangerGetsFewConnectionsAndAPairedDeviceMore() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        var answers: [Int] = []
        var idle: [Int32] = []
        let lock = NSLock()
        let done = expectation(description: "connections")
        RawHTTP.background {
            defer { done.fulfill() }
            // Four connections that say nothing hold every place a stranger has.
            for _ in 0..<RemoteServer.maxPerStranger { if let fd = RawHTTP.connect(port: port) { idle.append(fd) } }
            Thread.sleep(forTimeInterval: 0.2)
            if let fd = RawHTTP.connect(port: port, timeout: 2) {
                RawHTTP.write(fd, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
                let status = RawHTTP.read(fd)?.status ?? 0
                lock.lock(); answers.append(status); lock.unlock()
                Darwin.close(fd)
            }
            idle.forEach { Darwin.close($0) }
        }
        wait(for: [done], timeout: 10)
        lock.lock(); XCTAssertEqual(answers, [0], "The fifth is closed unread."); lock.unlock()
        // The same address, once a paired device's cookie came from it, has a paired device's room.
        let cookie = try XCTUnwrap(RemoteFixture.pair(remote))
        let trusted = expectation(description: "trusted")
        var statuses: [Int] = []
        RawHTTP.background {
            defer { trusted.fulfill() }
            guard let first = RawHTTP.connect(port: port) else { return }
            RawHTTP.write(first, "GET /api/state HTTP/1.1\r\nHost: \(host)\r\nCookie: nook_remote=\(cookie)\r\n\r\n")
            statuses.append(RawHTTP.read(first)?.status ?? 0)
            Thread.sleep(forTimeInterval: 0.1)
            var open: [Int32] = [first]
            for _ in 0..<6 {
                guard let fd = RawHTTP.connect(port: port) else { continue }
                RawHTTP.write(fd, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
                statuses.append(RawHTTP.read(fd)?.status ?? 0)
                open.append(fd)
            }
            open.forEach { Darwin.close($0) }
        }
        wait(for: [trusted], timeout: 15)
        XCTAssertEqual(statuses, Array(repeating: 200, count: 7), "Seven open at once from a paired device's address.")
    }

    func testAStrangerMayOpenOnlyAFewConnectionsInAWhile() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        var statuses: [Int] = []
        let done = expectation(description: "connections")
        RawHTTP.background {
            defer { done.fulfill() }
            for _ in 0...RemoteServer.strangerAcceptsPerWindow {
                guard let fd = RawHTTP.connect(port: port, timeout: 2) else { statuses.append(0); continue }
                RawHTTP.write(fd, "GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n")
                statuses.append(RawHTTP.read(fd)?.status ?? 0)
                Darwin.close(fd)
            }
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(statuses, Array(repeating: 200, count: RemoteServer.strangerAcceptsPerWindow) + [0], "One more than \(RemoteServer.strangerAcceptsPerWindow) in ten seconds is refused.")
    }

    // MARK: Live

    func testChangesReachTheStreamCoalesced() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let sink = RecordingSink()
        remote.broadcaster.add(sink)
        RemoteFixture.waitUntil { remote.watching && sink.named("conversation").count == 1 }
        XCTAssertTrue(model.remoteWatching)
        XCTAssertTrue(model.terminalBridge.detailed, "A phone watching reads Terminal as fully as the open island does.")
        XCTAssertEqual(sink.named("state").count, 1)
        let start = Date()
        for index in 0..<40 {
            model.notice = "aviso \(index)"
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let elapsed = Date().timeIntervalSince(start)
        RemoteFixture.waitUntil(2) { sink.named("state").last?["notice"] as? String == "aviso 39" }
        XCTAssertEqual(sink.named("state").last?["notice"] as? String, "aviso 39", "The last change always arrives.")
        let states = sink.named("state").count - 1
        XCTAssertLessThanOrEqual(states, Int((elapsed + 0.5) / RemoteAccess.snapshotInterval) + 1, "At most about five a second: \(states) in \(elapsed) s.")
        XCTAssertLessThan(states, 40)
        sink.close()
        RemoteFixture.waitUntil { !remote.watching }
        XCTAssertFalse(model.remoteWatching)
        XCTAssertFalse(model.terminalBridge.detailed, "Nobody watching: the collapsed island's light reading again.")
    }

    func testANewLineInTheTabIsAnAppendOnTheStream() throws {
        let (model, session, _) = RemoteFixture.model()
        let remote = try started(model)
        let sink = RecordingSink()
        remote.broadcaster.add(sink)
        RemoteFixture.waitUntil { sink.named("conversation").count == 1 }
        session.update(RemoteFixture.tab(RemoteFixture.claudeScreen(["> Revisa por qué falla el build.", "", "⏺ Voy a mirar el log del último build.", "", "⏺ Read(build.log)"])))
        RemoteFixture.waitUntil { sink.named("conversation").count == 2 }
        let update = try XCTUnwrap(sink.named("conversation").last)
        XCTAssertEqual(update["reset"] as? Bool, false)
        XCTAssertGreaterThan(update["from"] as? Int ?? 0, 0, "Only from the first line that changed.")
        let read = try XCTUnwrap((update["lines"] as? [[String: Any]])?.first { $0["text"] as? String == "⏺ Read(build.log)" })
        XCTAssertEqual(read["role"] as? String, "tool")
        XCTAssertEqual(read["name"] as? [Int], [2, 6])
    }

    // MARK: Over the network

    func testTheWholeFlowOverASocket() throws {
        let (model, session, recorder) = RemoteFixture.model()
        let remote = try started(model)
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        let page = try XCTUnwrap(RawHTTP.exchange(port: port, "GET / HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"))
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(String(decoding: page.body, as: UTF8.self), "<!doctype html><title>Nook</title>")
        let pairing = try XCTUnwrap(RawHTTP.exchange(port: port, "GET /pair?k=\(remote.currentPairingKey!) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Mozilla/5.0 (iPhone)\r\n\r\n"))
        XCTAssertEqual(pairing.status, 303)
        let cookie = try XCTUnwrap(pairing.header("Set-Cookie")?.components(separatedBy: ";").first)
        let state = try XCTUnwrap(RawHTTP.exchange(port: port, "GET /api/state HTTP/1.1\r\nHost: \(host)\r\nCookie: \(cookie)\r\n\r\n"))
        XCTAssertEqual(state.status, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: state.body) as? [String: Any])?["selected"] as? String, session.id)
        let body = "{\"tab\":\"\(session.id)\",\"text\":\"hola desde el iPhone\"}"
        let send = try XCTUnwrap(RawHTTP.exchange(port: port, "POST /api/send HTTP/1.1\r\nHost: \(host)\r\nCookie: \(cookie)\r\nOrigin: http://\(host)\r\nX-Nook-Remote: 1\r\n"
                                                  + "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body))
        XCTAssertEqual(send.status, 200, String(decoding: send.body, as: UTF8.self))
        XCTAssertEqual(recorder.all("message"), ["hola desde el iPhone"])
        let huge = try XCTUnwrap(RawHTTP.exchange(port: port, "GET / HTTP/1.1\r\nHost: \(host)\r\nX-Big: " + String(repeating: "a", count: 20_000) + "\r\n\r\n"))
        XCTAssertEqual(huge.status, 431)
    }

    func testKeepAliveServesOneRequestAfterAnother() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        var statuses: [Int] = []
        let done = expectation(description: "two answers")
        RawHTTP.background {
            defer { done.fulfill() }
            guard let fd = RawHTTP.connect(port: port) else { return }
            defer { Darwin.close(fd) }
            RawHTTP.write(fd, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            statuses.append(RawHTTP.read(fd)?.status ?? 0)
            RawHTTP.write(fd, "GET /app.js HTTP/1.1\r\nHost: \(host)\r\n\r\n")
            statuses.append(RawHTTP.read(fd)?.status ?? 0)
        }
        wait(for: [done], timeout: 8)
        XCTAssertEqual(statuses, [200, 200])
    }

    func testTheMacItselfIsRefusedOverASocket() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model, loopback: false)
        // The listener takes nothing over the loopback; were a connection to get through, it would hear the page is for the phone.
        if let answer = RawHTTP.exchange(port: remote.port, "GET / HTTP/1.1\r\nHost: 192.168.1.20:\(remote.port)\r\n\r\n", timeout: 2) {
            XCTAssertEqual(answer.status, 403)
            XCTAssertTrue(String(decoding: answer.body, as: UTF8.self).contains("Nook Remoto es para tu teléfono"))
            XCTAssertEqual(answer.header("Connection"), "close")
        }
    }

    func testTheEventStreamOverASocketAndTurningItOffEndsIt() throws {
        let (model, _, _) = RemoteFixture.model()
        let remote = try started(model)
        let cookie = try XCTUnwrap(RemoteFixture.pair(remote))
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        var received = "", ended = false
        let lock = NSLock()
        let gotEvents = expectation(description: "events")
        let closed = expectation(description: "closed")
        RawHTTP.background {
            guard let fd = RawHTTP.connect(port: port, timeout: 10) else { return }
            defer { Darwin.close(fd) }
            RawHTTP.write(fd, "GET /api/events HTTP/1.1\r\nHost: \(host)\r\nAccept: text/event-stream\r\nCookie: nook_remote=\(cookie)\r\n\r\n")
            let text = RawHTTP.stream(fd) { $0.contains("event: state") && $0.contains("event: conversation") }
            lock.lock(); received = text; lock.unlock()
            gotEvents.fulfill()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while Darwin.read(fd, &chunk, chunk.count) > 0 {}
            lock.lock(); ended = true; lock.unlock()
            closed.fulfill()
        }
        wait(for: [gotEvents], timeout: 8)
        lock.lock()
        XCTAssertTrue(received.hasPrefix("HTTP/1.1 200 OK\r\n"), received)
        XCTAssertTrue(received.contains("Content-Type: text/event-stream"))
        XCTAssertTrue(received.contains("\"selected\":\"\(model.sessions[0].id)\""))
        lock.unlock()
        RemoteFixture.waitUntil { remote.watching }
        XCTAssertTrue(remote.watching)
        remote.stop()
        wait(for: [closed], timeout: 5)
        lock.lock(); XCTAssertTrue(ended, "Turning it off ends every stream."); lock.unlock()
        XCTAssertFalse(model.remoteWatching)
        XCTAssertNil(RawHTTP.exchange(port: port, "GET / HTTP/1.1\r\nHost: \(host)\r\n\r\n", timeout: 2), "And the port is closed.")
    }
}
