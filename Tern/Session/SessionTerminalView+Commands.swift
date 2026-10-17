import AppKit
import SwiftTerm

/// Commands in the scrollback: jumping between their prompts and copying
/// their output.
///
/// Everything here reads what SwiftTerm recorded from the shell's OSC 133
/// marks — prompt rows and the prompt/input/output role of every cell — so
/// it follows the text through scrolling, reflow and trimming. Rows are
/// buffer rows (scrollback included), the coordinates `scrollTo(row:)` uses.
extension SessionTerminalView {
    // MARK: - Prompt navigation

    /// ⌘↑: scrolls the closest prompt above the screen to the top.
    func scrollToPreviousCommand() {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let top = terminal.buffer.yDisp
        guard let row = stride(from: top - 1, through: 0, by: -1).first(where: isPromptRow) else {
            NSSound.beep()
            return
        }
        scrollTo(row: row)
    }

    /// ⌘↓: scrolls the next prompt below the top of the screen to the top,
    /// or to the bottom when it is already on the last screen.
    func scrollToNextCommand() {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let rowCount = bufferRowCount
        let bottom = max(0, rowCount - terminal.rows)
        let next = (terminal.buffer.yDisp + 1 ..< rowCount).first(where: isPromptRow)
        scrollTo(row: min(next ?? bottom, bottom))
    }

    private func isPromptRow(_ row: Int) -> Bool {
        getTerminal().semanticRowKind(at: row) == .initial
    }

    /// Rows in the current buffer: the scrollback plus the screen.
    var bufferRowCount: Int {
        let terminal = getTerminal()
        // At least the rows up to the bottom of what is shown; more when
        // scrolled back.
        var count = terminal.buffer.yDisp + terminal.rows
        while terminal.bufferLine(atRow: count) != nil {
            count += 1
        }
        return count
    }

    // MARK: - Command output

