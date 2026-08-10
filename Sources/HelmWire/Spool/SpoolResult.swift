import Foundation

/// What helm writes back about a request, at `results/<id>.json`.
///
/// **A request channel with no response is half a protocol.** Without this the caller learns
/// which agent it started by polling `~/.claude/sessions/` for *"a new row whose pid descends
/// from that terminal and whose cwd matches"* — which is what `helm-spawn` does, and it is a
/// heuristic: two agents starting in one directory at the same time misattribute, and a
/// worktree makes that ordinary rather than exotic. helm is the one party that cannot get it
/// wrong, because it created the terminal and therefore knows the pid.
///
/// **Results live in their own directory** because the request file is deleted on claim. The
/// response has to outlive it, and exactly-once still holds.
///
/// **Lives in `HelmWire` (#221)**, alongside `SpoolRequest`, for the same reason: `Helm`'s own
/// `SpoolModel` writes this and `HelmTests` decodes it, both against one definition. The
/// standalone `helm-spool`/`helm-close`/`helm-capture`/`helm-command`/`helm-select`/`helm-name`
/// scripts still
/// read `json["status"] as? String` — they cannot `import HelmWire` (`AGENTS.md`'s "Why the spool
/// is a script, and must
/// stay one") — so a new `Status` case is not automatically visible to them; a caller adding one
/// has to update the scripts' string switches by hand, same as before #221.
package struct SpoolResult: Codable, Equatable {
    /// The life of one request, as the caller sees it.
    ///
    /// **`started` and `ready` are two writes to one file, and that is the design decision
    /// #54 asks to be made explicitly.** A mailbox is claimed by the agent's own
    /// `SessionStart` hook *after* the session comes up, so at the moment helm has a terminal
    /// there is no `owner.json` yet and no handle to report. The issue lists three answers:
    /// wait for the claim before writing anything; write twice; or make the caller resolve it.
    ///
    /// This is the second, for one reason that outranks the others: **a refusal and a slow
    /// start must never look the same from outside.** Waiting for the claim means an accepted
    /// request writes nothing for as long as an agent takes to boot, which is indistinguishable
    /// from helm not running, from the request never being seen, and from a watcher that is
    /// switched off. Writing `started` within milliseconds says *"I have this, here is your
    /// terminal"* and leaves only one thing outstanding. The cost is real and is paid by the
    /// caller: it waits for a **change**, not for a file to appear. `helm-spool` absorbs that,
    /// which is what a small CLI is for.
    ///
    /// The third answer — the caller resolves the handle — is the one this type exists to
    /// avoid: it puts the `~/.helm/mail` scan back into every caller, and a caller that gets
    /// it wrong gets it silently wrong (see `MailboxDirectory`).
    /// `CaseIterable` so `SpoolWireConformanceTests` can iterate every case rather than a
    /// sample: a new case added here without a matching switch arm in that test's exhaustive
    /// `expectation(for:)` is a compile error there, not a gap nobody notices.
    package enum Status: String, Codable, CaseIterable {
        /// A terminal exists in helm and the launch line has been written into its pty. No
        /// handle yet — the agent has not claimed a mailbox.
        case started
        /// The agent claimed a mailbox. `pid`, `sessionId`, `handle` and `runtime` are real,
        /// and the caller can address it now.
        case ready
        /// helm drew its own window and wrote a PNG (#174). **One write, not two** — unlike a
        /// spawn there is nothing outstanding after it, because drawing is synchronous and
        /// there is no second party to wait for. `capture` says what is in the image, including
        /// what is not.
        case captured
        /// The pane is off the bench and its pty is gone (#176). **One write**, like
        /// `captured` and unlike a spawn: closing is synchronous and there is no second party
        /// to wait for. `terminalId` is the pane that went and `pid` is what was in it.
        ///
        /// **`pid` is absent when the pane held a canvas (#284)**, because there was no process
        /// in it to name — the pane is off the bench and the artifact file and its `.notes.md`
        /// sidecar are exactly where they were. A caller reading `pid` gets the honest answer to
        /// *"what did I just destroy"*, which for a canvas is nothing.
        ///
        /// A close that was **refused** is `refused`, not this — a pane the operator is in, a
        /// pane with live work and no `force`, a uuid helm holds no pane for. That is the
        /// distinction #176 asks for by name: a teardown that silently did nothing is
        /// indistinguishable from helm not running.
        case closed
        /// helm carried out one of its own commands on the bench (#269). **One write**, like
        /// `captured` and `closed`: a command is applied synchronously to the bench value and
        /// there is no second party to wait for. `command` says which one ran and what the
        /// bench looks like after it.
        ///
        /// A command an agent may not send is `refused`, not this — and so is a command name
        /// this build does not have. The two are told apart by their `reason`, which is the
        /// whole of `SpoolCommandPolicy`.
        case ran
        /// The pane is the one its slot is showing, and the keyboard did not move (#284).
        /// **One write**, like `captured`, `closed` and `ran`: selecting is applied synchronously
        /// to the bench value and there is no second party to wait for. `select` says which pane,
        /// whether it is now visible, and where the keyboard was on each side of it.
        ///
        /// Written just as readily when the pane was **already** showing. That is not a lie about
        /// having done something: the caller asked for a state, the state holds, and the report
        /// says so — which is what an agent re-pushing an artifact (#272) actually wants to know.
        ///
        /// A select that was **refused** is `refused`, not this — a pane in the operator's own
        /// slot, or a uuid helm holds no pane for.
        case selected
        /// The pane is called what the request asked for (#313). **One write**, like `captured`,
        /// `closed`, `ran` and `selected`: naming is applied synchronously to the bench value and
        /// there is no second party to wait for. `name` says what it was called before and what
        /// it is called now.
        ///
        /// Written just as readily when the pane already had that name — the caller asked for a
        /// state and the state holds, which is `selected`'s argument and the same one.
        ///
        /// A name that was **refused** is `refused`, not this — a pane somebody has already named
        /// and no `rename`, a name that is empty or oversized or full of control characters, or a
        /// uuid helm holds no pane for.
        case named
        /// The terminal is alive but no mailbox appeared before the deadline. Deliberately
        /// **not** a failure and deliberately not cleaned up: the agent may be running
        /// perfectly well without the mail hooks installed. It exists; it cannot be
        /// addressed; `reason` says so.
        case unclaimed
        /// The request was read and refused — a command outside the allowlist, a cwd that is
        /// not there, an unparseable file. Nothing was started.
        case refused
        /// helm accepted the request and could not carry it out. `reason` says why.
        case failed
        /// The request was claimed, helm stopped before acting, and it was **not** re-run on
        /// restart. Exactly-once is the promise; a re-run after a crash mid-spawn is precisely
        /// the double-open #54 forbids. So the caller is told rather than left waiting.
        case abandoned
    }

    package let id: String
    package var status: Status
    /// `TerminalSession.id` — the same uuid the pane is persisted under, and the same one the
    /// child reads as `HELM_PANE` (`PaneEnvironment`). A `TerminalID` rather than a `UUID`
    /// directly, so it carries its own bare-string wire shape instead of the `.uuidString`
    /// every call site used to write out by hand — see `TerminalID`.
    package var terminalId: TerminalID?
    /// The pty's foreground pid once the agent is running. helm knows this authoritatively.
    ///
    /// On a `closed` result it is what was in the pane at the moment it went — the login shell
    /// when the pane was idle, the program that was running when `force` was used. That is the
    /// honest answer to *"what did I just destroy"*, and it costs no new field.
    package var pid: Int32?
    /// The agent's own id for its session, read out of `owner.json` — never guessed at.
    package var sessionId: String?
    /// The mailbox address, so the caller's next move ("now tell it something") needs no
    /// lookup of its own. **Read, never derived** — see `Handle`, whose own constructors are
    /// what make that a compiler-enforced fact here rather than only an argument in a comment.
    package var handle: Handle?
    /// `claude` or `pi`, as the mailbox reports it. One lookup answers for both runtimes,
    /// where the Claude session registry answers for only one.
    package var runtime: String?
    /// Why, on any status that is not a plain success. Present on `refused`, `failed`,
    /// `abandoned` and `unclaimed`.
    package var reason: String?
    /// What a `captured` result produced — the PNG's path, and **whether terminal content is in
    /// it**. A nested value rather than six more optional scalars on a type that is otherwise
    /// entirely about spawning, and the reason it is not optional-per-field: `terminalContent`
    /// only means anything alongside the path it describes.
    package var capture: CaptureReport?
    /// What a `ran` result did to the bench (#269) — which command, what it made, and where the
    /// keyboard was on each side of it. A nested value for the same reason `capture` is one:
    /// these fields only mean anything together, and none of them belongs on a type that is
    /// otherwise about spawning.
    package var command: CommandReport?
    /// What a `selected` result did to the bench (#284) — whether the pane is now visible, and
    /// where the keyboard was on each side of it. A nested value for `capture`'s and `command`'s
    /// reason: these fields only mean anything together.
    package var select: SelectReport?
    /// What a `named` result did to the pane (#313) — what it was called before, and what it is
    /// called now. A nested value for `capture`'s, `command`'s and `select`'s reason: these fields
    /// only mean anything together.
    package var name: NameReport?
    /// Seconds since the epoch, so a caller watching for the `started` → `ready` change has
    /// something that always differs between the two writes.
    package var updatedAt: Double

    package init(
        id: String, status: Status, terminalId: TerminalID? = nil, pid: Int32? = nil,
        sessionId: String? = nil, handle: Handle? = nil, runtime: String? = nil,
        reason: String? = nil, capture: CaptureReport? = nil, command: CommandReport? = nil,
        select: SelectReport? = nil, name: NameReport? = nil,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.status = status
        self.terminalId = terminalId
        self.pid = pid
        self.sessionId = sessionId
        self.handle = handle
        self.runtime = runtime
        self.reason = reason
        self.capture = capture
        self.command = command
        self.select = select
        self.name = name
        self.updatedAt = updatedAt
    }
}

