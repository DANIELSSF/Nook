import AppKit
import SwiftUI
import XCTest
@testable import Nook

/// The sound's settings and switches as the island words and shows them (`SoundSettingsPane.swift`): the words, that the tab exists in the card, and that the switches the views offer are
/// the model's (`AppModel.setAlertSound`, `setAlertSoundForAllTabs`, `alertSoundOnForAllTabs`), whose own tests are in `AlertSoundTests`.
@MainActor
final class SoundSettingsTests: XCTestCase {
    private func model() -> AppModel {
        AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-sound-ui-" + UUID().uuidString)!)
    }
    private func session(_ model: AppModel, title: String, tty: String) -> TerminalSession {
        let tab = TerminalTabSnapshot(windowID: 1, windowTitle: "IA", index: 1, tty: tty, customTitle: title, processes: ["login", "-zsh"], busy: false, selected: true, text: "")
        let session = TerminalSession(tab: tab, backend: .bundled, bridge: model.terminalBridge)
        model.sessions.append(session)
        return session
    }

    // MARK: The words

    func testATabsMenusOfferToTurnItsSoundOffWhileItIsOnAndOnWhileItIsOff() {
        XCTAssertEqual(SoundCopy.tabToggle(on: true), "Silenciar sonido de esta pestaña")
        XCTAssertEqual(SoundCopy.tabToggle(on: false), "Activar sonido de esta pestaña")
    }

    func testTheSummaryOfTheTabsSaysHowTheyStand() {
        XCTAssertEqual(SoundCopy.tabsSummary(on: 0, of: 0), SoundCopy.noTabs)
        XCTAssertEqual(SoundCopy.tabsSummary(on: 3, of: 3), "Todas con sonido")
        XCTAssertEqual(SoundCopy.tabsSummary(on: 0, of: 3), "Ninguna con sonido")
        XCTAssertEqual(SoundCopy.tabsSummary(on: 2, of: 3), "2 de 3 con sonido")
        XCTAssertEqual(SoundCopy.tabsSummary(on: 1, of: 1), "Con sonido")
        XCTAssertEqual(SoundCopy.tabsSummary(on: 0, of: 1), "Sin sonido")
    }

    func testTheVolumeIsAPercentage() {
        XCTAssertEqual(SoundCopy.percent(0.6), "60 %")
        XCTAssertEqual(SoundCopy.percent(0), "0 %")
        XCTAssertEqual(SoundCopy.percent(1), "100 %")
        XCTAssertEqual(SoundCopy.percent(0.333), "33 %")
    }

    func testEveryKindOfAlertHasANameALineAndASymbol() {
        XCTAssertEqual(NookAlert.Kind.allCases, [.finished, .question, .failed])
        XCTAssertEqual(NookAlert.Kind.allCases.map(SoundCopy.kind), ["Terminó", "Pregunta", "Error"])
        for kind in NookAlert.Kind.allCases {
            XCTAssertFalse(SoundCopy.kindDetail(kind).isEmpty)
            XCTAssertNotNil(NSImage(systemSymbolName: SoundCopy.symbol(kind), accessibilityDescription: nil), SoundCopy.symbol(kind))
        }
    }

    func testEverySymbolOfTheSoundTabExists() {
        for name in ["speaker.wave.2", "speaker.wave.2.fill", "speaker.slash", "speaker.slash.fill", "speaker.fill", "speaker.wave.3.fill", "play.fill", "chevron.up.chevron.down", "checkmark"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    // MARK: The tab

    func testTheSoundTabIsInTheCardAfterTheCatsAndWearsASpeaker() {
        XCTAssertEqual(SettingsTab.sound.title, "Sonido")
        XCTAssertEqual(SettingsTab.sound.symbol, "speaker.wave.2")
        XCTAssertEqual(SettingsTab.allCases.firstIndex(of: .sound), 2, "after Isla and Gato")
        XCTAssertEqual(SettingsTab.allCases.last, .screen, "the last one is where it was")
        XCTAssertEqual(Set(SettingsTab.allCases.map(\.symbol)).count, SettingsTab.allCases.count, "every tab has a symbol of its own")
    }

    // MARK: The switches the views offer

    func testTheTabListAndTheChipsReadTheModelsState() {
        let model = model()
        let a = session(model, title: "Claude Code", tty: "/dev/ttys041"), b = session(model, title: "Codex", tty: "/dev/ttys042")
        XCTAssertEqual(model.alertSoundOnForAllTabs, true)
        model.setAlertSound(false, for: b)
        XCTAssertNil(model.alertSoundOnForAllTabs, "mixed: neither chip is lit")
        XCTAssertEqual(SoundCopy.tabsSummary(on: model.sessions.filter(\.alertSoundOn).count, of: model.sessions.count), "1 de 2 con sonido")
        model.setAlertSoundForAllTabs(false)
        XCTAssertEqual(model.alertSoundOnForAllTabs, false)
        XCTAssertFalse(a.alertSoundOn); XCTAssertFalse(b.alertSoundOn)
        model.setAlertSoundForAllTabs(true)
        XCTAssertEqual(model.alertSoundOnForAllTabs, true)
    }

    func testPreviewingASoundPlaysItWhateverTheSwitchesSay() {
        let model = model()
        let player = RecordingPlayer()
        model.alertSoundPlayer = player
        model.alertSound.enabled = false
        model.previewAlertSound(.hero, for: .finished)
        XCTAssertEqual(player.played.map(\.sound), [.hero])
        model.previewAlertSound(for: .failed)
        XCTAssertEqual(player.played.last?.sound, .funk)
    }

    /// Choosing a sound for a kind saves it and plays it, as the picker does.
    func testChoosingASoundSetsItForItsKindAndLeavesTheOthers() {
        let model = model()
        model.alertSound.setSound(.bottle, for: .question)
        XCTAssertEqual(model.alertSound.question, .bottle)
        XCTAssertEqual(model.alertSound.finished, .glass)
        XCTAssertEqual(model.alertSound.failed, .funk)
    }

    func testTheResetPutsTheSoundsAndTheVolumeBackButNotTheTabsSwitches() {
        let model = model()
        let a = session(model, title: "Claude Code", tty: "/dev/ttys043")
        model.alertSound.finished = .tink; model.alertSound.volume = 0.2; model.alertSound.enabled = false
        model.setAlertSound(false, for: a)
        model.alertSound = AlertSoundSettings()
        XCTAssertEqual(model.alertSound, AlertSoundSettings())
        XCTAssertFalse(a.alertSoundOn, "a tab's own switch is the user's, not a setting of the sound")
    }

    /// The editor's switch and the menus' are the same switch: the tab's state follows whichever was used.
    func testEveryWayToSwitchATabIsTheSameSwitch() {
        let model = model()
        let tab = session(model, title: "ui", tty: "/dev/ttys044")
        model.setAlertSound(false, for: tab)
        XCTAssertFalse(tab.alertSoundOn)
        model.setAlertSound(!tab.alertSoundOn, for: tab)
        XCTAssertTrue(tab.alertSoundOn)
    }

    private final class RecordingPlayer: AlertSoundPlaying {
        var played: [(sound: AlertSound, volume: Double)] = []
        func play(_ sound: AlertSound, volume: Double) { played.append((sound, volume)) }
    }
}
