import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Unit tests run inside the app; they must not spawn shells of their
    /// own or overwrite the user's saved windows.
    private let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        SessionTerminalView.installLineEditingShortcuts()
        guard !isTesting else { return }
        if !WindowManager.shared.restoreWindows() {
            WindowManager.shared.newWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            WindowManager.shared.newWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = WindowManager.shared.controllers.compactMap(\.session.runningProgram)
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Tern?"
        alert.informativeText = running.count == 1
            ? "“\(running[0])” is still running. Quitting will terminate it."
            : "Programs are still running in \(running.count) tabs. Quitting will terminate them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !isTesting {
            WindowManager.shared.saveWindows()
        }
        WindowManager.shared.terminateAll()
    }
}
