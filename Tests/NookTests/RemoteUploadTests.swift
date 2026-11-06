import ImageIO
import XCTest
@testable import Nook

/// Images from the phone (`POST /api/upload`, and `files` on `/api/send`): only real images, under names Nook chooses, the device's
/// own until a message carries them, and then remembered like screenshots; a body over 64 KB is read only once its head passed every
/// check (docs/REMOTE_API.md, "Images from the phone").
@MainActor
final class RemoteUploadTests: XCTestCase {
    private var remotes: [RemoteAccess] = []
    /// The models behind them: a remote holds its model weakly, as Nook's does.
    private var models: [AppModel] = []

    override func tearDown() {
        remotes.forEach { $0.stop() }
        remotes = []
        models = []
        super.tearDown()
    }

    private func paired(vision: ScreenVision? = nil) throws -> (RemoteAccess, String, AppModel, TerminalSession, Recorder) {
        let (model, session, recorder) = RemoteFixture.model(vision: vision)
        models.append(model)
        let remote = try RemoteFixture.started(model)
        remotes.append(remote)
        return (remote, try XCTUnwrap(RemoteFixture.pair(remote)), model, session, recorder)
    }

    private func upload(_ remote: RemoteAccess, _ cookie: String?, _ data: Data, type: String = "image/png", headers: [String: String] = [:]) -> RemoteResponse? {
        RemoteFixture.call(remote, RemoteFixture.upload(data, type: type, remote: remote, cookie: cookie, headers: headers))
    }

    private func send(_ remote: RemoteAccess, _ cookie: String, _ body: [String: Any]) -> RemoteResponse? {
        RemoteFixture.call(remote, RemoteFixture.request("POST", "/api/send", remote: remote, cookie: cookie, json: body))
    }

    private func get(_ remote: RemoteAccess, _ path: String, _ cookie: String?) -> RemoteResponse? {
        RemoteFixture.call(remote, RemoteFixture.request("GET", path, remote: remote, cookie: cookie))
    }

    // MARK: The bytes