/// What naming a pane actually did — read back off the bench, never echoed from the request
/// (#313).
///
/// **`SelectReport.isVisible`'s promise, for the other addressed verb that changes something the
/// operator can see.** A result that only said *"named"* would leave the caller to re-read
/// `snapshot.json` and race it; worse, it would be indistinguishable from a helm that accepted the
/// request and rendered nothing.
///
/// **`previousName` is the field that makes the ownership rule legible in the answer.** A caller
/// that gets `previousName: nil` named a pane nothing had named; one that gets a string back
/// replaced somebody's words, and can say so to the operator who asked for it. It is also the only
/// record of what was there, since nothing else keeps one.
///
/// **No focus readings, and their absence is the policy's shape rather than an omission.**
/// `CommandReport` and `SelectReport` both carry `focusedPaneBefore`/`After` because both policies
/// promise not to move the keyboard, and an argument in a header is a claim where two readings are
/// a measurement. `SpoolNamePolicy` makes no such promise because naming cannot move the keyboard
/// at all — there is nothing here for a canary to catch.
package struct NameReport: Codable, Equatable {
    /// The pane, echoed rather than assumed from the request: a caller reading only the result
    /// file learns what happened without holding onto what it sent.
    package let pane: TerminalID
    /// What the pane was called immediately before, or nil when nothing had named it. **helm's own
    /// derived label reads as a name here**, because it is what was on the tab — the provenance
    /// that let this request through is `SpoolNamePolicy`'s business, not a caller's.
    package let previousName: String?
    /// What it is called now, **read back off the bench after the mutation** rather than copied
    /// from the request.
    package let name: String

    package init(pane: TerminalID, previousName: String?, name: String) {
        self.pane = pane
        self.previousName = previousName
        self.name = name
    }
}

