import AppKit
import GhosttyTerminal
import UserNotifications

// The pure logic behind the terminal's escape-sequence capabilities —
// ⌘-click link policy, command-finished/progress tab state, desktop
// notification gating — kept out of TerminalSession so `swift test` can
// exercise every rule headlessly. The session's delegate conformances
// (TerminalManager.swift) are thin sinks into these types.

// MARK: - TerminalURLPolicy

/// Which URLs a ⌘-click in the terminal grid may hand to the system.
///
/// Deliberately a strict allowlist: terminal content is untrusted (an agent or
/// any program can print an OSC 8 hyperlink with an arbitrary URI), and
/// `NSWorkspace.open` will happily launch whatever app claims a scheme —
/// `ssh:`, `x-apple.systempreferences:`, worse. Web links, mail, and local
/// files cover the real uses; everything else is dropped silently.
enum TerminalURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "file", "mailto"]

    /// The URL to open, or nil when the click must be ignored. Trims
    /// whitespace/newlines (grid-wrapped links), then requires a parseable
    /// URL with an explicitly allowed scheme — scheme-less strings ("
    /// example.com") are rejected rather than guessed at.
    static func validated(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }
}

// MARK: - TerminalActivity

/// One tab's command-activity chrome, as pure state: what OSC 9;4 progress is
/// live, and whether an unacknowledged command-finished mark is showing.
///
/// The quiet rules (GLOSSARY spirit — attention is state of existing
/// elements, never a popup):
/// - progress is shown wherever it's reported, selected tab included — it's
///   a hint, not an alert;
/// - a finished command marks only an INACTIVE tab (the user watched the
///   active one), and selecting the tab acknowledges the mark;
/// - an unknown exit code marks nothing — no data, no chrome.
struct TerminalActivity: Equatable {
    enum Progress: Equatable {
        /// OSC 9;4 state=set — a 0…100 gauge.
        case percent(Int)
        /// Running with no reported percentage.
        case indeterminate
        /// The emitter reported a progress error.
        case error
        /// Progress paused (percent kept when the emitter provided one).
        case paused(Int?)
    }

    enum Outcome: Equatable {
        case success(durationNanos: UInt64)
        case failure(exitCode: Int, durationNanos: UInt64)

        var durationNanos: UInt64 {
            switch self {
            case let .success(nanos), let .failure(_, nanos): nanos
            }
        }

        /// Tab tooltip for the tick/mark.
        var tooltip: String {
            let duration = TerminalActivity.formatDuration(nanos: durationNanos)
            switch self {
            case .success: return "Command finished in \(duration)"
            case let .failure(code, _): return "Command failed (exit \(code)) after \(duration)"
            }
        }
    }

    private(set) var progress: Progress?
    private(set) var outcome: Outcome?

    mutating func reportProgress(state: TerminalProgressState, percent: Int?) {
        switch state {
        case .remove:
            progress = nil
            // Removal is how a finishing command withdraws its bar; any
            // outcome mark that follows comes from finishCommand.
            return
        case .set:
            progress = .percent(min(max(percent ?? 0, 0), 100))
        case .indeterminate:
            progress = .indeterminate
        case .error:
            progress = .error
        case .pause:
            progress = .paused(percent)
        }
        // Fresh activity supersedes a stale finished-command mark.
        outcome = nil
    }

    mutating func finishCommand(exitCode: Int?, durationNanos: UInt64, isSelected: Bool) {
        progress = nil
        // The active tab's finish needs no chrome, and no exit code means
        // nothing truthful to show.
        guard !isSelected, let exitCode else { return }
        outcome =
            exitCode == 0
            ? .success(durationNanos: durationNanos)
            : .failure(exitCode: exitCode, durationNanos: durationNanos)
    }

    /// Selecting the tab acknowledges the finished-command mark (the bell's
    /// pattern; live progress is not attention and survives selection).
    mutating func acknowledge() {
        outcome = nil
    }

    /// Wall-clock duration for tooltips: sub-second in ms, sub-minute in
    /// seconds with one decimal, then m/s, then h/m.
    static func formatDuration(nanos: UInt64) -> String {
        let seconds = Double(nanos) / 1_000_000_000
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \((whole % 3600) / 60)m"
    }
}

// MARK: - TerminalNotificationGate

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
