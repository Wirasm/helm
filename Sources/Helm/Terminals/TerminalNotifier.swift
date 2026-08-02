import AppKit
import UserNotifications

/// When an OSC 9 / OSC 777 desktop notification is actually delivered.
/// A notification about a terminal the user is looking at is noise; one
/// from a backgrounded app or a pane they cannot see is the entire point.
///
/// `paneIsVisible` rather than `tabIsSelected` since the bench: with three panes on
/// screen at once, "selected" answers for only one of them, and the rule was always
/// about what the operator can actually see.
enum TerminalNotificationGate {
    static func shouldDeliver(appIsActive: Bool, paneIsVisible: Bool) -> Bool {
        !(appIsActive && paneIsVisible)
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

    /// nil under `swift run`, where `UNUserNotificationCenter.current()` would **abort the
    /// process** — it needs a real bundle, not merely an identifier.
    ///
    /// This asks `LaunchContext.isAppBundle`, not `bundleIdentifier != nil`. Those were the
    /// same question until #45 gave the SPM binary an identifier so both launch paths would
    /// share one `UserDefaults` domain. #45 migrated the activation check in `HelmApp.init`
    /// and missed this one, so the guard started passing while the abort remained: helm died
    /// with `bundleProxyForCurrentProcess is nil` the first time an agent asked for a desktop
    /// notification, taking every hosted session with it.
    ///
    /// The bundle *path* is what still separates the two binaries — see `LaunchContext`.
    /// Whether `UNUserNotificationCenter.current()` is safe to call for a process running from
    /// `bundleURL`. Pulled out so the rule is reachable from `swift test` — the crash it
    /// prevents cannot be, since `current()` aborts rather than throwing.
    /// `nonisolated` because it genuinely is — it reads no actor state, which is what lets the
    /// rule be tested without a main actor, exactly as `BoardModel.presence` is.
    nonisolated static func canDeliver(from bundleURL: URL) -> Bool {
        LaunchContext.isAppBundle(bundleURL)
    }

    private var center: UNUserNotificationCenter? {
        guard Self.canDeliver(from: Bundle.main.bundleURL) else { return nil }
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
