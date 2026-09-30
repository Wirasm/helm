import Foundation
import HelmWire

/// The agent-readable projection of helm's current bench.
///
/// This is reporting state, never restore state: benchd's document is the bench, and this adds
/// what only helm can see — ptys, titles, visibility, each agent's own status (plan D2 of #354).
/// A reader uses `writtenAt` to decide whether this file is fresh.
struct BenchSnapshot: Codable, Equatable {
    /// Everything except *when it was written*. `BenchSnapshotModel` skips a write whose content
    /// is unchanged, so that `writtenAt` is a change signal rather than a heartbeat — and the one
    /// field that always differs must not be what decides it.
    func sameContent(as other: BenchSnapshot) -> Bool {
        BenchSnapshot(writtenAt: other.writtenAt, workspaces: workspaces) == other
    }

    static let currentFormat = "helm.bench-snapshot"
    /// Still 1 after M5b dropped `awaitingRestore`, `isOffered` and `blockedReason` with #85's
    /// question: each was optional, and its absence reads as "no question open", which is now
    /// always true.
    static let currentVersion = 1

    let format: String
    let version: Int
    let writtenAt: Date
    let workspaces: [WorkspaceRecord]

    init(writtenAt: Date, workspaces: [WorkspaceRecord]) {
        format = Self.currentFormat
        version = Self.currentVersion
        self.writtenAt = writtenAt
        self.workspaces = workspaces
    }

    @MainActor
    static func project(
        writtenAt: Date,
        workspaces: WorkspaceModel,
        workbench: WorkbenchModel,
        terminals: TerminalManager,
        foregroundPid: (TerminalSession) -> pid_t? = { $0.foregroundPid }
    ) -> BenchSnapshot {
        let mountedPath = workbench.workspacePath
        return BenchSnapshot(
            writtenAt: writtenAt,
            workspaces: workspaces.workspaces.map { workspace in
                let mounted = workspace.path == mountedPath
                let bench =
                    mounted
                    ? workbench.bench
                    : workbench.document?.workspace(at: workspace.path)
                        .flatMap { Workbench(document: $0.bench) }
                return WorkspaceRecord(
                    workspace: workspace,
                    state: mounted ? .mounted : .parked,
                    bench: bench,
                    sessions: terminals.sessions(for: workspace.path),
                    foregroundPid: foregroundPid)
            })
    }

    struct WorkspaceRecord: Codable, Equatable {
        enum State: String, Codable { case mounted, parked }

        /// This field is read by agents outside the process against a versioned `format`, so
        /// `WorkspacePath`'s `Codable` has to keep encoding it as the bare string it always
        /// was — a single-value container, proven by `BenchSnapshotTests
        /// .testWorkspaceRecordPathEncodesAsABareStringUnchangedByWorkspacePath` rather than
        /// assumed.
        let path: WorkspacePath
        let name: String
        let state: State
        let columns: [ColumnRecord]
        @MainActor
        init(
            workspace: Workspace,
            state: State,
            bench: Workbench?,
            sessions: [TerminalSession],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            path = workspace.path
            name = workspace.name
            self.state = state
            guard let bench else {
                columns = []
                return
            }

            let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let focusedSlot = state == .mounted ? bench.focusedSlot : nil
            columns = bench.columns.map { column in
                ColumnRecord(
                    column: column,
                    focusedSlot: focusedSlot,
                    live: live,
                    foregroundPid: foregroundPid)
            }
        }
    }

    struct ColumnRecord: Codable, Equatable {
        let id: UUID
        let width: Double
        let slots: [SlotRecord]

        @MainActor
        init(
            column: Column,
            focusedSlot: Slot.ID?,
            live: [UUID: TerminalSession],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            id = column.id
            width = column.width
            slots = column.slots.map { slot in
                SlotRecord(
                    slot: slot,
                    mounted: focusedSlot != nil,
                    focused: slot.id == focusedSlot,
                    live: live,
                    foregroundPid: foregroundPid)
            }
        }
    }

