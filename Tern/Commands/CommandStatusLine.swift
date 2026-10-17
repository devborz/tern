import Foundation

/// The status line Tern adds after a command finishes:
///
///     ✓ 0 · 84 ms ⧉
///
/// A terminal draws every row in one font, so the line written into the
/// terminal is only a placeholder: blank cells carrying a hyperlink to the
/// command (`link`). The terminal view finds these cells and draws the status
/// over them in a smaller font, with a copy button when the command printed
/// something. The cells move with the text through scrolling, reflow and
/// trimming; ⌘-click on them copies the output too.
///
/// It is fed to the emulator locally (the shell never sees it), between the
/// command's output and the next prompt.
nonisolated enum CommandStatusLine {
    enum Outcome: Equatable {
        case succeeded, failed, unknown
    }

    /// Commands whose whole point is a clean screen.
    private static let screenClearingCommands: Set<String> = ["clear", "reset"]

    /// Cells after the status text, under the copy button.
    static let copyButtonColumns = 2

    static func shouldShow(for execution: CommandExecution) -> Bool {
        !screenClearingCommands.contains(execution.programName)
    }

    /// `✓ 0` and `84 ms`: the two parts of the status, shown in different colors.
    static func label(for execution: CommandExecution) -> (status: String, duration: String, outcome: Outcome) {
        let duration = execution.duration.map(format(duration:)) ?? "–"
        switch execution.exitCode {
        case 0?: return ("✓ 0", duration, .succeeded)
        case let code?: return ("✕ \(code)", duration, .failed)
        case nil: return ("? –", duration, .unknown)
        }
    }

    /// - Parameters:
    ///   - startOnNewLine: Pass `true` when the cursor is not at column 0
    ///     (the output did not end with a newline).
    ///   - hasOutput: The command printed something, so the line gets a copy button.
    static func render(_ execution: CommandExecution, startOnNewLine: Bool, hasOutput: Bool) -> String {
        let label = label(for: execution)
        // Roughly the width of what is drawn over it, so that ⌘-hover
        // underlines about the right stretch.
        let width = "\(label.status) · \(label.duration)".count + (hasOutput ? 1 + copyButtonColumns : 0)
        let cells = String(repeating: " ", count: width)
        let linked = "\u{1B}]8;;\(link(for: execution.id, hasOutput: hasOutput))\u{1B}\\\(cells)\u{1B}]8;;\u{1B}\\"
        return (startOnNewLine ? "\r\n" : "") + linked + "\r\n"
    }

    /// `tern://command/<id>`, with `?output` when the command printed something.
    static func link(for commandID: UUID, hasOutput: Bool) -> String {
        "tern://command/\(commandID.uuidString)" + (hasOutput ? "?output" : "")
    }

    /// The command a status line's `link` points to. Accepts SwiftTerm's
    /// stored hyperlink payload (`<params>;<link>`) as well as the bare link.
    static func command(fromLink link: String) -> (id: UUID, hasOutput: Bool)? {
        let url = link.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""
        guard url.hasPrefix("tern://command/") else { return nil }
        let rest = url.dropFirst("tern://command/".count)
        let hasOutput = rest.hasSuffix("?output")
        guard let id = UUID(uuidString: String(hasOutput ? rest.dropLast("?output".count) : rest)) else { return nil }
        return (id, hasOutput)
    }

    /// `84 ms`, `3.8 s`, `2m 05s`, `1h 02m`.
    static func format(duration: TimeInterval) -> String {
        // Each unit is chosen after rounding, so 999.6 ms reads "1.0 s", not "1000 ms".
        let milliseconds = Int((duration * 1000).rounded())
        if milliseconds < 1000 {
            return "\(max(0, milliseconds)) ms"
        }
        let tenths = Int((duration * 10).rounded())
        if tenths < 600 {
            return String(format: "%.1f s", Double(tenths) / 10)
        }
        let seconds = Int(duration.rounded())
        if seconds < 3600 {
            return String(format: "%dm %02ds", seconds / 60, seconds % 60)
        }
        let minutes = seconds / 60
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
