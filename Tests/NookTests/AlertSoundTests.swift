import AppKit
import XCTest
@testable import Nook

/// An alert may sound: only when one is really raised (never for the tab in front of the user, never for a hook and the screen
/// telling the same thing), with the switch for every tab and the tab's own both on. The tab's switch is kept by its identity, like
/// its name and colour. Tests hear nothing: the model's player is silent, and these record what would have played.
@MainActor
final class AlertSoundTests: XCTestCase {
    private let stem = "/dev/ttys6" + String(Int.random(in: 10...99)) + String(UUID().uuidString.prefix(4))
    private var a: String { stem + "a" }
    private var b: String { stem + "b" }
    private var c: String { stem + "c" }
    private lazy var logins = [a: "1759600000.000001", b: "1759600000.000002", c: "1759600000.000003"]

    private func suite() -> UserDefaults { UserDefaults(suiteName: "nook-alert-sound-" + UUID().uuidString)! }
    private func model(_ defaults: UserDefaults, player: RecordingPlayer? = nil) -> AppModel {
        let model = AppModel(receivesSignals: false, defaults: defaults)
        model.terminalBridge.runScript = { _ in }
        model.terminalBridge.resting = true
        model.terminalBridge.loginStampsReader = { [unowned self] in self.logins }
        model.frontTerminalWindow = { 7 }   // Terminal is active, its window 7 in front
        if let player { model.alertSoundPlayer = player }
        return model
    }
    /// `a` is the tab shown in Terminal's window in front: the user is looking at it. `b` and `c` are in a window behind.
    private func tabs(_ ttys: [String]? = nil) -> [TerminalTabSnapshot] {
        (ttys ?? [a, b, c]).map { tty in
            TerminalTabSnapshot(windowID: tty == a ? 7 : 8, windowTitle: "IA", index: 1, tty: tty, customTitle: "", processes: ["claude"], busy: false,
                                selected: tty == a || tty == b, text: tty)
        }
    }
    private func connect(_ model: AppModel, _ ttys: [String]? = nil) {
        let snapshot = tabs(ttys)
        model.updateExternalTabs(snapshot, ttys: Set(snapshot.map(\.tty)))
    }
    private func session(_ model: AppModel, _ tty: String) -> TerminalSession { model.sessions.first { $0.externalTTY == tty }! }

    // MARK: When it sounds

    func testTheModelIsSilentUntilTheRunningAppGivesItThePlayer() {
        XCTAssertTrue(AppModel(receivesSignals: false, defaults: suite()).alertSoundPlayer is SilentAlertSoundPlayer)
        XCTAssertEqual(AlertSoundSettings(), AlertSoundSettings.load(from: suite()), "on by default, with its default sounds")
        XCTAssertTrue(AlertSoundSettings().enabled)
    }

    func testAnAlertRaisedPlaysTheSoundOfItsKindOnce() {
        let player = RecordingPlayer()
        let model = model(suite(), player: player)
        connect(model)
        let now = Date()
        model.raiseAlert(.finished, for: session(model, b), message: "Claude terminó.", now: now)
        XCTAssertEqual(player.played, [.glass])
        model.raiseAlert(.finished, for: session(model, b), message: "Claude terminó su respuesta.", now: now.addingTimeInterval(2))
        XCTAssertEqual(player.played, [.glass], "a hook and the screen telling the same thing sound once")
        model.raiseAlert(.question, for: session(model, b), message: "Do you want to proceed?", now: now.addingTimeInterval(3))
        model.raiseAlert(.failed, for: session(model, c), message: "Claude terminó con un error.", now: now.addingTimeInterval(5))
        XCTAssertEqual(player.played, [.glass, .ping, .funk], "each kind its own sound")
        XCTAssertEqual(player.volumes, [0.6, 0.6, 0.6])
    }

    func testNothingSoundsForTheTabTheUserIsLookingAt() {
        let player = RecordingPlayer()
        let model = model(suite(), player: player)
        connect(model)
        model.raiseAlert(.finished, for: session(model, a), message: "Claude terminó.")
        XCTAssertNil(model.alert)
        XCTAssertEqual(player.played, [])
    }