    struct SlotRecord: Codable, Equatable {
        let id: UUID
        let height: Double
        let selectedPaneId: UUID
        let panes: [PaneRecord]

        @MainActor
        init(
            slot: Slot,
            mounted: Bool,
            focused: Bool,
            live: [UUID: TerminalSession],
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            id = slot.id
            height = slot.height
            selectedPaneId = slot.selected
            panes = slot.panes.map { pane in
                PaneRecord(
                    pane: pane,
                    selected: pane.id == slot.selected,
                    visible: mounted && pane.id == slot.selected,
                    focused: focused && pane.id == slot.selected,
                    live: live[pane.id],
                    foregroundPid: foregroundPid)
            }
        }
    }

    struct PaneRecord: Codable, Equatable {
        /// `browser` is a view onto the shared browser (#350); it carries neither record — the
        /// browser's own endpoint and tabs are benchd's and CDP's to report, not the bench's.
        /// `unsupported` is a pane benchd's document holds in a kind this build cannot show
        /// (#354); only a helm rendering from benchd has one. Additive, so the version stays.
        enum Kind: String, Codable {
            case terminal, canvas, browser, sessions, archon, worktrees, unsupported
        }

        let id: UUID
        let kind: Kind
        let isSelected: Bool
        let isVisible: Bool
        let isFocused: Bool
        let terminal: TerminalRecord?
        let canvas: CanvasRecord?
        /// Which kind benchd named, for an `unsupported` pane — what its tab shows. nil for
        /// every kind this build knows.
        let unsupportedKind: String?

        @MainActor
        init(
            pane: Pane,
            selected: Bool,
            visible: Bool,
            focused: Bool,
            live: TerminalSession?,
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            id = pane.id
            isSelected = selected
            isVisible = visible
            isFocused = focused
            switch pane.content {
            case let .terminal(resumable):
                kind = .terminal
                terminal = TerminalRecord(
                    id: pane.id,
                    session: live,
                    resumable: resumable,
                    foregroundPid: foregroundPid)
                canvas = nil
                unsupportedKind = nil
            case let .canvas(source):
                kind = .canvas
                terminal = nil
                canvas = CanvasRecord(source: source)
                unsupportedKind = nil
            case .browser:
                kind = .browser
                terminal = nil
                canvas = nil
                unsupportedKind = nil
            case .sessions:
                kind = .sessions
                terminal = nil
                canvas = nil
                unsupportedKind = nil
            case .archon:
                kind = .archon
                terminal = nil
                canvas = nil
                unsupportedKind = nil
            case .worktrees:
                kind = .worktrees
                terminal = nil
                canvas = nil
                unsupportedKind = nil
            case let .unsupported(named):
                kind = .unsupported
                terminal = nil
                canvas = nil
                unsupportedKind = named
            }
        }
    }

    /// The agent recorded in a pane (#63): what `bench restore` resumes there after benchd
    /// restarts (`just resume-all`). `ResumableAgent`'s three fields, so a reader sees exactly
    /// what the bench holds.
    struct ResumableRecord: Codable, Equatable {
        let command: String
        let session: String
        let cwd: String

        init(_ agent: ResumableAgent) {
            command = agent.command
            session = agent.session
            cwd = agent.cwd
        }
    }

    struct TerminalRecord: Codable, Equatable {
        let sessionId: UUID
        let isLive: Bool
        let status: String?
        let failure: String?
        let title: String?
        let foregroundPid: pid_t?
        /// The agent recorded in this pane: what `bench restore` resumes there. On the bench, so a
        /// parked workspace still reports it.
        let resumable: ResumableRecord?
        /// What the agent running in this pane says **it** is doing (#283). See `AgentRecord`.
        let agent: AgentRecord?

