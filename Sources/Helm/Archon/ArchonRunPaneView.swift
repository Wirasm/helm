import SwiftUI

struct ArchonRunPaneView: View {
    @ObservedObject var model: ArchonRunPaneModel

    var body: some View {
        Group {
            if let run = model.run {
                runContent(run)
            } else if let failure = model.failure {
                unavailable(failure)
            } else {
                ProgressView("Loading run…")
                    .foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
        .task { await model.poll() }
    }

    private func runContent(_ run: ArchonRun) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.workflowName).font(.headline)
                    Text(run.id).font(.caption2).foregroundStyle(Color.textFaint)
                }
                Spacer()
                Text(run.status).foregroundStyle(Color.textMuted)
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(ChromeBackground())
            Color.border.frame(height: 1)

            if let nodes = run.nodes, !nodes.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                            nodeRow(node)
                        }
                        if let failure = model.failure {
                            Text(failure).font(.caption).foregroundStyle(Color.accent)
                        }
                    }
                    .padding(12)
                }
            } else {
                unavailable("This run has not published node progress yet.")
            }
        }
        .foregroundStyle(Color.textPrimary)
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
                    Text(node.state.rawValue).font(.caption).foregroundStyle(Color.textMuted)
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

    private func unavailable(_ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.textMuted)
            Text("Run unavailable").foregroundStyle(Color.textPrimary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func icon(for state: ArchonNode.State) -> String {
        switch state {
        case .running: "circle.dotted"
        case .completed: "checkmark.circle"
        case .failed: "xmark.circle"
        case .skipped: "minus.circle"
        }
    }

    private static func duration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

struct ArchonRunTab: View {
    let reference: ArchonRunRef
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted)
            Text(reference.workflowName)
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
