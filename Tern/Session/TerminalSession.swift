import AppKit
import Observation
import SwiftTerm

/// One shell running in one terminal.
///
/// Owns the shell process lifecycle and everything that must outlive any
/// particular view: the PTY, the shell-integration parser, the command
/// tracker, and the emulator (SwiftTerm's `TerminalView`, which holds the
/// screen and scrollback). SwiftUI only hosts `terminalView`, so redraws or
/// re-created views never touch the shell or lose output.
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        case exited(code: Int32)
        case failedToStart(message: String)
    }

    let id = UUID()
    /// Tab title: the directory name, plus the running program: `app — vim`.
    private(set) var title: String = "Terminal"
    /// Window title: the path instead of the name: `~/Projects/app — vim`.
    private(set) var windowTitle: String = "Terminal"
    private(set) var currentDirectory: URL
    private(set) var state: State = .running
    /// `false` when the shell is not zsh, so commands cannot be tracked.
    private(set) var hasShellIntegration = false
    let commandTracker = CommandTracker()

    @ObservationIgnored let terminalView: SessionTerminalView
    /// Called once the shell process has exited and been reaped.
    @ObservationIgnored var onExit: ((TerminalSession) -> Void)?
    /// Called when a command finishes, after its status line is shown.
    @ObservationIgnored var onCommandFinished: ((CommandExecution) -> Void)?

    @ObservationIgnored private var process: PTYProcess?
    @ObservationIgnored private var shellIntegration: ShellIntegrationParser
    @ObservationIgnored private var appliedSettings: TerminalSettings
    /// Points added to the configured font size with ⌘= / ⌘−, in this tab only.
    @ObservationIgnored private var fontZoom = 0.0

    init(workingDirectory: URL?, settings: TerminalSettings = .current) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        currentDirectory = workingDirectory ?? home
        appliedSettings = settings

        let token = UUID().uuidString
        shellIntegration = ShellIntegrationParser(applicationID: token)

        var options = TerminalOptions.default
        options.scrollback = settings.scrollbackLines
        options.cursorStyle = settings.cursorStyle
        terminalView = SessionTerminalView(frame: .zero, font: settings.font, options: options)
        terminalView.isBackgroundTransparent = settings.isTranslucent
        terminalView.optionAsMetaKey = settings.optionAsMeta
        terminalView.statusFontSizeOffset = settings.statusFontSizeOffset
        // Report screen updates (`rangeChanged`), which place the status views.
        terminalView.notifyUpdateChanges = true
        terminalView.terminalDelegate = self
        terminalView.frame = terminalView.getOptimalFrameSize()

        terminalView.commandLookup = { [weak self] id in self?.commandTracker.execution(withID: id) }
        updateTitle()
        start(shell: settings.resolvedShellPath, integrationToken: token, commandSuggestions: settings.commandSuggestions)
    }

    /// The shell's process ID while it is running.
    var processID: pid_t? {
        process?.pid
    }

    /// Absolute path with the home directory abbreviated: `~/Projects/app`.
    var displayPath: String {
        Self.abbreviatingHome(currentDirectory.path)
    }

    /// The program the shell is running in the foreground — the command line
    /// when shell integration knows it, the process name otherwise — or
    /// `nil` while the shell is idle. Closing the session would kill it.
    var runningProgram: String? {
        guard let process, let group = process.foregroundProcessGroup, group != process.pid else { return nil }
        if let command = commandTracker.runningCommand, !command.command.isEmpty {
            return command.command
        }
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return "a program" }
        return String(cString: name)
    }

    /// Hangs up the shell. Safe to call more than once.
    func terminate() {
        process?.terminate()
    }

    func apply(_ settings: TerminalSettings) {
        defer { appliedSettings = settings }
        if settings.fontName != appliedSettings.fontName
            || settings.fontSize != appliedSettings.fontSize
            || settings.fontWeight != appliedSettings.fontWeight {
            terminalView.font = zoomedFont(settings)
        }
        if settings.isTranslucent != appliedSettings.isTranslucent {
            terminalView.isBackgroundTransparent = settings.isTranslucent
        }
        if settings.optionAsMeta != appliedSettings.optionAsMeta {
            terminalView.optionAsMetaKey = settings.optionAsMeta
        }
        if settings.statusFontSizeOffset != appliedSettings.statusFontSizeOffset {
            terminalView.statusFontSizeOffset = settings.statusFontSizeOffset
        }
        if settings.cursorStyle != appliedSettings.cursorStyle {
            terminalView.getTerminal().setCursorStyle(settings.cursorStyle)
        }
        if settings.scrollbackLines != appliedSettings.scrollbackLines {
            terminalView.changeScrollback(settings.scrollbackLines)
        }
    }

    /// ⌘= / ⌘− (`step` of ±1 point) and ⌘0 (`nil`, back to the configured size).
    func zoomFont(by step: Double?) {
        fontZoom = step.map { fontZoom + $0 } ?? 0
        let font = zoomedFont(appliedSettings)
        // Stop at the limits instead of piling up zoom that has no effect.
        fontZoom = font.pointSize - appliedSettings.fontSize
        terminalView.font = font
    }

    private func zoomedFont(_ settings: TerminalSettings) -> NSFont {
        var settings = settings
        let range = TerminalSettings.fontSizeRange
        settings.fontSize = min(max(settings.fontSize + fontZoom, range.lowerBound), range.upperBound)
        return settings.font
    }

    /// ⌘K: erases the scrollback and the screen. At the prompt the shell is
    /// asked to redraw it (Ctrl-L, which keeps what was typed); a running
    /// program just carries on from the top.
    func clearBuffer() {
        guard !terminalView.getTerminal().isCurrentBufferAlternate else { return }
        terminalView.feed(text: "\u{1B}[3J")
        if commandTracker.isAtPrompt {
            process?.write([0x0C])
        } else {
            terminalView.feed(text: "\u{1B}[H\u{1B}[2J")
        }
    }

    // MARK: - Process

    private func start(shell: String, integrationToken: String, commandSuggestions: Bool) {
        let launch = ShellLaunch.configuration(
            shell: shell,
            workingDirectory: currentDirectory,
            size: terminalView.windowSize,
            integrationToken: integrationToken,
            commandSuggestions: commandSuggestions
        )
        hasShellIntegration = launch.hasIntegration
        do {
            process = try PTYProcess(
                configuration: launch.configuration,
                onOutput: { [weak self] bytes in self?.receive(bytes) },
                onExit: { [weak self] status in self?.processExited(status: status) }
            )
        } catch {
            state = .failedToStart(message: error.localizedDescription)
            terminalView.feed(text: "\u{1B}[31m\(error.localizedDescription)\u{1B}[0m\r\n")
        }
    }

    /// Feeds shell output to the emulator, acting on shell-integration events
    /// at their exact position in the stream.
    private func receive(_ bytes: [UInt8]) {
        var fed = 0
        for located in shellIntegration.parse(bytes) {
            terminalView.feed(byteArray: bytes[fed..<located.endOffset])
            fed = located.endOffset
            handle(located.event)
        }
        if fed < bytes.count {
            terminalView.feed(byteArray: bytes[fed...])
        }
    }

    private func handle(_ event: ShellEvent) {
        switch event {
        case .workingDirectoryChanged(let url):
            if url != currentDirectory {
                currentDirectory = url
            }
        case .promptStarted:
            commandTracker.promptStarted()
        case .commandInputStarted:
            break
        case .commandStarted(let commandLine):
            commandTracker.commandStarted(commandLine ?? "", in: currentDirectory)
        case .commandFinished(let exitCode):
            if let execution = commandTracker.commandFinished(exitCode: exitCode) {
                showStatusLine(for: execution)
                onCommandFinished?(execution)
            }
        }
        updateTitle()
    }

    /// Writes the `✓ 0 · 84 ms` status line between the command's output and
    /// the next prompt. Local to the emulator; the shell never sees it.
    private func showStatusLine(for execution: CommandExecution) {
        let terminal = terminalView.getTerminal()
        guard !terminal.isCurrentBufferAlternate, CommandStatusLine.shouldShow(for: execution) else { return }
        let line = CommandStatusLine.render(
            execution,
            startOnNewLine: terminal.getCursorLocation().x != 0,
            hasOutput: terminalView.commandPrintedOutput()
        )
        terminalView.feed(text: line)
    }

    private func processExited(status: Int32) {
        process = nil
        commandTracker.sessionEnded(exitCode: status)
        state = .exited(code: status)
        terminalView.feed(text: "\r\n\u{1B}[0;2m[Process exited with code \(status)]\u{1B}[0m\r\n")
        updateTitle()
        onExit?(self)
    }

    // MARK: - Title

    private func updateTitle() {
        var suffix = ""
        if let command = commandTracker.runningCommand, !command.programName.isEmpty {
            suffix = " — \(command.programName)"
        }
        let newTitle = Self.directoryName(currentDirectory) + suffix
        if newTitle != title {
            title = newTitle
        }
        let newWindowTitle = displayPath + suffix
        if newWindowTitle != windowTitle {
            windowTitle = newWindowTitle
        }
    }

    /// `~` for home, `/` for the root, the last path component otherwise.
    static func directoryName(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path {
            return "~"
        }
        return path == "/" ? "/" : url.lastPathComponent
    }

    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process?.write(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        process?.resize(terminalView.windowSize)
        terminalView.setNeedsStatusLayout()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Programs may set a title with OSC 0/2; the tab title follows the
        // working directory instead.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7 is handled by `ShellIntegrationParser` before the emulator.
    }

    func scrolled(source: TerminalView, position: Double) {
        terminalView.setNeedsStatusLayout()
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        terminalView.setNeedsStatusLayout()
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // ⌘-click on a status line copies the command's output.
        if let command = CommandStatusLine.command(fromLink: link) {
            if !terminalView.copyCommandOutput(of: command.id) {
                NSSound.beep()
            }
            return
        }
        TerminalView.openDefaultLink(link)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        // OSC 52 copy, used by vim/tmux over ssh.
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
