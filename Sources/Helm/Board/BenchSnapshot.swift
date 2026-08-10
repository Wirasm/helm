import Foundation
import HelmWire

/// The agent-readable projection of helm's current bench.
///
/// This is reporting state, never restore state. `WorkspaceContext.workbench` remains the
/// persistence authority; a reader uses `writtenAt` to decide whether this file is fresh.
struct BenchSnapshot: Codable, Equatable {
    /// Everything except *when it was written*. `BenchSnapshotModel` skips a write whose content
    /// is unchanged, so that `writtenAt` is a change signal rather than a heartbeat — and the one
    /// field that always differs must not be what decides it.
    func sameContent(as other: BenchSnapshot) -> Bool {
        BenchSnapshot(writtenAt: other.writtenAt, workspaces: workspaces) == other
    }

    static let currentFormat = "helm.bench-snapshot"
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
        addressBook: AddressBook,
        foregroundPid: (TerminalSession) -> pid_t? = { $0.hostView.foregroundPid },
        agents: [pid_t: AgentSession] = [:]
    ) -> BenchSnapshot {
        let mountedPath = workbench.workspacePath
        return BenchSnapshot(
            writtenAt: writtenAt,
            workspaces: workspaces.workspaces.map { workspace in
                let mounted = workspace.path == mountedPath
                let bench =
                    mounted
                    ? workbench.bench
                    : workspaces.contexts[workspace.path.value]?.workbench
                        ?? Workbench.migrating(
                            from: workspaces.contexts[workspace.path.value] ?? WorkspaceContext())
                return WorkspaceRecord(
                    workspace: workspace,
                    state: mounted ? .mounted : .parked,
                    bench: bench,
                    // Only the mounted workspace can have an open question — the model holds
                    // one workspace at a time, and a parked one's arrangement is a value
                    // nothing can be asked about.
                    offer: mounted ? workbench.restoreOffer : nil,
                    // Only the mounted workspace's panes can carry a live offer, for
                    // `offer:`'s reason one line up — `resumeOffers` is this launch's question
                    // about the workspace the model currently holds. A parked workspace's
                    // *record* still shows, because that is on the bench and outlives a mount.
                    resumeOffers: mounted ? workbench.resumeOffers : [:],
                    sessions: terminals.sessions(for: workspace.path),
                    addressBook: addressBook,
                    foregroundPid: foregroundPid,
                    agents: agents)
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
        /// Present when this workspace is mounted but **waiting on the operator to say whether
        /// to restore its saved bench** (#85). Then `columns` is empty — nothing is built while
        /// the question is open — and without this field a reader could not tell that from a
        /// workspace helm simply has nothing for.
        ///
        /// **An added optional rather than a third `state`.** `State` is a `String` enum agents
        /// outside the process already decode; a new case would fail their decoder, where an
        /// unknown key is ignored. The version does not move for the same reason — this is
        /// additive, and `format`/`version` exist to announce a change a reader must handle.
        let awaitingRestore: RestoreOfferRecord?

        @MainActor
        init(
            workspace: Workspace,
            state: State,
            bench: Workbench?,
            offer: BenchRestoreOffer? = nil,
            resumeOffers: [Pane.ID: AgentResumeOffer] = [:],
            sessions: [TerminalSession],
            addressBook: AddressBook,
            foregroundPid: (TerminalSession) -> pid_t?,
            agents: [pid_t: AgentSession] = [:]
        ) {
            path = workspace.path
            name = workspace.name
            self.state = state
            awaitingRestore = offer.map(RestoreOfferRecord.init)
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
                    resumeOffers: resumeOffers,
                    addressBook: addressBook,
                    foregroundPid: foregroundPid,
                    agents: agents)
            }
        }
    }

    /// What the operator is being asked, for a reader that is not the operator (#85).
    ///
    /// The counts and nothing else. A reader has no way to answer the question — there is no
    /// spool kind for it, deliberately, because *"a question nobody will be there to answer
    /// must be answered in advance"* cuts both ways and an agent answering the operator's own
    /// question about their own bench is the seizure #85 exists to remove. What it can do is
    /// stop reading an empty `columns` as an empty helm.
    struct RestoreOfferRecord: Codable, Equatable {
        let paneCount: Int
        let terminalCount: Int
        let canvasCount: Int
        let agentCount: Int

        init(_ offer: BenchRestoreOffer) {
            paneCount = offer.paneCount
            terminalCount = offer.terminalCount
            canvasCount = offer.canvasCount
            agentCount = offer.agentCount
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
            resumeOffers: [Pane.ID: AgentResumeOffer],
            addressBook: AddressBook,
            foregroundPid: (TerminalSession) -> pid_t?,
            agents: [pid_t: AgentSession] = [:]
        ) {
            id = column.id
            width = column.width
            slots = column.slots.map { slot in
                SlotRecord(
                    slot: slot,
                    mounted: focusedSlot != nil,
                    focused: slot.id == focusedSlot,
                    live: live,
                    resumeOffers: resumeOffers,
                    addressBook: addressBook,
                    foregroundPid: foregroundPid,
                    agents: agents)
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
            resumeOffers: [Pane.ID: AgentResumeOffer],
            addressBook: AddressBook,
            foregroundPid: (TerminalSession) -> pid_t?,
            agents: [pid_t: AgentSession] = [:]
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
                    offer: resumeOffers[pane.id],
                    addressBook: addressBook,
                    foregroundPid: foregroundPid,
                    agents: agents)
            }
        }
    }

    struct PaneRecord: Codable, Equatable {
        enum Kind: String, Codable { case terminal, canvas }

        let id: UUID
        let kind: Kind
        let isSelected: Bool
        let isVisible: Bool
        let isFocused: Bool
        let terminal: TerminalRecord?
        let canvas: CanvasRecord?

        @MainActor
        init(
            pane: Pane,
            selected: Bool,
            visible: Bool,
            focused: Bool,
            live: TerminalSession?,
            offer: AgentResumeOffer? = nil,
            addressBook: AddressBook,
            foregroundPid: (TerminalSession) -> pid_t?,
            agents: [pid_t: AgentSession] = [:]
        ) {
            id = pane.id
            isSelected = selected
            isVisible = visible
            isFocused = focused
            switch pane.content {
            case let .terminal(_, resumable):
                kind = .terminal
                terminal = TerminalRecord(
                    id: pane.id,
                    session: live,
                    resumable: resumable,
                    offer: offer,
                    addressBook: addressBook,
                    foregroundPid: foregroundPid,
                    agents: agents)
                canvas = nil
            case let .canvas(source):
                kind = .canvas
                terminal = nil
                canvas = CanvasRecord(source: source)
            }
        }
    }

    /// One pane's #63 state, for a reader that is not the operator.
    ///
    /// **A reader cannot answer this either**, exactly as it cannot answer `awaitingRestore` —
    /// there is no spool kind for accepting a resume, and an agent resurrecting a conversation
    /// the operator has not asked for is the seizure #63's whole "offer, not push" exists to
    /// remove. What it can do is stop reading a restored shell as an ordinary one, and stop
    /// waiting on a pane whose agent is never coming back on its own.
    ///
    /// `blockedReason` is a **bare string, not a `Codable` enum**, for `WorkspaceRecord.State`'s
    /// reason spelled the other way round: a `String` enum would make a *new* reason fail an
    /// existing reader's decoder, where an unrecognised string is something a reader can print.
    /// The values are `AgentResumeOffer.Blocked`'s own names.
    struct ResumableRecord: Codable, Equatable {
        /// The runtime, its conversation id, and where it was working — `ResumableAgent`'s three
        /// fields, so a reader sees exactly what helm persisted rather than a summary of it.
        let command: String
        let session: String
        let cwd: String
        /// Whether the operator is being shown this pane's offer **right now**. False means the
        /// record is on the bench but no question is open — the agent is already running there,
        /// the workspace is parked, or the offer has been answered.
        let isOffered: Bool
        /// Why helm will not run the resume, when an offer is open and it will not. Absent
        /// means it will: `transcriptGone`, or `runtimeUnknown`.
        let blockedReason: String?

        init(_ agent: ResumableAgent, offer: AgentResumeOffer?) {
            command = agent.command
            session = agent.session
            cwd = agent.cwd
            isOffered = offer != nil
            switch offer?.blocked {
            case nil: blockedReason = nil
            case .transcriptGone: blockedReason = "transcriptGone"
            case .runtimeUnknown: blockedReason = "runtimeUnknown"
            }
        }
    }

    struct TerminalRecord: Codable, Equatable {
        let sessionId: UUID
        let isLive: Bool
        let status: String?
        let failure: String?
        let title: String?
        let foregroundPid: pid_t?
        let owner: OwnerRecord?
        /// What #63 recorded about this pane, and whether helm is asking about it right now.
        ///
        /// **The per-pane half of `awaitingRestore`**, and it is here for the reason that field
        /// is one level up: without it, a pane showing *"claude was running here — resume it?"*
        /// and a pane that never held an agent are byte-for-byte identical here — same
        /// `isLive: true`, same `status: "running"`, `owner: nil` in both. That is not
        /// hypothetical: proving #63 across a real restart, the snapshot could say the mount
        /// question was open and then had nothing at all to say about the offer that followed
        /// it, so the only way to see the offer was a screenshot.
        ///
        /// `resumeOffers` is one workspace's live question, so `isOffered` is only ever true on
        /// the mounted one. `resumable` is on the bench, so a **parked** workspace still reports
        /// what its panes were holding.
        let resumable: ResumableRecord?
        /// What the agent running in this pane says **it** is doing (#283). See `AgentRecord`.
        let agent: AgentRecord?

        @MainActor
        init(
            id: UUID,
            session: TerminalSession?,
            resumable: ResumableAgent? = nil,
            offer: AgentResumeOffer? = nil,
            addressBook: AddressBook,
            foregroundPid: (TerminalSession) -> pid_t?,
            agents: [pid_t: AgentSession] = [:]
        ) {
            sessionId = id
            isLive = session != nil
            self.resumable = resumable.map { ResumableRecord($0, offer: offer) }
            guard let session else {
                status = nil
                failure = nil
                title = nil
                self.foregroundPid = nil
                owner = nil
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
            case let .failed(issue):
                status = "failed"
                failure = issue
            }
            title = session.displayTitle
            let pid = foregroundPid(session)
            self.foregroundPid = pid
            // **The second join, and it goes through the same rule as the first (#247).** This
            // was `owners.first(where: { $0.pid == pid })` — a pid match with no liveness and no
            // identity behind it, so the first pid macOS recycled onto a live pane would put a
            // different agent's handle and session id into `snapshot.json`, the file agents
            // outside the process are told to trust. Two joins, one rule, spelled once in
            // `AddressBook`.
            owner = pid.flatMap { addressBook.owner(forPid: $0) }.map(OwnerRecord.init)
            // **The same pid, joined the direct way, and deliberately not through
            // `AddressBook`.** That value answers *which mailbox belongs to this process*, and
            // it earns its indirection because a recorded pid is neither identity nor liveness
            // (#247). This asks the registry about the pid helm is watching **right now**, which
            // is the direction `AgentRegistry.sessionLookup`'s own header says needs no liveness
            // check: the caller supplies a live foreground pid, so a row that matches carries
            // that same live number.
            agent = pid.flatMap { agents[$0] }.flatMap(AgentRecord.init)
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
    /// It does not have to. Claude Code publishes the answer itself, in the registry helm
    /// **already reads every publish** to join a pane to its mailbox: a session blocked on a
    /// dialog writes `status: "waiting"` with `waitingFor: "permission prompt"` into
    /// `~/.claude/sessions/<pid>.json`. Measured on a real stall, same run as the reproduction
    /// above. helm modelled that value in `AgentStatus` and then dropped it on the floor here,
    /// taking only `sessionId` out of the registry — so the only tell left outside the process
    /// was the whole snapshot's `writtenAt` going stale, which is second-order, and which #267
    /// deliberately made quiet.
    ///
    /// # The honest limits, because a reader has to know them
    ///
    /// - **Claude Code only.** pi and codex publish no registry, so their panes carry no record
    ///   at all — absence, never a false `idle`, which is `AgentRegistry`'s standing rule.
    /// - **`status` is one of the four names helm models**, and absent when the registry said
    ///   something this build does not. `waitingFor` still comes through in that case, and it is
    ///   the field that names the stall.
    /// - **`waiting` is not by itself a stall.** An agent that finished its turn and is waiting
    ///   for the operator is the healthy case. What distinguishes them is `waitingFor` — a
    ///   permission prompt is a question nobody at a spool-spawned pane will ever answer — and
    ///   how long it has been true.
    struct AgentRecord: Codable, Equatable {
        /// `busy`, `shell`, `idle` or `waiting`. See `AgentStatus`.
        let status: String?
        /// What it is waiting for, in Claude Code's own words. See `AgentSession.waitingFor`.
        let waitingFor: String?
        /// When `status` last changed — **a transition time, not a heartbeat**.
        ///
        /// **It is published as an absolute instant on purpose, and that is what makes this
        /// signal survive a snapshot nobody rewrote.** A stalled agent stops changing, so the
        /// last write of `snapshot.json` is the moment the stall began; `now - statusUpdatedAt`
        /// keeps growing correctly with no further writes, and a coordinator never has to poll
        /// `writtenAt` to notice. A precomputed *"quiet for N seconds"* would have been wrong the
        /// instant it was written down.
        let statusUpdatedAt: Date?

        /// `nil` when the row says nothing at all, so an empty record is never written.
        init?(_ session: AgentSession) {
            guard session.status != nil || session.waitingFor != nil else { return nil }
            status = session.status?.rawValue
            waitingFor = session.waitingFor
            statusUpdatedAt = session.statusUpdatedAt
        }
    }

    struct OwnerRecord: Codable, Equatable {
        /// A `Handle`, and read off the owner rather than copied out of it (#233). This was a
        /// second, untyped spelling of the concept `Handle` exists to carry, one file over from
        /// it and with no runtime boundary to make the duplicate honest — this file already
        /// imports `HelmWire`, and `init` below already has a `MailboxOwner` in hand, which is
        /// exactly `Handle(readingFrom:)`'s signature.
        ///
        /// The same wire obligation as `WorkspaceRecord.path` above comes with it: agents
        /// outside the process read this field, so `Handle` has to keep encoding it as the bare
        /// string it always was — a single-value container, proven by `BenchSnapshotTests
        /// .testOwnerRecordHandleEncodesAsABareStringUnchangedByHandle` rather than assumed.
        let handle: Handle
        let runtime: String?
        let pid: pid_t
        let sessionId: String?
        let cwd: String?

        init(_ owner: MailboxOwner) {
            handle = Handle(readingFrom: owner)
            runtime = owner.runtime
            pid = owner.pid
            sessionId = owner.sessionId
            cwd = owner.cwd
        }
    }

    struct CanvasRecord: Codable, Equatable {
        let source: CanvasSource
    }
}
