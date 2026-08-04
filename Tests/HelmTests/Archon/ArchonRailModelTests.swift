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

    /// **Rewritten twice, not deleted.** It first asserted that a paused run gets its own line;
    /// the minimal rail gave it a count instead. Now the counts are gone too, so what it
    /// asserts is the split that replaced them: `running` gets a live line, `completed` and
    /// `failed` go to the inbox, and everything else gets nothing at all.
    ///
    /// **`paused` getting nothing is the deliberate hole**, recorded on `ArchonRailModel`: it
    /// had only a number, and a row for it means putting the approve/reject verbs back.
    @MainActor
    func testRunningRunsGetALineAndFinishedRunsGetAnInboxRow() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [
                    .fixture(id: "a", status: "running"),
                    .fixture(id: "b", status: "completed"),
                    .fixture(id: "c", status: "paused"),
                    .fixture(id: "d", status: "failed"),
                    .fixture(id: "e", status: "cancelled"),
                ],
                counts: ["all": 9, "running": 1, "completed": 5, "paused": 1, "failed": 2]))
        let model = ArchonRailModel(
            client: client, defaults: try isolatedDefaults("archon-rail-running"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertEqual(
            Set(model.finished.map(\.id)), ["b", "d"],
            "completed and failed are the inbox; cancelled produced nothing and paused is not finished"
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
}

/// Records what the rail asked to open, so the click can be asserted without spawning `gh`.
private actor OpenedRuns {
    private(set) var ids: [String] = []

    func record(_ id: String) { ids.append(id) }
}
