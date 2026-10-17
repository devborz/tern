import AppKit
import SwiftUI

/// The content of a terminal window: the terminal, plus the command history
/// as a trailing panel.
struct TerminalWindowView: View {
    let session: TerminalSession
    @Bindable var state: TerminalWindowState

    var body: some View {
        HStack(spacing: 0) {
            TerminalHostView(session: session)
            if state.isHistoryVisible {
                Divider()
                CommandHistoryView(session: session) {
                    state.isHistoryVisible = false
                }
                .frame(width: 320)
                .background(.background)
            }
        }
        .background {
            if state.backgroundTranslucency > 0 {
                ZStack {
                    BehindWindowMaterial()
                    Color(nsColor: .textBackgroundColor).opacity(1 - state.backgroundTranslucency)
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: state.isHistoryVisible) { _, isVisible in
            if !isVisible {
                session.terminalView.window?.makeFirstResponder(session.terminalView)
            }
        }
    }
}

/// Blurs whatever is behind the window.
private struct BehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        // Stay translucent in background windows too, like Terminal.app.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
