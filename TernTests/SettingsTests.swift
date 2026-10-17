import AppKit
import SwiftTerm
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized)
struct SettingsTests {
    @Test func changesApplyToOpenTerminals() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            TerminalSettings.Key.fontSize, TerminalSettings.Key.fontWeight, TerminalSettings.Key.cursorStyle,
            TerminalSettings.Key.scrollbackLines, TerminalSettings.Key.backgroundTranslucency, TerminalSettings.Key.optionAsMeta,
            TerminalSettings.Key.statusFontSizeOffset,
        ]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                defaults.set(value, forKey: key)
            }
        }

        let manager = WindowManager.shared
        manager.newWindow()
        let controller = try #require(manager.controllers.last)
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        let view = controller.session.terminalView

        defaults.set(21.0, forKey: TerminalSettings.Key.fontSize)
        defaults.set(TerminalSettings.FontWeight.medium.rawValue, forKey: TerminalSettings.Key.fontWeight)
        defaults.set(CursorStyle.steadyBar.tagName, forKey: TerminalSettings.Key.cursorStyle)
        defaults.set(2_000, forKey: TerminalSettings.Key.scrollbackLines)
        defaults.set(0.4, forKey: TerminalSettings.Key.backgroundTranslucency)
        defaults.set(false, forKey: TerminalSettings.Key.optionAsMeta)
        defaults.set(-4.0, forKey: TerminalSettings.Key.statusFontSizeOffset)

        #expect(await eventually(timeout: .seconds(3)) { view.font.pointSize == 21 })
        #expect(NSFontManager.shared.weight(of: view.font) == TerminalSettings.FontWeight.medium.fontManagerWeight)
        #expect(view.getTerminal().options.cursorStyle == .steadyBar)
        #expect(view.getTerminal().options.scrollback == 2_000)
        #expect(!window.isOpaque)
        #expect(view.backgroundOpacity == 0)
        #expect(controller.state.backgroundTranslucency == 0.4)
        #expect(!view.optionAsMetaKey)
        #expect(view.statusFontSizeOffset == -4)

        defaults.set(0.0, forKey: TerminalSettings.Key.backgroundTranslucency)
        #expect(await eventually(timeout: .seconds(3)) { window.isOpaque })
        #expect(view.backgroundOpacity == 1)
    }

    @Test func fontWeightPicksClosestFaceOfFamily() {
        var settings = TerminalSettings()
        settings.fontWeight = .semibold
        #expect(NSFontManager.shared.weight(of: settings.font) == 8)

        // Menlo only has Regular and Bold.
        settings.fontName = "Menlo-Regular"
        settings.fontWeight = .medium
        #expect(settings.font.fontName == "Menlo-Regular")
        settings.fontWeight = .bold
        #expect(settings.font.fontName == "Menlo-Bold")
    }

    @Test func shellFieldIsFocusedOnlyByTheUser() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 460, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        defer { window.close() }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        func editableFields(in view: NSView) -> [ClickToEditTextField] {
            view.subviews.flatMap { subview in
                ((subview as? ClickToEditTextField).map { [$0] } ?? []) + editableFields(in: subview)
            }
        }
        var isEditing: Bool { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!
        }
        /// Delivers a click the way the run loop does, so it becomes
        /// `NSApp.currentEvent`, then lets AppKit settle as between real clicks.
        func click(at point: NSPoint) async throws {
            NSApp.postEvent(mouse(.leftMouseDown, at: point), atStart: true)
            // After the press, for a text field's mouse tracking loop.
            NSApp.postEvent(mouse(.leftMouseUp, at: point), atStart: false)
            if let event = NSApp.nextEvent(matching: .leftMouseDown, until: .now + 1, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true)
            try await Task.sleep(for: .milliseconds(50))
        }

        let field = try #require(editableFields(in: window.contentView!).first)
        let fieldCenter = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let header = NSPoint(x: 120, y: window.contentView!.bounds.height - 40)

        // Only a click on the field or Tab focuses it; not the window opening
        // or the ⌘, that opened it.
        #expect(field.isUserFocusing(mouse(.leftMouseDown, at: fieldCenter)))
        #expect(field.isUserFocusing(key(48, "\t")))
        #expect(!field.isUserFocusing(mouse(.leftMouseDown, at: header)))
        #expect(!field.isUserFocusing(key(43, ",", .command)))
        #expect(!field.isUserFocusing(nil))
        // Focusing it in code, as AppKit does when the window opens, does not start editing.
        window.makeFirstResponder(field)
        #expect(!isEditing)

        try await click(at: fieldCenter)
        #expect(isEditing, "a click in the field starts editing")
        try await click(at: fieldCenter)
        #expect(isEditing, "and another click there keeps it")
        try await click(at: header)
        #expect(!isEditing, "a click elsewhere ends editing")

        // What Return and Esc do in the field editor, and a click edits again after each.
        // (This test window never becomes key, and AppKit takes every other click on
        // the field as the one that would activate it; a click elsewhere first keeps
        // that from depending on the order of the steps.)
        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            try await click(at: header)
            try await click(at: fieldCenter)
            #expect(isEditing)
            (window.firstResponder as? NSTextView)?.doCommand(by: command)
            #expect(await eventually(timeout: .seconds(1)) { !isEditing }, "\(command) ends editing")
        }
        try await click(at: header)
        try await click(at: fieldCenter)
        #expect(isEditing, "and a click edits again")
    }

    @Test func invalidValuesFallBackToDefaults() {
        var settings = TerminalSettings()
        settings.shellPath = "/no/such/shell"
        #expect(settings.resolvedShellPath == ShellLaunch.defaultShell)
        settings.fontName = "No Such Font"
        #expect(settings.font.isFixedPitch)
    }
}