        @MainActor
        init(
            id: UUID,
            session: TerminalSession?,
            resumable: ResumableAgent? = nil,
            foregroundPid: (TerminalSession) -> pid_t?
        ) {
            sessionId = id
            isLive = session != nil
            self.resumable = resumable.map(ResumableRecord.init)
            guard let session else {
                status = nil
                failure = nil
                title = nil
                self.foregroundPid = nil
                agent = nil
                return
            }
            switch session.status {
            case .starting:
                status = "starting"
                failure = nil
            case .running:
                status = "running"
                failure = nil
            case .exited:
                status = "exited"
                failure = nil
            case let .failed(issue), let .unattachable(issue):
                status = "failed"
                failure = issue
            }
            title = session.displayTitle
            self.foregroundPid = foregroundPid(session)
            // What the pane's agent reports and whether benchd sees it waiting, both from
            // benchd's `sessions` (M5c). Which agent is in the pane and its mailbox are benchd's
            // to answer too (`bench mail who`, #358).
            agent = AgentRecord.of(
                report: session.report.flatMap(AgentRecord.init), waiting: session.waiting)
        }
    }

    /// What the agent running in this pane says **it** is doing — its own report, not helm's
    /// guess (#283).
    ///
    /// # Why this exists
    ///
    /// #179 gave every spool-spawned agent the operator's unattended posture, because *"a prompt
    /// in a pane nobody is watching is indistinguishable from an agent that never started"*. A
    /// posture removes prompts; it turns out it cannot remove all of them. Claude Code marks some
    /// of its own guardrails **bypass-immune** — measured in the shipped 2.1.226 binary,
    /// `CIRCUIT_BREAKER_TRAITS.dangerousRemoval = { bypassImmune: true }` — and the refusal says
    /// so in its own words: *"This requires explicit approval and cannot be auto-allowed by
    /// permission rules."* Reproduced 2026-08-10 under `claude --dangerously-skip-permissions`,
    /// which is the posture verbatim: `rm "$d"/*.json` raised *"Dangerous rm operation on
    /// possibly-empty variable path"* and sat there. In the incident it sat there for **six and a
    /// half hours**. So this is not a posture that is missing a flag, and no flag would have
    /// helped — the answer had to be **detection**.
    ///
    /// # Why it is the agent's word and not a heuristic
    ///
    /// #283 asks whether helm can tell *waiting at a prompt* from *thinking hard*, and answers
    /// that from the outside it may not be able to. From the **pty** it cannot: the vendored
    /// wrapper surfaces parsed actions, not bytes — title, bell, OSC 9;4 progress, OSC 133
    /// command-finished, OSC 9/777 — and an agent frozen on a modal emits none of them, so
    /// "nothing has been written for N minutes" is not a question helm can ask at all.
    ///
    /// It does not have to. Claude Code publishes the answer itself: a session blocked on a
    /// dialog writes `status: "waiting"` with `waitingFor: "permission prompt"` into
    /// `~/.claude/sessions/<pid>.json`. Measured on a real stall, same run as the reproduction
    /// above. benchd reads that row for the process in the pane's session, on its own machine,
    /// and hands it to helm as the session's `report` (M5c); helm reads no registry itself.
    ///
    /// # The honest limits, because a reader has to know them
    ///
    /// - **The agent's own report, plus benchd's `waiting` (M1, #357).** The report is Claude
    ///   Code's registry row, else the agent's last hook, so a pi or codex whose hooks are wired
    ///   (`bench wiring`) has one too. A pane whose agent reports nothing carries a record only
    ///   while benchd sees it waiting on the operator (a prompt on its screen) — otherwise
    ///   absence, never a false `idle`.
    /// - **`status` is one of the four names helm models**, and absent when the agent said
    ///   something else. `waitingFor` still comes through in that case, and it is the field that
    ///   names the stall. A registry row whose status benchd does not know is no report at all.
    /// - **`waiting` is not by itself a stall.** An agent that finished its turn and is waiting
    ///   for the operator is the healthy case. What distinguishes them is `waitingFor` — a
    ///   permission prompt is a question nobody at a spool-spawned pane will ever answer — and
    ///   how long it has been true.
    struct AgentRecord: Codable, Equatable {
        /// `busy`, `shell`, `idle` or `waiting`.
        let status: String?
        /// What it is waiting for, in the agent's own words: `"permission prompt"`, `"input
        /// needed"`, `"dialog open"`, … A bare string, since a reason this build has never heard
        /// of is still something a reader can print.
        let waitingFor: String?
        /// When `status` **or `waitingFor`** last changed — **a transition time, not a
        /// heartbeat**. Measured against Claude Code 2.1.226: a forced non-status write
        /// (`/rename`) left it alone, twelve minutes of a working session never moved it, and an
        /// `idle → busy → idle` moved it at each transition. A hook's report is dated when its
        /// activity last changed, which is the same kind of time.
        ///
        /// **That it also moves on a `waitingFor` change is better for this use, not worse**, and
        /// worth stating rather than glossing: #283 is *waiting for **this** since T*, so a prompt
        /// replaced by a different prompt **should** restart the age. A reader told only "when
        /// `status` changed" would conclude the opposite.
        ///
        /// **It is published as an absolute instant on purpose, and that is what makes this
        /// signal survive a snapshot nobody rewrote.** A stalled agent stops changing, so the
        /// last write of `snapshot.json` is the moment the stall began; `now - statusUpdatedAt`
        /// keeps growing correctly with no further writes, and a coordinator never has to poll
        /// `writtenAt` to notice. A precomputed *"quiet for N seconds"* would have been wrong the
        /// instant it was written down.
        ///
        /// **The cost, said plainly rather than discovered later: `snapshot.json` is now rewritten
        /// about as often as a watched agent changes state, bounded by the two-second poll.** This
        /// field is ordinary content, so it goes through `sameContent(as:)` like everything else,
        /// and while an agent is actively turning over its `busy`/`idle` flips are real changes —
        /// so #267's dedupe stops suppressing much for the duration. That is the trade #283 asks
        /// for by name and not a regression of #267: what #267 removed was a `writtenAt` that
        /// advanced when **nothing had happened**, and an agent stopping is the thing that
        /// happened. `BenchSnapshotModelTests` holds both halves — the no-change control still
        /// writes nothing, and a status transition alone still writes.
        let statusUpdatedAt: Date?

