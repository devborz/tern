import AppKit

/// A command's status drawn over its status line: `✓ 0 · 84 ms` in a font
/// a little smaller than the terminal's, then a copy button when the command
/// printed something. Placed by `SessionTerminalView`.
final class CommandStatusView: NSView {
    let copyButton = CopyOutputButton()
    /// The status as drawn.
    private(set) var text = NSAttributedString()
    private var textOrigin = NSPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The command shown.
    private(set) var commandID: UUID?

    /// Shows `execution` in a row of `rowHeight` points and sizes the view to fit.
    func show(_ execution: CommandExecution, hasOutput: Bool, font: NSFont, rowHeight: CGFloat) {
        commandID = execution.id
        let parts = CommandStatusLine.label(for: execution)
        let color: NSColor = switch parts.outcome {
        case .succeeded: .systemGreen
        case .failed: .systemRed
        case .unknown: .systemYellow
        }
        let text = NSMutableAttributedString(string: parts.status, attributes: [.font: font, .foregroundColor: color])
        text.append(NSAttributedString(
            string: " · \(parts.duration)",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        self.text = text

        // Drawn directly rather than with a text field, which wraps the
        // last word away when its own padding leaves it short of room.
        let textSize = text.size()
        textOrigin = NSPoint(x: 0, y: ((rowHeight - textSize.height) / 2).rounded())
        var width = ceil(textSize.width)

        copyButton.commandID = execution.id
        copyButton.isHidden = !hasOutput
        if hasOutput {
            let side = floor(rowHeight) - 2
            copyButton.frame = NSRect(x: width + 3, y: ((rowHeight - side) / 2).rounded(), width: side, height: side)
            width = copyButton.frame.maxX
        }
        setFrameSize(NSSize(width: width, height: rowHeight))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(at: textOrigin)
    }

    /// Only the copy button takes clicks; the rest of the line belongs to the
    /// terminal (selection, ⌘-click).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === copyButton ? hit : nil
    }
}
