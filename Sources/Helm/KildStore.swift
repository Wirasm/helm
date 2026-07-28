import Combine
import Foundation

/// App-level state for the whole frame: which folder you have open, and what the engine
/// says about it.
///
/// **Two halves, deliberately composed rather than merged.** `Cockpit` owns everything the
/// engine reports and nothing else; this type owns the workspace — a folder helm simply has
/// open, which the engine has never heard of. The old store conflated them, and the seam is
/// worth keeping visible: workspace state is persisted locally and survives an engine
/// restart, engine state is discarded on one.
///
/// One instance lives at RootView scope, fed by ONE poller. Never a poller per column.
@MainActor
final class KildStore: ObservableObject {
    /// Everything the engine reports. Read it directly for kilds, attention and collisions.
    let cockpit: Cockpit

    /// Forwards `Cockpit`'s change notifications into this object's.
    ///
    /// **Composition does not compose `ObservableObject`.** `@Published` synthesises a
    /// publisher on the type where the property is DECLARED, so mutating `cockpit.kilds`
    /// fires `Cockpit.objectWillChange` and nothing else. `KildStore` holds `cockpit` as a
    /// plain `let`, and no view observes `Cockpit` directly — so without this bridge the
    /// frame renders once with an empty engine and then freezes. Every poll would still run,
    /// still decode, still update state correctly, and never reach the screen: a UI that is
    /// wrong in a way no test and no log can see.
    ///
    /// The previous store held `rooms`/`archived` as its own `@Published` properties, so
    /// this was free. Splitting engine state into `Cockpit` is the right shape, but it makes
    /// the forwarding explicit work.
    private var cancellables = Set<AnyCancellable>()

    /// Where the open-workspace list is persisted — injectable so tests never touch
    /// the operator's real defaults.
    private let api: KildAPI
    private let defaults: UserDefaults

    /// The selected kild id — the sidebar drives it, the dock renders it (a selected kild
    /// wins the dock over any open artifact).
    @Published var selection: String?
    @Published var tab: KildsTab = .live
    /// Local archive search. The archive listing is already in hand, so filtering names and
    /// agents is immediate and needs no extra poll.
    ///
    /// It can no longer search message text: the archive carries **no log** — that was the
    /// most expensive listing in the engine and it was removed. Searching prose again would
    /// mean fetching every archived kild's messages, which is exactly the cost the removal
    /// bought back.
    @Published var historyQuery = ""
    /// Agent disclosure state, per workspace, persisted in its context.
    @Published var expandedKilds: Set<String> = []
    @Published private(set) var contexts: [String: WorkspaceContext]

    /// The kild named on the command line, if any.
    ///
    /// Held separately from `selection` because restoring a workspace context **overwrites**
    /// the selection — `applyContext` assigns it unconditionally. Reading the flag back out
    /// of `selection` therefore fails exactly when a context exists, which is the normal
    /// case, and fails silently: the harness captures whatever kild was selected last
    /// instead of the one it named, and nothing reports a problem.
    ///
    /// **Injected rather than read from `LaunchOptions` here**, and that is the whole point.
    /// Reading `ProcessInfo.arguments` directly made this permanently `nil` under
    /// `swift test`, so every line guarding it was structurally unreachable by the suite —
    /// including the test file written specifically to defend it, which passed while
    /// proving only the no-flag path. A test that cannot reach its own subject is worse
    /// than no test: it reports the branch as covered.
    private let launchKild: String?

    /// A `--kild` launch lands on History when the id is not live at first load; the first
    /// load corrects the tab once data arrives (testability seam).
    private var launchKildResolved: Bool

    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var selectedWorkspace: Workspace?
    /// The selected workspace's repo root — the main checkout even when the workspace is a
    /// worktree of it. Resolved off the main thread on selection (it shells out to git) and
    /// consumed by the artifact browser to preselect the matching `~/.prp` store.
    @Published private(set) var selectedWorkspaceRoot: String?

    init(
        api: KildAPI = KildHTTPClient(),
        defaults: UserDefaults = .standard,
        launchKild: String? = LaunchOptions.kildId
    ) {
        self.cockpit = Cockpit(api: api)
        self.api = api
        self.defaults = defaults
        self.launchKild = launchKild
        self.launchKildResolved = launchKild == nil
        self.selection = launchKild
        let restoredWorkspaces = WorkspacePersistence.load(from: defaults)
        let restoredContexts = WorkspaceContextStore.load(from: defaults)
        workspaces = restoredWorkspaces
        selectedWorkspace = WorkspacePersistence.loadSelection(
            from: defaults, in: restoredWorkspaces)
        contexts = restoredContexts
        cockpit.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        if let selectedWorkspace {
            applyContext(for: selectedWorkspace)
        }
        // An explicit `--kild` outranks whatever the restored context had selected.
        // Applied AFTER applyContext, which assigns `selection` unconditionally.
        if let launchKild { selection = launchKild }
    }