/// What bringing a pane forward actually did — observed after the fact, never asserted (#284).
///
/// **The same promise `CommandReport` makes, for the request that most needs it.** #284 is a
/// ticket about an effect an agent could not observe: a re-pushed artifact refreshed a pane the
/// agent had no way to see. A result that only said *"selected"* would answer half of it, so this
/// carries the two facts the caller would otherwise have to re-read `snapshot.json` for — and
/// race it, since the snapshot is written on its own schedule.
///
/// **`focusedPaneBefore`/`focusedPaneAfter` are `SpoolSelectPolicy`'s argument made checkable.**
/// That policy argues at length that showing a pane in another slot cannot move the keyboard. An
/// argument in a header is a claim; two readings of `Workbench.focusedPane` taken either side of
/// the mutation are a measurement, and the caller gets to make it rather than trusting this
/// repo's comments. They are equal on every select helm allows — `WorkbenchTests` and
/// `SpoolSelectPolicyTests` both pin it — and a change that broke it would say so in its own
/// result rather than only in a review.
package struct SelectReport: Codable, Equatable {
    /// The pane, echoed rather than assumed from the request: a caller reading only the result
    /// file learns what happened without holding onto what it sent.
    package let pane: TerminalID
    /// Whether the operator can now actually see it — **read back off the bench, not asserted
    /// from having asked**. `CONTEXT.md` is exact about the word: *visible* is its slot's
    /// selection in the mounted workspace, which is one step stronger than *selected*.
    ///
    /// It is what #284's *"real but unobservable"* finding asked for, and the honest reason it is
    /// a field rather than a guarantee: `WorkbenchSpoolPanes` reports what the bench says
    /// afterwards, exactly as it reports whether a close really removed the pane.
    package let isVisible: Bool
    /// The pane holding the keyboard immediately before the select, and immediately after. nil
    /// when there is no bench mounted at all.
    package let focusedPaneBefore: TerminalID?
    package let focusedPaneAfter: TerminalID?

    package init(
        pane: TerminalID, isVisible: Bool, focusedPaneBefore: TerminalID?,
        focusedPaneAfter: TerminalID?
    ) {
        self.pane = pane
        self.isVisible = isVisible
        self.focusedPaneBefore = focusedPaneBefore
        self.focusedPaneAfter = focusedPaneAfter
    }
}

