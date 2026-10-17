import Foundation

/// A lifecycle event reported by the shell through escape sequences
/// (OSC 133 semantic prompts and OSC 7 working directory).
nonisolated enum ShellEvent: Equatable, Sendable {
    /// OSC 133;A — the shell is about to draw a prompt.
    case promptStarted
    /// OSC 133;B — the prompt is drawn; the user is typing a command.
    case commandInputStarted
    /// OSC 133;C — a command line was submitted and is about to run.
    case commandStarted(commandLine: String?)
    /// OSC 133;D — the command finished with this exit status, if reported.
    case commandFinished(exitCode: Int32?)
    /// OSC 7 — the shell's working directory changed.
    case workingDirectoryChanged(URL)
}