    // MARK: - What the sidebar shows

    /// Live kilds under the workspace filter, grouped and sorted.
    ///
    /// Attribution is `Kild.cwd` rather than a worktree-name lookup: `/api/worktrees` was
    /// deleted with no successor, and `cwd` is the project directory, persisted, present
    /// even on an orphan. One less request and one less way to be wrong.
    var shownGroups: [KildGroup: [Kild]] {
        let scoped =
            selectedWorkspace.map {
                WorkspaceAttribution.kilds(in: $0.path, from: cockpit.kilds)
            } ?? cockpit.kilds
        return Attention.grouped(scoped)
    }

    /// Archived kilds under the workspace filter, newest first, matching the search.
    var shownArchive: [ArchivedKild] {
        let scoped =
            selectedWorkspace.map {
                WorkspaceAttribution.archived(in: $0.path, from: cockpit.archive)
            } ?? cockpit.archive
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }
        return scoped.filter { $0.matchesSearch(query) }
    }

    /// The dock's tenant: the selection resolved against what is actually shown, so a kild
    /// hidden by the workspace filter yields the dock back to the artifact.
    var selectedKild: Kild? {
        shownGroups.values.flatMap { $0 }.first { $0.id == selection }
    }

    /// Collisions for the selected kild. Derived — label it as such wherever it renders.
    var selectedCollisions: [Collision] {
        selection.flatMap { cockpit.collisions[$0] } ?? []
    }

    /// How many agents are waiting on you, across every kild in the open workspace.
    var waitingCount: Int {
        let scoped =
            selectedWorkspace.map {
                WorkspaceAttribution.kilds(in: $0.path, from: cockpit.kilds)
            } ?? cockpit.kilds
        return Attention.waitingCount(in: scoped)
    }

    // MARK: - Workspaces

    /// Open a folder as a workspace and select it. Opening one already open just
    /// selects it — the normalised path is the identity, so this cannot duplicate.
    func open(_ workspace: Workspace) {
        if !workspaces.contains(workspace) {
            workspaces.append(workspace)
            WorkspacePersistence.save(workspaces, to: defaults)
        }
        select(workspace)
    }

    /// Drop a workspace from the list. Purely local — there was never a
    /// registration, so there is nothing to unregister engine-side.
    func close(_ workspace: Workspace) {
        workspaces.removeAll { $0 == workspace }
        WorkspacePersistence.save(workspaces, to: defaults)
        contexts[workspace.path] = nil
        WorkspaceContextStore.save(contexts, to: defaults)
        if selectedWorkspace == workspace { select(nil) }
    }

    /// Saves the current workspace's UI state before changing the filter.
    /// TerminalManager retains the resources themselves; only their IDs and
    /// selection are context state.
    func saveContext(terminalManager: TerminalManager, artifact: ArtifactPaneModel) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        let workspaceSessions = terminalManager.sessions(for: workspace.path)
        context.terminalSessionIDs = workspaceSessions.map(\.id)
        context.selectedTerminalID =
            terminalManager.selected?.workspacePath == workspace.path
            ? terminalManager.selectedID : nil
        context.selectedKildID = selection
        context.kildsTab = tab
        context.historyQuery = historyQuery
        context.expandedKilds = expandedKilds
        context.openArtifactPath = artifact.document?.url.path
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func applyContext(for workspace: Workspace) {
        let context = contexts[workspace.path] ?? WorkspaceContext()
        selection = context.selectedKildID
        tab = context.kildsTab
        historyQuery = context.historyQuery
        expandedKilds = context.expandedKilds
    }

    func composerDraft(for kildID: String) -> String {
        guard let workspace = selectedWorkspace else { return "" }
        return contexts[workspace.path]?.composerDrafts[kildID] ?? ""
    }

    func setComposerDraft(_ draft: String, for kildID: String) {
        guard let workspace = selectedWorkspace else { return }
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.composerDrafts[kildID] = draft.isEmpty ? nil : draft
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func cacheBranch(_ branch: String?, for workspace: Workspace) {
        var context = contexts[workspace.path] ?? WorkspaceContext()
        context.branch = branch
        context.branchResolved = true
        contexts[workspace.path] = context
        WorkspaceContextStore.save(contexts, to: defaults)
    }

    func select(_ workspace: Workspace?) {
        selectedWorkspace = workspace
        selectedWorkspaceRoot = nil
        WorkspacePersistence.saveSelection(workspace, to: defaults)
        guard let workspace else { return }
        applyContext(for: workspace)
        Task { await refreshWorkspaceRoot() }
    }

    /// The repo root the selected workspace's `~/.prp` store is keyed by.
    ///
    /// Shorter than it was: resolving a workspace's kild worktrees needed a second request
    /// to `/api/worktrees`, which is gone. `Kild.cwd` answers it directly now, so only the
    /// git root resolution remains — and that runs once per selection, never per render.
    private func refreshWorkspaceRoot() async {
        guard let selectedWorkspace, selectedWorkspaceRoot == nil else { return }
        let path = selectedWorkspace.path
        let root = await Task.detached { WorkspaceStore.repositoryRoot(for: path) }.value
        guard self.selectedWorkspace == selectedWorkspace else { return }
        selectedWorkspaceRoot = root
    }

    // MARK: - The selected agent

    /// An agent within the selected kild, when one is open.
    ///
    /// Separate from `selection` rather than folded into it. A kild id and an agent handle
    /// are different identifiers for different objects, and the observe column already
    /// proved what happens when they share one binding: a handle lands where a kild id
    /// belongs and the dock silently empties.
    @Published var selectedAgent: String?

    /// Lines for the selected agent, from whichever source its ownership dictates.
    @Published private(set) var agentLines: [Conversation.Line] = []
    @Published private(set) var agentLinesError: String?
    @Published private(set) var isLoadingAgent = false

    /// Monotonic token for agent loads — see `openAgent` for why a handle comparison is
    /// not sufficient.
    private var agentLoad = 0

    /// Open an agent's conversation.
    ///
    /// The source is decided by `ownership`, not by trying the transcript and falling back:
    /// an attached agent has no pi session, so asking for its transcript is a question the
    /// engine can only refuse. Reading `Conversation.source` first means helm never sends a
    /// request it knows will fail, and never renders a refusal as though it were an error.
    func openAgent(_ agent: Agent, in kild: Kild) async {
        agentLoad += 1
        let load = agentLoad
        selectedAgent = agent.handle
        agentLines = []
        agentLinesError = nil
        isLoadingAgent = true

        // Only the newest load may write. Comparing the HANDLE after the await is not
        // enough: open A, open B, open A again, and A's first request — still in flight,
        // holding content from before B — lands to find the handle equal again and is
        // accepted as current. The guard sees the value it expects but not the same
        // instance of it, which a counter cannot be fooled by.
        func isCurrent() -> Bool { load == agentLoad }
        defer { if isCurrent() { isLoadingAgent = false } }

        do {
            let lines: [Conversation.Line]
            switch Conversation.source(for: agent) {
            case .transcript:
                // Chosen by `ownership` BEFORE the request. An attached agent has no pi
                // session, so this route can only refuse — trying it and falling back would
                // render a correct refusal as an error.
                let transcript = try await api.transcript(of: agent.handle, in: kild.id)
                lines = Conversation.lines(from: transcript)
            case .routedMessages:
                let log = try await api.messages(in: kild.id, since: nil)
                lines = Conversation.lines(for: agent.handle, from: log)
            }
            guard isCurrent() else { return }
            agentLines = lines
        } catch {
            guard isCurrent() else { return }
            agentLines = []
            agentLinesError = error.localizedDescription
        }
    }

    /// Close the agent view and return the dock to the kild.
    func closeAgent() {
        // Bump the token so a load still in flight cannot write into a closed view.
        agentLoad += 1
        selectedAgent = nil
        agentLines = []
        agentLinesError = nil
        isLoadingAgent = false
    }

    /// Send to an agent. There is no unlogged path — every instruction is in the log,
    /// attributed, because the engine spawns agents with pipes and there is no PTY to type
    /// into.
    func send(_ text: String, to handle: String, in kild: Kild.ID) async {
        do {
            try await api.send(to: [handle], text: text, in: kild)
            if selectedAgent == handle, let k = selectedKild { await reopenAgent(handle, in: k) }
        } catch {
            agentLinesError = error.localizedDescription
        }
    }

    private func reopenAgent(_ handle: String, in kild: Kild) async {
        guard let agent = kild.agents.first(where: { $0.handle == handle }) else { return }
        await openAgent(agent, in: kild)
    }

    // MARK: - Disposal

    /// The outcome of the last disposal attempt, for the UI to report.
    ///
    /// Held rather than thrown because all three outcomes are worth showing and only one is
    /// an error: it worked, the guard refused and said why, or it timed out and **may have
    /// happened anyway**.
    /// **Every case names the kild it is about.**
    ///
    /// It did not, and that was a latent bug of the kind this branch keeps producing: only
    /// `.removed` carried an id, so a slow refusal for kild A landing after a fast success
    /// for kild B would overwrite B's result with an unattributed message about A. Nothing
    /// reads this yet, which is exactly when it is cheap to fix — the moment a banner is
    /// wired to it, it reports the wrong kild and nobody can tell.
    enum DisposalOutcome: Equatable {
        case removed(kild: Kild.ID, report: DisposalReport)
        /// The guard declined. Not a failure — this is the mechanism working, and the
        /// message names what is at stake.
        case refused(kild: Kild.ID, reason: String)
        /// The engine did not answer in time. The tree may be gone. Never offer a retry.
        case unknown(kild: Kild.ID, message: String)

        /// Which kild this outcome describes, so a stale one can be discarded rather than
        /// shown against the wrong row.
        var kild: Kild.ID {
            switch self {
            case let .removed(kild, _), let .refused(kild, _), let .unknown(kild, _): kild
            }
        }
    }

    @Published var lastDisposal: DisposalOutcome?

    /// Remove a kild's worktree, reclaiming its disk.
    ///
    /// `force` overrides the unlanded-commit guard and nothing else. It cannot lose
    /// commits — the `kild/<worktree>` branch survives every path — which is why offering
    /// it is reasonable at all.
    ///
    /// The kild is NOT removed from local state on success. The next poll reports what the
    /// engine actually holds; removing it here would be helm asserting an outcome instead of
    /// observing one, and it is exactly the drift this store exists to avoid.
    func dispose(_ kild: Kild, force: Bool = false) async {
        do {
            let report = try await api.delete(kild.id, force: force)
            lastDisposal = .removed(kild: kild.id, report: report)
            await loadIdentities()
        } catch let error as KildAPIError {
            switch error {
            case .outcomeUnknown:
                lastDisposal = .unknown(
                    kild: kild.id, message: error.errorDescription ?? "outcome unknown")
                // Refresh anyway: the engine may well have completed it, and the poll is
                // the only way to find out which.
                await loadIdentities()
            default:
                lastDisposal = .refused(
                    kild: kild.id, reason: error.errorDescription ?? "refused")
            }
        } catch {
            lastDisposal = .refused(kild: kild.id, reason: error.localizedDescription)
        }
    }

    // MARK: - Polling

    /// The cheap tick: identity, agents, attention. Safe to run often.
    func loadIdentities() async {
        await cockpit.checkBoot()
        await cockpit.refreshIdentities()
    }

    /// The costly tick: git and cost, one subprocess per kild. Belongs on a slower cadence.
    func loadStatus() async {
        await cockpit.refreshStatus()
    }

    func loadArchive() async {
        await cockpit.refreshArchive()
        // Resolve ONLY on a successful fetch. `refreshArchive` swallows its own failure and
        // leaves `archive` untouched, so a failed call is indistinguishable from an empty
        // archive — and resolving against it would consume the one-shot flag while
        // answering nothing. That is the third time this function has been wrong in the
        // same way: first the readiness signal was the wrong list, then there was no
        // failure signal at all. The flag must only be spent by a call that could actually
        // answer the question.
        guard cockpit.errors[.archive] == nil else { return }
        resolveLaunchSelection()
    }

    /// A `--kild` launch that names an archived kild should land on History rather than
    /// showing an empty Live tab.
    ///
    /// Called ONLY from `loadArchive()`, and that is the whole correctness condition. An
    /// earlier version ran from `loadIdentities()` too and gated on
    /// `!kilds.isEmpty || !archive.isEmpty` — treating "live kilds arrived" as proof that
    /// data had arrived, when the question it answers needs the ARCHIVE. Identities land
    /// first, the OR passed on a non-empty live list, the archive was still `[]`, so the
    /// lookup found nothing — and it set `launchKildResolved = true` anyway, making the
    /// later archive load a no-op. On any engine with at least one live kild, which is every
    /// real one, the flip never happened.
    private func resolveLaunchSelection() {
        // Reads the FLAG, not `selection` — a restored context may have replaced the
        // selection since launch, and flipping to History for a kild the operator never
        // named is worse than not flipping at all.
        guard !launchKildResolved, let id = launchKild else { return }
        if cockpit.archive.contains(where: { $0.id == id }) { tab = .history }
        launchKildResolved = true
    }
}

extension ArchivedKild {
    /// Archive search over what the listing actually carries.
    ///
    /// Names and agent handles only. The archive no longer ships its log — that was the
    /// engine's most expensive listing, and removing it is what made "list my stopped
    /// kilds" stop meaning "send me every conversation I have ever had". Searching prose
    /// would mean fetching every archived kild's messages, which spends exactly what the
    /// removal saved.
    func matchesSearch(_ query: String) -> Bool {
        var fields = [id, name]
        if let worktree { fields.append(worktree) }
        fields.append(
            contentsOf: agents.flatMap { [$0.handle, $0.persona, $0.model].compactMap { $0 } })
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
