import SwiftUI

/// The Worktrees drawer (#382): every repository on the machine with a linked worktree, and the
/// bench's own, each a group of its worktrees. Driven from the keyboard: ↑↓ pick a worktree and
/// every other key is `WorktreesKeys`'s table — open, new, delete. Showing the drawer refreshes
/// it; the last answer stays on screen while the next is read.
struct WorktreesDrawerView: View {
    let drawer: WorktreesDrawer
    @ObservedObject var model: WorktreesModel
    let holdsKeyboard: Bool

    @State private var selected: String?
    /// The repository a new worktree is being typed for, while the composer is open.
    @State private var creatingIn: GitCommonDir?
    @State private var notice: String?
    @FocusState private var focused: Bool
    @FocusState private var composerFocused: Bool

    init(drawer: WorktreesDrawer, holdsKeyboard: Bool) {
        self.drawer = drawer
        _model = ObservedObject(wrappedValue: drawer.model)
        self.holdsKeyboard = holdsKeyboard
    }

    private var repos: [WorktreeRepo] { model.listed }
    private var rows: [Worktree] { repos.flatMap(\.worktrees) }
    private var selectedRow: Worktree? { rows.first { $0.id == selected } ?? rows.first }
    private var selectedRepo: WorktreeRepo? {
        selectedRow.flatMap { row in repos.first { $0.worktrees.contains(row) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorktreesTitle(
                repoCount: repos.count, worktreeCount: rows.count,
                isRefreshing: model.isRefreshing)
            Color.border.frame(height: 1)
            list
            if let repoID = creatingIn {
                Color.border.frame(height: 1)
                WorktreeComposer(
                    repoName: repos.first { $0.id == repoID }?.name ?? "",
                    isCreating: model.isCreating, failure: model.createFailure,
                    focus: $composerFocused,
                    submit: { branch in create(branch, in: repoID) },
                    cancel: closeComposer)
            }
            Color.border.frame(height: 1)
            WorktreesFooter(
                hints: WorktreesKeys.hints(on: selectedRow, in: selectedRepo),
                notice: notice, unlisted: model.unlistedCount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surface)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(phases: .down) { press in handle(press) }
        .onAppear { focused = holdsKeyboard }
        .onChange(of: holdsKeyboard) { focused = holdsKeyboard }
        // Once per showing: the drawer's view exists only while the drawer is open.
        .task { await model.refresh(workspaces: drawer.workspaces) }
        .alert(item: confirmation) { target in
            Alert(
                title: Text(WorktreesConfirmText.title(target, in: model)),
                message: Text(WorktreesConfirmText.message(target, in: model)),
                primaryButton: .destructive(Text(WorktreesConfirmText.button(target))) {
                    Task { await model.confirm() }
                },
                secondaryButton: .cancel { model.cancelConfirmation() })
        }
    }

    private var list: some View {
        let occupants = WorktreeOccupants.assign(
            WorktreeOccupants.occupants(of: drawer.document()), to: rows.map(\.id))
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(repos) { repo in
                        WorktreesRepoHeader(repo: repo, failure: model.refreshFailures[repo.id])
                        ForEach(repo.worktrees) { row in
                            WorktreeRow(
                                row: row, occupants: occupants[row.id] ?? [],
                                isSelected: row.id == selectedRow?.id,
                                isActing: model.actingPaths.contains(row.id),
                                failure: model.actionFailures[row.id],
                                select: {
                                    selected = row.id
                                    focused = true
                                }
                            )
                            .id(row.id)
                        }
                    }
                    if repos.isEmpty {
                        Text(model.isRefreshing ? "Looking for worktrees…" : "No worktrees found.")
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
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        let index = rows.firstIndex { $0.id == selectedRow?.id } ?? 0
        selected = rows[min(max(index + step, 0), rows.count - 1)].id
        return .handled
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !composerFocused, press.modifiers.isEmpty || press.modifiers == .shift,
            let key = press.key == .return ? "\r" : press.characters.first
        else { return .ignored }
        let action = WorktreesKeys.action(for: key, on: selectedRow, in: selectedRepo)
        if action != .none { notice = nil }
        switch action {
        case .none:
            return .ignored
        case .refresh:
            Task { await model.refresh(workspaces: drawer.workspaces) }
        case let .openWorkspace(row):
            drawer.openWorkspace(row.record.path)
        case let .openTerminal(row):
            let drawer = self.drawer
            Task {
                notice = await drawer.runInNewTerminal(
                    WorktreesDrawer.changeDirectoryLine(to: row.record.path))
            }
        case let .create(repo):
            model.clearCreateFailure()
            creatingIn = repo
            composerFocused = true
        case let .delete(row):
            Task { await model.requestDelete(of: row) }
        case let .cleanMerged(repo):
            model.requestCleanMerged(in: repo)
        }
        return .handled
    }

    private func create(_ branch: String, in repoID: GitCommonDir) {
        Task {
            guard let path = await model.create(branch: branch, in: repoID) else { return }
            selected = path
            closeComposer()
        }
    }

    private func closeComposer() {
        creatingIn = nil
        composerFocused = false
        focused = true
    }

    private var confirmation: Binding<WorktreesModel.Confirmation?> {
        Binding(
            get: { model.confirmation },
            set: { if $0 == nil { model.cancelConfirmation() } })
    }
}

/// The drawer's title: what it is, how much it found, and whether it is still reading.
private struct WorktreesTitle: View {
    let repoCount: Int
    let worktreeCount: Int
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("WORKTREES")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(Color.textMuted)
            Text("\(counted(repoCount, "repo")) · \(counted(worktreeCount, "worktree"))")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.textFaint)
            Spacer()
            if isRefreshing { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.surfaceRaised)
    }
}

/// One repository's heading: its name, and where its git directory is.
private struct WorktreesRepoHeader: View {
    let repo: WorktreeRepo
    let failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(repo.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(Self.abbreviated(repo.mainPath ?? repo.commonDir.path))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let failure {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// The keys that apply to the selected worktree, the last thing a key could not do, and how
/// many repositories were left out.
private struct WorktreesFooter: View {
    let hints: [String]
    let notice: String?
    let unlisted: Int

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
            } else if unlisted > 0 {
                Text("\(counted(unlisted, "repo")) with only a main checkout not shown")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// "1 repo", "2 repos".
private func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
