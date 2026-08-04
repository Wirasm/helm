import Combine
import XCTest

@testable import Helm

/// The rail, after the reduction.
///
/// **A lot of this suite's subjects genuinely no longer exist**, and the ones that were merely
/// *renamed* are rewritten to the property that replaced them rather than dropped:
/// "running and paused both get lines" became "only running does", and "the subline is the
/// current node's output preview" became "the subline is the current node's stage". What is
/// gone entirely is the liveness state, the `approve`/`reject`/`abandon` verbs and the
/// dismissal filter — see the commit message.
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

    /// **Rewritten, not deleted.** This asserted that a paused run gets a line of its own, on
    /// the argument that it is the one status blocked on the operator. The minimal rail gives
    /// a line to `running` and a count to everything else including `paused` — which is also
    /// what removed the approve/reject gate, since there is no longer a row to hang it on.
    @MainActor
    func testOnlyRunningRunsGetALineAndTheCountsDoNotRepeatThem() async throws {
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

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertEqual(
            model.statusCounts.map(\.status), ["paused", "failed", "completed"],
            "the one running run is a line above, so its count is spent and paused is not")
        XCTAssertEqual(model.statusCounts.map(\.count), [1, 2, 5])
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

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertEqual(model.statusCounts, [ArchonStatusCount(status: "running", count: 2)])
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
        XCTAssertEqual(model.statusCounts, [])
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
}
