import AppKit
import SwiftTerm
import SwiftUI

/// The standard Settings window (⌘,). Values are written straight to
/// `UserDefaults`; open terminals pick them up immediately.
struct SettingsView: View {
    private typealias Key = TerminalSettings.Key

    @AppStorage(Key.fontName) private var fontName = ""
    @AppStorage(Key.fontSize) private var fontSize = TerminalSettings.defaultFontSize
    @AppStorage(Key.fontWeight) private var fontWeight = TerminalSettings.FontWeight.regular
    @AppStorage(Key.statusFontSizeOffset) private var statusFontSizeOffset = TerminalSettings.defaultStatusFontSizeOffset
    @AppStorage(Key.cursorStyle) private var cursorStyle = CursorStyle.blinkBlock.tagName
    @AppStorage(Key.shellPath) private var shellPath = ShellLaunch.defaultShell
    @AppStorage(Key.commandSuggestions) private var commandSuggestions = true
    @AppStorage(Key.notifyLongCommands) private var notifyLongCommands = true
    @AppStorage(Key.optionAsMeta) private var optionAsMeta = true
    @AppStorage(Key.scrollbackLines) private var scrollbackLines = TerminalSettings.defaultScrollbackLines
    @AppStorage(Key.appearance) private var appearance = TerminalSettings.Appearance.system
    @AppStorage(Key.backgroundTranslucency) private var backgroundTranslucency = 0.0

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $fontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(FontChoice.monospaced) { choice in
                        Text(choice.familyName).tag(choice.postScriptName)
                    }
                }
                Picker("Weight", selection: $fontWeight) {
                    ForEach(TerminalSettings.FontWeight.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                StepperRow("Size", value: $fontSize, in: TerminalSettings.fontSizeRange, step: 1, text: "\(Int(fontSize)) pt")
                StepperRow(
                    "Status line size",
                    value: $statusFontSizeOffset,
                    in: TerminalSettings.statusFontSizeOffsetRange,
                    step: 1,
                    text: statusSizeDescription
                )
                Picker("Cursor", selection: $cursorStyle) {
                    ForEach(CursorStyle.allCases, id: \.tagName) { style in
                        Text(style.displayName).tag(style.tagName)
                    }
                }
            }

            Section {
                Toggle("Use Option as Meta key", isOn: $optionAsMeta)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Turn off to type characters your keyboard layout puts on Option.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Shell") {
                    ShellPathField(text: $shellPath)
                }
                Toggle("Command suggestions", isOn: $commandSuggestions)
                Toggle("Notify when long commands finish", isOn: $notifyLongCommands)
                StepperRow(
                    "Scrollback",
                    value: $scrollbackLines,
                    in: TerminalSettings.scrollbackRange,
                    step: 1000,
                    text: "\(scrollbackLines.formatted()) lines"
                )
            } header: {
                Text("Shell")
            } footer: {
                Text(shellFooter)
                    .foregroundStyle(isShellValid ? Color.secondary : Color.red)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(TerminalSettings.Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Background translucency") {
                    Slider(value: $backgroundTranslucency, in: TerminalSettings.backgroundTranslucencyRange)
                }
            }
        }
        .formStyle(.grouped)
        .background(EndsEditingOnClickOutside())
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusSizeDescription: String {
        let points = Int(statusFontSizeOffset)
        return switch points {
        case 0: "Same as text"
        case ..<0: "\(-points) pt smaller"
        default: "\(points) pt larger"
        }
    }

    /// An empty field means the default shell.
    private var effectiveShellPath: String {
        shellPath.isEmpty ? ShellLaunch.defaultShell : shellPath
    }

    private var isShellValid: Bool {
        FileManager.default.isExecutableFile(atPath: effectiveShellPath)
    }

    private var shellFooter: String {
        if !isShellValid {
            return "Not an executable file; new sessions use \(ShellLaunch.defaultShell)."
        }
        if URL(fileURLWithPath: effectiveShellPath).lastPathComponent != "zsh" {
            return "Command tracking and suggestions are only available with zsh. Applies to new tabs and windows."
        }
        return "Started as a login shell. Applies to new tabs and windows."
    }
}

/// The shell path field. An AppKit text field that takes focus only from a
/// click on it or Tab: SwiftUI's TextField was focused as soon as the
/// Settings window opened, so stray typing ended up in the path. Return and
/// Esc finish editing.
private struct ShellPathField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> ClickToEditTextField {
        let field = ClickToEditTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .right
        field.placeholderString = ShellLaunch.defaultShell
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: ClickToEditTextField, context: Context) {
        context.coordinator.text = $text
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:))
            else { return false }
            // Once the field editor is done with this key: ending editing in
            // the middle of it leaves the field unable to take a click again.
            DispatchQueue.main.async { [weak control] in
                control?.window?.makeFirstResponder(nil)
            }
            // Return still goes through the field's own handling, which
            // commits the text; Esc has nothing to commit.
            return selector == #selector(NSResponder.cancelOperation(_:))
        }
    }
}

/// A text field that refuses focus unless the user clicked it or tabbed to it.
final class ClickToEditTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        // `makeFirstResponder` asks this directly (not `acceptsFirstResponder`),
        // whoever calls it: AppKit when the window opens, SwiftUI, a click.
        isUserFocusing(NSApp.currentEvent) && super.becomeFirstResponder()
    }

    /// A click on this field, or Tab in its window.
    func isUserFocusing(_ event: NSEvent?) -> Bool {
        guard let event, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown: return bounds.contains(convert(event.locationInWindow, from: nil))
        case .keyDown: return event.keyCode == 48 // Tab
        default: return false
        }
    }
}

/// Ends text editing in its window when the user clicks anywhere but the
/// field being edited. AppKit otherwise leaves a field focused until another
/// view takes focus, and nothing else in Settings ever does.
private struct EndsEditingOnClickOutside: NSViewRepresentable {
    func makeNSView(context: Context) -> ClickOutsideView {
        ClickOutsideView()
    }

    func updateNSView(_ view: ClickOutsideView, context: Context) {}

    final class ClickOutsideView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.endEditing(clickedAt: event) }
                return event
            }
        }

        func endEditing(clickedAt event: NSEvent) {
            guard let window, event.window === window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let content = window.contentView
            else { return }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            if let hit = content.hitTest(point), let field = editor.delegate as? NSView,
               hit === editor || hit === field || hit.isDescendant(of: field) {
                return
            }
            window.makeFirstResponder(nil)
        }

        /// Never in the way of clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A setting changed with a stepper: the title on the left, the value and
/// the stepper on the right, lined up with the pickers.
private struct StepperRow<Value: Strideable>: View {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let text: String

    init(_ title: String, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride, text: String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.text = text
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}

/// An installed fixed-pitch font family.
private struct FontChoice: Identifiable {
    let familyName: String
    let postScriptName: String

    var id: String { postScriptName }

    static let monospaced: [FontChoice] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.compactMap { family in
            // Each member is [PostScript name, face name, weight, traits].
            guard let members = manager.availableMembers(ofFontFamily: family) else { return nil }
            let regular = members.first { ($0[1] as? String) == "Regular" } ?? members.first
            guard let name = regular?[0] as? String,
                  let font = NSFont(name: name, size: 12), font.isFixedPitch,
                  !family.hasPrefix(".")
            else { return nil }
            return FontChoice(familyName: family, postScriptName: name)
        }
    }()
}