        /// The record for what the agent reports. `status` is kept only when it is one of the
        /// four names; `nil` when that leaves nothing to say, so an empty record is never written.
        init?(_ report: BenchLiveSessions.Report) {
            let named = ["busy", "shell", "idle", "waiting"].contains(report.activity)
            guard named || report.waitingFor != nil else { return nil }
            status = named ? report.activity : nil
            waitingFor = report.waitingFor
            statusUpdatedAt = report.since
        }

        init(status: String?, waitingFor: String?, statusUpdatedAt: Date?) {
            self.status = status
            self.waitingFor = waitingFor
            self.statusUpdatedAt = statusUpdatedAt
        }

        /// The pane's record from the agent's report and benchd's `waiting` (M1, #357). The
        /// report keeps its own words when it already says what it waits for; otherwise
        /// benchd's wait stands, which is how an agent with no report at a prompt, a Claude trust
        /// prompt before the session registers, or a Claude registry row left saying `busy` (or a
        /// bare `waiting`) under a prompt (#283) gets a record that names the wait. With no wait
        /// from benchd the report is published as it is: a bare `waiting` is a finished turn,
        /// which is not a stall, and benchd does not count it either.
        static func of(
            report: AgentRecord?, waiting: BenchLiveSessions.Waiting?
        ) -> AgentRecord? {
            guard let waiting, report?.status != "waiting" || report?.waitingFor == nil
            else { return report }
            return AgentRecord(
                status: "waiting", waitingFor: waiting.waitingFor, statusUpdatedAt: waiting.since)
        }
    }

    struct CanvasRecord: Codable, Equatable {
        let source: CanvasSource
    }
}