/// What a command actually did to the bench — observed after the fact, never asserted.
///
/// **A caller that has to re-read `snapshot.json` to learn whether its own request worked is a
/// caller racing the snapshot** (#269). `spawn` carries `terminalId`/`pid`/`sessionId`/`handle`
/// for exactly that reason; this is the same promise for a command, and it is deliberately
/// small — enough to tell *it happened* from *it was refused* from *helm is older than this
/// request*, plus the two facts a caller's next move actually needs.
///
/// **`focusedPaneBefore` and `focusedPaneAfter` are the policy's promise made checkable.**
/// `SpoolCommandPolicy` argues at length that an allowed command does not move the operator's
/// keyboard. An argument in a header is a claim; two readings of `Workbench.focusedPane` taken
/// either side of the mutation are a measurement, and the caller gets to make it rather than
/// trusting this repo's comments. They are equal on every command in the allowlist —
/// `SpoolCommandPolicyTests` and `WorkbenchTests` both assert it — and a future command that
/// broke that would say so in its own result rather than only in a review.
///
/// A `TerminalID` for a pane that may hold a canvas is the currency the spool already uses:
/// `AcceptedCloseRequest.terminal` is one, and since #284 a close acts on a canvas pane through
/// exactly this type. The wire has one pane-id type, not two — see that field's own header for
/// why a second one over the same `Pane.id` namespace would buy nothing.
package struct CommandReport: Codable, Equatable {
    /// The command helm ran, by name. Echoed rather than assumed from the request: a caller
    /// reading only the result file learns what happened without holding onto what it sent.
    package let command: HelmCommandName
    /// The pane the command brought into being, when it brought one — `newTerminal`,
    /// `splitRight` and `splitDown` all do. nil for the ones that do not.
    ///
    /// It is also copied into `SpoolResult.terminalId`, so the field a caller already reads
    /// after a spawn means the same thing after a command, and `helm-close <terminalId>` is the
    /// next move with no lookup.
    package let paneCreated: TerminalID?
    /// The pane holding the keyboard immediately before the command, and immediately after.
    /// nil when there is no bench mounted at all.
    package let focusedPaneBefore: TerminalID?
    package let focusedPaneAfter: TerminalID?
    /// The bench after: how many columns, and how many panes across all of them. Enough to see
    /// a split land without opening `snapshot.json`, and no attempt to be a second snapshot —
    /// `~/.helm/bench/snapshot.json` is the full report and stays the one place for it.
    package let columns: Int
    package let panes: Int

    package init(
        command: HelmCommandName, paneCreated: TerminalID?, focusedPaneBefore: TerminalID?,
        focusedPaneAfter: TerminalID?, columns: Int, panes: Int
    ) {
        self.command = command
        self.paneCreated = paneCreated
        self.focusedPaneBefore = focusedPaneBefore
        self.focusedPaneAfter = focusedPaneAfter
        self.columns = columns
        self.panes = panes
    }
}

