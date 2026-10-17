import AppKit
import SwiftUI

/// Searchable list of the commands run in a session, newest first.
struct CommandHistoryView: View {
    let session: TerminalSession
    var onDismiss: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var results: [CommandExecution] {
        let newestFirst = session.commandTracker.executions.reversed()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(newestFirst) }
        return newestFirst.filter {
            $0.command.localizedCaseInsensitiveContains(query)
                || $0.workingDirectory.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Commands", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onExitCommand(perform: onDismiss)
                .padding(10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { isSearchFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        if !session.hasShellIntegration {
            ContentUnavailableView(
                "Commands Not Tracked",
                systemImage: "terminal",
                description: Text("Command tracking needs zsh shell integration.")
            )
        } else if results.isEmpty {
            if query.isEmpty {
                ContentUnavailableView(
                    "No Commands Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Commands you run in this tab appear here.")
                )
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            List(results) { execution in
                CommandHistoryRow(execution: execution) {
                    // The output lives in the scrollback, as long as it is there.
                    if !session.terminalView.copyCommandOutput(of: execution.id) {
                        NSSound.beep()
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct CommandHistoryRow: View {
    let execution: CommandExecution
    var copyOutput: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(execution.command.isEmpty ? "(unknown command)" : execution.command)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                status
                Text(execution.duration.map(CommandStatusLine.format(duration:)) ?? "")
                    .monospacedDigit()
                Spacer(minLength: 4)
                Text(execution.startedAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(TerminalSession.abbreviatingHome(execution.workingDirectory.path))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy Command") { copy(execution.command) }
            Button("Copy Output", action: copyOutput)
            Button("Copy Directory") { copy(execution.workingDirectory.path) }
        }
    }

    @ViewBuilder
    private var status: some View {
        if execution.isRunning {
            Label("Running", systemImage: "circle.dotted")
        } else if let code = execution.exitCode {
            Label("\(code)", systemImage: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(code == 0 ? .green : .red)
                .monospacedDigit()
        } else {
            Label("Unknown", systemImage: "questionmark.circle")
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
