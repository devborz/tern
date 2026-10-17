import Darwin
import Foundation
import SwiftTerm
@testable import Tern

/// Polls `condition` while letting the main queue run (PTY output is
/// delivered there). Returns whether the condition became true in time.
func eventually(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Whether any process has exactly this command line.
func processExists(commandLine: String) -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "^\(commandLine)$"]
    pgrep.standardOutput = FileHandle.nullDevice
    try? pgrep.run()
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0
}

extension TerminalSession {
    /// Sends keystrokes through the same path as the keyboard.
    func type(_ text: String) {
        send(source: terminalView, data: ArraySlice(Array(text.utf8)))
    }

    /// The active screen plus scrollback as plain text, one line per row,
    /// without trailing blanks (erased cells hold spaces).
    var screenText: String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        var row = 0
        while let line = terminal.getScrollInvariantLine(row: row) {
            let text = line.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) }
            )
            lines.append(String(text.reversed().drop { $0 == " " }.reversed()))
            row += 1
        }
        return lines.joined(separator: "\n")
    }

    var finishedCommands: [CommandExecution] {
        commandTracker.executions.filter { !$0.isRunning }
    }

    /// Types a command and waits until the shell reports it finished.
    @discardableResult
    func run(_ command: String, timeout: Duration = .seconds(15)) async -> CommandExecution? {
        let before = finishedCommands.count
        type(command + "\r")
        guard await eventually(timeout: timeout, { finishedCommands.count > before && commandTracker.isAtPrompt }) else {
            return nil
        }
        return finishedCommands.last
    }

    func waitForPrompt() async -> Bool {
        await eventually { commandTracker.isAtPrompt }
    }
}
