import SwiftUI

/// The Archon drawer (#382): what Archon is doing in the active workspace's project, on
/// Archon's own ground, driven from the keyboard.
///
/// Top to bottom: the title and the keys, the runs waiting on the operator, the running ones,
/// the finished ones he has not cleared, and the one input. ↑↓ pick a run; every other key is
/// `ArchonKeys`'s table, and the hint line under the list only names the keys that apply to the
/// run picked.
struct ArchonDrawerView: View {
    let drawer: ArchonDrawer
    @ObservedObject var model: ArchonModel
    let holdsKeyboard: Bool

    @State private var selected: String?
    @State private var expanded: Set<String> = []
    @State private var armedCancel: String?
    @State private var notice: String?
    @FocusState private var listFocused: Bool
    @FocusState private var composerFocused: Bool

    init(drawer: ArchonDrawer, holdsKeyboard: Bool) {
        self.drawer = drawer
        _model = ObservedObject(wrappedValue: drawer.model)
        self.holdsKeyboard = holdsKeyboard
    }

    private var workspace: WorkspacePath? { drawer.workspace() }
    private var runs: [ArchonRun] { model.gated + model.running + model.finished }
    private var selectedRun: ArchonRun? {
        runs.first { $0.id == selected } ?? runs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ArchonDrawerTitle(workspace: workspace)
            Color.archonBorder.frame(height: 1)
            list
            Color.archonBorder.frame(height: 1)
            ArchonKeyHints(run: selectedRun, notice: notice)
            Color.archonBorder.frame(height: 1)
            ArchonComposer(
                model: model, workspacePath: workspace, focus: $composerFocused,
                isFocused: composerFocused
            )
            .onKeyPress(.escape) {
                composerFocused = false
                listFocused = true
                return .handled
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.archonSurface)
        .onAppear { listFocused = holdsKeyboard }
        .onChange(of: holdsKeyboard) { listFocused = holdsKeyboard && !composerFocused }
        // Keyed on the workspace: switching one restarts the poll about the new one, and hiding
        // the drawer ends it.
        .task(id: workspace) { await model.poll(in: workspace) }
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("WAITING ON YOU", model.gated)
                    section("RUNNING", model.running)
                    section("FINISHED", model.finished)
                    if runs.isEmpty {
                        Text(
                            workspace == nil ? ArchonModel.noWorkspace : "No Archon runs here yet."
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.textFaint)
                        .padding(12)
                    }
                }
            }
            .onChange(of: selected) { _, id in
                if let id { scroller.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(phases: .down) { press in handle(press) }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [ArchonRun]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.textFaint)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(rows, id: \.id) { run in
                ArchonRunRow(
                    run: run, stages: run.stages(nodes: model.liveNodes[run.id]),
                    isSelected: run.id == selectedRun?.id, isExpanded: expanded.contains(run.id),
                    isBusy: model.busyRuns.contains(run.id), isCancelArmed: armedCancel == run.id,
                    select: {
                        selected = run.id
                        listFocused = true
                    }
                )
                .id(run.id)
            }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !runs.isEmpty else { return .handled }
        let index = runs.firstIndex { $0.id == selectedRun?.id } ?? 0
        selected = runs[min(max(index + step, 0), runs.count - 1)].id
        armedCancel = nil
        return .handled
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty || press.modifiers == .shift,
            let key = press.key == .return
                ? "\r" : press.key == .delete ? "\u{7F}" : press.characters.first
        else { return .ignored }
        let action = ArchonKeys.action(for: key, on: selectedRun, armedCancel: armedCancel)
        if case .armCancel = action {} else { armedCancel = nil }
        return perform(action)
    }

    private func perform(_ action: ArchonKeyAction) -> KeyPress.Result {
        notice = nil
        switch action {
        case .none:
            return .ignored
        case .focusComposer:
            listFocused = false
            composerFocused = true
        case let .toggleExpanded(id):
            if expanded.remove(id) == nil { expanded.insert(id) }
        case let .open(run):
            model.open(run)
        case let .decide(decision, run):
            Task {
                await model.choose(decision, on: run, in: workspace)
                if model.reply != nil { composerFocused = true }
            }
        case let .resume(run):
            Task { await model.resume(run, in: workspace) }
        case let .armCancel(id):
            armedCancel = id
        case let .cancel(run):
            armedCancel = nil
            Task { await model.cancel(run, in: workspace) }
        case let .followLog(run):
            let drawer = self.drawer
            Task { notice = await drawer.runInNewTerminal(ArchonKeys.followLogLine(for: run)) }
        case let .dismiss(run):
            model.dismiss(run, in: workspace)
        }
        return .handled
    }
}

/// The drawer's title: Archon's mark in its duotone, and the workspace it is about.
private struct ArchonDrawerTitle: View {
    let workspace: WorkspacePath?

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
                .foregroundStyle(.archonBrand)
            Text("ARCHON")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(.archonBrand)
            if let workspace {
                Text(URL(fileURLWithPath: workspace.value).lastPathComponent)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.archonSurfaceRaised)
    }
}

/// The keys that do something for the picked run, and the last thing a key could not do.
private struct ArchonKeyHints: View {
    let run: ArchonRun?
    let notice: String?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
            }
            Spacer()
            if let notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.danger)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var hints: [String] {
        var hints = ["↑↓ select", "/ start"]
        guard let run else { return hints }
        if run.isFinished {
            hints += ["⏎ open", "⌫ clear"]
        } else {
            hints.append("⏎ stages")
        }
        if run.isAwaitingDecision {
            hints += ["a approve", "x reject"]
            if let count = run.gate?.decisions.count, count > 0 {
                hints.append("1-\(min(count, 9)) decide")
            }
        }
        if run.status == ArchonRunStatus.failed || run.isPaused { hints.append("r resume") }
        if run.isRunning { hints.append("c c cancel") }
        hints.append("l log")
        return hints
    }
}
