import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import Tern

/// End-to-end tests: a real login zsh (with the user's own dotfiles) on a
/// real PTY, driven through the same input path as the keyboard, observed
/// through shell-integration events and the emulator's screen buffer.
@Suite(.serialized)
struct TerminalSessionTests {
    private func makeSession(in directory: String = NSTemporaryDirectory()) async throws -> TerminalSession {
        let session = TerminalSession(workingDirectory: URL(fileURLWithPath: directory, isDirectory: true))
        try #require(session.hasShellIntegration)
        try #require(await session.waitForPrompt(), "zsh never showed a prompt")
        return session
    }

    @Test func tracksCommandsExitCodesAndWorkingDirectory() async throws {
        let session = try await makeSession()
        defer { session.terminate() }

        let cd = try #require(await session.run("cd /tmp"))
        #expect(cd.command == "cd /tmp")
        #expect(cd.exitCode == 0)
        #expect(session.currentDirectory.path == "/tmp")
        #expect(session.title == "tmp")
        #expect(session.windowTitle == "/tmp")

        let failing = try #require(await session.run("ls /definitely/not/here"))
        #expect(failing.exitCode != 0)
        #expect(failing.workingDirectory.path == "/tmp")
        #expect(try #require(failing.duration) >= 0)

        let exit3 = try #require(await session.run("(exit 3)"))
        #expect(exit3.exitCode == 3)

        // Pressing Return at an empty prompt is not a command.
        session.type("\r")
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.finishedCommands.count == 3)

        // Each finished command got a status line.
        for execution in session.finishedCommands {
            #expect(session.terminalView.statusRow(of: execution.id) != nil, "\(execution.command)")
        }
    }

    @Test func statusLineStartsOnFreshLineAndKeepsUnicode() async throws {
        let session = try await makeSession()
        defer { session.terminate() }

        let execution = try #require(await session.run("printf 'привет, мир 👋'"))
        #expect(execution.command == "printf 'привет, мир 👋'")
        let screen = session.screenText
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        let outputIndex = try #require(lines.lastIndex { $0.hasPrefix("привет, мир 👋") }, "\(screen)")
        #expect(session.terminalView.statusRow(of: execution.id) == outputIndex + 1)
    }

    @Test func controlCInterruptsRunningCommand() async throws {
        let session = try await makeSession()
        defer { session.terminate() }

        session.type("sleep 30\r")
        #expect(await eventually { session.commandTracker.runningCommand?.command == "sleep 30" })
        try await Task.sleep(for: .milliseconds(300))
        session.type("\u{03}")
        #expect(await eventually(timeout: .seconds(5)) { session.finishedCommands.last?.command == "sleep 30" })
        #expect(session.finishedCommands.last?.exitCode == 130)
    }

    @Test func controlZSuspendsJobAndHangupCleansItUp() async throws {
        let session = try await makeSession()
        let job = "sleep 4343"

        session.type(job + "\r")
        #expect(await eventually { processExists(commandLine: job) })
        try await Task.sleep(for: .milliseconds(200))
        session.type("\u{1A}")
        #expect(await eventually(timeout: .seconds(5)) { session.finishedCommands.last?.command == job && session.commandTracker.isAtPrompt })
        #expect(session.finishedCommands.last?.exitCode == 128 + SIGTSTP)
        #expect(processExists(commandLine: job), "the suspended job should still exist")

        // Closing the session must not leave the stopped job behind.
        session.terminate()
        #expect(await eventually(timeout: .seconds(5)) { !processExists(commandLine: job) })
    }

    @Test func resizeReachesThePTYAndSendsSIGWINCH() async throws {
        let session = try await makeSession()
        defer { session.terminate() }

        try #require(await session.run("TRAPWINCH() { print WINCH-RECEIVED }") != nil)
        let view = session.terminalView
        let rowHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
        view.setFrameSize(NSSize(width: view.frame.width, height: rowHeight * 31 + 1))
        #expect(view.getTerminal().rows == 31)
        #expect(await eventually(timeout: .seconds(5)) { session.screenText.contains("WINCH-RECEIVED") })

        try #require(await session.run("stty size") != nil)
        #expect(session.screenText.contains("31 \(view.getTerminal().cols)"))
    }

    @Test(arguments: [("vim -u NONE -N -n", ":q\r"), ("top", "q")])
    func fullScreenProgramsRunAndExitCleanly(command: String, quit: String) async throws {
        let session = try await makeSession()
        defer { session.terminate() }
        let terminal = session.terminalView.getTerminal()

        session.type(command + "\r")
        #expect(await eventually { terminal.isCurrentBufferAlternate }, "\(command) never switched to the alternate screen")
        try await Task.sleep(for: .milliseconds(500))
        session.type(quit)
        #expect(await eventually { session.finishedCommands.last?.command == command && session.commandTracker.isAtPrompt })
        #expect(session.finishedCommands.last?.exitCode == 0)
        #expect(!terminal.isCurrentBufferAlternate)
    }

    @Test func exitEndsSessionAndReapsShell() async throws {
        let session = try await makeSession()
        let pid = try #require(session.processID)

        session.type("exit\r")
        #expect(await eventually { session.state == .exited(code: 0) })
        #expect(session.processID == nil)
        #expect(!processIsAlive(pid))
        #expect(session.commandTracker.executions.last?.command == "exit")
        #expect(session.commandTracker.runningCommand == nil)
    }

    @Test func terminateKillsShellAndItsForegroundJob() async throws {
        let session = try await makeSession()
        let pid = try #require(session.processID)
        let job = "sleep 4242"

        session.type(job + "\r")
        #expect(await eventually { processExists(commandLine: job) })
        session.terminate()
        #expect(await eventually(timeout: .seconds(5)) { if case .exited = session.state { true } else { false } })
        #expect(!processIsAlive(pid))
        #expect(await eventually(timeout: .seconds(5)) { !processExists(commandLine: job) })
    }
}
