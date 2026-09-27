import SwiftUI

/// One run in the Archon drawer (#382): its workflow, a dot per stage, where it is or how it
/// ended, and what it was asked to do. Selected, it expands to the stage names under the dots.
struct ArchonRunRow: View {
    let run: ArchonRun
    let stages: [ArchonStage]?
    let isSelected: Bool
    let isExpanded: Bool
    let isBusy: Bool
    /// A first `c` is waiting for its second on this row.
    let isCancelArmed: Bool
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(run.workflowName)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 170, alignment: .leading)
                if let stages {
                    ArchonStageDots(stages: stages)
                } else {
                    ArchonOutcomeMark(status: run.status)
                }
                Text(whereLine)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(whereTint)
                    .lineLimit(1)
                if isBusy { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                Text(run.userMessage ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 360, alignment: .trailing)
                CopyableLabel(value: run.id, hint: "Click to copy the run id — \(run.id)") {
                    Text(run.shortID)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.textFaint)
                }
            }
            if let gate = run.gate { gateLine(gate) }
            if isExpanded, let stages { ArchonStageList(stages: stages) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.archonSurfaceRaised : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    /// Where the run is, or how it ended, in a few words.
    private var whereLine: String {
        if isCancelArmed { return "press c again to cancel" }
        if run.isFinished {
            let failed = stages?.first { $0.state == .failed }?.id
            let when = run.completedAt.map { " · " + Self.age(since: $0) } ?? ""
            if run.status == ArchonRunStatus.failed {
                return (failed.map { "failed at \($0)" } ?? "failed") + when
            }
            return "done" + when
        }
        let stage = run.currentStage ?? (run.isPaused ? "paused" : "starting")
        let since = run.startedAt.map { " · " + Self.age(since: $0) } ?? ""
        return stage + since
    }

    private var whereTint: Color {
        if isCancelArmed { return .danger }
        switch run.status {
        case ArchonRunStatus.failed: return .danger
        case ArchonRunStatus.paused: return .attention
        case ArchonRunStatus.running: return .archonRunning
        default: return .textMuted
        }
    }

    private func gateLine(_ gate: ArchonGate) -> some View {
        HStack(spacing: 8) {
            Text(gate.blockedReason ?? (gate.message.isEmpty ? gate.nodeId : gate.message))
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(isExpanded ? 6 : 1)
            if gate.isAwaitingDecision {
                ForEach(Array(gate.decisions.prefix(9).enumerated()), id: \.offset) {
                    index, decision in
                    Text("\(index + 1) \(decision.label ?? decision.id)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.attention)
                }
            }
        }
        .padding(.leading, 180)
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

/// A run's stages as dots, in workflow order. The colour is the stage's state; the one it is on
/// pulses.
struct ArchonStageDots: View {
    let stages: [ArchonStage]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(stages) { stage in
                ArchonStageDot(state: stage.state)
                    .help("\(stage.id): \(ArchonStageDot.word(for: stage.state))")
            }
        }
    }
}

struct ArchonStageDot: View {
    let state: ArchonStage.State
    @State private var dim = false

    var body: some View {
        Group {
            switch state {
            case .pending:
                Circle().strokeBorder(Color.textFaint, lineWidth: 1)
            case .skipped:
                Circle().strokeBorder(Color.textFaint, lineWidth: 1)
                    .overlay(Rectangle().fill(Color.textFaint).frame(height: 1))
            case .completed:
                Circle().fill(Color.archonTeal)
            case .failed:
                Circle().fill(Color.danger)
            case .running:
                Circle().fill(Color.archonRunning).opacity(dim ? 0.35 : 1)
            case .paused:
                Circle().fill(Color.attention).opacity(dim ? 0.45 : 1)
            }
        }
        .frame(width: 8, height: 8)
        .animation(
            state == .running || state == .paused
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil,
            value: dim
        )
        .onAppear { dim = state == .running || state == .paused }
    }

    static func word(for state: ArchonStage.State) -> String {
        switch state {
        case .pending: "not reached"
        case .running: "running"
        case .paused: "waiting"
        case .completed: "done"
        case .failed: "failed"
        case .skipped: "skipped"
        }
    }
}

/// How a finished run ended, for a run whose stages nobody asked for (before Archon's
/// `workflow runs --verbose`): one mark rather than a row of guessed dots.
struct ArchonOutcomeMark: View {
    let status: String

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(status == ArchonRunStatus.failed ? Color.danger : Color.archonTeal)
            .frame(width: 14, height: 6)
    }
}

/// The expanded row: every stage by name, its state, and how long it took.
struct ArchonStageList: View {
    let stages: [ArchonStage]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(stages) { stage in
                HStack(spacing: 8) {
                    ArchonStageDot(state: stage.state)
                    Text(stage.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                    Text(ArchonStageDot.word(for: stage.state))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted)
                    if let ms = stage.durationMs {
                        Text(Self.duration(ms))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.textFaint)
                    }
                    if let error = stage.error {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.danger)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.leading, 180)
        .padding(.top, 2)
    }

    static func duration(_ ms: Int) -> String {
        ms < 60_000
            ? String(format: "%.1fs", Double(ms) / 1000) : "\(ms / 60_000)m\((ms / 1000) % 60)s"
    }
}
