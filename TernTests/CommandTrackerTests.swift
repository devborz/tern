import Foundation
import Testing
@testable import Tern

struct CommandTrackerTests {
    private let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)

    @Test func recordsFinishedCommand() throws {
        let tracker = CommandTracker()
        tracker.promptStarted()
        #expect(tracker.isAtPrompt)

        let start = Date()
        tracker.commandStarted("make test", in: directory, at: start)
        #expect(tracker.runningCommand?.command == "make test")
        #expect(!tracker.isAtPrompt)

        let finished = try #require(tracker.commandFinished(exitCode: 2, at: start.addingTimeInterval(1)))
        #expect(finished.command == "make test")
        #expect(finished.workingDirectory == directory)
        #expect(finished.exitCode == 2)
        #expect(finished.finishedAt == start.addingTimeInterval(1))
        #expect(try #require(finished.duration) >= 0)
        #expect(tracker.runningCommand == nil)
        #expect(tracker.executions == [finished])
    }

    @Test func finishWithoutRunningCommandIsIgnored() {
        let tracker = CommandTracker()
        #expect(tracker.commandFinished(exitCode: 0) == nil)
        #expect(tracker.executions.isEmpty)
    }

    @Test func lostFinishMarkIsClosedByNextPrompt() {
        let tracker = CommandTracker()
        tracker.commandStarted("ssh host", in: directory)
        tracker.promptStarted()
        #expect(tracker.runningCommand == nil)
        #expect(tracker.executions.first?.isRunning == false)
        #expect(tracker.executions.first?.exitCode == nil)
    }

    @Test func sessionEndFinishesRunningCommand() {
        let tracker = CommandTracker()
        tracker.commandStarted("exit 3", in: directory)
        tracker.sessionEnded(exitCode: 3)
        #expect(tracker.executions.first?.exitCode == 3)
        #expect(tracker.runningCommand == nil)
    }
}

struct CommandNotifierTests {
    private func execution(exitCode: Int32?, duration: TimeInterval) -> CommandExecution {
        var execution = CommandExecution(command: "make", workingDirectory: URL(fileURLWithPath: "/"), startedAt: .now)
        execution.exitCode = exitCode
        execution.duration = duration
        return execution
    }

    @Test func notifiesOnlyForLongCommandsOutOfSight() {
        #expect(CommandNotifier.shouldNotify(execution(exitCode: 0, duration: 12), windowIsInFront: false))
        #expect(!CommandNotifier.shouldNotify(execution(exitCode: 0, duration: 12), windowIsInFront: true))
        #expect(!CommandNotifier.shouldNotify(execution(exitCode: 0, duration: 9.9), windowIsInFront: false))
    }

    @Test func describesTheResult() {
        #expect(CommandNotifier.message(for: execution(exitCode: 0, duration: 125)) == ("✓ make", "Finished in 2m 05s"))
        #expect(CommandNotifier.message(for: execution(exitCode: 2, duration: 12)) == ("✕ make", "Exit code 2 after 12.0 s"))
    }
}

struct CommandStatusLineTests {
    @Test(arguments: [
        (0.0, "0 ms"), (0.084, "84 ms"), (0.9996, "1.0 s"), (3.84, "3.8 s"),
        (59.96, "1m 00s"), (125, "2m 05s"), (3725, "1h 02m"),
    ])
    func formatsDurations(duration: TimeInterval, expected: String) {
        #expect(CommandStatusLine.format(duration: duration) == expected)
    }

    @Test func labelsTheOutcome() {
        var execution = CommandExecution(command: "git status", workingDirectory: URL(fileURLWithPath: "/"), startedAt: .now)
        execution.exitCode = 0
        execution.duration = 0.084
        #expect(CommandStatusLine.label(for: execution) == ("✓ 0", "84 ms", .succeeded))
        execution.exitCode = 2
        execution.duration = 3.8
        #expect(CommandStatusLine.label(for: execution) == ("✕ 2", "3.8 s", .failed))
        execution.exitCode = nil
        #expect(CommandStatusLine.label(for: execution) == ("? –", "3.8 s", .unknown))
    }

    @Test func rendersALinkedPlaceholderLine() {
        var execution = CommandExecution(command: "ls", workingDirectory: URL(fileURLWithPath: "/"), startedAt: .now)
        execution.exitCode = 0
        execution.duration = 0.084
        let link = CommandStatusLine.link(for: execution.id, hasOutput: true)
        let line = CommandStatusLine.render(execution, startOnNewLine: false, hasOutput: true)
        // Blank cells for "✓ 0 · 84 ms" and the copy button, all linked to the command.
        #expect(line == "\u{1B}]8;;\(link)\u{1B}\\" + String(repeating: " ", count: 11 + 3) + "\u{1B}]8;;\u{1B}\\\r\n")

        let quiet = CommandStatusLine.render(execution, startOnNewLine: true, hasOutput: false)
        #expect(quiet.hasPrefix("\r\n\u{1B}]8;;\(CommandStatusLine.link(for: execution.id, hasOutput: false))"))
        #expect(quiet.contains(String(repeating: " ", count: 11) + "\u{1B}]8;;\u{1B}\\"))
    }

    @Test func parsesLinks() {
        let id = UUID()
        let withOutput = CommandStatusLine.link(for: id, hasOutput: true)
        let withoutOutput = CommandStatusLine.link(for: id, hasOutput: false)
        #expect(CommandStatusLine.command(fromLink: withOutput)?.id == id)
        #expect(CommandStatusLine.command(fromLink: withOutput)?.hasOutput == true)
        #expect(CommandStatusLine.command(fromLink: withoutOutput)?.hasOutput == false)
        // SwiftTerm stores the OSC 8 payload as "<params>;<link>".
        #expect(CommandStatusLine.command(fromLink: ";" + withOutput)?.id == id)
        #expect(CommandStatusLine.command(fromLink: "id=1;" + withoutOutput)?.id == id)
        #expect(CommandStatusLine.command(fromLink: ";https://example.com") == nil)
        #expect(CommandStatusLine.command(fromLink: "tern://command/not-a-uuid") == nil)
    }

    @Test func skipsScreenClearingCommands() {
        let clear = CommandExecution(command: "clear", workingDirectory: URL(fileURLWithPath: "/"), startedAt: .now)
        let ls = CommandExecution(command: "ls -la", workingDirectory: URL(fileURLWithPath: "/"), startedAt: .now)
        #expect(!CommandStatusLine.shouldShow(for: clear))
        #expect(CommandStatusLine.shouldShow(for: ls))
    }
}
