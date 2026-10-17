import AppKit
import SwiftTerm
import Testing
@testable import Tern

/// Native tab behaviour, driven through `WindowManager` and AppKit's own
/// tab actions (what ⌘T, the "+" button, "Move Tab to New Window" and ⌘W do).
@Suite(.serialized)
struct WindowTabsTests {
    @Test func tabsAreNativeWindowsWithIndependentShells() async throws {
        let manager = WindowManager.shared
        let initialCount = manager.controllers.count

        manager.newWindow()
        let first = try #require(manager.controllers.last)
        let firstWindow = try #require(first.window)
        manager.newTab(after: first)
        let second = try #require(manager.controllers.last)
        let secondWindow = try #require(second.window)
        defer {
            firstWindow.close()
            secondWindow.close()
        }

        #expect(manager.controllers.count == initialCount + 2)
        #expect(secondWindow.firstResponder === second.session.terminalView)
        #expect(firstWindow.tabbingIdentifier == TerminalWindowController.tabbingIdentifier)
        #expect(firstWindow.tabbedWindows?.contains(secondWindow) == true)

        // Each tab runs its own shell.
        #expect(await first.session.waitForPrompt())
        #expect(await second.session.waitForPrompt())
        let firstPID = try #require(first.session.processID)
        let secondPID = try #require(second.session.processID)
        #expect(firstPID != secondPID)

        // The window title shows the working directory, the tab its name.
        try #require(await second.session.run("cd /usr/bin") != nil)
        #expect(await eventually { secondWindow.title == "/usr/bin" })
        #expect(secondWindow.tab.title == "bin")
        #expect(secondWindow.subtitle.isEmpty)
        #expect(firstWindow.tab.title != "bin")

        // Detaching keeps the same window, controller and shell.
        secondWindow.moveTabToNewWindow(nil)
        #expect(await eventually { secondWindow.tabbedWindows == nil || secondWindow.tabbedWindows?.count == 1 })
        #expect(second.session.processID == secondPID)
        #expect(processIsAlive(secondPID))

        // The tab bar's "+" button sends newWindowForTab: up the window's responder chain.
        let countBeforePlus = manager.controllers.count
        #expect(firstWindow.tryToPerform(#selector(NSResponder.newWindowForTab(_:)), with: nil))
        let plusTab = try #require(manager.controllers.last)
        #expect(manager.controllers.count == countBeforePlus + 1)
        #expect(firstWindow.tabbedWindows?.contains { $0 === plusTab.window } == true)
        plusTab.window?.performClose(nil)

        // Closing a tab hangs up its shell and forgets the controller.
        secondWindow.performClose(nil)
        #expect(await eventually { !processIsAlive(secondPID) })
        #expect(!manager.controllers.contains { $0 === second })
        #expect(processIsAlive(firstPID))
    }

    @Test func terminalStartsBelowTransparentTitleBarAt80x25() throws {
        let manager = WindowManager.shared
        manager.newWindow()
        let controller = try #require(manager.controllers.last)
        let window = try #require(controller.window)
        defer { window.close() }
        window.layoutIfNeeded()

        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent)
        let view = controller.session.terminalView
        let frame = view.convert(view.bounds, to: nil)
        #expect(frame.maxY <= window.contentLayoutRect.maxY)
        #expect(view.getTerminal().cols == 80)
        #expect(view.getTerminal().rows == 25)
    }

    @Test func closingATabWithARunningProgramAsksFirst() async throws {
        let manager = WindowManager.shared
        manager.newWindow()
        let controller = try #require(manager.controllers.last)
        let window = try #require(controller.window)
        defer { window.close() }
        let session = controller.session
        #expect(await session.waitForPrompt())
        #expect(session.runningProgram == nil)
        #expect(controller.windowShouldClose(window))

        session.type("sleep 30\r")
        #expect(await eventually { session.runningProgram == "sleep 30" })

        // Cancel keeps the tab and the program.
        #expect(!controller.windowShouldClose(window))
        var sheet = try #require(await eventually { window.attachedSheet != nil } ? window.attachedSheet : nil)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        #expect(window.isVisible)
        #expect(session.runningProgram == "sleep 30")

        // Close closes it and hangs up the shell.
        let pid = try #require(session.processID)
        #expect(!controller.windowShouldClose(window))
        sheet = try #require(await eventually { window.attachedSheet != nil } ? window.attachedSheet : nil)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(await eventually { !window.isVisible && !processIsAlive(pid) })
        #expect(!manager.controllers.contains { $0 === controller })
    }

    @Test func windowsAndTabsAreRestored() async throws {
        let manager = WindowManager.shared
        manager.newWindow()
        let first = try #require(manager.controllers.last)
        manager.newTab(after: first)
        let second = try #require(manager.controllers.last)
        manager.newWindow()
        let other = try #require(manager.controllers.last)
        let windows = [first, second, other].compactMap(\.window)
        for (controller, directory) in zip([first, second, other], ["/usr/share", "/usr/lib", "/usr/bin"]) {
            #expect(await controller.session.waitForPrompt())
            try #require(await controller.session.run("cd \(directory)") != nil)
        }

        let saved = manager.savedWindows(of: [first.window!, other.window!])
        #expect(saved.map(\.directories) == [["/usr/share", "/usr/lib"], ["/usr/bin"]])
        #expect(saved[0].selectedTab == 1)
        windows.forEach { $0.close() }

        let restored = manager.restore(saved)
        defer { restored.joined().forEach { $0.window?.close() } }
        #expect(restored.map { $0.map(\.session.currentDirectory.path) } == saved.map(\.directories))
        let restoredFirst = try #require(restored.first?.first?.window)
        #expect(restoredFirst.tabbedWindows?.count == 2)
        #expect(restoredFirst.tabGroup?.selectedWindow === restored[0][1].window)
        #expect(restoredFirst.frame == saved[0].frame)
        #expect(restored[1].first?.window?.tabbedWindows == nil)
    }

    @Test func newTabStartsInCurrentDirectory() async throws {
        let manager = WindowManager.shared
        manager.newWindow()
        let first = try #require(manager.controllers.last)
        defer { first.window?.close() }
        #expect(await first.session.waitForPrompt())
        try #require(await first.session.run("cd /usr/share") != nil)

        manager.newTab(after: first)
        let second = try #require(manager.controllers.last)
        defer { second.window?.close() }
        #expect(second.session.currentDirectory.path == "/usr/share")
        #expect(await second.session.waitForPrompt())
        try #require(await second.session.run("pwd") != nil)
        #expect(second.session.screenText.contains("/usr/share"))
    }
}
