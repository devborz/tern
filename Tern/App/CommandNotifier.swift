import AppKit
import UserNotifications

/// Tells the user when a long command finishes in a window they are not
/// looking at: a notification (clicking it brings the window back) and one
/// bounce of the Dock icon. Permission is asked the first time it is needed.
final class CommandNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CommandNotifier()

    /// Commands shorter than this never notify.
    static let minimumDuration: TimeInterval = 10

    static func shouldNotify(_ execution: CommandExecution, windowIsInFront: Bool) -> Bool {
        guard let duration = execution.duration else { return false }
        return duration >= minimumDuration && !windowIsInFront
    }

    /// `✓ make` / `Finished in 2m 05s`, `✕ make` / `Exit code 2 after 2m 05s`.
    static func message(for execution: CommandExecution) -> (title: String, body: String) {
        let duration = execution.duration.map(CommandStatusLine.format(duration:)) ?? "–"
        switch execution.exitCode {
        case 0?:
            return ("✓ \(execution.command)", "Finished in \(duration)")
        case let code?:
            return ("✕ \(execution.command)", "Exit code \(code) after \(duration)")
        case nil:
            return ("\(execution.command)", "Finished after \(duration)")
        }
    }

    func commandFinished(_ execution: CommandExecution, in controller: TerminalWindowController) {
        guard let window = controller.window,
              Self.shouldNotify(execution, windowIsInFront: NSApp.isActive && window.isKeyWindow)
        else { return }
        NSApp.requestUserAttention(.informationalRequest)

        let message = Self.message(for: execution)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = TerminalSession.abbreviatingHome(execution.workingDirectory.path)
        content.body = message.body
        content.sound = .default
        content.userInfo = ["session": controller.session.id.uuidString]
        let request = UNNotificationRequest(identifier: execution.id.uuidString, content: content, trigger: nil)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Tern may be active with the command's window behind another one.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = (response.notification.request.content.userInfo["session"] as? String).flatMap(UUID.init)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let sessionID {
                    WindowManager.shared.showSession(sessionID)
                }
            }
        }
        completionHandler()
    }
}
