import AppKit
import XCTest
@testable import Nook

/// The Permisos tab's logic: what each state shows and does, how the tab reads the system, which events make it read again, and the
/// card's window following its content. Nothing here prompts, opens System Settings or touches Terminal: the system's side is a
/// recorder.
@MainActor
final class PermissionsPaneTests: XCTestCase {
    typealias State = NookPermission.State

    /// Stands in for the system. Reads can be held back to see a read that is still under way.
    final class Recorder {
        var states: [NookPermission: State] = [:]
        var folders: [ClaudeFolder] = []
        var stateReads = 0, claudeReads = 0
        var requests: [NookPermission] = []
        var settingsOpened: [NookPermission] = []
        var terminalOpens = 0
        /// What macOS answers to a request.
        var answer: State = .granted
        var holdReads = false
        /// macOS's prompt is up and nobody has answered it yet.
        var holdRequests = false
        var heldRequests: [(State) -> Void] = []
        var heldStates: [([NookPermission: State]) -> Void] = []
        var heldClaude: [([ClaudeFolder]) -> Void] = []

        var services: PermissionsModel.Services {
            PermissionsModel.Services(
                readStates: { [self] done in
                    stateReads += 1
                    if holdReads { heldStates.append(done) } else { done(states) }
                },
                readClaude: { [self] done in
                    claudeReads += 1
                    if holdReads { heldClaude.append(done) } else { done(folders) }
                },
                request: { [self] permission, done in
                    requests.append(permission)
                    if holdRequests { heldRequests.append(done) } else { done(answer) }
                },
                openSettings: { [self] permission in settingsOpened.append(permission) },
                openTerminal: { [self] done in terminalOpens += 1; done() })
        }

        /// Finishes the reads that were held back.
        func release() {
            holdReads = false
            let (s, c) = (heldStates, heldClaude)
            heldStates = []; heldClaude = []
            s.forEach { $0(states) }
            c.forEach { $0(folders) }
        }
    }

    private func model(_ recorder: Recorder, states: [NookPermission: State] = [:], center: NotificationCenter = NotificationCenter(), workspace: NotificationCenter = NotificationCenter()) -> PermissionsModel {
        PermissionsModel(services: recorder.services, states: states, center: center, workspace: workspace,
                         bundleOf: { $0.userInfo?["bundle"] as? String }, settle: 0.05)
    }

    // MARK: What each state shows

    func testEachStateReadsAndActsAsSpecified() {
        for permission in NookPermission.allCases {
            let granted = permission.presentation(for: .granted)
            XCTAssertEqual(granted.chip, "Activado"); XCTAssertEqual(granted.tone, .good); XCTAssertNil(granted.action, "\(permission): nothing to do when it is on")

            let notAsked = permission.presentation(for: .notAsked)
            XCTAssertEqual(notAsked.chip, "Sin activar")
            XCTAssertEqual(notAsked.tone, permission.essential ? .attention : .neutral, "Only the needed permission turns amber when it is off.")
            // macOS has no prompt to wait for in Accessibility: it goes to the pane. Everywhere else the prompt is still possible.
            XCTAssertEqual(notAsked.action, permission == .accessibility ? .openSettings : .request, "\(permission)")

            let denied = permission.presentation(for: .denied)
            XCTAssertEqual(denied.chip, "Denegado")
            XCTAssertEqual(denied.tone, permission.essential ? .bad : .attention, "Red is for the needed permission only.")
            XCTAssertEqual(denied.action, .openSettings, "A refused permission can only be switched on in System Settings.")

            let unknown = permission.presentation(for: .unknown)
            XCTAssertEqual(unknown.tone, .neutral)
            XCTAssertEqual(unknown.action, permission == .automation ? .openTerminal : .openSettings)

            let reading = permission.presentation(for: nil)
            XCTAssertNil(reading.action, "Nothing to press before the state is known.")
            XCTAssertEqual(reading.tone, .neutral)
        }
        XCTAssertEqual(NookPermission.automation.presentation(for: .unknown).chip, "Abre Terminal para comprobarlo")
        XCTAssertEqual(NookPermission.accessibility.presentation(for: .notAsked).action?.title, "Abrir Ajustes", "Accessibility always goes to the exact pane.")
        XCTAssertEqual(NookPermission.microphone.presentation(for: .notAsked).action?.title, "Pedir permiso")
        XCTAssertEqual(NookPermission.speech.presentation(for: .denied).action?.title, "Abrir Ajustes")
        XCTAssertEqual(PermissionAction.openTerminal.title, "Abrir Terminal")
    }

