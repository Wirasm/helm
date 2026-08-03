import Combine
import XCTest

@testable import Helm

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

    /// **Rewritten, not deleted.** This asserted "only `running` gets a line", which was #40's
    /// first sketch and is no longer true: a paused run is stopped waiting for a person, and
    /// answering that with a number is the actions gap the rail was reframed to close. The
    /// property that replaced it is *running and paused get lines, and the collapsed counts
    /// never say the same run twice.*
    @MainActor
    func testRunningAndPausedGetLinesAndTheCountsDoNotRepeatThem() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [
                    .fixture(id: "a", status: "running"),
                    .fixture(id: "b", status: "completed"),
                    .fixture(id: "c", status: "paused"),
                ],
                counts: ["all": 9, "running": 1, "completed": 5, "paused": 1, "failed": 2]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-running"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.active.map(\.id), ["a", "c"])
        XCTAssertEqual(
            model.statusCounts.map(\.status), ["failed", "completed"],
            "the one running and the one paused run are lines above, so their counts are spent")
        XCTAssertEqual(model.statusCounts.map(\.count), [2, 5])
        XCTAssertEqual(model.liveness, .live)
    }

    /// Archon's `counts` are over the whole project while its `runs` array is the newest
    /// twenty, so a status can hold more runs than the rail can show. The remainder has to
    /// stay on the collapsed line rather than vanishing with the row.
    @MainActor
    func testARunWithNoRowLeavesItsRemainderOnTheCollapsedLine() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [.fixture(id: "a", status: "running")],
                counts: ["all": 4, "running": 3]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-remainder"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.active.map(\.id), ["a"])
        XCTAssertEqual(model.statusCounts, [ArchonStatusCount(status: "running", count: 2)])
    }

    @MainActor
    func testTheSublineIsTheCurrentNodesPreview() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        await client.setDetails([
            "a": .fixture(
                id: "a",
                nodes: [
                    .fixture(nodeId: "plan", state: .completed, outputPreview: "old"),
                    .fixture(nodeId: "implement", state: .running, outputPreview: "writing\ntests"),
                ])
        ])
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-preview"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.previews["a"], "writing tests")
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

        XCTAssertEqual(model.active.map(\.id), ["a"])
        XCTAssertNil(model.previews["a"])
        XCTAssertEqual(model.liveness, .live)
    }

    /// "No runs" and "cannot reach Archon" rendered identically before this. They are opposite
    /// states: one means nothing is happening, the other means nothing in the rail works.
    @MainActor
    func testAnEmptyAnswerIsDistinctFromNoAnswer() async throws {
        let client = FakeArchonClient()
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-liveness"))

        await model.refresh(in: workspace)
        XCTAssertEqual(model.liveness, .live)
        XCTAssertEqual(model.active, [])

        await client.setFailure(.notInstalled())
        await model.refresh(in: workspace)
        guard case let .unreachable(reason) = model.liveness else {
            return XCTFail("expected unreachable, got \(model.liveness)")
        }
        XCTAssertTrue(reason.contains("archon workflow runs"), reason)
    }

    /// The last known runs survive a failed poll: one hiccup must not make the list flap.
    @MainActor
    func testAFailedPollKeepsTheLastKnownRuns() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-stale"))
        await model.refresh(in: workspace)

        await client.setFailure(.notInstalled())
        await model.refresh(in: workspace)

        XCTAssertEqual(model.active.map(\.id), ["a"])
    }

    @MainActor
    func testWithNoWorkspaceNothingIsAskedAndNothingIsShown() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-no-workspace"))
        await model.refresh(in: workspace)

        await model.refresh(in: nil)

        XCTAssertEqual(model.active, [])
        XCTAssertEqual(model.liveness, .unknown)
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
    func testEnterLaunchesWhatTheGearHoldsAndClearsTheField() async throws {
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
        XCTAssertEqual(model.launchFailure, "Choose a workflow in the gear before launching.")

        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .automatic)
        model.draft = "   \n "
        await model.launch(in: workspace)
        XCTAssertEqual(model.launchFailure, "Type what the workflow should do.")

        model.draft = "do it"
        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .branch(" "))
        await model.launch(in: workspace)
        XCTAssertEqual(model.launchFailure, "Name the branch in the gear, or let Archon name it.")

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.launchRequests, 0, "not one of these reached Archon")
        XCTAssertEqual(model.draft, "do it", "a rejected launch must not eat what was typed")
    }

    /// Every rejection is about the draft or the gear, so touching either makes the sentence
    /// under the field a statement about a state that no longer exists.
    @MainActor
    func testEditingTheDraftOrTheGearClearsTheLastRejection() async throws {
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

    // MARK: - The gear

    @MainActor
    func testTheGearRemembersItsConfigAcrossARelaunch() throws {
        let defaults = try isolatedDefaults("archon-rail-config")
        let first = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)

        first.config = ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40"))

        let second = ArchonRailModel(client: FakeArchonClient(), defaults: defaults)
        XCTAssertEqual(
            second.config, ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40")),
            "a popover dismissed by clicking away fires nothing to save on, so every change saves")
    }

    @MainActor
    func testOpeningTheGearLoadsWorkflowsAndSeedsAnUnsetChoice() async throws {
        let client = FakeArchonClient(
            workflowList: .init(
                workflows: [.init(name: "ship", description: "Ship it", provider: nil, model: nil)],
                errors: []))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-gear"))

        await model.loadWorkflows(in: workspace)

        XCTAssertTrue(model.isConfigOpen)
        XCTAssertEqual(model.workflows.map(\.name), ["ship"])
        XCTAssertEqual(model.config.workflow, "ship")
    }

    @MainActor
    func testOpeningTheGearWithNoWorkspaceSaysSoRatherThanShowingNothing() async throws {
        let model = ArchonRailModel(
            client: FakeArchonClient(), defaults: try isolatedDefaults("archon-rail-gear-empty"))

        await model.loadWorkflows(in: nil)

        XCTAssertEqual(model.launchFailure, ArchonRailModel.noWorkspace)
    }

    // MARK: - Archon's own verbs

    /// Abandon is terminal, so nothing is resumed after it — and the rail re-reads Archon
    /// straight away rather than showing the run for another two seconds as if the click had
    /// missed.
    @MainActor
    func testAbandonEndsTheRunAndResumesNothing() async throws {
        let run = ArchonRun.fixture(id: "a", status: "running")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [run]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-abandon"))
        await model.refresh(in: workspace)

        await model.act(.abandon, on: run, in: workspace)

        let log = await client.actionLog()
        XCTAssertEqual(log.map(\.action), [.abandon])
        XCTAssertEqual(log.map(\.runID), ["a"])
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.resumedRuns, [], "abandon ends a run; there is nothing to continue")
        XCTAssertEqual(metrics.listCalls, 2, "the row must not linger after the verb succeeded")
        XCTAssertNil(model.actionFailure)
    }

    /// **The half of `approve` that Archon does not do for you.** In `--json` mode approve
    /// records the decision and returns without executing — it says so with `resumable: true` —
    /// because executing would stream workflow output over the one-line JSON contract. A rail
    /// that stopped there would leave the run sitting exactly where it was, which is a button
    /// that lies by omission.
    @MainActor
    func testApproveRecordsTheDecisionAndThenActuallyContinuesTheRun() async throws {
        let run = ArchonRun.fixture(id: "a", status: "paused")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [run]))
        await client.setActionAcknowledgement(
            .fixture(action: "approve", resumable: true))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-approve"))
        await model.refresh(in: workspace)

        await model.act(.approve(comment: nil), on: run, in: workspace)

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.resumedRuns, ["a"])
        XCTAssertNil(model.actionFailure)
    }

    /// A reject that Archon answers with `resumable: false` cancelled the run outright — there
    /// is no rework pass to drive, and resuming it anyway would restart something the operator
    /// just refused.
    @MainActor
    func testARejectThatCancelledTheRunIsNotResumed() async throws {
        let run = ArchonRun.fixture(id: "a", status: "paused")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [run]))
        await client.setActionAcknowledgement(
            .fixture(action: "reject", cancelled: true, resumable: false))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-reject"))

        await model.act(.reject(reason: nil), on: run, in: workspace)

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.resumedRuns, [])
    }

    /// The decision is already recorded by the time the resume runs, so "approve failed" would
    /// be the wrong sentence — the operator has to be told which half worked.
    @MainActor
    func testAFailedResumeSaysTheApprovalWasStillRecorded() async throws {
        let run = ArchonRun.fixture(id: "a", status: "paused")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [run]))
        await client.setActionAcknowledgement(.fixture(action: "approve", resumable: true))
        await client.setResumeFailure(.notInstalled())
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-approve-failure"))

        await model.act(.approve(comment: nil), on: run, in: workspace)

        let failure = try XCTUnwrap(model.actionFailure)
        XCTAssertTrue(failure.hasPrefix("Approve recorded, but the run did not restart:"), failure)
    }

    /// `--json` mode catches its own failures, prints `{"ok": false}` and exits ZERO. Reporting
    /// success off the exit status would tell the operator a run was abandoned that Archon
    /// never found.
    @MainActor
    func testAVerbArchonRefusedIsReportedRatherThanCountedAsDone() async throws {
        let run = ArchonRun.fixture(id: "a", status: "running")
        let client = FakeArchonClient(runsResponse: .fixture(runs: [run]))
        await client.setActionAcknowledgement(
            .fixture(ok: false, action: "abandon", error: "Workflow run not found"))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-refused"))

        await model.act(.abandon, on: run, in: workspace)

        XCTAssertEqual(
            model.actionFailure, "Archon refused to abandon this run: Workflow run not found")
    }

    // MARK: - Dismissing, which is not deleting

    /// Dismissal drops the row **and** the count it came from, so the rail never shows a
    /// dismissed run twice — once as a line and once as a number.
    @MainActor
    func testDismissingARunDropsItsLineAndItsCountWithoutTouchingArchon() async throws {
        let run = ArchonRun.fixture(id: "a", status: "running")
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [run], counts: ["all": 1, "running": 1]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-dismiss"))
        await model.refresh(in: workspace)
        XCTAssertEqual(model.active.map(\.id), ["a"])

        model.dismiss(run, in: workspace)

        XCTAssertEqual(model.active, [])
        XCTAssertEqual(model.statusCounts, [], "a dismissed run must not come back as a number")
        XCTAssertEqual(model.dismissedCount, 1)
        let log = await client.actionLog()
        XCTAssertTrue(log.isEmpty, "dismissal is helm's own filter — Archon is never told")
    }

    /// Bulk is the real case, and it has to ask Archon for the ids: the line's number comes
    /// from `counts`, computed over the whole project, while the rows are the newest twenty.
    /// Dismissing what happened to be on hand would take a line reading 128 to 108.
    @MainActor
    func testDismissingAStatusAsksForEveryRunInItRatherThanTheVisibleTwenty() async throws {
        let completed = (1...3).map { ArchonRun.fixture(id: "c\($0)", status: "completed") }
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: completed, counts: ["all": 3, "completed": 3]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-dismiss-all"))
        await model.refresh(in: workspace)
        XCTAssertEqual(model.statusCounts.map(\.count), [3])

        await model.dismissAll(status: "completed", in: workspace)

        XCTAssertEqual(model.statusCounts, [])
        XCTAssertEqual(model.dismissedCount, 3)
        let metrics = await client.metrics()
        XCTAssertEqual(metrics.statusFilters.last, "completed")
        XCTAssertEqual(
            metrics.limits.last, ArchonRailModel.bulkDismissLimit,
            "'dismiss all' that dismisses the newest twenty of a hundred is not 'all'")
    }

    /// The way back. Dismissal is a view filter, and a filter with no undo is indistinguishable
    /// from the deletion Archon does not offer and helm must not imply.
    @MainActor
    func testDismissalsSurviveARelaunchAndCanBeUndone() async throws {
        let defaults = try isolatedDefaults("archon-rail-dismiss-persist")
        let run = ArchonRun.fixture(id: "a", status: "running")
        let response = ArchonRunsResponse.fixture(runs: [run], counts: ["all": 1, "running": 1])
        let first = ArchonRailModel(
            client: FakeArchonClient(runsResponse: response), defaults: defaults)
        await first.refresh(in: workspace)
        first.dismiss(run, in: workspace)

        let second = ArchonRailModel(
            client: FakeArchonClient(runsResponse: response), defaults: defaults)
        await second.refresh(in: workspace)
        XCTAssertEqual(second.active, [], "a dismissal that a relaunch forgets is not a dismissal")

        second.restoreDismissed(in: workspace)

        XCTAssertEqual(second.active.map(\.id), ["a"])
        XCTAssertEqual(second.dismissedCount, 0)
    }

    /// Per workspace: dismissing a run in one project must not hide anything in another, and
    /// the two projects' Archon histories have nothing to do with each other.
    @MainActor
    func testDismissalsAreScopedToOneWorkspace() async throws {
        let defaults = try isolatedDefaults("archon-rail-dismiss-scope")
        let run = ArchonRun.fixture(id: "a", status: "running")
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [run], counts: ["all": 1, "running": 1]))
        let model = ArchonRailModel(client: client, defaults: defaults)
        await model.refresh(in: workspace)
        model.dismiss(run, in: workspace)
        XCTAssertEqual(model.active, [])

        await model.refresh(in: "/tmp/other-project")

        XCTAssertEqual(model.active.map(\.id), ["a"])
    }
}
