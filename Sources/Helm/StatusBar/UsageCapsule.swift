import HelmWire
import SwiftUI

/// How close the operator's Claude and codex plans are to their limits (#143): one capsule,
/// one part per harness and account, e.g. `Claude 62% · resets 14:00   Claude .claude-b 12%
/// · resets 15:00   codex 30% · resets Fri 09:00`. Absent until a harness has reported.
///
/// benchd holds the figures (`usage` in its `sessions` answer), as each harness published them on
/// benchd's machine: Claude Code through its statusline (`bench statusline`), codex through its
/// rollout (`bench hook codex`). helm reads no harness file. Redrawn every minute as well as on
/// every change, because a figure goes stale, and a window resets, with nothing reporting.
struct UsageCapsule: View {
    @ObservedObject var foregrounds: SessionForegrounds

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let summary = UsageSummary(foregrounds.usage, now: context.date) {
                HStack(spacing: 8) {
                    ForEach(summary.parts, id: \.label) { part in
                        Text(part.label).foregroundStyle(color(of: part, in: summary))
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(summary.nearLimit ? Color.attention : Color.selection, in: Capsule())
                .help(summary.help)
            }
        }
    }

    private func color(of part: UsageSummary.Part, in summary: UsageSummary) -> Color {
        if part.stale { return .textFaint }
        return summary.nearLimit ? .surface : .textPrimary
    }
}

/// What the capsule says, from benchd's figures at `now`. nil when there is nothing to show.
///
/// Per harness it shows the **binding** window, the fullest one that has not reset, because that
/// is the one that stops the agent; the help lists every window. Two rules decide what a figure
/// is worth:
/// - A window whose reset time has passed is dropped: its percentage is then known wrong.
/// - A figure older than `staleAfter` is drawn faint, and the help says when it is from. Both
///   sources go quiet while nothing runs, so an old figure is ordinary and must not look current.
struct UsageSummary: Equatable {
    struct Part: Equatable {
        let label: String
        let stale: Bool
    }

    let parts: [Part]
    /// A current figure is at or over `nearAt`: the capsule fills with `attention`.
    let nearLimit: Bool
    let help: String

    /// codex's own TUI drops a limit after 15 minutes without a report.
    static let staleAfter: TimeInterval = 15 * 60
    static let nearAt = 90.0

    init?(_ usage: [BenchUsage], now: Date, calendar: Calendar = .current) {
        let clock = UsageClock(now: now, calendar: calendar)
        var parts: [Part] = []
        var lines: [String] = []
        var near = false
        for report in usage {
            let live = report.windows.filter { ($0.resetsAt ?? .distantFuture) > now }
            guard let binding = live.max(by: { $0.usedPercent < $1.usedPercent }) else {
                continue
            }
            let name = Self.name(of: report)
            let stale = now.timeIntervalSince(binding.at) > Self.staleAfter
            parts.append(Part(label: name + " " + clock.figure(binding), stale: stale))
            near = near || (!stale && binding.usedPercent >= Self.nearAt)
            lines += live.sorted { $0.minutes < $1.minutes }.map { window in
                "\(name) \(Self.length(of: window.minutes)) \(clock.figure(window))"
                    + (now.timeIntervalSince(window.at) > Self.staleAfter
                        ? ", as of \(clock.time(window.at))" : "")
            }
        }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
        nearLimit = near
        help =
            lines.joined(separator: "\n")
            + "\nAs each harness last reported it; faint once 15 minutes old."
    }

    /// The harness, and for a second login its config dir's name: `Claude .claude-b`.
    private static func name(of report: BenchUsage) -> String {
        let harness = report.harness == "claude" ? "Claude" : report.harness
        guard let account = report.account else { return harness }
        return harness + " " + URL(fileURLWithPath: account).lastPathComponent
    }

    /// 300 → `5h`, 10080 → `7d`.
    private static func length(of minutes: Int) -> String {
        minutes % 1440 == 0 ? "\(minutes / 1440)d" : "\(minutes / 60)h"
    }
}

/// How the capsule writes a percentage and a time: `HH:mm` today, `EEE HH:mm` on another day.
private struct UsageClock {
    let now: Date
    let calendar: Calendar

    func figure(_ window: BenchUsage.Window) -> String {
        let percent = "\(Int(window.usedPercent.rounded()))%"
        guard let resets = window.resetsAt else { return percent }
        return percent + " · resets " + time(resets)
    }

    func time(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = calendar.timeZone
        format.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return format.string(from: date)
    }
}