    func testTabsFinishingTogetherSoundOnce() {
        let player = RecordingPlayer()
        let model = model(suite(), player: player)
        connect(model)
        let now = Date()
        model.raiseAlert(.finished, for: session(model, b), message: "Claude terminó.", now: now)
        model.raiseAlert(.question, for: session(model, c), message: "¿Sigo?", now: now.addingTimeInterval(0.4))
        XCTAssertEqual(model.alert?.sessionID, session(model, c).id, "both alerts are raised")
        XCTAssertEqual(player.played, [.glass], "one sound, not a chord")
        model.raiseAlert(.failed, for: session(model, b), message: "Error.", now: now.addingTimeInterval(1.5))
        XCTAssertEqual(player.played, [.glass, .funk])
    }

    func testTheSwitchForEveryTabSilencesThemAllAndIsSaved() {
        let defaults = suite(), player = RecordingPlayer()
        let model = model(defaults, player: player)
        connect(model)
        model.alertSound.enabled = false
        model.raiseAlert(.question, for: session(model, b), message: "¿Sigo?")
        XCTAssertEqual(model.alert?.kind, .question, "the alert itself still goes up")
        XCTAssertEqual(player.played, [])
        XCTAssertFalse(AppModel(receivesSignals: false, defaults: defaults).alertSound.enabled)
    }

    func testATabsOwnSwitchSilencesOnlyIt() {
        let player = RecordingPlayer()
        let model = model(suite(), player: player)
        connect(model)
        let now = Date()
        model.setAlertSound(false, for: session(model, b))
        XCTAssertFalse(session(model, b).alertSoundOn)
        model.raiseAlert(.finished, for: session(model, b), message: "Claude terminó.", now: now)
        XCTAssertEqual(session(model, b).unreadNotice, "Claude terminó.", "the tab still gets its notice")
        XCTAssertEqual(player.played, [])
        model.raiseAlert(.finished, for: session(model, c), message: "Claude terminó.", now: now.addingTimeInterval(2))
        XCTAssertEqual(player.played, [.glass])
    }

    func testVolumeAndSoundsAreTheUsers() {
        let defaults = suite(), player = RecordingPlayer()
        let model = model(defaults, player: player)
        connect(model)
        model.alertSound.volume = 0.3
        model.alertSound.setSound(.purr, for: .question)
        model.raiseAlert(.question, for: session(model, b), message: "¿Sigo?")
        XCTAssertEqual(player.played, [.purr])
        XCTAssertEqual(player.volumes, [0.3])
        let reloaded = AlertSoundSettings.load(from: defaults)
        XCTAssertEqual(reloaded.question, .purr)
        XCTAssertEqual(reloaded.volume, 0.3)

        model.alertSound.volume = 1.7
        XCTAssertEqual(model.alertSound.volume, 1, "out of range is brought back inside")
        model.alertSound.volume = 0
        XCTAssertNil(model.alertSound.sound(for: .finished, tabOn: true), "no volume, no sound")
    }

    func testAnUnreadableSettingIsTheDefault() {
        let defaults = suite()
        defaults.set("comet", forKey: AlertSoundSettings.Key.finished)
        defaults.set("yes", forKey: AlertSoundSettings.Key.enabled)
        XCTAssertEqual(AlertSoundSettings.load(from: defaults), AlertSoundSettings())
    }

    func testThePreviewPlaysWhateverTheSwitchesSay() {
        let player = RecordingPlayer()
        let model = model(suite(), player: player)
        model.alertSound.enabled = false
        model.alertSound.volume = 0.8
        model.previewAlertSound(.hero)
        model.previewAlertSound(for: .question)
        XCTAssertEqual(player.played, [.hero, .ping])
        XCTAssertEqual(player.volumes, [0.8, 0.8])
    }

    func testEverySoundIsOneTheMacHas() {
        for sound in AlertSound.allCases { XCTAssertNotNil(NSSound(named: sound.systemName), sound.systemName) }
        XCTAssertEqual(AlertSound.submarine.systemName, "Submarine")
    }

    // MARK: Every tab at once

    func testEveryTabsSwitchAtOnce() {
        let defaults = suite()
        let model = model(defaults)
        connect(model)
        XCTAssertEqual(model.alertSoundOnForAllTabs, true)
        model.setAlertSoundForAllTabs(false)
        XCTAssertEqual(model.sessions.map(\.alertSoundOn), [false, false, false])
        XCTAssertEqual(model.alertSoundOnForAllTabs, false)
        model.setAlertSound(true, for: session(model, a))
        XCTAssertNil(model.alertSoundOnForAllTabs, "some on, some off")
        model.setAlertSoundForAllTabs(true)
        XCTAssertEqual(model.sessions.map(\.alertSoundOn), [true, true, true])
        XCTAssertEqual(defaults.stringArray(forKey: AlertSoundSettings.Key.mutedTabs), [])
    }

