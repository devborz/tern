import AppKit
import Observation
import SwiftTerm
import SwiftUI

/// Per-window UI state, shared between AppKit and the SwiftUI content.
@Observable
final class TerminalWindowState {
    var isHistoryVisible = false
    var backgroundTranslucency = 0.0
}

/// One native window — and therefore one native tab — showing one session.
///
/// Tabs are plain `NSWindow`s in a tab group (`tabbingIdentifier` +
/// `addTabbedWindow`), so dragging, detaching, merging and the Window menu
/// tab commands all come from AppKit.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    static let tabbingIdentifier = "dev.tern.terminal"

    let session: TerminalSession
    let state = TerminalWindowState()
    var onClose: ((TerminalWindowController) -> Void)?
    var onNewTabRequest: ((TerminalWindowController) -> Void)?

    init(session: TerminalSession) {
        self.session = session

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize(for: session)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // No separate title bar: the terminal background runs under it.
        // SwiftUI keeps the content itself below it (safe area).
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .automatic
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isRestorable = false
        // The controller owns the window; AppKit must not release it on close.
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 240, height: 120)

        let hosting = NSHostingController(rootView: TerminalWindowView(session: session, state: state))
        // The window, not SwiftUI's ideal size, decides the content size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        var contentSize = Self.initialContentSize(for: session)
        window.setContentSize(contentSize)
        // The content view also spans the title bar; add room for it.
        contentSize.height += window.frame.height - window.contentLayoutRect.height
        window.setContentSize(contentSize)
        window.initialFirstResponder = session.terminalView

        super.init(window: window)
        window.delegate = self
        session.terminalView.applyAppearanceColors()
        observeSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func focusTerminal() {
        window?.makeFirstResponder(session.terminalView)
    }

    func toggleHistory() {
        state.isHistoryVisible.toggle()
    }

    /// The window background is the terminal background, title bar included:
    /// the text background color when solid, the blurred desktop under a
    /// tint (drawn by `TerminalWindowView`) when translucent.
    func apply(_ settings: TerminalSettings) {
        session.apply(settings)
        state.backgroundTranslucency = settings.backgroundTranslucency
        guard let window else { return }
        window.isOpaque = !settings.isTranslucent
        window.backgroundColor = settings.isTranslucent ? .clear : .textBackgroundColor
    }

    /// The "+" button in the tab bar and the "New Tab" responder action.
    override func newWindowForTab(_ sender: Any?) {
        onNewTabRequest?(self)
    }

    // MARK: - NSWindowDelegate

    /// Asks first when closing would kill a running program, like Terminal.app.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let program = session.runningProgram else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "“\(program)” is still running. Closing the tab will terminate it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn {
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        session.terminate()
        onClose?(self)
    }

    // MARK: - Private

    /// 80×25 cells plus the margin.
    private static func initialContentSize(for session: TerminalSession) -> NSSize {
        let cells = session.terminalView.getOptimalFrameSize().size
        return NSSize(width: ceil(cells.width) + 6, height: ceil(cells.height) + 4)
    }

    /// Mirrors the session's titles and directory into the window and its tab.
    private func observeSession() {
        withObservationTracking {
            guard let window else { return }
            let title = session.windowTitle
            if window.title != title {
                window.title = title
            }
            let tabTitle = session.title
            if window.tab.title != tabTitle {
                window.tab.title = tabTitle
            }
            if window.representedURL != session.currentDirectory {
                window.representedURL = session.currentDirectory
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeSession() }
        }
    }
}