    func testEveryChipIsWordsAndASymbolNotColourAlone() {
        for permission in NookPermission.allCases {
            for state in [State.granted, .notAsked, .denied, .unknown] {
                let shown = permission.presentation(for: state)
                XCTAssertFalse(shown.chip.isEmpty); XCTAssertFalse(shown.symbol.isEmpty)
                XCTAssertNotNil(NSImage(systemSymbolName: shown.symbol, accessibilityDescription: nil), "\(shown.symbol) is a real SF Symbol")
            }
        }
        for action in [PermissionAction.request, .openSettings, .openTerminal] {
            XCTAssertNotNil(NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil), action.symbol)
        }
        for symbol in NookPermission.allCases.map(\.symbol) + ["bell.badge", "bell.slash", "lock.shield", "gearshape", "circle.lefthalf.filled", "ellipsis.circle"] + SettingsTab.allCases.map(\.symbol) {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testOnlyAccessibilityHasAnAsideAboutUpdates() throws {
        let note = try XCTUnwrap(NookPermission.accessibility.note)
        XCTAssertTrue(note.contains("«−»") && note.contains("añadirlo"), "It tells how to put Nook back on the list.")
        XCTAssertTrue(note.localizedCaseInsensitiveContains("actualizar") && note.localizedCaseInsensitiveContains("firma"))
        XCTAssertNil(NookPermission.automation.note); XCTAssertNil(NookPermission.microphone.note); XCTAssertNil(NookPermission.speech.note)
    }

    func testTheTabsAreIslaAndPermisos() {
        XCTAssertEqual(SettingsTab.allCases, [.island, .permissions])
        XCTAssertEqual(SettingsTab.allCases.map(\.title), ["Isla", "Permisos"])
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-perms-tab-" + UUID().uuidString)!)
        XCTAssertEqual(model.settingsTab, .island, "The card opens on the island's settings.")
        model.showPermissions()   // no window in a test: nothing to open, nothing breaks
        XCTAssertFalse(model.settingsOpen)
        XCTAssertTrue(model.permissions.states.isEmpty && !model.permissions.isActive && !model.permissions.isRequesting, "The model's permissions read nothing until the card is open.")
    }

    // MARK: Reading

    func testRefreshReadsEveryStateAndTheClaudeFolders() {
        let recorder = Recorder()
        recorder.states = [.automation: .granted, .accessibility: .notAsked, .microphone: .denied, .speech: .unknown]
        recorder.folders = [ClaudeFolder(name: "~/.claude", enabled: true)]
        let model = model(recorder)
        XCTAssertTrue(model.states.isEmpty, "Nothing is read until the tab asks.")
        XCTAssertNil(model.claudeFolders)
        XCTAssertEqual(model.presentation(for: .automation).chip, "Leyendo…")
        model.refresh()
        XCTAssertEqual(model.states, recorder.states)
        XCTAssertEqual(model.claudeFolders, recorder.folders)
        XCTAssertEqual(model.presentation(for: .microphone).chip, "Denegado")
        XCTAssertEqual(recorder.stateReads, 1); XCTAssertEqual(recorder.claudeReads, 1)
    }

    func testARefreshDuringARefreshIsNotDoubledButIsNotLost() {
        let recorder = Recorder()
        recorder.states = [.automation: .notAsked]
        recorder.holdReads = true
        let model = model(recorder)
        model.refresh(); model.refresh(); model.refresh()
        XCTAssertEqual(recorder.stateReads, 1, "One read at a time.")
        // The system answers the read that was held; the refreshes asked for meanwhile become one more read, which runs at once.
        recorder.states = [.automation: .granted]
        recorder.release()
        XCTAssertEqual(recorder.stateReads, 2, "The refreshes asked for meanwhile become one more read.")
        XCTAssertEqual(model.states[.automation], .granted, "The last word is the newest read.")
        model.refresh()
        XCTAssertEqual(recorder.stateReads, 3, "Back to normal afterwards.")
    }

    func testTheNeededPermissionMissingRaisesTheDot() {
        let recorder = Recorder()
        let model = model(recorder)
        XCTAssertFalse(model.needsAttention, "Unknown until read: no dot.")
        for (state, dot) in [(State.notAsked, true), (.denied, true), (.granted, false), (.unknown, false)] {
            recorder.states = [.automation: state, .accessibility: .denied, .microphone: .denied, .speech: .denied]
            model.refresh()
            XCTAssertEqual(model.needsAttention, dot, "Terminal \(state): the optional ones being off never raise it.")
        }
    }

    func testGuidesOpenAndCloseOneByOne() {
        let model = model(Recorder())
        XCTAssertFalse(model.isOpen(NookPermission.accessibility.id))
        model.toggleGuide(NookPermission.accessibility.id)
        model.toggleGuide(PermissionsModel.claudeKey)
        XCTAssertTrue(model.isOpen(NookPermission.accessibility.id)); XCTAssertTrue(model.isOpen(PermissionsModel.claudeKey))
        XCTAssertFalse(model.isOpen(NookPermission.microphone.id))
        model.toggleGuide(NookPermission.accessibility.id)
        XCTAssertFalse(model.isOpen(NookPermission.accessibility.id)); XCTAssertTrue(model.isOpen(PermissionsModel.claudeKey))
    }

    // MARK: Actions

    func testEachButtonDoesOnlyWhatItSays() {
        for permission in NookPermission.allCases {
            for state in [State.granted, .notAsked, .denied, .unknown] {
                guard let action = permission.presentation(for: state).action else { continue }
                let recorder = Recorder()
                let model = model(recorder, states: [permission: state])
                var handedOff = 0
                model.onOpenedSettings = { handedOff += 1 }
                model.perform(action, for: permission)
                switch action {
                case .request:
                    XCTAssertEqual(recorder.requests, [permission], "\(permission) \(state)")
                    XCTAssertEqual(recorder.settingsOpened, []); XCTAssertEqual(recorder.terminalOpens, 0); XCTAssertEqual(handedOff, 0)
                case .openSettings:
                    XCTAssertEqual(recorder.settingsOpened, [permission], "\(permission) \(state): its own pane")
                    XCTAssertEqual(recorder.requests, [], "A refused or Accessibility permission is never asked for."); XCTAssertEqual(recorder.terminalOpens, 0)
                    XCTAssertEqual(handedOff, 1, "The island is told the user was sent to System Settings.")
                case .openTerminal:
                    XCTAssertEqual(recorder.terminalOpens, 1)
                    XCTAssertEqual(recorder.requests, []); XCTAssertEqual(recorder.settingsOpened, []); XCTAssertEqual(handedOff, 0)
                }
            }
        }
    }

    func testAnAnsweredRequestUpdatesTheRowAndReadsTheRestAgain() {
        let recorder = Recorder()
        recorder.states = [.microphone: .granted, .speech: .notAsked]
        recorder.answer = .granted
        let model = model(recorder, states: [.microphone: .notAsked, .speech: .notAsked])
        model.perform(.request, for: .microphone)
        XCTAssertEqual(model.states[.microphone], .granted)
        XCTAssertEqual(recorder.stateReads, 1, "Everything is read again after an action.")
        recorder.answer = .denied
        recorder.states = [.microphone: .denied]
        model.perform(.request, for: .microphone)
        XCTAssertEqual(model.states[.microphone], .denied, "A refusal in macOS's prompt shows as Denegado, with the Settings button next.")
        XCTAssertEqual(model.presentation(for: .microphone).action, .openSettings)
    }

    func testWhileMacOSsPromptIsUpTheModelSaysSoAndStopsWhenItIsAnswered() {
        let recorder = Recorder()
        recorder.holdRequests = true
        recorder.states = [.microphone: .granted]
        let model = model(recorder, states: [.microphone: .notAsked])
        XCTAssertFalse(model.isRequesting)
        model.perform(.request, for: .microphone)
        XCTAssertTrue(model.isRequesting, "The island must not put itself away at the click that answers macOS's prompt.")
        XCTAssertEqual(model.states[.microphone], .notAsked, "Nothing changes until the user answers.")
        recorder.heldRequests.forEach { $0(.granted) }
        XCTAssertFalse(model.isRequesting)
        XCTAssertEqual(model.states[.microphone], .granted)
        // Going to the pane is not waiting for an answer.
        model.perform(.openSettings, for: .microphone)
        XCTAssertFalse(model.isRequesting)
    }

    func testOpeningTerminalReadsAgainOnceItHasSettled() {
        let recorder = Recorder()
        recorder.states = [.automation: .notAsked]
        let model = model(recorder, states: [.automation: .unknown])
        let settled = expectation(description: "read after Terminal opened")
        model.perform(.openTerminal, for: .automation)
        XCTAssertEqual(recorder.stateReads, 0, "Terminal needs a moment before its permission can be read.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(recorder.stateReads, 1)
        XCTAssertEqual(model.states[.automation], .notAsked, "Terminal open: the permission can be asked for now.")
        XCTAssertEqual(model.presentation(for: .automation).action, .request)
    }

    // MARK: When to read again

    func testItReadsWhenTheUserComesBackAndNotBefore() throws {
        let recorder = Recorder()
        let center = NotificationCenter(), workspace = NotificationCenter()
        let model = model(recorder, center: center, workspace: workspace)
        let panel = NotchPanel(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let plain = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        func post(_ name: Notification.Name, on target: NotificationCenter = center, object: Any? = nil, bundle: String? = nil) {
            target.post(name: name, object: object, userInfo: bundle.map { ["bundle": $0] })
        }

        // Closed card: no event reads anything.
        post(NSApplication.didBecomeActiveNotification)
        post(NSWindow.didBecomeKeyNotification, object: panel)
        post(NSWorkspace.didDeactivateApplicationNotification, on: workspace, bundle: PermissionsModel.systemSettingsBundle)
        XCTAssertEqual(recorder.stateReads, 0, "The card is not on screen: nothing is read.")

        // Open: it reads at once.
        model.setActive(true)
        XCTAssertEqual(recorder.stateReads, 1, "Showing the card reads.")
        model.setActive(true)
        XCTAssertEqual(recorder.stateReads, 1, "Already showing: no second read.")

        post(NSApplication.didBecomeActiveNotification)
        XCTAssertEqual(recorder.stateReads, 2, "Nook came forward.")
        post(NSWindow.didBecomeKeyNotification, object: panel)
        XCTAssertEqual(recorder.stateReads, 3, "One of Nook's panels took the keyboard (the user clicked the card).")
        post(NSWindow.didBecomeKeyNotification, object: plain)
        XCTAssertEqual(recorder.stateReads, 3, "A window that is not Nook's island or card does not count.")
        post(NSWorkspace.didDeactivateApplicationNotification, on: workspace, bundle: PermissionsModel.systemSettingsBundle)
        XCTAssertEqual(recorder.stateReads, 4, "System Settings gave up the front: the user is back from the pane.")
        post(NSWorkspace.didDeactivateApplicationNotification, on: workspace, bundle: "com.apple.finder")
        XCTAssertEqual(recorder.stateReads, 4, "Other apps leaving the front change nothing.")
        post(NSWorkspace.didTerminateApplicationNotification, on: workspace, bundle: PermissionsModel.terminalBundle)
        XCTAssertEqual(recorder.stateReads, 5, "Terminal quit: its permission can no longer be read.")
        post(NSWorkspace.didTerminateApplicationNotification, on: workspace, bundle: "com.apple.finder")
        XCTAssertEqual(recorder.stateReads, 5)

        // Terminal opening is read once it has settled.
        post(NSWorkspace.didLaunchApplicationNotification, on: workspace, bundle: PermissionsModel.terminalBundle)
        XCTAssertEqual(recorder.stateReads, 5)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(recorder.stateReads, 6, "Terminal opened: its permission can be read now.")

        // Closed again: silent.
        model.setActive(false)
        post(NSApplication.didBecomeActiveNotification)
        XCTAssertEqual(recorder.stateReads, 6)
    }

    func testTheWatchedAppsAreSystemSettingsAndTerminal() {
        XCTAssertEqual(PermissionsModel.systemSettingsBundle, "com.apple.systempreferences")
        XCTAssertEqual(PermissionsModel.terminalBundle, "com.apple.Terminal")
        let note = Notification(name: NSWorkspace.didLaunchApplicationNotification, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        XCTAssertEqual(PermissionsModel.bundle(of: note), NSRunningApplication.current.bundleIdentifier)
        XCTAssertNil(PermissionsModel.bundle(of: Notification(name: NSWorkspace.didLaunchApplicationNotification)))
    }

    func testTheDefaultServicesTouchNothingUntilTheyAreCalled() {
        // Building the model with the real services (as the card does) reads and asks nothing by itself.
        let model = PermissionsModel(center: NotificationCenter(), workspace: NotificationCenter())
        XCTAssertTrue(model.states.isEmpty); XCTAssertNil(model.claudeFolders); XCTAssertFalse(model.isActive)
    }

    // MARK: Claude's signals

    func testClaudeFoldersShowWhichOnesHaveTheHooks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nook-perms-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent(".claude"), second = home.appendingPathComponent(".claude-work")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: ClaudeHooks.settingsURL(in: folder))
        }
        let folders = ClaudeHooks.folders(home: home)
        XCTAssertEqual(folders.map(\.lastPathComponent), [".claude", ".claude-work"])
        try ClaudeHooks.write(enabled: true, to: [first], command: "test-hook")
        let read = ClaudeFolder.read(folders: folders, isEnabled: { ClaudeHooks.isEnabled(in: $0, command: "test-hook") })
        XCTAssertEqual(read, [ClaudeFolder(name: "~/.claude", enabled: true), ClaudeFolder(name: "~/.claude-work", enabled: false)])
        XCTAssertEqual(ClaudeSignalsPresentation.make(enabled: false, folders: read).chip, "1 de 2 carpetas")
    }

    func testClaudeSignalsRowReadsAndActsByState() {
        let on = ClaudeFolder(name: "~/.claude", enabled: true), off = ClaudeFolder(name: "~/.claude-work", enabled: false)
        let enabled = ClaudeSignalsPresentation.make(enabled: true, folders: [on])
        XCTAssertEqual(enabled.chip, "Activado"); XCTAssertEqual(enabled.tone, .good); XCTAssertEqual(enabled.action, .disable)
        XCTAssertEqual(enabled.action.title, "Desactivar…")
        let partial = ClaudeSignalsPresentation.make(enabled: false, folders: [on, off])
        XCTAssertEqual(partial.chip, "1 de 2 carpetas"); XCTAssertEqual(partial.tone, .attention)
        XCTAssertEqual(partial.action, .enable, "A Claude in the other folder would never signal: the button turns them on everywhere.")
        XCTAssertEqual(partial.action.title, "Activar avisos…")
        for folders in [[off], [], nil] as [[ClaudeFolder]?] {
            let none = ClaudeSignalsPresentation.make(enabled: false, folders: folders)
            XCTAssertEqual(none.chip, "Sin activar"); XCTAssertEqual(none.tone, .neutral); XCTAssertEqual(none.action, .enable)
        }
        // The model's own flag decides "Activado", whatever the folder read says meanwhile.
        XCTAssertEqual(ClaudeSignalsPresentation.make(enabled: true, folders: nil).chip, "Activado")
    }

    // MARK: Proactive help

    func testNoticesAboutAPermissionOfferThePermisosTab() {
        // The wording Nook's own notices have today.
        let real = [
            TerminalBridgeError.automationDenied.errorDescription!,
            "Activa Nook en Privacidad y seguridad → Accesibilidad. Si instalas una versión nueva de Nook, macOS puede pedir el permiso otra vez.",
            "Añadí la imagen como archivo al mensaje; Claude puede abrirla al enviarlo. Para pegarla como con ⌃V en la terminal, activa Nook en Accesibilidad.",
            "Terminal tardó demasiado en responder. Si macOS muestra un permiso para Nook, acéptalo y pulsa Buscar de nuevo.",
            "No se pudo verificar el permiso de Terminal (-1).",
            "macOS no permitió abrir Terminal. Usa ‘Copiar conexión’ y pega el comando en una terminal libre.",
            "Activa Reconocimiento de voz para Nook en Ajustes del Sistema → Privacidad y seguridad.",
        ]
        for text in real { XCTAssertTrue(PermissionHelp.opensPermissions(text), text) }
        // Everything else a notice says stays a plain notice, Claude's own messages included.
        let others = ["No hay ninguna imagen en el portapapeles.", "Pegar imágenes funciona en pestañas con Claude o Codex.", "Esta sesión ya no está disponible.",
                      "Avisos de Claude activados. En una sesión ya abierta, revisa /hooks para aprobar o cargar el cambio; algunas versiones requieren reabrir Claude.",
                      "Diagnóstico copiado. Incluye el final de la pantalla de esta pestaña; pégalo donde quieras revisarlo.",
                      "claude: Claude needs your permission to use Bash", "claude: Claude necesita tu aprobación para usar Bash", "Falta el componente de terminal. Vuelve a construir Nook."]
        for text in others { XCTAssertFalse(PermissionHelp.opensPermissions(text), text) }
    }

    // MARK: Coming back from System Settings

    func testTheCardComesBackOnceWhenTheUserReturnsSoon() {
        var resume = SettingsResume()
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(resume.due(now: start), "Nothing to resume unless the user was sent to System Settings.")
        resume.arm(now: start)
        XCTAssertTrue(resume.due(now: start.addingTimeInterval(90)), "Back within minutes: the tab returns.")
        XCTAssertFalse(resume.due(now: start.addingTimeInterval(91)), "Once.")
        resume.arm(now: start)
        XCTAssertFalse(resume.due(now: start.addingTimeInterval(SettingsResume.window + 1)), "Hours later it would only be in the way.")
        resume.arm(now: start)
        resume.clear()
        XCTAssertFalse(resume.due(now: start.addingTimeInterval(5)), "Closing the card by hand, or opening it again, cancels it.")
    }

    // MARK: The window follows the card

    private func makeWindow(_ screen: CGSize, tab: SettingsTab, open: Set<String> = [], states: [NookPermission: State] = [.automation: .unknown, .accessibility: .notAsked, .microphone: .denied, .speech: .granted]) -> (SettingsWindow, AppModel) {
        let model = AppModel(receivesSignals: false, defaults: UserDefaults(suiteName: "nook-perms-window-" + UUID().uuidString)!)
        model.settingsTab = tab
        let permissions = PermissionsModel(services: Recorder().services, states: states, claudeFolders: [ClaudeFolder(name: "~/.claude", enabled: false)], openGuides: open,
                                           center: NotificationCenter(), workspace: NotificationCenter())
        return (SettingsWindow(model: model, screen: screen, topInset: 32, level: .normal, permissions: permissions) {}, model)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }

    func testTheWindowGrowsForThePermisosTabKeepingTheCardsTopUnderTheIsland() {
        // Far off every display: SwiftUI only lays a card out while its window is on screen, and nobody should see this one.
        let screen = CGRect(x: -40000, y: -40000, width: 1512, height: 982)
        let (window, model) = makeWindow(screen.size, tab: .island)
        let island = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
        window.place(under: island, on: screen)
        window.panel.orderFrontRegardless()
        defer { window.hide() }
        settle()
        let islandHeight = window.cardSize.height
        let top = window.cardFrame.maxY
        XCTAssertEqual(top, island.minY - SettingsPlacement.gap, accuracy: 0.5)

        model.settingsTab = .permissions
        settle()
        XCTAssertGreaterThan(window.cardSize.height, islandHeight + 100, "Five permissions are taller than the island's sliders; the window followed.")
        XCTAssertLessThanOrEqual(window.cardSize.height, screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin + 1, "It never runs off the screen.")
        XCTAssertEqual(window.cardFrame.maxY, top, accuracy: 0.5, "The card's top edge stays under the island while its height changes.")
        XCTAssertEqual(window.cardFrame.height, window.cardSize.height, accuracy: 0.5)
        XCTAssertEqual(window.cardFrame.width, SettingsCard.width, accuracy: 0.5)

        model.settingsTab = .island
        settle()
        XCTAssertEqual(window.cardSize.height, islandHeight, accuracy: 1, "Back on the island's tab, the card is as tall as before.")
        XCTAssertEqual(window.cardFrame.maxY, top, accuracy: 0.5)
    }

    func testOnAShortScreenThePermisosListScrollsInsteadOfOverflowing() {
        let screen = CGRect(x: -40000, y: -40000, width: 1280, height: 720)
        let all = Set(NookPermission.allCases.map(\.id) + [PermissionsModel.claudeKey])
        let (window, _) = makeWindow(screen.size, tab: .permissions, open: all)
        let island = CGRect(x: screen.midX - 286, y: screen.maxY - 266, width: 572, height: 266)
        window.place(under: island, on: screen)
        window.panel.orderFrontRegardless()
        defer { window.hide() }
        settle()
        XCTAssertGreaterThan(window.cardSize.height, 380, "A long list: the card takes the room it has.")
        XCTAssertLessThanOrEqual(window.cardSize.height, screen.height - island.height - SettingsPlacement.gap - SettingsPlacement.margin + 1,
                                 "Every guide open and the card still fits under the island.")
        XCTAssertTrue(screen.contains(window.cardFrame))
        XCTAssertGreaterThanOrEqual(window.cardFrame.minY, screen.minY + SettingsPlacement.margin - 0.5)
    }

    func testTheIslandsTabIsStillCompact() {
        let (window, _) = makeWindow(CGSize(width: 1512, height: 982), tab: .island)
        XCTAssertGreaterThan(window.cardSize.height, 250)
        XCTAssertLessThan(window.cardSize.height, 460, "The tabs add a row; the sliders' card is still a card.")
    }
}