    // MARK: Kept by the tab's identity

    func testATabsSwitchHoldsWhenItIsReopenedAndAcrossALaunch() {
        let defaults = suite(), player = RecordingPlayer()
        let model = model(defaults, player: player)
        connect(model)
        model.setAlertSound(false, for: session(model, b))
        model.close(session(model, b))       // the ×: the tab lives on in Terminal
        model.connectTerminalTab(tabs([b])[0])   // what reopening does once Terminal shows it
        XCTAssertFalse(session(model, b).alertSoundOn)

        let relaunched = self.model(defaults, player: player)
        relaunched.restoreTabState(keeping: [a, b, c].map { TrackedTerminalTab(windowID: 8, tty: $0, login: logins[$0]) }, logins: logins)
        connect(relaunched)
        XCTAssertFalse(session(relaunched, b).alertSoundOn)
        XCTAssertTrue(session(relaunched, c).alertSoundOn)
        relaunched.raiseAlert(.finished, for: session(relaunched, b), message: "Claude terminó.")
        XCTAssertEqual(player.played, [])
    }

    func testANewTabOnAReusedTTYStartsWithItsSoundOn() {
        let defaults = suite()
        let model = model(defaults)
        connect(model)
        model.setAlertSound(false, for: session(model, b))

        // While Nook was away, b's tab closed and Terminal gave its TTY to a new tab.
        logins[b] = "1759700000.000009"
        let relaunched = self.model(defaults)
        relaunched.restoreTabState(keeping: [a, c].map { TrackedTerminalTab(windowID: 8, tty: $0, login: logins[$0]) }, logins: logins)
        XCTAssertEqual(defaults.stringArray(forKey: AlertSoundSettings.Key.mutedTabs), [], "the closed tab's switch is forgotten")
        relaunched.connectTerminalTab(tabs([b])[0])
        XCTAssertTrue(session(relaunched, b).alertSoundOn)
    }

    func testWhatIsKeptForANookSessionThatEndedIsForgottenAtLaunch() {
        let defaults = suite()
        // Sessions of Nook's own (tmux), with a backend that never starts tmux.
        let backend = TmuxBackend(executable: "/usr/bin/true", socket: "/tmp/nook-alert-sound-\(getpid()).sock", configuration: "/dev/null")
        func nookSession(_ name: String) -> TerminalSession {
            TerminalSession(record: SessionRecord(id: name, name: name, kind: .shell, directory: NSTemporaryDirectory(), socket: backend.socket, ownsSession: true),
                            backend: backend, create: false)
        }
        let first = model(defaults)
        let kept = nookSession("nook-kept"), gone = nookSession("nook-gone")
        first.sessions = [kept, gone]
        connect(first)
        for tab in [kept, gone, session(first, b)] { first.setAlertSound(false, for: tab) }
        first.moveSession(gone.id, to: 0)
        XCTAssertTrue(TabOrder.load(from: defaults).ids.contains(gone.id))

        // Relaunched: tmux still has the one session and not the other, and Terminal's tabs are the same tabs.
        let relaunched = model(defaults)
        relaunched.sessions = [nookSession("nook-kept")]
        relaunched.restoreTabState(keeping: [a, b, c].map { TrackedTerminalTab(windowID: 8, tty: $0, login: logins[$0]) }, logins: logins)
        connect(relaunched)
        XCTAssertEqual(Set(defaults.stringArray(forKey: AlertSoundSettings.Key.mutedTabs) ?? []), [kept.id, session(relaunched, b).id],
                       "the session that ended takes its switch with it; the restored session and the Terminal tab keep theirs")
        XCTAssertFalse(TabOrder.load(from: defaults).ids.contains(gone.id), "and its place in the strip")
        XCTAssertTrue(TabOrder.load(from: defaults).ids.contains(kept.id))
        XCTAssertFalse(session(relaunched, b).alertSoundOn)
    }
}

/// What would have played, in order.
final class RecordingPlayer: AlertSoundPlaying {
    private(set) var played: [AlertSound] = []
    private(set) var volumes: [Double] = []
    func play(_ sound: AlertSound, volume: Double) { played.append(sound); volumes.append(volume) }
}
