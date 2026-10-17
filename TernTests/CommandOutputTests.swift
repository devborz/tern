import AppKit
import SwiftTerm
import Testing
@testable import Tern

/// Commands in the scrollback of a real zsh: their output, the status views
/// over their status lines, jumping between prompts, clearing, font zoom.
@Suite(.serialized)
struct CommandOutputTests {
    private func makeSession() async throws -> TerminalSession {
        let session = TerminalSession(workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        try #require(await session.waitForPrompt())
        return session
    }

    /// Whether a screen row has cells of the status line of `commandID`.
    private func row(_ row: Int, of view: SessionTerminalView, linksTo commandID: UUID?) -> Bool {
        guard let commandID, let line = view.getTerminal().getLine(row: row) else { return false }
        return (0 ..< line.count).contains { col in
            (line[col].getPayload() as? String).flatMap(CommandStatusLine.command(fromLink:))?.id == commandID
        }
    }

    private func screenLine(_ view: SessionTerminalView, row: Int) -> String {
        let terminal = view.getTerminal()
        let text = terminal.getLine(row: row)?.translateToString(trimRight: true) { terminal.getCharacter(for: $0) } ?? ""
        return String(text.reversed().drop { $0 == " " }.reversed())
    }

    @Test func outputIsReadFromTheScrollback() async throws {
        let session = try await makeSession()
        defer { session.terminate() }
        let view = session.terminalView

        let lines = try #require(await session.run("printf 'one\\ntwo\\n'"))
        #expect(view.commandOutput(of: lines.id) == "one\ntwo")

        // zsh's "%" for a missing final newline is not output.
        let partial = try #require(await session.run("printf 'no newline'"))
        #expect(view.commandOutput(of: partial.id) == "no newline")

        // Soft-wrapped rows are one line.
        let wide = try #require(await session.run("printf '%0200d\\n' 0"))
        #expect(view.commandOutput(of: wide.id) == String(repeating: "0", count: 200))

        // Nothing printed: no copy button, nothing to copy.
        let quiet = try #require(await session.run("cd ."))
        #expect(view.commandOutput(of: quiet.id) == nil)
    }

    @Test func statusViewsSitOnStatusLines() async throws {
        let session = try await makeSession()
        defer { session.terminate() }
        let view = session.terminalView

        let first = try #require(await session.run("echo first"))
        let failed = try #require(await session.run("ls /definitely/not/here"))
        let quiet = try #require(await session.run("true"))

        // They appear as soon as the screen updates, without a resize.
        var visible: [CommandStatusView] { view.statusViews.filter { !$0.isHidden } }
        #expect(await eventually { visible.compactMap(\.commandID) == [first.id, failed.id, quiet.id] })
        let rowHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
        for status in visible {
            // At the start of its own status line, right under the output.
            let row = Int((view.bounds.height - status.frame.midY) / rowHeight)
            #expect(self.row(row, of: view, linksTo: status.commandID))
            #expect(status.frame.minX == 0)
            #expect(status.frame.height == rowHeight)
        }
        // Only commands that printed something can be copied.
        #expect(visible.map(\.copyButton.isHidden) == [false, false, true])

        // The status text follows the terminal font, a little smaller (by the
        // user's setting), shown whole, with the copy button right after it.
        let status = try #require(visible.first)
        let statusFont = try #require(status.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(TerminalSettings().statusFontSizeOffset < 0)
        #expect(Double(statusFont.pointSize) == Double(max(7, view.font.pointSize + view.statusFontSizeOffset)))
        #expect(status.text.string == "✓ 0 · " + CommandStatusLine.format(duration: first.duration!))
        let textWidth = status.text.size().width
        #expect(status.copyButton.frame.minX >= textWidth)
        #expect(status.copyButton.frame.minX - textWidth < statusFont.pointSize / 2)

        // Scrolled out of sight, they go away.
        let numbers = try #require(await session.run("seq 1 100"))
        #expect(await eventually { visible.compactMap(\.commandID) == [numbers.id] })
    }

    @Test func statusViewsFollowTheirLinesWhileResizing() async throws {
        let session = try await makeSession()
        defer { session.terminate() }
        let view = session.terminalView
        let original = view.frame.size

        try #require(await session.run("echo one") != nil)
        try #require(await session.run("echo two") != nil)
        view.layoutStatusViews()

        // Checked right after each size change, without letting the run
        // loop catch up: that lag made the buttons jitter in a live resize.
        let rowHeight = view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)
        for size in [
            NSSize(width: original.width, height: original.height + 37),
            NSSize(width: original.width, height: original.height - 53),
            NSSize(width: original.width * 0.6, height: original.height),
            NSSize(width: original.width * 1.3, height: original.height + 11),
            original,
        ] {
            view.setFrameSize(size)
            let visible = view.statusViews.filter { !$0.isHidden }
            #expect(!visible.isEmpty)
            for status in visible {
                let row = Int((view.bounds.height - status.frame.midY) / rowHeight)
                #expect(self.row(row, of: view, linksTo: status.commandID), "\(size): row \(row) is \"\(screenLine(view, row: row))\"")
            }
        }
    }

    @Test func jumpsBetweenCommandPrompts() async throws {
        let session = try await makeSession()
        defer { session.terminate() }
        let view = session.terminalView
        let terminal = view.getTerminal()

        try #require(await session.run("seq 1 60") != nil)
        try #require(await session.run("seq 1 60") != nil)
        let bottom = terminal.buffer.yDisp

        view.scrollToPreviousCommand()
        let previous = terminal.buffer.yDisp
        #expect(previous < bottom)
        #expect(terminal.semanticRowKind(at: previous) == .initial)
        #expect(screenLine(view, row: 0).hasSuffix("seq 1 60"))

        view.scrollToPreviousCommand()
        #expect(terminal.buffer.yDisp < previous)
        view.scrollToNextCommand()
        #expect(terminal.buffer.yDisp == previous)
        view.scrollToNextCommand()
        #expect(terminal.buffer.yDisp == bottom)
    }

    @Test func clearBufferKeepsAWorkingPrompt() async throws {
        let session = try await makeSession()
        defer { session.terminate() }
        let view = session.terminalView
        let terminal = view.getTerminal()

        try #require(await session.run("seq 1 100; echo marker-to-clear") != nil)
        #expect(view.bufferRowCount > terminal.rows)
        session.clearBuffer()
        #expect(await eventually { view.bufferRowCount == terminal.rows && !session.screenText.contains("marker-to-clear") })
        #expect(try #require(await session.run("echo still-here")).exitCode == 0)
        #expect(session.screenText.contains("still-here"))
    }

    @Test func fontZoomStaysWithinLimits() {
        let session = TerminalSession(workingDirectory: nil)
        defer { session.terminate() }
        let view = session.terminalView
        let base = view.font.pointSize

        session.zoomFont(by: 1)
        #expect(view.font.pointSize == base + 1)
        session.zoomFont(by: nil)
        #expect(view.font.pointSize == base)

        for _ in 0 ..< 100 {
            session.zoomFont(by: 1)
        }
        #expect(Double(view.font.pointSize) == TerminalSettings.fontSizeRange.upperBound)
        // Zoom past the limit is not remembered.
        session.zoomFont(by: -1)
        #expect(Double(view.font.pointSize) == TerminalSettings.fontSizeRange.upperBound - 1)
    }
}
