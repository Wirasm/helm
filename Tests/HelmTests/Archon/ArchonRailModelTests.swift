import Combine
import XCTest

@testable import Helm

/// The rail, after the reduction.
///
/// **A lot of this suite's subjects genuinely no longer exist**, and the ones that were merely
/// *renamed* are rewritten to the property that replaced them rather than dropped:
/// "running and paused both get lines" became "only running does", and "the subline is the
/// current node's output preview" became "the subline is the current node's stage". What is
/// gone entirely is the liveness state, the `abandon` verb and the run pane — see the commit
/// message. `approve`/`reject` came back with #150 and are exercised below.
final class ArchonRailModelTests: XCTestCase {
    private let workspace = "/tmp/project"

    // MARK: - Visibility

    @MainActor
    func testVisibilityDefaultsHiddenAndPersists() throws {
        let defaults = try isolatedDefaults("archon-rail-visibility")
        let model = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)
        XCTAssertFalse(model.isVisible)

        model.toggleVisibility()

        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(defaults.bool(forKey: ArchonRailModel.visibilityKey))
    }

    /// ⇧⌘R end to end. It was tested in two halves that never met — one proving the shortcut
    /// maps to `.helmToggleRail`, one proving `toggleVisibility()` flips a flag — so the
    /// subscription in between, which is the part that can actually be deleted by accident,
    /// was never exercised at all.
    @MainActor
    func testPostingTheToggleNotificationReachesTheModel() throws {
        let defaults = try isolatedDefaults("archon-rail-notification")
        let model = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)
        let flipped = expectation(description: "isVisible changed")
        let observer = model.$isVisible.dropFirst().sink { _ in flipped.fulfill() }

        NotificationCenter.default.post(name: .helmToggleRail, object: nil)

        wait(for: [flipped], timeout: 2)
        observer.cancel()
        XCTAssertTrue(model.isVisible)
        XCTAssertTrue(
            defaults.bool(forKey: ArchonRailModel.visibilityKey),
            "the rail is hidden by default, so the shortcut has to work with no rail view alive")
    }

    // MARK: - Polling

    /// **Rewritten three times, not deleted.** It first asserted that a paused run gets its own
    /// line; the minimal rail gave it a count instead; then the counts went and it had nothing
    /// at all. What it asserts now is the three-way split the gates restored: `paused` is its
    /// own list, `running` is another, `completed` and `failed` are the inbox, and `cancelled`
    /// is still nowhere because the operator ended it themselves.
    @MainActor
    func testTheThreeListsAreGatedRunningAndFinished() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [
                    .fixture(id: "a", status: "running"),
                    .fixture(id: "b", status: "completed"),
                    .paused(id: "c"),
                    .fixture(id: "d", status: "failed"),
                    .fixture(id: "e", status: "cancelled"),
                ],
                counts: ["all": 9, "running": 1, "completed": 5, "paused": 1, "failed": 2]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-running"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.gated.map(\.id), ["c"])
        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertEqual(
            Set(model.finished.map(\.id)), ["b", "d"],
            "completed and failed are the inbox; cancelled produced nothing and paused has its own list"
        )
    }

    /// **Rewritten, not deleted.** This asserted that a status holding more runs than the rail
    /// could show left its remainder on a collapsed count line. There is no collapsed line any
    /// more, so what survives of its subject is the opposite guarantee: `counts` is not read at
    /// all, and cannot put a run on screen that `runs` did not carry.
    @MainActor
    func testCountsNoLongerReachTheRail() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [.fixture(id: "a", status: "running")],
                counts: ["all": 128, "running": 3, "completed": 97, "failed": 28]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-remainder"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertEqual(
            model.finished, [],
            "97 completed in the counts, none in runs — a count can no longer invent a row")
    }

    /// Newest first, by `completed_at`. A run missing it sorts last rather than breaking the
    /// comparison.
    @MainActor
    func testTheInboxIsNewestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_785_800_000)
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [
                    .fixture(id: "old", status: "completed", completedAt: base),
                    .fixture(id: "undated", status: "completed", completedAt: nil),
                    .fixture(
                        id: "new", status: "completed", completedAt: base.addingTimeInterval(600)),
                ]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-inbox-order"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.finished.map(\.id), ["new", "old", "undated"])
    }

    /// Clearing is helm-only and survives the next poll — otherwise the row returns two seconds
    /// later and the gesture means nothing.
    @MainActor
    func testAClearedRunStaysGoneAcrossTheNextPoll() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [
                    .fixture(id: "b", status: "completed"),
                    .fixture(id: "d", status: "failed"),
                ]))
        let defaults = try isolatedDefaults("archon-rail-dismiss")
        let model = ArchonRailModel(client: client, defaults: defaults)
        await model.refresh(in: workspace)

        model.dismiss(try XCTUnwrap(model.finished.first { $0.id == "b" }), in: workspace)
        XCTAssertEqual(model.finished.map(\.id), ["d"])

        await model.refresh(in: workspace)

        XCTAssertEqual(model.finished.map(\.id), ["d"], "Archon still reports it; helm does not")
    }

    /// And survives a relaunch, which is the whole reason it is persisted rather than held in
    /// memory: quitting must not undo the clearing.
    @MainActor
    func testAClearedRunSurvivesARelaunch() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "b", status: "completed")]))
        let defaults = try isolatedDefaults("archon-rail-dismiss-relaunch")
        let first = ArchonRailModel(client: client, defaults: defaults)
        await first.refresh(in: workspace)
        first.dismiss(try XCTUnwrap(first.finished.first), in: workspace)

        let second = ArchonRailModel(client: client, defaults: defaults)
        await second.refresh(in: workspace)

        XCTAssertEqual(second.finished, [])
    }

    /// A run cleared in one workspace is not cleared in another — the store is keyed by
    /// workspace, and two projects' inboxes are separate.
    @MainActor
    func testClearingIsScopedToTheWorkspace() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "b", status: "completed")]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-dismiss-scope"))
        await model.refresh(in: workspace)
        model.dismiss(try XCTUnwrap(model.finished.first), in: workspace)

        await model.refresh(in: "/tmp/other-project")

        XCTAssertEqual(model.finished.map(\.id), ["b"])
    }

    /// Clicking a finished row asks the opener for that run, and nothing spawns during a poll.
    @MainActor
    func testOpeningAFinishedRunAsksTheOpenerOnceForThatRun() async throws {
        let opened = OpenedRuns()
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "b", status: "completed")]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-open"),
            opener: ArchonRunOpener { run in await opened.record(run.id) })

        await model.refresh(in: workspace)
        let duringPoll = await opened.ids
        XCTAssertEqual(duringPoll, [], "a poll resolves nothing — it is lazy on click")

        model.open(try XCTUnwrap(model.finished.first))
        try await Task.sleep(for: .milliseconds(50))

        let afterClick = await opened.ids
        XCTAssertEqual(afterClick, ["b"])
    }

    /// **Rewritten from `testTheSublineIsTheCurrentNodesPreview`.** The subline names the
    /// *stage* now — `implement` — rather than an excerpt of what that stage wrote: the stage
    /// is the thing that advances, and the writing is read in Archon's own UI.
    @MainActor
    func testTheSublineIsTheCurrentNodesStage() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        await client.setDetails([
            "a": .fixture(
                id: "a",
                nodes: [
                    .fixture(nodeId: "plan", state: .completed),
                    .fixture(nodeId: "implement", state: .running),
                ])
        ])
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-stage"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.stages["a"], "implement")
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.detailRequests, ["a"], "only running runs cost a second process")
    }

    /// A detail call that fails costs that run its subline and nothing else — the run is
    /// already on screen from the list call, and failing the whole refresh would trade a
    /// missing line for a missing rail.
    @MainActor
    func testAFailedDetailCallCostsOnlyTheSubline() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        await client.setDetailFailure(.notInstalled())
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-detail-failure"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertNil(model.stages["a"])
    }

    /// The last known runs survive a failed poll: one hiccup must not make the lines flap.
    @MainActor
    func testAFailedPollKeepsTheLastKnownRuns() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-stale"))
        await model.refresh(in: workspace)

        await client.setFailure(.notInstalled())
        await model.refresh(in: workspace)

        XCTAssertEqual(model.running.map(\.id), ["a"])
    }

    @MainActor
    func testWithNoWorkspaceNothingIsAskedAndNothingIsShown() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-no-workspace"))
        await model.refresh(in: workspace)

        await model.refresh(in: nil)

        XCTAssertEqual(model.running, [])
        XCTAssertEqual(model.finished, [])
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, 1, "no workspace, no project to ask about")
    }

    @MainActor
    func testRefreshesNeverOverlap() async throws {
        let client = FakeArchonClient()
        await client.setDelay(.milliseconds(30))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-overlap"))

        let path = workspace
        async let first: Void = model.refresh(in: path)
        async let second: Void = model.refresh(in: path)
        _ = await (first, second)

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.maximumListCalls, 1)
        XCTAssertEqual(metrics.listCalls, 1, "the dropped one is not queued behind the first")
    }

    @MainActor
    func testPollStopsWhenCancelled() async throws {
        let model = ArchonRailModel(
            client: FakeArchonClient(), defaults: try isolatedDefaults("archon-rail-poll"))
        let poll = Task { await model.poll(in: "/tmp/project", every: .milliseconds(1)) }
        try? await Task.sleep(for: .milliseconds(10))
        poll.cancel()
        await poll.value
    }

    // MARK: - Launching

    @MainActor
    func testSendLaunchesWhatTheSettingsHoldAndClearsTheField() async throws {
        let client = FakeArchonClient()
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-launch"))
        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40"))
        model.draft = "implement issue 40"

        await model.launch(in: workspace)

        let request = await client.lastLaunch()
        XCTAssertEqual(
            request,
            ArchonLaunchRequest(
                workspacePath: workspace, workflow: "ship", input: "implement issue 40",
                worktree: .branch("issue-40")))
        XCTAssertEqual(
            model.draft, "", "the field is the one control; a stale draft would relaunch")
        XCTAssertNil(model.launchFailure)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.listCalls, 1, "the new run appears without waiting")
    }

    /// Every rejection branch. They are the whole validation surface of the one control the
    /// rail has, and only the happy path was covered.
    @MainActor
    func testEveryRejectionSaysWhyAndLaunchesNothing() async throws {
        let client = FakeArchonClient()
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-rejections"))

        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .automatic)
        model.draft = "do it"
        await model.launch(in: nil)
        XCTAssertEqual(model.launchFailure, ArchonRailModel.noWorkspace)

        model.config = ArchonLaunchConfig(workflow: "  ", worktree: .automatic)
        await model.launch(in: workspace)
        XCTAssertEqual(model.launchFailure, "Choose a workflow in the settings before launching.")

        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .automatic)
        model.draft = "   \n "
        await model.launch(in: workspace)
        XCTAssertEqual(model.launchFailure, "Type what the workflow should do.")

        model.draft = "do it"
        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .branch(" "))
        await model.launch(in: workspace)
        XCTAssertEqual(
            model.launchFailure, "Name the branch in the settings, or let Archon name it.")

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.launchRequests, 0, "not one of these reached Archon")
        XCTAssertEqual(model.draft, "do it", "a rejected launch must not eat what was typed")
    }

    /// Every rejection is about the draft or the settings, so touching either makes the
    /// sentence under the field a statement about a state that no longer exists.
    @MainActor
    func testEditingTheDraftOrTheSettingsClearsTheLastRejection() async throws {
        let model = ArchonRailModel(
            client: FakeArchonClient(), defaults: try isolatedDefaults("archon-rail-clearing"))
        model.config = ArchonLaunchConfig(workflow: "", worktree: .automatic)
        model.draft = "do it"
        await model.launch(in: workspace)
        XCTAssertNotNil(model.launchFailure)

        model.config.workflow = "ship"

        XCTAssertNil(model.launchFailure)
    }

    /// `--detach` answering `detached: false` means Archon ran the whole workflow in that
    /// child instead. A different failure from a refusal, and one the operator has to be told
    /// about because the field would otherwise clear as if it had worked.
    @MainActor
    func testARejectedAcknowledgementIsReportedAndKeepsTheDraft() async throws {
        let client = FakeArchonClient()
        await client.setAcknowledgement(.fixture(ok: true, detached: false))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-ack"))
        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .automatic)
        model.draft = "do it"

        await model.launch(in: workspace)

        XCTAssertEqual(model.launchFailure, "Archon did not accept the detached launch.")
        XCTAssertEqual(model.draft, "do it")
    }

    /// **The one line of text the rail keeps that is not in its list**, and the reason it does:
    /// a send button that silently does nothing is a worse defect than a sentence.
    @MainActor
    func testAFailedLaunchSurfacesArchonsOwnReason() async throws {
        let client = FakeArchonClient()
        await client.setFailure(.notInstalled())
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-launch-failure"))
        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .automatic)
        model.draft = "do it"

        await model.launch(in: workspace)

        XCTAssertEqual(
            model.launchFailure, ArchonCLIError.notInstalled().localizedDescription)
    }

    // MARK: - The settings

    @MainActor
    func testTheSettingsRememberTheirConfigAcrossARelaunch() throws {
        let defaults = try isolatedDefaults("archon-rail-config")
        let first = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)

        first.config = ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40"))

        let second = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)
        XCTAssertEqual(
            second.config, ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40")),
            "a popover dismissed by clicking away fires nothing to save on, so every change saves")
    }

    @MainActor
    func testOpeningTheSettingsLoadsWorkflowsAndSeedsAnUnsetChoice() async throws {
        let client = FakeArchonClient(
            workflowList: .init(
                workflows: [.init(name: "ship", description: "Ship it", provider: nil, model: nil)],
                errors: []))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-settings"))

        await model.loadWorkflows(in: workspace)

        XCTAssertTrue(model.isConfigOpen)
        XCTAssertEqual(model.workflows.map(\.name), ["ship"])
        XCTAssertEqual(model.config.workflow, "ship")
    }

    @MainActor
    func testOpeningTheSettingsWithNoWorkspaceSaysSoRatherThanShowingNothing() async throws {
        let model = ArchonRailModel(
            client: FakeArchonClient(),
            defaults: try isolatedDefaults("archon-rail-settings-empty"))

        await model.loadWorkflows(in: nil)

        XCTAssertEqual(model.launchFailure, ArchonRailModel.noWorkspace)
    }

    // MARK: - Answering a gate

    @MainActor
    private func gatedModel(
        _ name: String, gate: ArchonGate = .fixture(), client: FakeArchonClient? = nil
    ) async throws -> (ArchonRailModel, FakeArchonClient) {
        let client =
            client ?? FakeArchonClient(runsResponse: .fixture(runs: [.paused(gate: gate)]))
        let model = ArchonRailModel(client: client, defaults: try isolatedDefaults(name))
        await model.refresh(in: workspace)
        return (model, client)
    }

    /// A gate whose text Archon does not read sends on one click. Two would be a click that
    /// buys nothing, which is exactly the bloat #147 cut.
    @MainActor
    func testAPlainApprovalSendsOnTheFirstClick() async throws {
        let (model, client) = try await gatedModel("archon-gate-plain")

        await model.choose(.approve, on: model.gated[0], in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.map(\.decision), [.approve])
        XCTAssertNil(calls.decisions.first?.text)
        XCTAssertNil(model.reply, "nothing was armed — it just went")
    }

    /// A rejection's reason drives the `on_reject` rework, so the click points the composer at
    /// the gate instead of sending an unexplained failure.
    @MainActor
    func testRejectArmsTheComposerRatherThanSendingBlind() async throws {
        let (model, client) = try await gatedModel("archon-gate-reject-arms")

        await model.choose(.reject, on: model.gated[0], in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.count, 0, "nothing is sent until the reason is typed")
        XCTAssertEqual(model.reply?.decision, .reject)
        XCTAssertEqual(model.reply?.runID, "run-1")
    }

    /// `captureResponse` makes the comment the node's own output, so a one-click approve would
    /// silently write the literal string `Approved` into the run.
    @MainActor
    func testACaptureResponseGateArmsTheComposer() async throws {
        let (model, _) = try await gatedModel(
            "archon-gate-capture", gate: .fixture(captureResponse: true))

        await model.choose(.approve, on: model.gated[0], in: workspace)

        XCTAssertEqual(model.reply?.decision, .approve)
    }

    /// **The launch draft survives a gate.** One field, two strings behind it — because losing a
    /// half-written instruction to answer an approval is the version of this that gets sworn at.
    @MainActor
    func testAnsweringAGateNeverTouchesTheLaunchDraft() async throws {
        let (model, _) = try await gatedModel("archon-gate-draft")
        model.draft = "half a thought"

        await model.choose(.reject, on: model.gated[0], in: workspace)
        model.replyText = "the tests are red"
        model.disarm()

        XCTAssertNil(model.reply)
        XCTAssertEqual(model.draft, "half a thought")
        XCTAssertEqual(model.replyText, "")
    }

    /// The typed answer reaches Archon, and the recorded decision is followed through with the
    /// resume it leaves behind — `--json` records without executing.
    @MainActor
    func testTheTypedAnswerIsSentAndTheParkedRunIsResumed() async throws {
        let (model, client) = try await gatedModel("archon-gate-send")

        await model.choose(.reject, on: model.gated[0], in: workspace)
        model.replyText = "the tests are red"
        await model.sendReply(in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.map(\.text), ["the tests are red"])
        XCTAssertEqual(calls.decisions.map(\.runID), ["run-1"])
        XCTAssertEqual(calls.resumes, ["run-1"], "resumable: true means helm has to drive it")
        XCTAssertNil(model.reply, "a sent answer gives the composer back")
        XCTAssertNil(model.actionFailure)
    }

    /// An empty answer is a real one: for an interactive loop it is what finalizes rather than
    /// running another iteration, so it must be sendable.
    @MainActor
    func testAnEmptyAnswerStillSends() async throws {
        let (model, client) = try await gatedModel(
            "archon-gate-empty", gate: .fixture(type: .interactiveLoop))

        await model.choose(.approve, on: model.gated[0], in: workspace)
        await model.sendReply(in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.count, 1)
        XCTAssertEqual(calls.decisions.first?.text, "")
    }

    /// `ok: false` on a zero exit. Reported as Archon's own refusal rather than as success.
    @MainActor
    func testARefusedDecisionSaysWhyAndResumesNothing() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        await client.setDecision(.fixture(ok: false, error: "run not found"))
        let (model, _) = try await gatedModel("archon-gate-refused", client: client)

        await model.choose(.approve, on: model.gated[0], in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(model.actionFailure, "Archon refused to approve this run: run not found")
        XCTAssertEqual(calls.resumes, [], "a refusal is not a decision to follow through")
    }

    /// **The third wrong answer this avoids**: by the time a resume fails the approval is
    /// already recorded, so "approve failed" would be false. The sentence says both halves —
    /// and it survives the refresh that follows, which is where an earlier shape lost it.
    @MainActor
    func testAResumeThatFailsIsReportedWithoutUnsayingTheApproval() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        await client.setResume(.fixture(ok: true, detached: false))
        let (model, _) = try await gatedModel("archon-gate-resume-failed", client: client)

        await model.choose(.approve, on: model.gated[0], in: workspace)

        XCTAssertEqual(
            model.actionFailure,
            "Approve recorded, but Archon did not restart the run. Resume it from a terminal.")
    }

    /// The other half of the resume failure: not `ok: false` but the call throwing outright —
    /// archon missing, the deadline killing it, or `resume`'s own "nowhere to run it" refusal.
    /// Still a recorded approval, so still not "approve failed".
    @MainActor
    func testAResumeThatThrowsStillSaysTheApprovalWasRecorded() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        await client.setResumeFailure(.notInstalled())
        let (model, _) = try await gatedModel("archon-gate-resume-throws", client: client)

        await model.choose(.approve, on: model.gated[0], in: workspace)

        let failure = try XCTUnwrap(model.actionFailure)
        XCTAssertTrue(
            failure.hasPrefix("Approve recorded, but the run did not restart: "),
            "the decision landed; only the restart did not — got \(failure)")
        XCTAssertTrue(failure.contains("archon"), "and it carries Archon's own reason")
    }

    /// A rejection that cancelled the run answers `resumable: false`, and there is genuinely
    /// nothing left to drive — resuming anyway would be a call against a cancelled run.
    @MainActor
    func testARejectionThatCancelsTheRunResumesNothingAndReportsNothing() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        await client.setDecision(
            .fixture(action: "reject", resumable: false, cancelled: true))
        let (model, _) = try await gatedModel("archon-gate-cancelled", client: client)

        await model.choose(.reject, on: model.gated[0], in: workspace)
        model.replyText = "three strikes"
        await model.sendReply(in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.count, 1)
        XCTAssertEqual(calls.resumes, [], "cancelled runs have nothing to resume")
        XCTAssertNil(model.actionFailure)
    }

    /// The decision call *throwing* rather than refusing — a different path from `ok: false`,
    /// and the one a missing `archon` or a hung child takes.
    @MainActor
    func testADecisionCallThatThrowsSurfacesArchonsOwnReason() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        await client.setDecisionFailure(.notInstalled())
        let (model, _) = try await gatedModel("archon-gate-throws", client: client)

        await model.choose(.approve, on: model.gated[0], in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(
            model.actionFailure, ArchonCLIError.notInstalled().localizedDescription)
        XCTAssertEqual(calls.resumes, [], "nothing was recorded, so there is nothing to follow")
    }

    /// **A double-press must not become a double-approve**, which Archon throws on: the second
    /// decision finds the gate already resolved. `busyRuns` is inserted synchronously before the
    /// first `await`, so the second press is refused before it can reach the client.
    @MainActor
    func testASecondPressWhileTheFirstIsInFlightIsRefused() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        await client.setDelay(.milliseconds(50))
        let (model, _) = try await gatedModel("archon-gate-double-press", client: client)
        let run = model.gated[0]

        // `path` hoisted out of `self` for the reason `testRefreshesNeverOverlap` does it: an
        // `async let` that touches a test-case property sends `self` across an isolation
        // boundary, which Swift 6 rejects.
        let path = workspace
        async let first: Void = model.choose(.approve, on: run, in: path)
        async let second: Void = model.choose(.approve, on: run, in: path)
        _ = await (first, second)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.count, 1, "the second press found the run already busy")
    }

    /// The `Set` rather than a flag, earning itself: answering one gate must not disable the
    /// other, and a spinner over the whole rail would say the wrong thing about it.
    @MainActor
    func testTwoGatesAreAnsweredIndependently() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.paused(id: "a"), .paused(id: "b")]))
        let (model, _) = try await gatedModel("archon-gate-two", client: client)
        XCTAssertEqual(model.gated.map(\.id), ["a", "b"])

        await model.choose(.reject, on: model.gated[0], in: workspace)
        XCTAssertEqual(model.reply?.runID, "a")

        // Arming the second replaces the first rather than queuing it — one composer, one gate.
        await model.choose(.reject, on: model.gated[1], in: workspace)
        XCTAssertEqual(model.reply?.runID, "b")
        model.replyText = "not this one either"
        await model.sendReply(in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(calls.decisions.map(\.runID), ["b"], "only the armed gate was answered")
    }

    /// A gate answered anywhere else — Archon's own UI, a terminal — takes the composer back
    /// with it. Leaving it armed would offer Send against a decision already made.
    @MainActor
    func testAGateAnsweredElsewhereDisarmsTheComposer() async throws {
        let client = FakeArchonClient(runsResponse: .fixture(runs: [.paused()]))
        let (model, _) = try await gatedModel("archon-gate-elsewhere", client: client)
        await model.choose(.reject, on: model.gated[0], in: workspace)
        XCTAssertNotNil(model.reply)

        await client.setRuns(.fixture(runs: [.fixture(id: "run-1", status: "running")]))
        await model.refresh(in: workspace)

        XCTAssertNil(model.reply)
        XCTAssertEqual(model.gated, [])
        XCTAssertEqual(
            model.actionFailure, "That gate was answered elsewhere. Nothing was sent.",
            "the silent version reverts the field mid-sentence and turns the next Enter into a launch"
        )
    }

    /// helm answering the gate itself is the one case the composer is *expected* to lose, so it
    /// gets no sentence — the approve that just succeeded is not news of a lost draft.
    ///
    /// The guard that makes this true is the `busyRuns` check in `apply`, and this is the half
    /// of it a test can pin deterministically: drop the `disarm()` from `decide` and a
    /// successful send starts telling the operator their answer went somewhere else.
    @MainActor
    func testHelmsOwnDecisionDisarmsWithoutComplaining() async throws {
        let (model, _) = try await gatedModel("archon-gate-own-decision")

        await model.choose(.reject, on: model.gated[0], in: workspace)
        model.replyText = "no good"
        await model.sendReply(in: workspace)

        XCTAssertNil(model.reply)
        XCTAssertNil(model.actionFailure)
    }

    /// A gate that is not the operator's has no verbs, and asking for one anyway is a call
    /// Archon throws on — so the model refuses before the process is spawned.
    @MainActor
    func testAGateThatIsNotYoursIsNeverSent() async throws {
        let (model, client) = try await gatedModel(
            "archon-gate-not-yours", gate: .fixture(resolved: "approved"))

        await model.choose(.approve, on: model.gated[0], in: workspace)

        let calls = await client.gateCalls()
        XCTAssertEqual(model.gated.map(\.id), ["run-1"], "it still gets a line — it is paused")
        XCTAssertEqual(calls.decisions.count, 0)
        XCTAssertNil(model.reply)
    }

    /// The rail's other failure line must not be cleared by this one: they sit on different
    /// halves and mean different things.
    @MainActor
    func testADecisionWithNoWorkspaceSaysSoOnItsOwnLine() async throws {
        let (model, _) = try await gatedModel("archon-gate-no-workspace")
        let run = model.gated[0]

        await model.choose(.approve, on: run, in: nil)

        XCTAssertEqual(model.actionFailure, ArchonRailModel.noWorkspace)
        XCTAssertNil(model.launchFailure)
    }
}

/// Records what the rail asked to open, so the click can be asserted without spawning `gh`.
private actor OpenedRuns {
    private(set) var ids: [String] = []

    func record(_ id: String) { ids.append(id) }
}