    func testTheDeclaredTypeMustBeWhatTheBytesAre() {
        let png = RemoteFixture.image(), jpeg = RemoteFixture.image("public.jpeg" as CFString), gif = RemoteFixture.image("com.compuserve.gif" as CFString)
        XCTAssertTrue(RemoteImageKind.png.matches(png))
        XCTAssertTrue(RemoteImageKind.jpeg.matches(jpeg))
        XCTAssertTrue(RemoteImageKind.gif.matches(gif))
        XCTAssertTrue(RemoteImageKind.webp.matches(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)))
        XCTAssertFalse(RemoteImageKind.png.matches(jpeg))
        XCTAssertFalse(RemoteImageKind.jpeg.matches(png))
        XCTAssertFalse(RemoteImageKind.webp.matches(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEfmt ".utf8)))
        XCTAssertFalse(RemoteImageKind.png.matches(Data()))
        XCTAssertEqual(RemoteImageKind(contentType: "image/jpeg; charset=binary"), .jpeg)
        XCTAssertNil(RemoteImageKind(contentType: "image/heic"), "The page converts HEIC to JPEG first.")
        XCTAssertNil(RemoteImageKind(contentType: "image/svg+xml"), "An SVG is a document, not a picture.")
        XCTAssertNil(RemoteImageKind(contentType: nil))
        XCTAssertEqual(RemoteImages.inspect(png)?.width, 40)
        XCTAssertEqual(RemoteImages.inspect(png)?.height, 30)
        var broken = png.prefix(40)
        broken.append(Data(repeating: 0x41, count: 200))
        XCTAssertNil(RemoteImages.inspect(Data(broken)), "A PNG's signature on bytes that don't decode is no picture.")
        XCTAssertTrue(SentShot.isShotName(RemoteImages.name() + ".jpg"))
        XCTAssertFalse(SentShot.isShotName("imagen-movil-20261105-093012-K3F9A2.jpg"), "Only Nook's own names.")
        XCTAssertFalse(SentShot.isShotName("imagen-20261105-093012.png"), "The island's pasted images are not the phone's to fetch.")
        XCTAssertFalse(SentShot.isShotName("imagen-movil-20261105-093012-k3f9a2.svg"))
    }

    // MARK: Uploading

    func testAnImageIsKeptUnderNooksOwnNameForItsDeviceOnly() throws {
        let (remote, cookie, _, _, _) = try paired()
        let other = try XCTUnwrap(RemoteFixture.pair(remote))
        let response = try XCTUnwrap(upload(remote, cookie, RemoteFixture.image(), headers: ["x-file-name": "../../evil.png"]))
        XCTAssertEqual(response.status, 200, String(decoding: response.body, as: UTF8.self))
        let json = RemoteFixture.json(response)
        let id = try XCTUnwrap(json["id"] as? String)
        XCTAssertTrue(id.hasPrefix("imagen-movil-") && id.hasSuffix(".png"), id)
        XCTAssertTrue(SentShot.isShotName(id))
        XCTAssertEqual(json["url"] as? String, "/api/shot/" + id)
        XCTAssertEqual(json["width"] as? Int, 40)
        XCTAssertEqual(json["height"] as? Int, 30)
        let path = remote.imagesFolder.appendingPathComponent(id).path
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), RemoteFixture.image())
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(get(remote, "/api/shot/" + id, cookie)?.status, 200, "Its device sees it as a preview.")
        XCTAssertEqual(get(remote, "/api/shot/" + id, cookie)?.headers.first { $0.0 == "Content-Type" }?.1, "image/png")
        XCTAssertEqual(get(remote, "/api/shot/" + id, other)?.status, 404, "Another device doesn't, until it went with a message.")
    }

    func testOnlyRealImagesFromThePageAreTaken() throws {
        let (remote, cookie, _, _, _) = try paired()
        let png = RemoteFixture.image()
        XCTAssertEqual(upload(remote, nil, png)?.status, 401)
        XCTAssertEqual(upload(remote, cookie, png, headers: ["x-nook-remote": ""])?.status, 403)
        XCTAssertEqual(upload(remote, cookie, png, headers: ["origin": "http://evil.example"])?.status, 403)
        XCTAssertEqual(upload(remote, cookie, png, type: "text/html")?.status, 415)
        XCTAssertEqual(upload(remote, cookie, png, type: "application/json")?.status, 415)
        XCTAssertEqual(upload(remote, cookie, png, type: "image/jpeg")?.status, 415, "Declared JPEG, but the bytes are a PNG.")
        XCTAssertEqual(upload(remote, cookie, Data("<svg onload=alert(1)>".utf8), type: "image/png")?.status, 415)
        var broken = png.prefix(40)
        broken.append(Data(repeating: 0x41, count: 200))
        XCTAssertEqual(upload(remote, cookie, Data(broken))?.status, 415, "The signature alone is not enough: it must decode.")
        XCTAssertEqual(upload(remote, cookie, Data())?.status, 400)
        XCTAssertEqual(upload(remote, cookie, RemoteFixture.image("public.jpeg" as CFString), type: "image/jpeg")?.status, 200)
        XCTAssertEqual(upload(remote, cookie, RemoteFixture.image("com.compuserve.gif" as CFString), type: "image/gif")?.status, 200)
        let names = try FileManager.default.contentsOfDirectory(atPath: remote.imagesFolder.path)
        XCTAssertEqual(names.count, 2, "Only what passed was written: \(names)")
    }

    func testADeviceHasTwentyWaitingAndThirtyInTenMinutes() throws {
        let (remote, cookie, _, _, _) = try paired()
        let png = RemoteFixture.image()
        for index in 0..<RemoteUploads.maxPending { XCTAssertEqual(upload(remote, cookie, png)?.status, 200, "\(index)") }
        let full = upload(remote, cookie, png)
        XCTAssertEqual(full?.status, 409)
        XCTAssertEqual(RemoteFixture.json(full)["error"] as? String, "Tienes 20 imágenes sin enviar; envía o quita alguna antes de adjuntar otra.")
        let gauge = RemoteUploadGauge(), start = Date()
        for _ in 0..<RemoteUploadGauge.perWindow { XCTAssertTrue(gauge.allows("a", count: true, now: start)) }
        XCTAssertFalse(gauge.allows("a", count: true, now: start.addingTimeInterval(599)))
        XCTAssertTrue(gauge.allows("b", count: false, now: start), "Each device its own.")
        XCTAssertTrue(gauge.allows("a", count: true, now: start.addingTimeInterval(601)))
        let uploads = RemoteUploads()
        XCTAssertTrue(uploads.issue(RemoteUpload(name: "x", path: "/x", device: "a", issued: start, width: 1, height: 1), now: start))
        XCTAssertNotNil(uploads.waiting("x", for: "a", now: start.addingTimeInterval(3599)))
        XCTAssertNil(uploads.waiting("x", for: "a", now: start.addingTimeInterval(3601)), "Not sent within an hour: no longer offered.")
    }

    // MARK: Sending

    func testAMessageCarriesItsImagesAndRemembersThem() throws {
        let (remote, cookie, model, session, recorder) = try paired()
        let other = try XCTUnwrap(RemoteFixture.pair(remote))
        let first = try XCTUnwrap(RemoteFixture.json(upload(remote, cookie, RemoteFixture.image()))["id"] as? String)
        let second = try XCTUnwrap(RemoteFixture.json(upload(remote, cookie, RemoteFixture.image("public.jpeg" as CFString), type: "image/jpeg"))["id"] as? String)
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "mira", "files": [first, second]])?.status, 200)
        let folder = remote.imagesFolder.path
        XCTAssertEqual(recorder.all("message"), ["mira \(folder)/\(first) \(folder)/\(second)"], "As the island's attached images: the words, then the paths.")
        XCTAssertEqual(session.sentHistory.last, "mira \(folder)/\(first) \(folder)/\(second)")
        let shots = try XCTUnwrap((RemoteFixture.json(get(remote, "/api/state", cookie))["detail"] as? [String: Any])?["shots"] as? [[String: Any]])
        XCTAssertEqual(shots.map { $0["url"] as? String }, ["/api/shot/" + first, "/api/shot/" + second])
        XCTAssertEqual(shots.map { $0["text"] as? String }, ["mira", "mira"])
        XCTAssertEqual(get(remote, "/api/shot/" + second, other)?.status, 200, "Sent, it is the conversation's: any paired device sees it.")
        XCTAssertEqual(get(remote, "/api/shot/" + second, other)?.headers.first { $0.0 == "Content-Type" }?.1, "image/jpeg")
        let again = send(remote, cookie, ["tab": session.id, "text": "otra vez", "files": [first]])
        XCTAssertEqual(again?.status, 400, "Used up.")
        XCTAssertEqual(RemoteFixture.json(again)["error"] as? String, "La imagen ya no está disponible; adjúntala otra vez.")
        XCTAssertEqual(model.sentShots(for: session).count, 2)
    }

    func testOnlyThisDevicesWaitingImagesMayGo() throws {
        let (remote, cookie, _, session, recorder) = try paired()
        let other = try XCTUnwrap(RemoteFixture.pair(remote))
        let theirs = try XCTUnwrap(RemoteFixture.json(upload(remote, other, RemoteFixture.image()))["id"] as? String)
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": [theirs]])?.status, 400, "Another device's image.")
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": ["imagen-movil-20261105-093012-aaaaaa.png"]])?.status, 400)
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": ["../../etc/passwd"]])?.status, 400)
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": [1]])?.status, 400)
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": "uno"])?.status, 400)
        let six = (0..<6).compactMap { _ in RemoteFixture.json(upload(remote, cookie, RemoteFixture.image()))["id"] as? String }
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": six])?.status, 400, "Five at most.")
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "x", "files": [six[0], six[0]]])?.status, 400)
        XCTAssertTrue(recorder.all("message").isEmpty, "Nothing went.")
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "files": [six[0]]])?.status, 200, "Images alone, without words.")
        XCTAssertEqual(recorder.all("message"), [remote.imagesFolder.path + "/" + six[0]])
    }

    func testImagesOfAMessageThatDidNotGoWaitForAnotherTry() throws {
        let (remote, cookie, model, session, recorder) = try paired()
        let id = try XCTUnwrap(RemoteFixture.json(upload(remote, cookie, RemoteFixture.image()))["id"] as? String)
        model.messageSender = { _, _, done in done(false) }
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "mira", "files": [id]])?.status, 502)
        XCTAssertTrue(model.sentShots(for: session).isEmpty)
        model.messageSender = { text, _, done in recorder.note("message", text); done(true) }
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "mira", "files": [id]])?.status, 200, "The same image, on the retry.")
        XCTAssertEqual(model.sentShots(for: session).map(\.name), [id])
    }

    func testTheScreenGoesAfterThePhonesImages() throws {
        let vision = try ScreenVisionUIFixture.vision(enabled: true, attach: true)
        let (remote, cookie, model, session, recorder) = try paired(vision: vision)
        let id = try XCTUnwrap(RemoteFixture.json(upload(remote, cookie, RemoteFixture.image()))["id"] as? String)
        XCTAssertEqual(RemoteFixture.call(remote, RemoteFixture.request("POST", "/api/send", remote: remote, cookie: cookie, json: ["tab": session.id, "text": "mira", "files": [id]]),
                                          timeout: 20)?.status, 200)
        let files = MessageAttachments.parts(of: try XCTUnwrap(recorder.all("message").first)).files
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual((files[0] as NSString).lastPathComponent, id)
        XCTAssertTrue((files[1] as NSString).lastPathComponent.hasPrefix("pantalla-"))
        XCTAssertEqual(model.sentShots(for: session).map { ($0.name as NSString).substring(to: 9) }, ["imagen-mo", "pantalla-"], "Remembered in the message's order.")
    }

    func testAQuestionsTextFieldTakesNoImages() throws {
        let question = ["⏺ Antes de seguir necesito una decisión.", "", "☐ Database", "", "Which database should we use?", "",
                        "  1. PostgreSQL", "  2. SQLite", "❯ 3. Type something.", String(repeating: "─", count: 60), "  4. Chat about this", "",
                        "Enter to select · ↑/↓ to navigate · Esc to cancel"].joined(separator: "\n")
        let (model, session, _) = RemoteFixture.model(screen: question)
        let remote = try RemoteFixture.started(model)
        remotes.append(remote)
        let cookie = try XCTUnwrap(RemoteFixture.pair(remote))
        XCTAssertNotNil(model.fieldAnswer(for: session))
        let id = try XCTUnwrap(RemoteFixture.json(upload(remote, cookie, RemoteFixture.image()))["id"] as? String)
        XCTAssertEqual(send(remote, cookie, ["tab": session.id, "text": "SQLite con WAL", "files": [id]])?.status, 409)
        RemoteFixture.waitUntil { !remote.devices.isEmpty }
        XCTAssertNotNil(remote.uploads.waiting(id, for: try XCTUnwrap(remote.devices.first).id), "It waits for the next message.")
    }

    func testRemovingADeviceDropsItsWaitingImages() throws {
        let (remote, cookie, _, _, _) = try paired()
        let id = try XCTUnwrap(RemoteFixture.json(upload(remote, cookie, RemoteFixture.image()))["id"] as? String)
        RemoteFixture.waitUntil { !remote.devices.isEmpty }
        let device = try XCTUnwrap(remote.devices.first)
        remote.remove(device)
        XCTAssertNil(remote.uploads.waiting(id, for: device.id))
    }

    // MARK: Large bodies over the network

    func testABigBodyIsReadOnlyOnceItsHeadPassedEveryCheck() throws {
        let (remote, cookie, _, _, _) = try paired()
        let port = remote.port, host = "127.0.0.1:\(remote.port)"
        func head(_ path: String = "/api/upload", length: Int, cookie: String? = nil, type: String = "image/png") -> String {
            "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nX-Nook-Remote: 1\r\nOrigin: http://\(host)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\n"
                + (cookie.map { "Cookie: nook_remote=\($0)\r\n" } ?? "") + "\r\n"
        }
        // Each is answered without a byte of its body sent: the decision comes from the head.
        let refusals: [(String, Int)] = [
            (head(length: 5_000_000), 401),
            (head(length: 13 * 1024 * 1024, cookie: cookie), 413),
            (head(length: 5_000_000, cookie: cookie, type: "application/octet-stream"), 415),
            (head("/api/send", length: 200_000, cookie: cookie, type: "application/json"), 413),
        ]
        for (request, status) in refusals {
            let start = Date()
            XCTAssertEqual(RawHTTP.exchange(port: port, request, timeout: 3)?.status, status, request)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "At once, not after a timeout.")
        }
        // A real photo-sized image from a paired device goes through.
        let big = RemoteFixture.image(width: 600, height: 400, noise: true)
        XCTAssertGreaterThan(big.count, RemoteHTTPParser.maxBody)
        var answer: RawHTTP.Answer?
        let done = expectation(description: "uploaded")
        RawHTTP.background {
            defer { done.fulfill() }
            guard let fd = RawHTTP.connect(port: port, timeout: 10) else { return }
            defer { Darwin.close(fd) }
            RawHTTP.write(fd, head(length: big.count, cookie: cookie))
            _ = big.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            answer = RawHTTP.read(fd)
        }
        wait(for: [done], timeout: 15)
        XCTAssertEqual(answer?.status, 200, answer.map { String(decoding: $0.body, as: UTF8.self) } ?? "no answer")
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: answer?.body ?? Data()) as? [String: Any])?["width"] as? Int, 600)
    }

    func testTwoLargeUploadsAtATimeAndTheRightsGoBack() throws {
        let (remote, cookie, _, _, _) = try paired()
        let head = RemoteFixture.upload(Data(), remote: remote, cookie: cookie, headers: ["content-length": "200000"])
        let peer = RemoteFixture.peer(remote)
        var releases: [() -> Void] = []
        for _ in 0..<RemoteUploadGauge.inFlight {
            guard case .large(let limit, let timeout, let release) = remote.bodyDecision(for: head, from: peer) else { return XCTFail() }
            XCTAssertEqual(limit, RemoteImages.maxBytes)
            XCTAssertEqual(timeout, RemoteImages.uploadTimeout)
            releases.append(release)
        }
        guard case .refuse(let busy) = remote.bodyDecision(for: head, from: peer) else { return XCTFail("A third waits.") }
        XCTAssertEqual(busy.status, 503)
        releases[0](); releases[0]()
        guard case .large = remote.bodyDecision(for: head, from: peer) else { return XCTFail("Released once, however often called.") }
        guard case .refuse = remote.bodyDecision(for: head, from: peer) else { return XCTFail("A double release frees one place only.") }
        let stranger = RemotePeer(address: RemoteIP("192.168.1.20")!, verdict: .thisMac, port: remote.port)
        guard case .refuse(let mac) = remote.bodyDecision(for: head, from: stranger) else { return XCTFail() }
        XCTAssertEqual(mac.status, 403, "Never from the Mac itself.")
        var other = head
        other.path = "/api/log"
        guard case .refuse(let elsewhere) = remote.bodyDecision(for: other, from: peer) else { return XCTFail() }
        XCTAssertEqual(elsewhere.status, 413, "Only an upload may be large.")
    }
}