/// What a capture actually contains — computed from the view tree, never asserted.
///
/// **The honesty is the feature.** #174 says it in as many words: *"a PNG with a blank terminal
/// that does not announce itself is worse than no PNG"*. Every field here exists so a caller
/// who has only the result file, and a caller who has only the image, both learn the same
/// thing.
///
/// **Lives in `HelmWire`, not beside the AppKit drawing code that produces it.** `WindowCapture`
/// (`Sources/Helm/Capture/WindowCapture.swift`) does the actual `NSView`/`CALayer` work and
/// stays there — this struct is the pure value that crosses into `SpoolResult.capture`, which
/// `helm-capture` decodes without linking AppKit at all.
package struct CaptureReport: Codable, Equatable {
    /// Where the PNG is. Absolute, so nothing has to know where the spool lives.
    package let path: String
    package let pixelWidth: Int
    package let pixelHeight: Int
    /// Backing scale — 2 on a retina display, so `pixelWidth / scale` is the size in points a
    /// layout assertion would be written against.
    package let scale: Double
    /// The window that was drawn, by title. With `HELM_DEFAULTS_SUITE` set that reads
    /// `helm — <suite>`, which is how a caller tells its own instance from the operator's.
    package let window: String
    package let terminalContent: TerminalContent
    /// How many terminal panes were on the bench in this window. `terminalContent` is `.absent`
    /// exactly when this is zero.
    package let terminalSurfaces: Int
    /// How many of them could **not** be drawn. Zero on `.included`, all of them on
    /// `.excluded`, and the reason `.partial` exists as a case at all.
    package let terminalSurfacesExcluded: Int

    package init(
        path: String, pixelWidth: Int, pixelHeight: Int, scale: Double, window: String,
        terminalContent: TerminalContent, terminalSurfaces: Int, terminalSurfacesExcluded: Int
    ) {
        self.path = path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.window = window
        self.terminalContent = terminalContent
        self.terminalSurfaces = terminalSurfaces
        self.terminalSurfacesExcluded = terminalSurfacesExcluded
    }
}

/// Whether terminal cells are in the PNG.
///
/// **`.included` is earned per capture, never assumed.** #174 scoped this feature expecting the
/// answer to always be no — *"the terminal is a Metal-layer NSView, so Metal content does not
/// come out of `CALayer.render(in:)`"* — and that premise is right about `CAMetalLayer` and
/// wrong about what helm actually runs. The vendored wrapper says so itself: *"the render
/// pipeline can swap `self.layer` to an IOSurfaceLayer for IOSurface-backed compositing"*
/// (`AppTerminalView+Lifecycle.swift:176`). An IOSurface-backed layer has real `contents`, and
/// the layer tree draws it.
///
/// So the question is asked of **each surface at capture time** rather than answered once here.
/// Both states are reachable in one process — a pane that has not rendered yet is still a
/// `CAMetalLayer` — which is exactly why `.partial` is a case rather than an impossibility.
package enum TerminalContent: String, Codable {
    /// No terminal pane in the window at all, so nothing is missing from the image.
    case absent
    /// Every terminal pane's cells are in the PNG.
    case included
    /// No terminal pane's cells are. Their regions carry a marker in the PNG itself.
    case excluded
    /// Some are and some are not. The ones that are not carry the marker; the ones that are
    /// are untouched.
    case partial
}
