import AppKit

/// Creates terminal windows and tabs, and keeps their controllers alive.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [TerminalWindowController] = []
    private var settings = TerminalSettings.current
    private var lastCascadePoint = NSPoint.zero

    private init() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowManager.shared.settingsDidChange() }
        }
        NSApp.appearance = settings.appearance.nsAppearance
    }

    var keyController: TerminalWindowController? {
        NSApp.keyWindow?.windowController as? TerminalWindowController
    }

    /// ⌘N: a new window, in the home directory.
    func newWindow() {
        let controller = makeController(workingDirectory: nil)
        guard let window = controller.window else { return }
        if controllers.count == 1 {
            window.center()
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        } else {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        }
        show(controller)
    }

    /// ⌘T: a new tab next to the current one, in the same directory.
    func newTab() {
        guard let current = keyController else {
            newWindow()
            return
        }
        newTab(after: current)
    }

    func newTab(after current: TerminalWindowController) {
        guard let currentWindow = current.window else { return }
        let controller = makeController(workingDirectory: current.session.currentDirectory)
        guard let window = controller.window else { return }
        currentWindow.addTabbedWindow(window, ordered: .above)
        show(controller)
    }

    func toggleHistory() {
        keyController?.toggleHistory()
    }

    /// Brings the window (tab) of a session to the front.
    func showSession(_ id: UUID) {
        guard let controller = controllers.first(where: { $0.session.id == id }) else { return }
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Hangs up every shell; called when the app quits.
    func terminateAll() {
        for controller in controllers {
            controller.session.terminate()
        }
    }

    // MARK: - Restoring windows

    /// One window as it is saved at quit: its tabs' working directories in
    /// tab order, which tab is selected, and where it was.
    struct SavedWindow: Codable, Equatable {
        var frame: CGRect
        var directories: [String]
        var selectedTab: Int
    }

    private static let savedWindowsKey = "savedWindows"

    /// Remembers the open windows and tabs; called when the app quits.
    func saveWindows() {
        // Frontmost first; minimized windows are not in `orderedWindows`.
        let windows = NSApp.orderedWindows + controllers.compactMap(\.window)
        let data = try? JSONEncoder().encode(savedWindows(of: windows))
        UserDefaults.standard.set(data, forKey: Self.savedWindowsKey)
    }

    /// Reopens the windows and tabs open at the last quit. Returns `false`
    /// when there were none.
    func restoreWindows() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.savedWindowsKey),
              let saved = try? JSONDecoder().decode([SavedWindow].self, from: data),
              !saved.isEmpty
        else { return false }
        // Back to front, so the frontmost window ends up in front.
        restore(saved.reversed())
        return true
    }

    /// The terminal windows among `windows`, one entry per tab group, in the
    /// order their first window appears.
    func savedWindows(of windows: [NSWindow]) -> [SavedWindow] {
        var seen = Set<ObjectIdentifier>()
        var saved: [SavedWindow] = []
        for window in windows where window.windowController is TerminalWindowController {
            guard !seen.contains(ObjectIdentifier(window)) else { continue }
            let tabs = window.tabbedWindows ?? [window]
            seen.formUnion(tabs.map(ObjectIdentifier.init))
            let sessions = tabs.compactMap { ($0.windowController as? TerminalWindowController)?.session }
            let selected = window.tabGroup?.selectedWindow.flatMap { tabs.firstIndex(of: $0) } ?? 0
            saved.append(SavedWindow(frame: window.frame, directories: sessions.map(\.currentDirectory.path), selectedTab: selected))
        }
        return saved
    }

    /// Opens saved windows, each with its tabs. Returns their controllers,
    /// one array of tabs per window.
    @discardableResult
    func restore(_ saved: [SavedWindow]) -> [[TerminalWindowController]] {
        saved.map { savedWindow in
            var tabs: [TerminalWindowController] = []
            for path in savedWindow.directories {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                let controller = makeController(workingDirectory: exists ? URL(fileURLWithPath: path, isDirectory: true) : nil)
                guard let window = controller.window else { continue }
                if let previous = tabs.last?.window {
                    previous.addTabbedWindow(window, ordered: .above)
                } else if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedWindow.frame) }) {
                    window.setFrame(savedWindow.frame, display: false)
                } else {
                    // Its display is gone.
                    window.center()
                }
                controller.showWindow(nil)
                tabs.append(controller)
            }
            let selected = tabs.indices.contains(savedWindow.selectedTab) ? tabs[savedWindow.selectedTab] : tabs.first
            if let selected {
                show(selected)
            }
            return tabs
        }
    }

    // MARK: - Private

    private func makeController(workingDirectory: URL?) -> TerminalWindowController {
        let session = TerminalSession(workingDirectory: workingDirectory, settings: settings)
        let controller = TerminalWindowController(session: session)
        controller.apply(settings)
        controller.onClose = { [weak self] controller in
            self?.controllers.removeAll { $0 === controller }
        }
        controller.onNewTabRequest = { [weak self] controller in
            self?.newTab(after: controller)
        }
        session.onCommandFinished = { [weak self, weak controller] execution in
            guard let self, let controller, settings.notifyLongCommands else { return }
            CommandNotifier.shared.commandFinished(execution, in: controller)
        }
        session.onExit = { [weak controller] session in
            // Like Terminal.app: close when the shell exits cleanly, keep the
            // output visible otherwise.
            if case .exited(code: 0) = session.state {
                controller?.close()
            }
        }
        controllers.append(controller)
        return controller
    }

    private func show(_ controller: TerminalWindowController) {
        controller.showWindow(nil)
        controller.focusTerminal()
    }

    private func settingsDidChange() {
        let newSettings = TerminalSettings.current
        guard newSettings != settings else { return }
        settings = newSettings
        NSApp.appearance = newSettings.appearance.nsAppearance
        for controller in controllers {
            controller.apply(newSettings)
        }
    }
}
