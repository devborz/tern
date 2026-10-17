import AppKit
import SwiftTerm
import SwiftUI

/// Embeds a session's terminal view in SwiftUI.
///
/// The terminal view belongs to the session, not to this representable, so
/// SwiftUI may rebuild this view at will without affecting the shell or the
/// scrollback; the existing terminal view is simply re-parented.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView(terminalView: session.terminalView)
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.host(session.terminalView)
    }
}

/// Gives the terminal a small margin. The margin is left unpainted: the
/// window's background is the terminal background (see `TerminalWindowController`).
final class TerminalContainerView: NSView {
    private static let margin = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 0)
    private var terminalView: SessionTerminalView

    init(terminalView: SessionTerminalView) {
        self.terminalView = terminalView
        super.init(frame: terminalView.frame)
        wantsLayer = true
        host(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func host(_ view: SessionTerminalView) {
        guard view.superview !== self else { return }
        terminalView.removeFromSuperview()
        terminalView = view
        view.removeFromSuperview()
        addSubview(view)
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let margin = Self.margin
        terminalView.frame = NSRect(
            x: margin.left,
            y: margin.top,
            width: max(0, bounds.width - margin.left - margin.right),
            height: max(0, bounds.height - margin.top - margin.bottom)
        )
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks in the margin focus the terminal.
        window?.makeFirstResponder(terminalView)
    }
}
