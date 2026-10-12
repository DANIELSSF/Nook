import AppKit
import XCTest
@testable import Nook

/// What the screen vision tests share: pictures made in code, a capturer that never asks macOS for anything (no test can hold the
/// Screen Recording permission), a registrar that never runs Claude, and private folders and sockets of their own.
enum ScreenVisionFixture {
    /// A picture of `width`×`height` pixels: a two-tone pattern (small as PNG), or noise (large as PNG, as a photo would be).
    static func image(width: Int, height: Int, noise: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if noise, let data = context.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            var seed: UInt32 = 0x9E3779B9
            for index in 0..<(width * height * 4) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 24)
            }
        } else {
            context.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.3, green: 0.75, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
        return context.makeImage()!
    }

    /// A private folder for screenshots, inside one of the user's own (as `/tmp/nook-<uid>` is).
    static func folder() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nsv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base.appendingPathComponent("images")
    }

    /// A socket path short enough for `sockaddr_un`.
    static func socketPath() -> String { NSTemporaryDirectory() + "nsv-\(UUID().uuidString.prefix(8)).sock" }

    static func defaults() -> UserDefaults {
        let name = "nook-screen-vision-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func posixPermissions(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// 7 October 2026, 14:03:22 local time, a whole second.
    static var date: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 3, second: 22))!
    }
}

/// A capturer that hands back what the test says, and remembers what it was asked.
final class FakeScreenCapturer: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(choice: ScreenDisplayChoice, pid: pid_t, maxLongEdge: Int)] = []
    var result: Result<[CapturedDisplay], Error>
    var delay: TimeInterval = 0

    init(_ result: Result<[CapturedDisplay], Error> = .success([CapturedDisplay(image: ScreenVisionFixture.image(width: 1512, height: 982), name: "Pantalla integrada")])) {
        self.result = result
    }

    var calls: [(choice: ScreenDisplayChoice, pid: pid_t, maxLongEdge: Int)] { lock.lock(); defer { lock.unlock() }; return _calls }

    func capture(_ choice: ScreenDisplayChoice, excluding pid: pid_t, maxLongEdge: Int) async throws -> [CapturedDisplay] {
        lock.lock(); _calls.append((choice, pid, maxLongEdge)); lock.unlock()
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return try result.get()
    }
}

/// A registrar that answers as told and remembers the order of the jobs.
final class FakeRegistrar: ScreenVisionRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var registerResult: Result<ScreenVisionRegistrationResult, Error> = .success(ScreenVisionRegistrationResult(folders: ["~/.claude", "~/.claude-work"], added: ["~/.claude", "~/.claude-work"]))
    var unregisterResult: Result<ScreenVisionRegistrationResult, Error> = .success(ScreenVisionRegistrationResult(folders: ["~/.claude", "~/.claude-work"]))

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func register() throws -> ScreenVisionRegistrationResult {
        lock.lock(); _calls.append("register"); lock.unlock()
        return try registerResult.get()
    }

    func unregister() throws -> ScreenVisionRegistrationResult {
        lock.lock(); _calls.append("unregister"); lock.unlock()
        return try unregisterResult.get()
    }
}

@MainActor
final class ScreenVisionTests: XCTestCase {
    private func vision(_ capturer: FakeScreenCapturer = FakeScreenCapturer(), registrar: FakeRegistrar = FakeRegistrar(), defaults: UserDefaults = ScreenVisionFixture.defaults(),
                        folder: URL? = nil, timeout: TimeInterval = 2) throws -> ScreenVision {
        ScreenVision(defaults: defaults, capturer: capturer, registrar: registrar, folder: try folder ?? ScreenVisionFixture.folder(),
                     relayPath: ScreenVisionFixture.socketPath(), ownPID: 4242, timeout: timeout, now: { ScreenVisionFixture.date })
    }

    /// Lets the main queue run (where jobs report back) until `condition` holds.
    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    // MARK: The setting

