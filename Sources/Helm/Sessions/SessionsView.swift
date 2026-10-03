import HelmWire
import SwiftUI

/// The sessions list (#384): one line per running session, as benchd orders them, then the
/// finished ones behind a disclosure, the newest few (`SessionsModel.listed`). Keyboard first:
/// ↑↓ move, Return opens, ⌫ dismisses a finished one. A click opens too.
struct SessionsView: View {
    @ObservedObject var model: SessionsModel
    let holdsKeyboard: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NeedsYouSection(foregrounds: TerminalManager.shared.foregrounds) { model.goTo($0) }
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
                    ForEach(model.running) { row in line(row) }
                    if !model.finished.isEmpty {
                        FinishedDisclosure(
                            count: model.finished.count, isOpen: model.showsFinished,
                            toggle: model.toggleFinished)
                    }
                    if model.showsFinished {
                        ForEach(model.finished.prefix(SessionsModel.finishedListed)) { row in
                            line(row)
                        }
                        let older = model.finished.count - SessionsModel.finishedListed
                        if older > 0 {
                            Text("\(older) older not listed")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.textFaint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .onChange(of: model.selected) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
    }

    private func line(_ row: BenchSessionRow) -> some View {
        SessionRowView(
            row: row, isSelected: row.id == model.selected,
            open: { Task { await model.open(row) } },
            dismiss: { Task { await model.dismiss(row) } }
        )
        .id(row.id)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let listed = model.listed
        guard !listed.isEmpty else { return .ignored }
        let current = listed.firstIndex { $0.id == model.selected } ?? -1
        let next = min(max(current + step, 0), listed.count - 1)
        model.selected = listed[next].id
        return .handled
    }

    private func act(_ action: @escaping (BenchSessionRow) async -> Void) -> KeyPress.Result {
        guard let row = model.listed.first(where: { $0.id == model.selected }) else {
            return .ignored
        }
        Task { await action(row) }
        return .handled
    }
}

/// The line that opens or closes this workspace's finished sessions.
private struct FinishedDisclosure: View {
    let count: Int
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text("finished \(count)")
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chrome)
        .help(isOpen ? "Hide finished sessions" : "Show the newest finished sessions")
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
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.chrome)
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

    /// "feat/x · busy · 2m · claude-opus-5-5", "waiting: permission prompt · 40m", "finished 3h
    /// ago". The model comes last, so a narrow drawer cuts it before what the agent is doing.
    static func status(_ row: BenchSessionRow, now: Date) -> String {
        let status: String
        switch row.state {
        case let .running(activity, detail):
            let word = activity.replacingOccurrences(of: "_", with: " ")
            let doing = detail.map { "\(word): \($0)" } ?? word
            status = "\(doing) · \(BenchSessionRow.age(sinceMs: row.updatedAtMs, now: now))"
        case let .finished(atMs):
            status = "finished \(BenchSessionRow.age(sinceMs: atMs, now: now)) ago"
        }
        let line = row.branch.map { "\($0) · \(status)" } ?? status
        return row.model.map { "\(line) · \($0)" } ?? line
    }

    /// What pressing the row does, for its tooltip.
    static func help(_ row: BenchSessionRow) -> String {
        switch row.open {
        case .focusPane: "Show the pane it runs in"
        case .benchAttach: "Show it in a new pane"
        case .claudeAttach: "Attach to the background job in a new terminal"
        case .resume: "Resume it in a new terminal, in \(row.cwd)"
        case .transcript: "Open its transcript"
        }
    }
}
