import Foundation
import Observation

/// Turns shell-integration events into `CommandExecution` records.
///
/// Works purely from shell events — never from rendered terminal text.
/// History is kept in memory for the lifetime of the session.
@Observable
final class CommandTracker {
    /// Commands in the order they started; a running command is last.
    private(set) var executions: [CommandExecution] = []
    private(set) var isAtPrompt = false

    @ObservationIgnored private var runningSince: ContinuousClock.Instant?
    @ObservationIgnored private let clock = ContinuousClock()

    private let maxExecutions = 10_000

    /// A command by its ID, searched newest first.
    func execution(withID id: UUID) -> CommandExecution? {
        executions.last { $0.id == id }
    }

    var runningCommand: CommandExecution? {
        guard let last = executions.last, last.isRunning else { return nil }
        return last
    }

    func promptStarted() {
        // A prompt while a command is still marked running means its finish
        // mark was lost; close it out without an exit code.
        finishRunningCommand(exitCode: nil)
        isAtPrompt = true
    }

    func commandStarted(_ commandLine: String, in workingDirectory: URL, at date: Date = .now) {
        finishRunningCommand(exitCode: nil)
        isAtPrompt = false
        executions.append(CommandExecution(command: commandLine, workingDirectory: workingDirectory, startedAt: date))
        runningSince = clock.now
        if executions.count > maxExecutions {
            executions.removeFirst(executions.count - maxExecutions)
        }
    }

    /// Returns the finished execution, or `nil` if no command was running
    /// (e.g. the user just pressed Return at the prompt).
    @discardableResult
    func commandFinished(exitCode: Int32?, at date: Date = .now) -> CommandExecution? {
        finishRunningCommand(exitCode: exitCode, at: date)
    }

    /// The shell exited; a command still running (e.g. `exit` itself) ends with it.
    func sessionEnded(exitCode: Int32) {
        finishRunningCommand(exitCode: exitCode)
        isAtPrompt = false
    }

    @discardableResult
    private func finishRunningCommand(exitCode: Int32?, at date: Date = .now) -> CommandExecution? {
        guard let index = executions.indices.last, executions[index].isRunning else { return nil }
        executions[index].finishedAt = date
        executions[index].exitCode = exitCode
        executions[index].duration = runningSince.map { (clock.now - $0).timeInterval }
            ?? date.timeIntervalSince(executions[index].startedAt)
        runningSince = nil
        return executions[index]
    }
}

nonisolated private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
