import SwiftUI

/// One terminal's tab in a slot strip. Observes its session directly so a title or
/// status change re-renders that tab alone rather than the whole strip.
struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let slot: SurfaceSlot

    private var isSelected: Bool { slot.isSelected }

    var body: some View {
        PaneTab(
            title: session.displayTitle, truncation: .tail,
            closeHelp: "Close terminal (kills this shell)", slot: slot
        ) { indicator }
    }

    @ViewBuilder
    private var indicator: some View {
        if session.status == .exited {
            // Dead shell: mark the tab so the fallback pane isn't a surprise.
            Image(systemName: "poweroff")
                .font(.system(size: 8))
                .foregroundStyle(Color.textFaint)
        } else if session.hasBell, !isSelected {
            // Bell from a tab you are not looking at (BEL — e.g. an agent asking
            // for attention). Cleared when the tab is selected.
            Circle()
                .fill(Color.attention)
                .frame(width: 5, height: 5)
                .accessibilityLabel("Bell")
        } else if let outcome = session.activity.outcome, !isSelected {
            // A command finished in this tab while it was off screen; duration (and
            // exit code on failure) in the tooltip. Selecting acknowledges.
            switch outcome {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accent)
                    .help(outcome.tooltip)
                    .accessibilityLabel("Command finished")
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.danger)
                    .help(outcome.tooltip)
                    .accessibilityLabel("Command failed")
            }
        } else if let progress = session.activity.progress {
            // OSC 9;4: a tracked command is running (shown on the selected
            // tab too — it's a hint, not an alert).
            progressHint(progress)
        }
    }

    @ViewBuilder
    private func progressHint(_ progress: TerminalActivity.Progress) -> some View {
        switch progress {
        case let .percent(percent):
            // Tiny determinate ring, drawn by hand — the native circular
            // ProgressView doesn't shrink to tab-chrome size.
            ZStack {
                Circle()
                    .stroke(Color.border, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(Color.textMuted, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            .help("\(percent)%")
            .accessibilityLabel("Progress \(percent)%")
        case .error:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(Color.danger)
                .help("Command reported a progress error")
                .accessibilityLabel("Progress error")
        case .indeterminate, .paused:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
                .help("Command running")
                .accessibilityLabel("Command running")
        }
    }
}