    /// Whether the command that just finished printed anything, judged from
    /// the cursor back to its command line. Called when the shell reports
    /// the end of a command, before the status line is written.
    func commandPrintedOutput() -> Bool {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return false }
        let cursor = terminal.getCursorLocation()
        var row = bufferRowCount - terminal.rows + cursor.y
        if cursor.x == 0 {
            row -= 1
        }
        while row >= 0, !rowHasPromptOrInput(row) {
            if !rowText(row).isEmpty {
                return true
            }
            row -= 1
        }
        return false
    }

    /// The output of a command whose status line is still in the buffer:
    /// the rows between its command line and its status line, as plain text
    /// with soft-wrapped rows joined. `nil` when it printed nothing.
    func commandOutput(of commandID: UUID) -> String? {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate, let statusRow = statusRow(of: commandID) else { return nil }
        var firstRow = statusRow
        while firstRow > 0, !rowHasPromptOrInput(firstRow - 1) {
            firstRow -= 1
        }

        var lines: [String] = []
        var joinsNext = false
        for row in firstRow ..< statusRow {
            var text = rowText(row)
            if row == statusRow - 1, endsWithPromptSPMark(row) {
                // zsh marks output without a final newline with an inverse
                // "%" (PROMPT_SP); it is not part of the output.
                text.removeLast()
            }
            if joinsNext, let previous = lines.popLast() {
                text = previous + text
            }
            lines.append(text)
            joinsNext = row + 1 < statusRow && terminal.bufferLine(atRow: row + 1)?.isWrapped == true
        }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Copies a command's output to the clipboard; `false` when there is
    /// none, or it is no longer in the buffer.
    @discardableResult
    func copyCommandOutput(of commandID: UUID) -> Bool {
        guard let output = commandOutput(of: commandID) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        return true
    }

    /// The buffer row where a command's status line starts.
    func statusRow(of commandID: UUID) -> Int? {
        guard var row = stride(from: bufferRowCount - 1, through: 0, by: -1)
            .first(where: { rowLinks(to: commandID, row: $0) })
        else { return nil }
        // In a very narrow window the status line itself may wrap.
        while row > 0, rowLinks(to: commandID, row: row - 1) {
            row -= 1
        }
        return row
    }

    private func rowHasPromptOrInput(_ row: Int) -> Bool {
        let terminal = getTerminal()
        return (0 ..< terminal.cols).contains { col in
            switch terminal.semanticContent(at: Position(col: col, row: row)) {
            case .prompt?, .input?: true
            default: false
            }
        }
    }

    private func rowText(_ row: Int) -> String {
        let terminal = getTerminal()
        guard let line = terminal.bufferLine(atRow: row) else { return "" }
        let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) {
            terminal.getCharacter(for: $0)
        }
        return String(text.reversed().drop { $0 == " " }.reversed())
    }

    private func endsWithPromptSPMark(_ row: Int) -> Bool {
        let terminal = getTerminal()
        guard let line = terminal.bufferLine(atRow: row),
              let last = (0 ..< line.count).last(where: { !" \0".contains(terminal.getCharacter(for: line[$0])) })
        else { return false }
        return terminal.getCharacter(for: line[last]) == "%" && line[last].attribute.style.contains(.inverse)
    }

    /// The status line a cell belongs to, from the hyperlink on it.
    private func linkedCommand(_ cell: CharData) -> (id: UUID, hasOutput: Bool)? {
        guard cell.hasPayload, let payload = cell.getPayload() as? String else { return nil }
        return CommandStatusLine.command(fromLink: payload)
    }

    /// The first column in a buffer row that is part of a status line.
    private func firstLinkedColumn(inRow row: Int) -> Int? {
        guard let line = getTerminal().bufferLine(atRow: row) else { return nil }
        return (0 ..< line.count).first { linkedCommand(line[$0]) != nil }
    }

    private func rowLinks(to commandID: UUID, row: Int) -> Bool {
        guard let line = getTerminal().bufferLine(atRow: row) else { return false }
        return (0 ..< line.count).contains { linkedCommand(line[$0])?.id == commandID }
    }

    // MARK: - Status views

    /// Schedules placing the status views over the status lines on screen;
    /// called whenever the screen content or scroll position changes.
    func setNeedsStatusLayout() {
        guard !isStatusLayoutPending else { return }
        isStatusLayoutPending = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutStatusViews()
        }
    }

    func layoutStatusViews() {
        isStatusLayoutPending = false
        let terminal = getTerminal()
        // Each status line on screen, by the row and column it starts at.
        var spots: [(execution: CommandExecution, hasOutput: Bool, row: Int, col: Int)] = []
        if !terminal.isCurrentBufferAlternate {
            let top = terminal.buffer.yDisp
            for screenRow in 0 ..< terminal.rows {
                guard let col = firstLinkedColumn(inRow: top + screenRow),
                      let line = terminal.bufferLine(atRow: top + screenRow),
                      let command = linkedCommand(line[col]),
                      !spots.contains(where: { $0.execution.id == command.id }),
                      let execution = commandLookup?(command.id)
                else { continue }
                spots.append((execution, command.hasOutput, screenRow, col))
            }
        }

        while statusViews.count < spots.count {
            let view = CommandStatusView()
            // Rows are drawn from the top; keep the views fixed to the top too.
            view.autoresizingMask = [.minYMargin]
            view.copyButton.onCopy = { [weak self] id in self?.copyCommandOutput(of: id) ?? false }
            addSubview(view)
            statusViews.append(view)
        }
        let cell = cellSize
        let statusFont = NSFont(descriptor: font.fontDescriptor, size: max(7, font.pointSize + statusFontSizeOffset)) ?? font
        for (index, view) in statusViews.enumerated() {
            guard index < spots.count else {
                view.isHidden = true
                continue
            }
            let spot = spots[index]
            view.show(spot.execution, hasOutput: spot.hasOutput, font: statusFont, rowHeight: cell.height)
            // The view is not flipped: row 0 is at the top.
            view.setFrameOrigin(NSPoint(
                x: CGFloat(spot.col) * cell.width,
                y: bounds.height - CGFloat(spot.row + 1) * cell.height
            ))
            view.isHidden = false
        }
    }

    /// The size of one character cell, computed the way SwiftTerm does.
    private var cellSize: CGSize {
        let terminal = getTerminal()
        let height = getOptimalFrameSize().height / CGFloat(max(1, terminal.rows))
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = font.advancement(forGlyph: font.glyph(withName: "W")).width
        return CGSize(width: max(1, (width * scale).rounded() / scale), height: height)
    }
}
