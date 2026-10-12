import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var controller = NotchController(model: model)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        model.capturePrivacy.startObservingApplication()
        // The running app keeps a record of panels that lost a Space and of the state after each wake (`SpaceMembership`); tests write none.
        SpaceMembership.shared.journal = SpacesJournal.append
        _ = controller
        // Keys to a Terminal tab first try to go with Terminal left behind, checked on its screen (`TerminalAppBridge.press`).
        model.terminalBridge.backgroundKeys = true
        model.restore()
        model.watchMemory()
        // Opened at night, the cat is asleep until it is clicked or the lights come on (`PetBedtime`).
        model.petBedtime.launch()
        controller.expand(focus: true)
        ClaudeHooks.refreshHelperInBackground()
        // The socket Claude's screen tool asks through, and the tool kept registered while screen vision is on.
        model.screenVision.start()
        // Only the running app makes a sound, quits for real and asks with an alert when the island can't: the model's own are inert,
        // so tests and previews never beep, end their process or wait on a modal alert.
        model.alertSoundPlayer = SystemAlertSoundPlayer()
        model.terminateApp = { NSApp.terminate(nil) }
        let capturePrivacy = model.capturePrivacy
        model.quitFallback = { QuitAlert.ask(capturePrivacy: capturePrivacy) }
    }
    /// Every quit comes here: the user's (⌘Q, "Salir de Nook" in any menu) is asked first, in the island; the Mac logging out,
    /// restarting or shutting down, and another app's quit, are not (`AppModel.shouldTerminate`). SIGTERM never comes here.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only a key event can say it is a repeat (asking any other event raises).
        let event = NSApp.currentEvent
        let held = event?.type == .keyDown && event?.isARepeat == true
        return model.shouldTerminate(QuitRequest(event: NSAppleEventManager.shared().currentAppleEvent), keyRepeat: held)
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.save()
        model.sessions.forEach { $0.disconnectClients() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.expand(focus: true); return true
    }
    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        let open = NSMenuItem(title: "Abrir Nook", action: #selector(showNook), keyEquivalent: "n")
        open.target = self; appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edición"); editItem.submenu = edit
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    @objc private func showNook() { controller.expand(focus: true) }
}
