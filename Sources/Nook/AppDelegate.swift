import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    lazy var controller = NotchController(model: model)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        _ = controller
        model.restore()
        controller.expand(focus: true)
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