    func testItIsOffByDefaultAndRemembersBothSwitches() throws {
        let defaults = ScreenVisionFixture.defaults()
        let vision = try vision(defaults: defaults)
        XCTAssertFalse(vision.enabled, "Nobody's screen is seen until they turn it on.")
        XCTAssertFalse(vision.attachToMessages)
        XCTAssertFalse(vision.attachesToMessages)
        vision.attachToMessages = true
        XCTAssertFalse(vision.attachesToMessages, "The composer's toggle does nothing while the setting is off.")
        vision.enabled = true
        XCTAssertTrue(vision.attachesToMessages)
        XCTAssertTrue(defaults.bool(forKey: "nook.screenVision.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "nook.screenVision.attach"))
        let again = try self.vision(defaults: defaults)
        XCTAssertTrue(again.enabled); XCTAssertTrue(again.attachToMessages, "Both switches come back after a relaunch.")
        XCTAssertEqual(again.registration, .idle, "A model that was not started registers nothing.")
        again.enabled = false
        XCTAssertFalse(again.attachToMessages, "Turning the setting off disarms the composer's toggle too.")
        XCTAssertFalse(defaults.bool(forKey: "nook.screenVision.attach"))
        again.enabled = true
        XCTAssertFalse(again.attachesToMessages, "Back on, no message carries the screen until the toggle is turned on again.")
    }

    func testOnlyAMessageToAnAgentThatIsNotACommandCarriesTheScreen() throws {
        let vision = try vision()
        XCTAssertFalse(vision.offersToggle(for: .claude), "No toggle while the setting is off.")
        vision.enabled = true; vision.attachToMessages = true
        XCTAssertTrue(vision.offersToggle(for: .claude)); XCTAssertTrue(vision.offersToggle(for: .codex))
        XCTAssertFalse(vision.offersToggle(for: nil), "A plain shell has no use for it.")
        XCTAssertTrue(vision.attaches(text: "¿qué ves en este error?", agent: .claude))
        XCTAssertTrue(vision.attaches(text: "mira esto", agent: .codex), "Codex opens an image path too.")
        XCTAssertTrue(vision.attaches(text: "", agent: .claude), "An image on its own still goes with the screen.")
        XCTAssertFalse(vision.attaches(text: "ls -la", agent: nil), "A shell would get the path as an argument.")
        XCTAssertFalse(vision.attaches(text: "/model opus", agent: .claude), "A path after a command would change it.")
        XCTAssertFalse(vision.attaches(text: "  /clear", agent: .claude))
        XCTAssertFalse(vision.attaches(text: "!git status", agent: .claude), "Claude's shell mode would run the path.")
        XCTAssertTrue(vision.attaches(text: "usa /tmp/x como carpeta", agent: .claude), "A slash later in the text is just text.")
        vision.attachToMessages = false
        XCTAssertFalse(vision.attaches(text: "mira esto", agent: .claude))
    }

    // MARK: Capturing

    func testACaptureLeavesNookOutAndSavesAPrivatePNGAtPointSize() async throws {
        let capturer = FakeScreenCapturer()
        let folder = try ScreenVisionFixture.folder()
        let vision = try vision(capturer, folder: folder)
        vision.enabled = true
        let shots = try await vision.capture(origin: .claude)
        XCTAssertEqual(capturer.calls.count, 1)
        XCTAssertEqual(capturer.calls.first?.choice, .pointer, "The display under the pointer, unless asked otherwise.")
        XCTAssertEqual(capturer.calls.first?.pid, 4242, "Nook's own process is the one left out of the picture.")
        XCTAssertEqual(capturer.calls.first?.maxLongEdge, 1920)
        let shot = try XCTUnwrap(shots.first)
        XCTAssertEqual(shots.count, 1)
        XCTAssertEqual((shot.path as NSString).lastPathComponent, "pantalla-20261007-140322.png")
        XCTAssertEqual((shot.path as NSString).deletingLastPathComponent, folder.path)
        XCTAssertEqual(shot.mimeType, "image/png")
        XCTAssertEqual(shot.display, "Pantalla integrada")
        XCTAssertEqual([shot.width, shot.height], [1512, 982])
        XCTAssertEqual(shot.date, ScreenVisionFixture.date)
        XCTAssertNotNil(NSImage(contentsOfFile: shot.path))
        XCTAssertEqual(ScreenVisionFixture.posixPermissions(shot.path), 0o600, "Only the user can read a picture of their screen.")
        XCTAssertEqual(ScreenVisionFixture.posixPermissions(folder.path), 0o700)
        XCTAssertEqual(vision.lastCapture?.origin, .claude)
        XCTAssertEqual(vision.lastCapture?.shots, shots)
        XCTAssertEqual(vision.lastCapture?.cue, "Claude miró tu pantalla")
    }

    func testEveryDisplayGetsItsOwnFileAndNoCaptureOverwritesAnother() async throws {
        let capturer = FakeScreenCapturer(.success([CapturedDisplay(image: ScreenVisionFixture.image(width: 1512, height: 982), name: "Integrada"),
                                                    CapturedDisplay(image: ScreenVisionFixture.image(width: 1920, height: 1080), name: "Externa")]))
        let vision = try vision(capturer)
        vision.enabled = true
        let shots = try await vision.capture(.all, origin: .claude)
        XCTAssertEqual(capturer.calls.first?.choice, .all)
        XCTAssertEqual(shots.map { ($0.path as NSString).lastPathComponent }, ["pantalla-20261007-140322-1.png", "pantalla-20261007-140322-2.png"])
        XCTAssertEqual(shots.map(\.display), ["Integrada", "Externa"])
        // The same second again (the clock is fixed): new names, the earlier files untouched.
        let again = try await vision.capture(.all, origin: .composer)
        XCTAssertEqual(again.map { ($0.path as NSString).lastPathComponent }, ["pantalla-20261007-140322-1-2.png", "pantalla-20261007-140322-2-2.png"])
        XCTAssertTrue(shots.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testACaptureWhileOffIsRefusedWithoutLooking() async throws {
        let capturer = FakeScreenCapturer()
        let vision = try vision(capturer)
        do {
            _ = try await vision.capture(origin: .claude)
            XCTFail("It must not capture while off.")
        } catch {
            XCTAssertEqual(error as? ScreenVisionError, .disabled)
            XCTAssertEqual(error.localizedDescription, "La visión de pantalla está desactivada en Nook. Actívala en los ajustes de Nook para que Claude pueda ver tu pantalla.")
        }
        XCTAssertTrue(capturer.calls.isEmpty, "The screen is not even looked at.")
        XCTAssertNil(vision.lastCapture)
    }

    func testTheCapturersReasonsComeThroughInTheUsersWords() async throws {
        let capturer = FakeScreenCapturer(.failure(ScreenVisionError.noPermission))
        let vision = try vision(capturer)
        vision.enabled = true
        do { _ = try await vision.capture(origin: .claude); XCTFail() } catch {
            XCTAssertEqual(error as? ScreenVisionError, .noPermission)
            XCTAssertEqual(error.localizedDescription, "Nook no tiene permiso para grabar la pantalla. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema.")
            XCTAssertTrue(PermissionHelp.opensPermissions(error.localizedDescription), "The island's notice offers the Permisos tab.")
        }
        capturer.result = .failure(NSError(domain: "SCStreamErrorDomain", code: -3802, userInfo: [NSLocalizedDescriptionKey: "La pantalla no está disponible."]))
        do { _ = try await vision.capture(origin: .claude); XCTFail() } catch {
            XCTAssertEqual(error as? ScreenVisionError, .failed("La pantalla no está disponible."))
            XCTAssertEqual(error.localizedDescription, "No se pudo capturar la pantalla: La pantalla no está disponible.")
        }
        capturer.result = .success([])
        do { _ = try await vision.capture(origin: .claude); XCTFail() } catch {
            XCTAssertEqual(error as? ScreenVisionError, .noDisplay)
        }
    }

    func testACaptureThatNeverAnswersTimesOut() async throws {
        let capturer = FakeScreenCapturer()
        capturer.delay = 3
        let vision = try vision(capturer, timeout: 0.2)
        vision.enabled = true
        let started = Date()
        do { _ = try await vision.capture(origin: .claude); XCTFail() } catch {
            XCTAssertEqual(error as? ScreenVisionError, .timedOut)
            XCTAssertEqual(error.localizedDescription, "La captura de pantalla tardó demasiado.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The caller is not held until the capture gives up.")
    }

    // MARK: The composer's send

    func testWithoutTheScreenTheMessageGoesAtOnceAsBefore() throws {
        let capturer = FakeScreenCapturer()
        let vision = try vision(capturer)
        var delivered: [String]?
        vision.prepareMessage(files: ["/tmp/a.png"], withScreen: false, deliver: { delivered = $0 }, failed: { XCTFail($0) })
        XCTAssertEqual(delivered, ["/tmp/a.png"], "Same turn, no capture.")
        XCTAssertFalse(vision.capturing)
        XCTAssertTrue(capturer.calls.isEmpty)
    }

    func testWithTheScreenTheFreshShotGoesAfterTheAttachedImages() throws {
        let vision = try vision()
        vision.enabled = true; vision.attachToMessages = true
        var delivered: [String]?
        vision.prepareMessage(files: ["/tmp/a.png"], withScreen: true, deliver: { delivered = $0 }, failed: { XCTFail($0) })
        XCTAssertTrue(vision.capturing, "The message waits for its screenshot.")
        XCTAssertNil(delivered)
        waitUntil { delivered != nil }
        let files = try XCTUnwrap(delivered)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files.first, "/tmp/a.png")
        XCTAssertTrue(files[1].hasSuffix("/pantalla-20261007-140322.png"), files[1])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1]))
        XCTAssertFalse(vision.capturing)
        XCTAssertEqual(vision.lastCapture?.origin, .composer)
        XCTAssertEqual(vision.lastCapture?.cue, "Pantalla adjunta al mensaje")
        XCTAssertEqual(MessageAttachments.message(text: "¿qué falla aquí?", files: files), "¿qué falla aquí? /tmp/a.png " + files[1],
                       "The agent gets the screenshot as a path at the end, like a pasted image.")
    }

    func testAFailedCaptureSendsNothingAndSaysWhy() throws {
        let capturer = FakeScreenCapturer(.failure(ScreenVisionError.noPermission))
        let vision = try vision(capturer)
        vision.enabled = true; vision.attachToMessages = true
        var delivered = false
        var notice: String?
        vision.prepareMessage(files: [], withScreen: true, deliver: { _ in delivered = true }, failed: { notice = $0 })
        waitUntil { notice != nil }
        XCTAssertFalse(delivered, "Claude would not have seen the screen: nothing goes.")
        XCTAssertEqual(notice, "No se envió el mensaje porque no se pudo adjuntar tu pantalla: Nook no tiene permiso para grabar la pantalla. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema. Tu mensaje sigue en el campo.")
        XCTAssertTrue(PermissionHelp.opensPermissions(notice ?? ""))
        XCTAssertFalse(vision.capturing)
        XCTAssertNil(vision.lastCapture)
    }

    func testTheSettingTurnedOffMeanwhileKeepsTheMessage() throws {
        let vision = try vision()
        vision.enabled = true; vision.attachToMessages = true
        var notice: String?
        vision.prepareMessage(files: [], withScreen: true, deliver: { _ in XCTFail("Sent without the screen") }, failed: { notice = $0 })
        vision.enabled = false
        waitUntil { notice != nil }
        XCTAssertTrue(notice?.contains("desactivada") == true, notice ?? "")
    }

    // MARK: The pictures

    func testThePictureIsTheDisplaysPointSizeNeverLargerThan1920() {
        func size(_ width: CGFloat, _ height: CGFloat) -> [Int] {
            let size = ScreenShotFile.outputSize(points: CGSize(width: width, height: height), maxLongEdge: 1920)
            return [size.width, size.height]
        }
        XCTAssertEqual(size(1512, 982), [1512, 982], "A MacBook's display in points stays as it is.")
        XCTAssertEqual(size(2560, 1440), [1920, 1080])
        XCTAssertEqual(size(1080, 1920), [1080, 1920], "A display turned upright is measured on its long side too.")
        XCTAssertEqual(size(3440, 1440), [1920, 804])
        XCTAssertEqual(size(1280, 800), [1280, 800], "Never scaled up.")
        XCTAssertEqual(size(0, 0), [1, 1])
    }

    func testTheDisplayUnderThePointerIsTheOneTaken() {
        let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [(1, CGRect(x: 0, y: 0, width: 1512, height: 982)), (2, CGRect(x: 1512, y: -200, width: 2560, height: 1440))]
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .pointer, pointer: CGPoint(x: 2000, y: 100), main: 1), [2])
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .pointer, pointer: CGPoint(x: 300, y: 500), main: 1), [1])
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .pointer, pointer: nil, main: 2), [2], "No pointer: the main display.")
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .pointer, pointer: CGPoint(x: -50, y: -50), main: 1), [1], "Off every display: the main one.")
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .main, pointer: CGPoint(x: 2000, y: 100), main: 1), [1])
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .main, pointer: nil, main: 99), [1], "A main display that is gone: the first.")
        XCTAssertEqual(ScreenShotFile.chooseDisplays(displays, choice: .all, pointer: nil, main: 1), [1, 2])
        XCTAssertEqual(ScreenShotFile.chooseDisplays([], choice: .pointer, pointer: .zero, main: 1), [])
    }

    func testAScreenFullOfPhotosGoesAsJPEGToStaySmall() throws {
        let ui = try XCTUnwrap(ScreenShotFile.encode(ScreenVisionFixture.image(width: 1512, height: 982)))
        XCTAssertEqual(ui.mimeType, "image/png", "Text and flat colours stay lossless.")
        XCTAssertEqual(ui.ext, "png")
        XCTAssertLessThan(ui.data.count, ScreenShotFile.pngLimit)
        let noise = ScreenVisionFixture.image(width: 1200, height: 800, noise: true)
        let photo = try XCTUnwrap(ScreenShotFile.encode(noise))
        XCTAssertEqual(photo.mimeType, "image/jpeg", "\(photo.data.count) bytes")
        XCTAssertEqual(photo.ext, "jpg")
        let png = try XCTUnwrap(ScreenShotFile.encode(noise, pngLimit: .max))
        XCTAssertLessThan(photo.data.count, png.data.count)
        XCTAssertNotNil(NSImage(data: photo.data))
    }

    func testOnlyThisFeaturesOldScreenshotsAreCleared() throws {
        let folder = try ScreenVisionFixture.folder()
        try ScreenShotFile.prepare(folder)
        let manager = FileManager.default
        let old = ScreenVisionFixture.date.addingTimeInterval(-2 * 24 * 60 * 60)
        for name in ["pantalla-20261005-100000.png", "imagen-05102026100000.png", "pantalla-20261007-130000.png"] {
            manager.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([1]))
        }
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: folder.appendingPathComponent("pantalla-20261005-100000.png").path)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: folder.appendingPathComponent("imagen-05102026100000.png").path)
        try manager.setAttributes([.modificationDate: ScreenVisionFixture.date.addingTimeInterval(-3600)], ofItemAtPath: folder.appendingPathComponent("pantalla-20261007-130000.png").path)
        ScreenShotFile.prune(folder, now: ScreenVisionFixture.date)
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: folder.path)), ["imagen-05102026100000.png", "pantalla-20261007-130000.png"],
                       "A pasted image is not this feature's to clear, and an hour-old screenshot stays.")
    }

    func testAFolderThatIsALinkIsNotWrittenThrough() async throws {
        let folder = try ScreenVisionFixture.folder()
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nsv-elsewhere-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
        let vision = try vision(folder: folder)
        vision.enabled = true
        do { _ = try await vision.capture(origin: .claude); XCTFail("It wrote through a link.") } catch {
            guard case .failed(let reason)? = error as? ScreenVisionError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("no es privada"), reason)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    // MARK: The permission

    func testScreenRecordingIsAnOptionalPermissionWithItsOwnPane() {
        let permission = NookPermission.screenRecording
        XCTAssertFalse(permission.essential)
        XCTAssertEqual(permission.title, "Grabación de pantalla")
        XCTAssertTrue(permission.settingsURL.absoluteString.hasSuffix("?Privacy_ScreenCapture"))
        XCTAssertTrue(permission.steps[0].contains("Privacidad y seguridad → Grabación de pantalla y audio del sistema"), permission.steps[0])
        XCTAssertNotNil(NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil))
        XCTAssertEqual(NookPermission.screenRecordingState(granted: true, asked: false), .granted)
        XCTAssertEqual(NookPermission.screenRecordingState(granted: true, asked: true), .granted)
        XCTAssertEqual(NookPermission.screenRecordingState(granted: false, asked: false), .notAsked, "macOS can still show its prompt.")
        XCTAssertEqual(NookPermission.screenRecordingState(granted: false, asked: true), .denied, "After the prompt only System Settings can turn it on.")
        XCTAssertEqual(permission.presentation(for: .notAsked).action, .request)
        XCTAssertEqual(permission.presentation(for: .denied).action, .openSettings)
    }

    // MARK: Registering the tool

    func testNothingIsRegisteredBeforeTheAppStartsIt() throws {
        let registrar = FakeRegistrar()
        let vision = try vision(registrar: registrar)
        vision.enabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(registrar.calls, [], "A test or a preview never reaches Claude's configuration.")
        XCTAssertEqual(vision.registration, .idle)
    }

    func testTurningItOnRegistersTheToolAndAskForARestartThenOffRemovesIt() throws {
        let registrar = FakeRegistrar()
        let vision = try vision(registrar: registrar)
        vision.start(serving: false)
        XCTAssertEqual(registrar.calls, [], "Off: nothing to do at launch.")
        vision.enabled = true
        XCTAssertEqual(vision.registration, .working("Añadiendo la herramienta a Claude Code…"))
        waitUntil { vision.registration != .working("Añadiendo la herramienta a Claude Code…") }
        XCTAssertEqual(vision.registration, .ready(["~/.claude", "~/.claude-work"]))
        XCTAssertTrue(vision.needsClaudeRestart, "Sessions already open only see a new tool after a restart.")
        XCTAssertEqual(ScreenVision.describe(vision.registration), "Claude puede pedir una captura con la herramienta capture_screen (~/.claude y ~/.claude-work).")
        vision.enabled = false
        XCTAssertEqual(vision.registration, .working("Quitando la herramienta de Claude Code…"))
        waitUntil { vision.registration == .idle }
        XCTAssertEqual(registrar.calls, ["register", "unregister"])
        XCTAssertFalse(vision.needsClaudeRestart)
    }

    func testAtLaunchWhileOnItMakesSureTheToolIsThere() throws {
        let defaults = ScreenVisionFixture.defaults()
        defaults.set(true, forKey: ScreenVision.enabledKey)
        let registrar = FakeRegistrar()
        registrar.registerResult = .success(ScreenVisionRegistrationResult(folders: ["~/.claude"], added: []))
        let vision = try vision(registrar: registrar, defaults: defaults)
        vision.start(serving: false)
        waitUntil { vision.registration == .ready(["~/.claude"]) }
        XCTAssertEqual(registrar.calls, ["register"])
        XCTAssertFalse(vision.needsClaudeRestart, "Already registered everywhere: no restart to ask for.")
        vision.start(serving: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(registrar.calls, ["register"], "Started once.")
    }

    func testAFailedRegistrationSaysWhyAndCanBeRetried() throws {
        let registrar = FakeRegistrar()
        registrar.registerResult = .failure(ScreenVisionRegistrationError.claudeNotFound(manual: "claude mcp add --scope user --transport stdio nook-screen -- '/x y/nook-hook' --mcp-screen"))
        let vision = try vision(registrar: registrar)
        vision.start(serving: false)
        vision.enabled = true
        waitUntil { if case .failed = vision.registration { return true } else { return false } }
        XCTAssertEqual(vision.registration, .failed("No se encontró Claude Code (el comando claude). Instálalo, o añade la herramienta a mano con: claude mcp add --scope user --transport stdio nook-screen -- '/x y/nook-hook' --mcp-screen"))
        XCTAssertTrue(vision.enabled, "The composer's screenshots do not need the tool: the setting stays on.")
        registrar.registerResult = .success(ScreenVisionRegistrationResult(folders: ["~/.claude"], added: ["~/.claude"]))
        vision.retryRegistration()
        waitUntil { vision.registration == .ready(["~/.claude"]) }
        XCTAssertEqual(registrar.calls, ["register", "register"])
    }

    func testQuickOnOffOnEndsRegistered() throws {
        let registrar = FakeRegistrar()
        let vision = try vision(registrar: registrar)
        vision.start(serving: false)
        vision.enabled = true; vision.enabled = false; vision.enabled = true
        waitUntil { registrar.calls.count == 3 && vision.registration != .working("Añadiendo la herramienta a Claude Code…") }
        XCTAssertEqual(registrar.calls, ["register", "unregister", "register"], "One job after another, in order.")
        XCTAssertEqual(vision.registration, .ready(["~/.claude", "~/.claude-work"]), "Only the last job's outcome shows.")
    }
}
