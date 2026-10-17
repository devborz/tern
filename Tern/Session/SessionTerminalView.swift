import AppKit
import SwiftTerm

/// SwiftTerm's terminal view (emulator + renderer) with the small additions
/// Tern needs. Owned by `TerminalSession`, hosted by `TerminalHostView`.
final class SessionTerminalView: TerminalView {
    /// The size to report to the PTY.
    var windowSize: PTYProcess.WindowSize {
        let terminal = getTerminal()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let cells = getOptimalFrameSize().size
        return PTYProcess.WindowSize(
            columns: terminal.cols,
            rows: terminal.rows,
            pixelWidth: Int(cells.width * scale),
            pixelHeight: Int(cells.height * scale)
        )
    }

    /// Status views laid over the status lines on screen; see
    /// `SessionTerminalView+Commands.swift`.
    var statusViews: [CommandStatusView] = []
    var isStatusLayoutPending = false
    /// Finds the command a status line belongs to.
    var commandLookup: ((UUID) -> CommandExecution?)?
    /// Status text size relative to the terminal font, in points.
    var statusFontSizeOffset: CGFloat = TerminalSettings.defaultStatusFontSizeOffset {
        didSet { layoutStatusViews() }
    }

    /// Leaves cells with the default background unpainted, so the window's
    /// translucent background shows through. Explicit background colors and
    /// reverse video stay opaque.
    var isBackgroundTransparent = false {
        didSet { applyAppearanceColors() }
    }

    /// Follows the light/dark appearance with the system text colors and the
    /// matching ANSI palette. SwiftTerm resolves colors when they are set, so
    /// they are re-applied on every appearance change.
    func applyAppearanceColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        installColors(isDark ? TerminalPalette.dark : TerminalPalette.light)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
            // Also makes SwiftTerm drop its cached colors and redraw.
            backgroundOpacity = isBackgroundTransparent ? 0 : 1
            caretColor = NSColor.textColor.withAlphaComponent(0.7)
            selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // SwiftTerm has resized and reflowed the grid by now; moving the status
        // views in the same pass keeps them on their lines during a live
        // resize instead of trailing a frame behind.
        layoutStatusViews()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceColors()
    }

    // MARK: - Line-editing shortcuts

    /// macOS text-editing shortcuts (⌘⌫, ⌥←, …), sent as the keys the shell's
    /// line editor (zle, readline) understands, like iTerm2's "Natural Text
    /// Editing" and Ghostty. SwiftTerm's `keyDown` cannot be overridden, so an
    /// app-wide monitor offers every key press to the focused terminal first.
    static func installLineEditingShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                (event.window?.firstResponder as? SessionTerminalView)?.sendLineEditingKey(for: event) ?? false
            }
            return handled ? nil : event
        }
    }

    /// Sends `event` as a line-editing key if it is one; returns whether it
    /// did. Programs that turned on the kitty keyboard protocol get the real
    /// keys instead, and so does an input method that is composing text.
    func sendLineEditingKey(for event: NSEvent) -> Bool {
        guard getTerminal().keyboardEnhancementFlags.isEmpty, !hasMarkedText(),
              let bytes = Self.lineEditingBytes(for: event)
        else { return false }
        send(bytes)
        return true
    }

    static func lineEditingBytes(for event: NSEvent) -> [UInt8]? {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) else {
            return nil
        }
        // Arrow and delete keys also carry .function/.numericPad; ignore those.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (modifiers, key) {
        case ([.command], 0x7F): return [0x15]                          // ⌘⌫  ^U: erase the line
        case ([.command], NSDeleteFunctionKey): return [0x0B]           // ⌘⌦  ^K: erase to end of line
        case ([.command], NSLeftArrowFunctionKey): return [0x01]        // ⌘←  ^A: start of line
        case ([.command], NSRightArrowFunctionKey): return [0x05]       // ⌘→  ^E: end of line
        case ([.option], 0x7F): return [0x1B, 0x7F]                     // ⌥⌫  erase word before
        case ([.option], NSDeleteFunctionKey): return [0x1B, 0x64]      // ⌥⌦  ESC d: erase word after
        case ([.option], NSLeftArrowFunctionKey): return [0x1B, 0x62]   // ⌥←  ESC b: word back
        case ([.option], NSRightArrowFunctionKey): return [0x1B, 0x66]  // ⌥→  ESC f: word forward
        default: return nil
        }
    }
}
