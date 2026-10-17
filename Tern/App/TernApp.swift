import AppKit
import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Terminal windows are AppKit windows created by `WindowManager`, so
        // that tabs are native NSWindow tabs; SwiftUI provides the menus and
        // the Settings window.
        Settings {
            SettingsView()
        }
        .commands {
            TerminalCommands()
        }
    }
}

struct TerminalCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { WindowManager.shared.newWindow() }
                .keyboardShortcut("n")
            Button("New Tab") { WindowManager.shared.newTab() }
                .keyboardShortcut("t")
        }
        CommandGroup(after: .pasteboard) {
            Button("Clear Buffer") { session?.clearBuffer() }
                .keyboardShortcut("k")
        }
        CommandGroup(after: .textEditing) {
            // SwiftTerm's find bar answers the standard find-panel action.
            Menu("Find") {
                Button("Find…") { find(.showFindPanel) }
                    .keyboardShortcut("f")
                Button("Find Next") { find(.next) }
                    .keyboardShortcut("g")
                Button("Find Previous") { find(.previous) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { find(.setFindString) }
                    .keyboardShortcut("e")
            }
        }
        CommandGroup(before: .toolbar) {
            Button("Command History") { WindowManager.shared.toggleHistory() }
                .keyboardShortcut("y")
            Button("Previous Command") { session?.terminalView.scrollToPreviousCommand() }
                .keyboardShortcut(.upArrow)
            Button("Next Command") { session?.terminalView.scrollToNextCommand() }
                .keyboardShortcut(.downArrow)
            Divider()
            Button("Bigger") { session?.zoomFont(by: 1) }
                .keyboardShortcut("=")
            Button("Smaller") { session?.zoomFont(by: -1) }
                .keyboardShortcut("-")
            Button("Default Size") { session?.zoomFont(by: nil) }
                .keyboardShortcut("0")
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { NSApp.keyWindow?.selectPreviousTab(nil) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Show Next Tab") { NSApp.keyWindow?.selectNextTab(nil) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
        }
    }

    /// The session of the frontmost terminal window.
    private var session: TerminalSession? {
        WindowManager.shared.keyController?.session
    }

    private func find(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
    }
}
