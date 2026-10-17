import AppKit
import SwiftTerm
import Testing
@testable import Tern

/// ⌘/⌥ text-editing shortcuts, translated to line-editor keys and checked
/// against what a real zsh does with them.
@Suite(.serialized)
struct LineEditingShortcutTests {
    @Test func translatesShortcutsToLineEditorKeys() {
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.backspace, [.command])) == [0x15])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.forwardDelete, [.command])) == [0x0B])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.left, [.command])) == [0x01])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.right, [.command])) == [0x05])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.backspace, [.option])) == [0x1B, 0x7F])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.forwardDelete, [.option])) == [0x1B, 0x64])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.left, [.option])) == [0x1B, 0x62])
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.right, [.option])) == [0x1B, 0x66])

        // Everything else is left to SwiftTerm.
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.backspace, [])) == nil)
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.left, [])) == nil)
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.left, [.command, .shift])) == nil)
        #expect(SessionTerminalView.lineEditingBytes(for: .key(.left, [.control])) == nil)
    }

    @Test func editsTheCommandLineInZsh() async throws {
        let session = TerminalSession(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        defer { session.terminate() }
        let view = session.terminalView
        // Keys typed before zle takes over the tty go through the kernel's
        // line discipline instead, where DEL erases a character and ^U the line.
        func waitForLineEditor() async throws {
            try #require(await eventually { session.commandTracker.isAtPrompt && view.getTerminal().bracketedPasteMode })
        }
        try await waitForLineEditor()

        func press(_ key: TestKey, _ modifiers: NSEvent.ModifierFlags) {
            #expect(view.sendLineEditingKey(for: .key(key, modifiers)))
        }
        func runTyped() async throws -> String {
            let before = session.finishedCommands.count
            session.type("\r")
            try #require(await eventually { session.finishedCommands.count > before })
            try await waitForLineEditor()
            return try #require(session.finishedCommands.last).command
        }

        // ⌘⌫ erases what was typed.
        session.type("echo wrong")
        press(.backspace, .command)
        session.type("echo right")
        #expect(try await runTyped() == "echo right")

        // ⌘← goes to the start of the line.
        session.type("cho start")
        press(.left, .command)
        session.type("e")
        #expect(try await runTyped() == "echo start")

        // ⌥← goes back a word, ⌥⌫ erases the word before the cursor.
        session.type("echo a c x")
        press(.backspace, .option)
        press(.left, .option)
        session.type("b ")
        #expect(try await runTyped().trimmingCharacters(in: .whitespaces) == "echo a b c")

        // ⌥→ goes forward a word, ⌘⌦ erases to the end of the line.
        session.type("echo keep drop")
        press(.left, .command)
        press(.right, .option)
        press(.right, .option)
        press(.forwardDelete, .command)
        #expect(try await runTyped() == "echo keep")

        // ⌥⌦ erases the word after the cursor.
        session.type("echo zap ok")
        press(.left, .command)
        press(.right, .option)
        press(.forwardDelete, .option)
        #expect(try await runTyped() == "echo ok")
    }

    @Test func appMonitorRoutesShortcutsToTheFocusedTerminal() async throws {
        let manager = WindowManager.shared
        manager.newWindow()
        let controller = try #require(manager.controllers.last)
        let window = try #require(controller.window)
        defer { window.close() }
        let session = controller.session
        try #require(await eventually { session.terminalView.getTerminal().bracketedPasteMode })
        #expect(window.firstResponder === session.terminalView)

        let before = session.finishedCommands.count
        session.type("echo wrong")
        NSApp.sendEvent(.key(.backspace, .command, window: window))
        session.type("echo right\r")
        #expect(await eventually { session.finishedCommands.count > before && session.commandTracker.isAtPrompt })
        #expect(session.finishedCommands.last?.command == "echo right")
    }
}

enum TestKey {
    case backspace, forwardDelete, left, right

    var characters: String {
        switch self {
        case .backspace: "\u{7F}"
        case .forwardDelete: String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!)
        case .left: String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
        case .right: String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .backspace: 51
        case .forwardDelete: 117
        case .left: 123
        case .right: 124
        }
    }

    /// The extra flags AppKit sets for these keys.
    var implicitFlags: NSEvent.ModifierFlags {
        switch self {
        case .backspace: []
        case .forwardDelete: .function
        case .left, .right: [.function, .numericPad]
        }
    }
}

extension NSEvent {
    static func key(_ key: TestKey, _ modifiers: NSEvent.ModifierFlags, window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers.union(key.implicitFlags),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.keyCode
        )!
    }
}
