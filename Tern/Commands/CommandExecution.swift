import Foundation

/// One command line run by the shell, as reported by shell integration.
nonisolated struct CommandExecution: Identifiable, Equatable, Sendable {
    let id: UUID
    let command: String
    let workingDirectory: URL
    let startedAt: Date
    var finishedAt: Date?
    var exitCode: Int32?
    /// Measured with a monotonic clock, so wall-clock changes do not skew it.
    var duration: TimeInterval?

    init(id: UUID = UUID(), command: String, workingDirectory: URL, startedAt: Date) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
    }

    var isRunning: Bool { finishedAt == nil }
    var succeeded: Bool { exitCode == 0 }

    /// The program name: the first word of the command line.
    var programName: String {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
    }
}
