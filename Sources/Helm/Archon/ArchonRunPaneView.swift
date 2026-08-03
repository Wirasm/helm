import SwiftUI

struct ArchonRunPaneView: View {
    @ObservedObject var model: ArchonRunPaneModel
    /// Opening one run out of a status list. The pane holds no bench knowledge — where a run
    /// lands is `Workbench.placement(forOpening:)`'s decision, as it is for the rail.
    let openRun: (ArchonPaneRef) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Color.border.frame(height: 1)
            content(for: model.content)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color.textPrimary)
        .background(Color.surface)
        .task { await model.poll() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption2).foregroundStyle(Color.textFaint)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
        }
        .padding(12)
        .background(ChromeBackground())
    }

    private var title: String {
        switch model.reference {
        case let .run(_, workflowName): workflowName
        case let .runs(status): "\(status) runs"
        }
    }

    private var subtitle: String {
        switch (model.reference, model.content) {
        case let (.run(id, _), .run(run)): "\(run.status) · \(id)"
        case let (.run(id, _), _): id
        case let (.runs, .list(runs)): "\(runs.count) shown, newest first"
        case (.runs, _): "Archon's most recent"
        }
    }

    @ViewBuilder
    private func content(for content: ArchonRunPaneModel.Content?) -> some View {
        // Checked BEFORE the content, because a failed poll used to be unreachable whenever
        // `nodes` was empty: the stale run kept the pane on the "not started yet" branch while
        // every poll silently failed. "Archon is unreachable" and "this run has not begun"
        // must never look the same.
        if let failure = model.failure {
            ArchonNotice(
                title: "Run unavailable", detail: failure, icon: "exclamationmark.triangle")
        } else {
            switch content {
            case let .run(run):
                if let nodes = run.nodes, !nodes.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if let error = run.metadata?.error {
                                // `failed` does NOT mean the work failed — a run whose only
                                // failing node was `create-pr` reports it while the branch is
                                // committed and validated. So the reason, when Archon gives
                                // one, is shown rather than left to the status word.
                                Text(error)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color.accent)
                                    .textSelection(.enabled)
                            }
                            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                                nodeRow(node)
                            }
                        }
                        .padding(12)
                    }
                } else {
                    ArchonNotice(
                        title: "Nothing to show yet",
                        detail: "This run has not published node progress.", icon: "clock")
                }
            case let .list(runs):
                if runs.isEmpty {
                    ArchonNotice(
                        title: "No runs", detail: "Archon reports none with this status.",
                        icon: "checkmark.circle")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(runs, id: \.id) { run in listRow(run) }
                        }
                        .padding(12)
                    }
                }
            case nil:
                ProgressView("Loading…").foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func listRow(_ run: ArchonRun) -> some View {
        Button {
            openRun(.run(id: run.id, workflowName: run.workflowName))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(run.workflowName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if let startedAt = run.startedAt {
                        Text(startedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(Color.textFaint)
                    }
                }
                if let error = run.metadata?.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(2)
                }
                Text(run.workingPath ?? "No working path")
                    .font(.caption2)
                    .foregroundStyle(Color.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.surfaceRaised))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func nodeRow(_ node: ArchonNode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: node.state))
                .frame(width: 14)
                .foregroundStyle(node.state == .running ? Color.accent : Color.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.nodeId).font(.system(.body, design: .monospaced, weight: .semibold))
                    Spacer()
                    Text(node.state.raw).font(.caption).foregroundStyle(Color.textMuted)
                    if let duration = node.durationMs {
                        Text(Self.duration(duration)).font(.caption).foregroundStyle(
                            Color.textFaint)
                    } else if node.state == .running, let startedAt = node.startedAt {
                        Text(startedAt, style: .relative).font(.caption).foregroundStyle(
                            Color.textFaint)
                    }
                }
                if let preview = node.outputPreview {
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.textMuted)
                        .textSelection(.enabled)
                }
                if let error = node.error {
                    Text(error)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.accent)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.surfaceRaised))
    }

    private func icon(for state: ArchonNode.State) -> String {
        switch state {
        case .running: "circle.dotted"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .skipped: "minus.circle"
        // A state Archon added after this shipped. Shown as itself with a neutral mark
        // rather than guessed at — the name still reaches the operator via `state.raw`.
        case .unknown: "questionmark.circle"
        }
    }

    private static func duration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

/// "There is nothing here, and this is why." One view rather than two near-identical ones,
/// which is what the rail and the pane each grew.
///
/// **Deliberately not `ContentUnavailableView`.** That one styles itself from the system's
/// defaults, and a system default is exactly the thing `Design/Palette.swift` exists to stop
/// helm spending — three unrelated colour sources is how the app stopped reading as one.
struct ArchonNotice: View {
    let title: String
    let detail: String?
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Color.textMuted)
            Text(title).foregroundStyle(Color.textPrimary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct ArchonRunTab: View {
    let reference: ArchonPaneRef
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted)
            Text(reference.title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 180)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .disabled(!canClose)
            .opacity(canClose ? 1 : 0.3)
            .help(canClose ? "Close run pane" : "The last pane cannot be closed")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.selection : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: onSelect)
    }
}
