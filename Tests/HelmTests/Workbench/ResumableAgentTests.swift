import HelmWire
import XCTest

@testable import Helm

/// #63: a restored pane offers to resume the agent it was holding.
///
/// The ticket's shape, in order: *"a restored tab that had an agent shows it can be resumed,
/// naming the session and its directory"*, *"accepting runs the agent's own resume in that
/// terminal — helm composes a command, it does not reimplement resume"*, *"declining leaves a
/// plain shell"*, and *"a session whose transcript is gone says so plainly rather than offering
/// a resume that will fail"*.
@MainActor
final class ResumableAgentTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-resume")

    private func agent(
        _ session: String = "4f2a1b3c-0000-1111-2222-333344445555",
        command: String = "claude",
        cwd: String = "/tmp/helm-resume"
    ) -> ResumableAgent {
        ResumableAgent(command: command, session: session, cwd: cwd)
    }

    private func row(pid: pid_t, session: String, cwd: String?) -> AgentSession {
        AgentSession(pid: pid, cwd: cwd, status: .busy, sessionId: session)
    }

    // MARK: - The record, and that it survives a relaunch

    /// The whole of #63's persistence: without this the offer has nothing to be about.
    func testTheAgentOnAPaneSurvivesTheStore() throws {
        let defaults = try isolatedDefaults("resumable-agent-store")
        let pane = UUID()
        let bench = Workbench(
            panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))])

        WorkspaceContextStore.save(
            ["/one": WorkspaceContext(workbench: bench)], to: defaults)

        let restored = try XCTUnwrap(
            WorkspaceContextStore.load(from: defaults)["/one"]?.workbench)
        XCTAssertEqual(
            restored.pane(pane)?.content, .terminal(face: .terminal, agent: agent()),
            "the pty died with the process; the id of the conversation it held did not")
    }

    /// A pane with nothing recorded encodes as it always did, so a bench written by this build
    /// is still readable by one that predates it — and vice versa.
    func testAPaneWithNoAgentEncodesExactlyAsItDidBefore() throws {
        let data = try JSONEncoder().encode(Pane.Content.terminal(face: .terminal))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["kind"], "no new key on a pane with nothing to say")
    }

    /// A pre-#63 blob has no `agent` key at all, which is not an error and has lost nothing.
    func testABenchWrittenBeforeThisBuildStillDecodes() throws {
        let pane = UUID()
        let blob = """
            {"columns":[{"id":"\(UUID().uuidString)","width":1,"slots":[
              {"id":"\(UUID().uuidString)","height":1,"selected":"\(pane.uuidString)",
               "panes":[{"id":"\(pane.uuidString)","content":{"kind":"terminal"}}]}]}],
             "focusedSlot":"\(UUID().uuidString)"}
            """

        let bench = try JSONDecoder().decode(Workbench.self, from: Data(blob.utf8))

        XCTAssertEqual(bench.pane(pane)?.content, .terminal(face: .terminal, agent: nil))
    }

    /// A malformed record costs the pane its offer, never the pane. `Slot.init(from:)` skips a
    /// pane it cannot read at all, and losing a terminal because helm could not read a *hint*
    /// about it is the wrong trade.
    func testAMalformedAgentCostsTheOfferAndNotTheTerminal() throws {
        let pane = UUID()
        let blob = """
            {"columns":[{"id":"\(UUID().uuidString)","width":1,"slots":[
              {"id":"\(UUID().uuidString)","height":1,"selected":"\(pane.uuidString)",
               "panes":[{"id":"\(pane.uuidString)",
                         "content":{"kind":"terminal","agent":{"command":42}}}]}]}],
             "focusedSlot":"\(UUID().uuidString)"}
            """

        let bench = try JSONDecoder().decode(Workbench.self, from: Data(blob.utf8))

        XCTAssertEqual(bench.terminalPaneIDs, [pane], "the terminal survives")
        XCTAssertTrue(bench.resumableAgents.isEmpty, "and it simply has nothing to offer")
    }

    /// ⌘T rebuilds `.terminal`, and dropping the agent there would silently retire the offer
    /// every time the operator looked at the chat face.
    func testTogglingTheFaceKeepsTheAgent() throws {
        let pane = UUID()
        var bench = Workbench(
            panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))])

        bench.toggleFace()

        XCTAssertEqual(bench.pane(pane)?.content, .terminal(face: .chat, agent: agent()))
    }

    // MARK: - The line helm composes

    func testTheResumeLineIsTheAgentsOwnFlagWithHelmsIdInIt() throws {
        let line = try XCTUnwrap(AgentResume.line(resuming: agent(), notice: nil))

        XCTAssertEqual(
            line,
            "cd '/tmp/helm-resume' && 'claude' '--dangerously-skip-permissions' --resume "
                + "'4f2a1b3c-0000-1111-2222-333344445555'",
            "helm composes a command; it does not reimplement resume")
    }

    /// **The detail worth stealing.** An agent that resumes believing nothing happened acts on
    /// stale context — that is the failure, not the death itself.
    func testAResumedAgentIsToldItWasRestarted() throws {
        let line = try XCTUnwrap(AgentResume.line(resuming: agent()))

        XCTAssertTrue(
            line.hasSuffix(SpoolLaunchLine.quoted(AgentResume.notice)),
            "the notice is the last argument, so it is the first thing the agent reads")
        XCTAssertFalse(
            AgentResume.notice.contains("\n"),
            "one line: an embedded newline inside a bracketed paste is a continuation the "
                + "shell is still waiting on")
    }

    /// The posture is `SpoolUnattendedPolicy`'s, not a second spelling of it — a resumed agent
    /// must be the agent that died, and that one was started with the operator's standing flags.
    func testTheResumeLineCarriesTheSamePostureASpawnDoes() throws {
        let line = try XCTUnwrap(AgentResume.line(resuming: agent(), notice: nil))

        for argument in SpoolUnattendedPolicy.arguments(for: "claude", requested: []) {
            XCTAssertTrue(
                line.contains(SpoolLaunchLine.quoted(argument)),
                "\(argument) is what a spawned claude gets, so it is what a resumed one gets")
        }
    }

    /// **Measured against the real CLI, both halves, because the obvious reasoning gets
    /// one of them backwards.** `--resume` is *not* cwd-scoped — the same session id
    /// resolved from the parent directory, from `$HOME` and from `/tmp`. But the resumed
    /// agent adopts the **process** cwd: resumed from `/tmp`, `pwd` answered `/tmp`. A
    /// restored pane's pty is rooted at the workspace, so without this an agent started in
    /// a subdirectory comes back in a directory it never worked in — a different
    /// `CLAUDE.md`, a different git repository, and every relative path in its own context
    /// now pointing elsewhere. It would run, look healthy, and be wrong.
    func testTheResumeLineReturnsTheAgentToTheDirectoryItWasWorkingIn() throws {
        let line = try XCTUnwrap(
            AgentResume.line(
                resuming: agent(cwd: "/tmp/helm-resume/packages/api"), notice: nil))

        XCTAssertTrue(
            line.hasPrefix("cd '/tmp/helm-resume/packages/api' && "),
            "a restored pane's pty is rooted at the workspace, not at the subdirectory "
                + "the agent was in")
    }

    /// `&&` rather than `;`, so a directory that no longer exists stops the line instead of
    /// starting an agent somewhere arbitrary. The operator clicked Resume, so they are at
    /// the pane and the shell's own error is in front of them.
    func testAGoneDirectoryStopsTheLineRatherThanRelocatingTheAgent() throws {
        let line = try XCTUnwrap(AgentResume.line(resuming: agent(), notice: nil))

        XCTAssertTrue(line.contains("' && '"), "&& is what makes a failed cd fatal")
        XCTAssertFalse(line.contains("; "), "a `;` would run the agent in the wrong place")
    }

    func testAnEmbeddedQuoteInACwdCannotEscapeTheLine() throws {
        let hostile = "/tmp/a" + "'" + "; rm -rf /; cd " + "'"
        let line = try XCTUnwrap(
            AgentResume.line(resuming: agent(cwd: hostile), notice: nil))

        XCTAssertTrue(
            line.hasPrefix("cd " + SpoolLaunchLine.quoted(hostile) + " && "),
            "the cwd comes off disk, so it is quoted like everything else")
        XCTAssertFalse(line.contains("rm -rf / "), "nothing escapes the quoting")
    }

    func testAnEmbeddedQuoteInASessionIdCannotEscapeTheLine() throws {
        let line = try XCTUnwrap(
            AgentResume.line(resuming: agent("a'; rm -rf /; echo '"), notice: nil))

        XCTAssertTrue(
            line.hasSuffix("'a'\\''; rm -rf /; echo '\\'''"),
            "POSIX single-quoting, the one escaping rule a shell has no exceptions to")
    }

    func testARuntimeHelmCannotResumeGetsNoLine() {
        XCTAssertNil(AgentResume.line(resuming: agent(command: "pi")))
    }

    // MARK: - The offer, and when helm refuses to make one

    func testAnOfferNamesTheSessionAndItsDirectory() {
        let offer = AgentResumeOffer.offer(agent(), in: UUID()) { _ in true }

        XCTAssertTrue(offer.canResume)
        XCTAssertEqual(AgentResumeBar.detail(for: offer), "4f2a1b3c… in /tmp/helm-resume")
        XCTAssertTrue(AgentResumeBar.headline(for: offer).contains("resume it?"))
    }

    /// *"A session whose transcript is gone says so plainly rather than offering a resume that
    /// will fail."*
    func testAGoneTranscriptIsSaidPlainlyRatherThanOffered() {
        let offer = AgentResumeOffer.offer(agent(), in: UUID()) { _ in false }

        XCTAssertFalse(offer.canResume)
        XCTAssertEqual(offer.blocked, .transcriptGone)
        XCTAssertTrue(
            AgentResumeBar.headline(for: offer).contains("transcript is gone"),
            "the operator is told why, not shown a button that would fail")
    }

    func testARuntimeHelmCannotResumeSaysSoRatherThanCheckingATranscript() {
        let offer = AgentResumeOffer.offer(agent(command: "pi"), in: UUID()) { _ in true }

        XCTAssertEqual(offer.blocked, .runtimeUnknown("pi"))
    }

    /// The transcript check is Claude Code's store, read where Claude Code puts it.
    func testTheTranscriptCheckReadsTheRuntimesOwnStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-resume-transcripts-\(UUID().uuidString)")
        let slug = TranscriptLocator.directoryName(for: "/tmp/helm-resume")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(slug), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "{}".write(
            to: root.appendingPathComponent(slug)
                .appendingPathComponent("4f2a1b3c-0000-1111-2222-333344445555.jsonl"),
            atomically: true, encoding: .utf8)

        XCTAssertTrue(AgentObserver.transcriptExists(agent(), root: root))
        XCTAssertFalse(
            AgentObserver.transcriptExists(agent("nothing-was-ever-written"), root: root))
    }

    // MARK: - Watching the panes

    func testAnAgentSeenInAPaneIsWrittenDownOnIt() throws {
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace, restoring: nil)
        let pane = try XCTUnwrap(model.bench?.panes.first?.id)
        let observing = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(
                foreground: [pane: 4242],
                rows: [4242: row(pid: 4242, session: "abc", cwd: "/tmp/sub")]),
            launcher: RecordingLauncher())
        observing.activate(workspacePath: workspace, restoring: model.bench)

        observing.observeAgents()

        XCTAssertEqual(
            observing.bench?.pane(pane)?.content,
            .terminal(
                face: .terminal,
                agent: ResumableAgent(command: "claude", session: "abc", cwd: "/tmp/sub")),
            "the registry's own cwd, because an agent started in a subdirectory is not "
                + "working in the workspace root")
    }

    /// **The record is sticky**, and this is the case that decides it: a `claude` running a
    /// bash command hands the pty's foreground to a child, so a record cleared on absence
    /// would be erased and rewritten several times a minute — and would be *absent* if helm
    /// died inside one of those windows, which is the crash #63 exists for.
    func testARecordIsNotErasedWhenTheAgentStopsBeingTheForegroundProcess() throws {
        let terminals = TerminalManager()
        let seen = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:]), launcher: RecordingLauncher())
        seen.activate(workspacePath: workspace, restoring: nil)
        let pane = try XCTUnwrap(seen.bench?.panes.first?.id)
        let watching = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(
                foreground: [pane: 77], rows: [77: row(pid: 77, session: "abc", cwd: nil)]),
            launcher: RecordingLauncher())
        watching.activate(workspacePath: workspace, restoring: seen.bench)
        watching.observeAgents()
        let blind = WorkbenchModel(
            terminals: terminals, agents: .blind, launcher: RecordingLauncher())
        blind.activate(workspacePath: workspace, restoring: watching.bench)

        blind.observeAgents()

        XCTAssertEqual(
            blind.bench?.resumableAgents.map(\.agent.session), ["abc"],
            "what was running here is still what was running here")
    }

    // MARK: - Answering

    func testAcceptingRunsTheAgentsOwnResumeInThatPaneAndNowhereElse() throws {
        let terminals = TerminalManager()
        let launcher = RecordingLauncher()
        let pane = UUID()
        let other = UUID()
        let bench = Workbench(
            panes: [
                Pane(id: pane, content: .terminal(face: .terminal, agent: agent())),
                Pane(id: other, content: .terminal(face: .terminal)),
            ])
        let model = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:]), launcher: launcher)
        model.activate(workspacePath: workspace, restoring: bench)
        XCTAssertNotNil(model.resumeOffers[pane], "the restored pane asks")
        XCTAssertNil(model.resumeOffers[other], "the pane that held nothing does not")

        model.resume(pane)

        XCTAssertEqual(launcher.sent.count, 1)
        XCTAssertEqual(launcher.sent[0].terminal, pane, "into the pane it was about")
        XCTAssertEqual(launcher.sent[0].line, AgentResume.line(resuming: agent()))
        XCTAssertNil(model.resumeOffers[pane], "and the question is closed")
    }

    /// *"Declining leaves a plain shell. Nothing is auto-started."* — and the record goes with
    /// it, or the same offer returns on every launch until the pane is closed.
    func testDecliningLeavesAPlainShellAndDoesNotAskAgain() throws {
        let terminals = TerminalManager()
        let launcher = RecordingLauncher()
        let pane = UUID()
        let model = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:]), launcher: launcher)
        model.activate(
            workspacePath: workspace,
            restoring: Workbench(
                panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))]))

        model.dismissResume(pane)

        XCTAssertTrue(launcher.sent.isEmpty, "nothing is auto-started")
        XCTAssertNil(model.resumeOffers[pane])
        XCTAssertTrue(
            model.bench?.resumableAgents.isEmpty ?? false,
            "a declined agent left on the pane is one offered again forever")
        XCTAssertEqual(model.bench?.terminalPaneIDs, [pane], "and the shell is still there")
    }

    /// An offer answered by events rather than by a click: the agent turned up, so there is
    /// nothing left to ask. This is what puts an accepted resume's own band away.
    func testAnOfferRetiresWhenTheAgentTurnsUpInThePane() throws {
        let terminals = TerminalManager()
        let pane = UUID()
        let bench = Workbench(
            panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))])
        let model = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:]), launcher: RecordingLauncher())
        model.activate(workspacePath: workspace, restoring: bench)
        XCTAssertNotNil(model.resumeOffers[pane])

        let resumed = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(
                foreground: [pane: 999],
                rows: [999: row(pid: 999, session: agent().session, cwd: nil)]),
            launcher: RecordingLauncher())
        resumed.activate(workspacePath: workspace, restoring: bench)

        XCTAssertNil(
            resumed.resumeOffers[pane],
            "a pane that already holds the conversation must not be asked about it")
    }

    /// **A bench comes off disk, so two panes can carry one id — and building the offers must
    /// not trap on that.** `AgentRegistry.row(in:)`, added on this same branch, argues the rule
    /// in its own header: *"`Dictionary(_:uniquingKeysWith:)` rather than `uniqueKeysWithValues:`,
    /// because the latter traps and a hand-edited registry directory is not worth a crash."*
    /// The offers were built the trapping way, over a value decoded from `UserDefaults` rather
    /// than from a directory — a worse place for it, because the crash is at mount and every
    /// relaunch reaches it again.
    ///
    /// `Workbench.normalize()` says so itself one type over: *"unreachable through any mutation
    /// — but a decoded bench is not built by a mutation, so this is not an assertion."* Nothing
    /// dedupes pane ids on the way in.
    func testTwoPanesCarryingOneIdDoNotTrapWhenTheOffersAreBuilt() throws {
        let pane = UUID()
        let bench = Workbench(
            panes: [
                Pane(id: pane, content: .terminal(face: .terminal, agent: agent("first"))),
                Pane(id: pane, content: .terminal(face: .terminal, agent: agent("second"))),
            ])
        let model = WorkbenchModel(
            terminals: TerminalManager(),
            agents: .fixture(foreground: [:], rows: [:]), launcher: RecordingLauncher())

        model.activate(workspacePath: workspace, restoring: bench)

        XCTAssertEqual(
            model.resumeOffers.count, 1,
            "one id, one offer — the duplicate is degenerate, and picking one is the answer; "
                + "trapping is not")
    }

    // MARK: - What a reader outside the process sees

    /// **The per-pane half of `awaitingRestore`.** Without it a pane showing "claude was running
    /// here — resume it?" and a pane that never held an agent are byte-for-byte identical in
    /// `snapshot.json` — same `isLive`, same `status`, `owner: nil` in both. Measured while
    /// proving #63 across a real restart: the snapshot could say the mount question was open and
    /// then had nothing to say about the offer that followed it, so the only way to see the
    /// offer was a screenshot.
    func testARestoredPaneSaysInTheSnapshotThatItIsBeingOfferedAResume() throws {
        let pane = UUID()
        let snapshot = try project(
            bench: Workbench(
                panes: [
                    Pane(id: pane, content: .terminal(face: .terminal, agent: agent())),
                    Pane(content: .terminal(face: .terminal)),
                ]), suite: "resume-snapshot-offered")

        let records = try panes(in: snapshot)
        let offered = try XCTUnwrap(records[pane]?.resumable)
        XCTAssertEqual(offered.session, agent().session, "a reader sees what helm persisted")
        XCTAssertEqual(offered.command, "claude")
        XCTAssertEqual(offered.cwd, "/tmp/helm-resume")
        XCTAssertTrue(offered.isOffered, "the operator is being asked about this pane right now")
        XCTAssertNil(offered.blockedReason, "and helm can make good on it")
        XCTAssertEqual(
            records.values.compactMap(\.resumable).count, 1,
            "the pane that held nothing says nothing — or every reader learns to ignore the key")
    }

    /// A blocked offer is the state a reader most needs told apart from a live one: waiting on
    /// an agent that is never coming back is the whole cost of not saying so.
    func testABlockedOfferNamesItsReasonInTheSnapshot() throws {
        let pane = UUID()
        let snapshot = try project(
            bench: Workbench(
                panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))]),
            transcripts: [], suite: "resume-snapshot-blocked")

        let record = try XCTUnwrap(try panes(in: snapshot)[pane]?.resumable)
        XCTAssertTrue(record.isOffered)
        XCTAssertEqual(record.blockedReason, "transcriptGone")
    }

    /// The control: a pane with nothing recorded carries no key at all, on a bench that is
    /// otherwise identical. It is what fails if the field is written unconditionally.
    func testAPaneThatNeverHeldAnAgentCarriesNoResumeRecord() throws {
        let pane = UUID()
        let snapshot = try project(
            bench: Workbench(panes: [Pane(id: pane, content: .terminal(face: .terminal))]),
            suite: "resume-snapshot-control")

        XCTAssertNil(try panes(in: snapshot)[pane]?.resumable)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot))
                as? [String: Any])
        XCTAssertFalse(
            String(describing: json).contains("resumable"),
            "an absent record is an absent key, not a null one")
    }

    /// **A parked workspace still says what its panes were holding — and never that it is being
    /// asked about them.** The two halves come from different places on purpose: the *record*
    /// is on the bench, which is a value in `WorkspaceModel.contexts` and outlives any mount;
    /// the *question* is `WorkbenchModel.resumeOffers`, which is this launch's, about the one
    /// workspace the model currently holds.
    ///
    /// Without this a reader has to mount a workspace to learn whether anything was running in
    /// it, which defeats the point of a snapshot that reports every workspace at once.
    ///
    /// **`isOffered == false` here is a control and passes either way**, and it is worth saying
    /// why rather than leaving it to look like a measurement. `project` guards the parked branch
    /// with `mounted ? workbench.resumeOffers : [:]`, but the model recomputes `resumeOffers` on
    /// every mount — so by the time this workspace is parked the dictionary is the *other*
    /// workspace's and holds none of these pane ids anyway. The guard is belt-and-braces, and
    /// this assertion is what fails if a later change ever makes the offers survive a mount.
    func testAParkedWorkspaceStillReportsWhatItsPanesHeldWithoutClaimingAnOpenQuestion() throws {
        let defaults = try isolatedDefaults("resume-snapshot-parked")
        let workspaces = WorkspaceModel(defaults: defaults)
        let terminals = TerminalManager()
        let model = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:]), launcher: RecordingLauncher())

        let parked = Workspace(path: "/tmp/helm-resume-parked")
        let pane = UUID()
        workspaces.open(parked)
        model.activate(
            workspacePath: parked.path,
            restoring: Workbench(
                panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))]))
        XCTAssertNotNil(model.resumeOffers[pane], "it is asked about while it is mounted")
        workspaces.saveContext(terminalManager: terminals, workbench: model)

        // Mounting another workspace parks the first — the model holds one at a time.
        let mounted = Workspace(path: "/tmp/helm-resume-mounted")
        workspaces.open(mounted)
        model.activate(workspacePath: mounted.path, restoring: nil)

        let snapshot = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: model, terminals: terminals,
            addressBook: AddressBook(owners: [], sessionFor: { _ in nil })
        ) { _ in nil }

        let record = try XCTUnwrap(snapshot.workspaces.first { $0.path == parked.path })
        XCTAssertEqual(record.state, .parked)
        let resumable = try XCTUnwrap(
            record.columns.flatMap(\.slots).flatMap(\.panes).first?.terminal?.resumable,
            "the record is on the bench, so parking a workspace does not erase what it held")
        XCTAssertEqual(resumable.session, agent().session)
        XCTAssertFalse(
            resumable.isOffered,
            "nobody is being asked about a workspace that is not on screen")
    }

    private func project(
        bench: Workbench, transcripts: Set<String>? = nil, suite: String
    ) throws -> BenchSnapshot {
        let workspace = Workspace(path: workspace.value)
        let workspaces = WorkspaceModel(defaults: try isolatedDefaults(suite))
        workspaces.open(workspace)
        let terminals = TerminalManager()
        let model = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:], transcripts: transcripts),
            launcher: RecordingLauncher())
        model.activate(workspacePath: workspace.path, restoring: bench)
        return BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: model, terminals: terminals,
            addressBook: AddressBook(owners: [], sessionFor: { _ in nil })
        ) { _ in nil }
    }

    private func panes(in snapshot: BenchSnapshot) throws -> [UUID: BenchSnapshot.TerminalRecord] {
        let record = try XCTUnwrap(snapshot.workspaces.first)
        return Dictionary(
            record.columns.flatMap(\.slots).flatMap(\.panes)
                .compactMap { pane in pane.terminal.map { (pane.id, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Controls
    //
    // Both pass on `origin/development` too. They are here because #63 could satisfy every
    // assertion above by offering more, and these are what fail if it does.

    func testAPaneThatNeverHeldAnAgentIsNeverAskedAbout() throws {
        let terminals = TerminalManager()
        let model = WorkbenchModel(
            terminals: terminals, agents: .blind, launcher: RecordingLauncher())

        model.activate(workspacePath: workspace, restoring: nil)

        XCTAssertTrue(model.resumeOffers.isEmpty, "a fresh shell has nothing to resume")
    }

    func testARestoredShellIsStillJustAShellUntilSomebodyAnswers() throws {
        let terminals = TerminalManager()
        let launcher = RecordingLauncher()
        let pane = UUID()
        let model = WorkbenchModel(
            terminals: terminals,
            agents: .fixture(foreground: [:], rows: [:]), launcher: launcher)

        model.activate(
            workspacePath: workspace,
            restoring: Workbench(
                panes: [Pane(id: pane, content: .terminal(face: .terminal, agent: agent()))]))

        XCTAssertTrue(
            launcher.sent.isEmpty,
            "offer, not push — an agent restarting itself unbidden after a crash is exactly "
                + "the case where it should not")
    }
}
