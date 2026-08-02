import SwiftUI

/// One terminal's tab in a slot strip. Observes its session directly so a title or
/// status change re-renders that tab alone rather than the whole strip.
struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            indicator
            Text(session.displayTitle)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!canClose)
            .opacity(canClose ? 1 : 0.3)
            .help(
                canClose
                    ? "Close terminal (kills this shell)" : "The last pane cannot be closed")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.selection : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: onSelect)
    }

    /// The tab's one indicator slot, by precedence: dead shell > bell (orange
    /// keeps priority) > finished-command tick/mark (panes you cannot see, cleared
    /// when one comes on screen) > live progress hint. All state, no popups — the
    /// quiet rules live in `TerminalActivity`.
    ///
    /// **Do not copy the `!isSelected` gating into an agent-status indicator.**
    /// Hiding a mark on the tab you are looking at is right for a shell-command
    /// outcome — you watched it happen, so selecting the tab acknowledges it. It is
    /// wrong for a per-workspace agent rollup, where selecting a workspace shows you
    /// one of its N terminals and says nothing about the others; that indicator must
    /// follow one rule everywhere, including where you already are.
    @ViewBuilder
    private var indicator: some View {
        if session.status == .exited {
            // Dead shell: mark the tab so the fallback pane isn't a surprise.
            Image(systemName: "poweroff")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        } else if session.hasBell, !isSelected {
            // Bell from a tab you are not looking at (BEL — e.g. an agent asking
            // for attention). Cleared when the tab is selected.
            Circle()
                .fill(.orange)
                .frame(width: 5, height: 5)
                .accessibilityLabel("Bell")
        } else if let outcome = session.activity.outcome, !isSelected {
            // A command finished in this tab while it was off screen; duration (and
            // exit code on failure) in the tooltip. Selecting acknowledges.
            switch outcome {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .help(outcome.tooltip)
                    .accessibilityLabel("Command finished")
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
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
                    .stroke(.quaternary, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            .help("\(percent)%")
            .accessibilityLabel("Progress \(percent)%")
        case .error:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(.red)
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

// MARK: - CanvasTab

/// A canvas's tab: what it is showing, and no indicator. A canvas has no shell to
/// report a bell, an exit code or a progress sequence.
struct CanvasTab: View {
    let source: CanvasSource
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!canClose)
            .opacity(canClose ? 1 : 0.3)
            .help(canClose ? "Close canvas" : "The last pane cannot be closed")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.selection : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: onSelect)
    }

    /// The filename for a file, the host for a URL — the shortest thing that still
    /// tells two open canvases apart.
    private var label: String {
        switch source {
        case let .file(path): (path as NSString).lastPathComponent
        case let .url(url): url.host() ?? url.absoluteString
        case .empty: "New canvas"
        }
    }

    private var icon: String {
        switch source {
        case .file: "doc.text"
        case .url, .empty: "globe"
        }
    }
}
