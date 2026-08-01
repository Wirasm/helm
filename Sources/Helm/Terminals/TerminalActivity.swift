import GhosttyTerminal

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
