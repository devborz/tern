import Foundation
import Testing
@testable import Tern

/// Command suggestions in a real login zsh with Tern's integration, but with
/// a throwaway config whose history holds one command instead of the user's
/// dotfiles. Driven through the PTY, observed in the raw output.
@Suite(.serialized)
struct CommandSuggestionTests {
    @Test func tabAcceptsSuggestionAndStillCompletes() async throws {
        let shell = try TestShell(commandSuggestions: true)
        defer { shell.close() }
        try #require(await shell.waitForLineEditor())

        try #require(await shell.run("print -r -- loaded=${+functions[_zsh_autosuggest_start]}", expecting: "loaded=1"))

        // The rest of the history entry is shown after what was typed.
        shell.type("ech")
        #expect(await eventually(timeout: .seconds(5)) { shell.output.contains("hello-from-history") })
        shell.type("\t")
        try await Task.sleep(for: .milliseconds(300))
        shell.type("\r")
        #expect(await eventually(timeout: .seconds(5)) { shell.hasOutputLine("hello-from-history") })

        // Without a suggestion, Tab completes as usual.
        shell.type("cd /usr/sh")
        try await Task.sleep(for: .milliseconds(300))
        shell.type("\t")
        try await Task.sleep(for: .milliseconds(300))
        shell.type("\r")
        #expect(await shell.run("pwd", expecting: "/usr/share"))
    }

    @Test func canBeTurnedOff() async throws {
        let shell = try TestShell(commandSuggestions: false)
        defer { shell.close() }
        try #require(await shell.waitForLineEditor())

        #expect(await shell.run("print -r -- loaded=${+functions[_zsh_autosuggest_start]}", expecting: "loaded=0"))
    }

    @Test func leavesUsersOwnTabBindingAlone() async throws {
        let shell = try TestShell(commandSuggestions: true, zshrc: "bindkey '^I' complete-word")
        defer { shell.close() }
        try #require(await shell.waitForLineEditor())

        #expect(await shell.run("print -r -- loaded=${+functions[_zsh_autosuggest_start]}", expecting: "loaded=1"))
        #expect(await shell.run("bindkey '^I'", expecting: "\"^I\" complete-word"))
    }
}

private final class TestShell {
    private(set) var output = ""
    private var process: PTYProcess?
    private let directory: URL

    init(commandSuggestions: Bool, zshrc: String = "") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tern-suggestions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ": 1700000000:0;echo hello-from-history\n"
            .write(to: directory.appendingPathComponent("history"), atomically: true, encoding: .utf8)
        try """
        HISTFILE='\(directory.path)/history' HISTSIZE=100 SAVEHIST=0
        PS1='%% '
        \(zshrc)

        """.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        var configuration = ShellLaunch.configuration(
            shell: ShellLaunch.defaultShell,
            workingDirectory: directory,
            size: PTYProcess.WindowSize(columns: 120, rows: 24),
            integrationToken: "test",
            commandSuggestions: commandSuggestions
        ).configuration
        // Our .zshenv switches to this directory instead of the user's config.
        configuration.environment["TERN_ORIG_ZDOTDIR"] = directory.path
        process = try PTYProcess(
            configuration: configuration,
            onOutput: { [weak self] bytes in self?.output += String(decoding: bytes, as: UTF8.self) },
            onExit: { _ in }
        )
    }

    func type(_ text: String) {
        process?.write(Array(text.utf8))
    }

    /// Waits until zsh is reading a command line (it turns on bracketed paste).
    func waitForLineEditor() async -> Bool {
        await eventually { output.contains("\u{1B}[?2004h") }
    }

    /// Runs a command and waits for an output line ending with `expected`.
    func run(_ command: String, expecting expected: String) async -> Bool {
        type(command + "\r")
        return await eventually(timeout: .seconds(5)) { hasOutputLine(expected) }
    }

    /// Whether a line ends with `expected`. Output lines may begin with the
    /// shell's OSC 133 marks.
    func hasOutputLine(_ expected: String) -> Bool {
        output.components(separatedBy: "\r\n").contains { $0.hasSuffix(expected) }
    }

    func close() {
        process?.terminate()
        try? FileManager.default.removeItem(at: directory)
    }
}
