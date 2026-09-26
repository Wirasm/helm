import HelmWire
import SwiftUI

/// The sessions list (#384): one line per session, the running ones first and then the newest,
/// as benchd orders them. Keyboard first: ↑↓ move, Return opens, ⌫ dismisses a finished one.
/// A click opens too.
struct SessionsView: View {
    @ObservedObject var model: SessionsModel
    let holdsKeyboard: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Color.border.frame(height: 1)
            }
            if model.rows.isEmpty {
                Text(model.problem == nil ? "No agent sessions in this workspace." : "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surface)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { act { await model.open($0) } }
        .onKeyPress(.delete) { act { await model.dismiss($0) } }
        .onAppear { focused = holdsKeyboard }
        .onChange(of: holdsKeyboard) { focused = holdsKeyboard }
        .task(id: model.workspace) { await model.watch() }
    }

    private var rows: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        SessionRowView(
                            row: row, isSelected: row.id == model.selected,
                            open: { Task { await model.open(row) } },
                            dismiss: { Task { await model.dismiss(row) } }
                        )
                        .id(row.id)
                    }
                }
            }
            .onChange(of: model.selected) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !model.rows.isEmpty else { return .ignored }
        let current = model.rows.firstIndex { $0.id == model.selected } ?? -1
        let next = min(max(current + step, 0), model.rows.count - 1)
        model.selected = model.rows[next].id
        return .handled
    }

    private func act(_ action: @escaping (BenchSessionRow) async -> Void) -> KeyPress.Result {
        guard let row = model.rows.first(where: { $0.id == model.selected }) else {
            return .ignored
        }
        Task { await action(row) }
        return .handled
    }
}

/// One session: its harness, its name, what it is doing and how long ago.
private struct SessionRowView: View {
    let row: BenchSessionRow
    let isSelected: Bool
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if row.parent != nil {
                Text("↳").foregroundStyle(Color.textFaint)
            }
            Text(row.harness)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textFaint)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(SessionLine.title(row))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(SessionLine.status(row, now: Date()))
                    .font(.system(size: 10.5))
                    .foregroundStyle(SessionLine.isRunning(row) ? Color.textMuted : Color.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !SessionLine.isRunning(row) {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textMuted)
                .help("Take this finished session off the list")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.selection : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(SessionLine.help(row))
    }
}

/// What a row says, pure so it is testable without a view.
enum SessionLine {
    static func title(_ row: BenchSessionRow) -> String {
        row.name ?? String(row.id.prefix(8))
    }

    static func isRunning(_ row: BenchSessionRow) -> Bool {
        if case .running = row.state { true } else { false }
    }

    /// "busy · 2m", "waiting: permission prompt · 40m", "finished 3h ago".
    static func status(_ row: BenchSessionRow, now: Date) -> String {
        switch row.state {
        case let .running(activity, detail):
            let word = activity.replacingOccurrences(of: "_", with: " ")
            let doing = detail.map { "\(word): \($0)" } ?? word
            return "\(doing) · \(age(since: row.updatedAtMs, now: now))"
        case let .finished(atMs):
            return "finished \(age(since: atMs, now: now)) ago"
        }
    }

    /// What pressing the row does, for its tooltip.
    static func help(_ row: BenchSessionRow) -> String {
        switch row.open {
        case .focusPane: "Show the pane it runs in"
        case .benchAttach: "Attach to it in a new terminal"
        case .claudeAttach: "Attach to the background job in a new terminal"
        case .resume: "Resume it in a new terminal, in \(row.cwd)"
        case .transcript: "Open its transcript"
        }
    }

    static func age(since ms: UInt64, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - Int(ms / 1000))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
