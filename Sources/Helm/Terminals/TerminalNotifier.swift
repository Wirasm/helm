import AppKit
import UserNotifications

/// When an OSC 9 / OSC 777 desktop notification is actually delivered.
/// A notification about the terminal the user is looking at is noise; one
/// from a backgrounded app or an unselected tab is the entire point.
enum TerminalNotificationGate {
    static func shouldDeliver(appIsActive: Bool, tabIsSelected: Bool) -> Bool {
        !(appIsActive && tabIsSelected)
    }
}

// MARK: - TerminalNotifier

/// Delivers terminal-requested desktop notifications through
/// `UNUserNotificationCenter`. Authorization is requested lazily on the first
/// event (the triggering notification is delivered once granted); denial
/// degrades silently — the sequences are best-effort by nature.
///
/// Caveat: UserNotifications requires a real bundle identity. Running as a
/// bare SPM executable (`swift run helm`) there is none — `current()` would
/// abort the process — so delivery is a silent no-op there; the `make app`
/// bundle has the full path.
@MainActor
final class TerminalNotifier: NSObject {
    static let shared = TerminalNotifier()

    private var authorizationRequested = false

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func deliver(title: String, body: String) {
        guard let center else { return }
        if center.delegate !== self { center.delegate = self }
        guard authorizationRequested else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }  // denied: degrade silently
                Task { @MainActor in self.add(title: title, body: body) }
            }
            return
        }
        add(title: title, body: body)
    }

    private func add(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // nil trigger = deliver now; unauthorized adds fail silently, which
        // is exactly the degradation we want.
        center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            ))
    }
}

extension TerminalNotifier: UNUserNotificationCenterDelegate {
    /// Tapping the notification brings helm forward.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    /// Shown as a banner even while helm is frontmost — the gate already
    /// ensured the event came from an unselected tab, so it's not redundant.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
