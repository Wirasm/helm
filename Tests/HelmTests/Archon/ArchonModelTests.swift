import Combine
import XCTest

@testable import Helm

/// The Archon drawer's model (#382): three lists from `workflow runs`, the live runs' nodes
/// from one `workflow status`, the attention queue answered through the composer, and the
/// finished inbox.
///
/// The rail's visibility tests left with the rail: the drawer is shown by benchd's document
/// (`DrawerTests`), and the rail itself is gone (#382).
// swiftlint:disable:next type_body_length - legacy (#418): 521 lines, limit 350
final class ArchonModelTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/project")

    // MARK: - Polling

    /// **Rewritten four times, not deleted.** What it asserts now is the split the attention
    /// queue drew: the queue is Archon's, a paused run it holds is not drawn twice, a paused run
    /// it does not hold (a sub-run's parent, an answer being continued) is live work, and
    /// `cancelled` is still nowhere because the operator ended it themselves.
    @MainActor
    func testTheListsAreTheQueueRunningAndFinished() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(
                runs: [
                    .fixture(id: "a", status: "running"),
                    .fixture(id: "b", status: "completed"),
                    .fixture(id: "c", status: "paused"),
                    .fixture(id: "p", status: "paused"),
                    .fixture(id: "d", status: "failed"),
                    .fixture(id: "e", status: "cancelled"),
                ],
                counts: ["all": 9, "running": 1, "completed": 5, "paused": 1, "failed": 2]))
        await client.setQueue([try .select(runId: "c")])
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-running"))

        await model.refresh(in: workspace)

        XCTAssertEqual(model.queue.map(\.runId), ["c"])
        XCTAssertEqual(model.running.map(\.id), ["a", "p"])
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
        let model = ArchonModel(
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
        let model = ArchonModel(
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
        let model = ArchonModel(client: client, defaults: defaults)
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
        let first = ArchonModel(client: client, defaults: defaults)
        await first.refresh(in: workspace)
        first.dismiss(try XCTUnwrap(first.finished.first), in: workspace)

        let second = ArchonModel(client: client, defaults: defaults)
        await second.refresh(in: workspace)

        XCTAssertEqual(second.finished, [])
    }

    /// A run cleared in one workspace is not cleared in another — the store is keyed by
    /// workspace, and two projects' inboxes are separate.
    @MainActor
    func testClearingIsScopedToTheWorkspace() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "b", status: "completed")]))
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-dismiss-scope"))
        await model.refresh(in: workspace)
        model.dismiss(try XCTUnwrap(model.finished.first), in: workspace)

        await model.refresh(in: WorkspacePath("/tmp/other-project"))

        XCTAssertEqual(model.finished.map(\.id), ["b"])
    }

    /// Clicking a finished row asks the opener for that run, and nothing spawns during a poll.
    @MainActor
    func testOpeningAFinishedRunAsksTheOpenerOnceForThatRun() async throws {
        let opened = OpenedRuns()
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "b", status: "completed")]))
        let model = ArchonModel(
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

    /// The last known runs survive a failed poll: one hiccup must not make the lines flap.
    @MainActor
    func testAFailedPollKeepsTheLastKnownRuns() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-stale"))
        await model.refresh(in: workspace)

        await client.setFailure(.notInstalled())
        await model.refresh(in: workspace)

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertNil(model.refreshFailure, "one hiccup after a good poll says nothing")
    }

    /// #523: with no rows to keep, a failed poll must not read as "no runs here yet".
    @MainActor
    func testAPollThatFailsWithNothingToShowSaysWhy() async throws {
        let client = FakeArchonClient()
        await client.setFailure(.notInstalled())
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-first-failure"))

        await model.refresh(in: workspace)

        let failure = try XCTUnwrap(model.refreshFailure)
        XCTAssertTrue(failure.contains("/tmp/project"), failure)
        XCTAssertTrue(failure.contains("No such file or directory"), failure)
    }

    /// #523: a second failure in a row is not a hiccup. The rows stay, the reason joins them,
    /// and the next good poll takes it away.
    @MainActor
    func testFailuresThatKeepHappeningSayWhyUntilAPollSucceeds() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-repeated-failure"))
        await model.refresh(in: workspace)

        await client.setFailure(.notInstalled())
        await model.refresh(in: workspace)
        await model.refresh(in: workspace)

        XCTAssertEqual(model.running.map(\.id), ["a"])
        XCTAssertNotNil(model.refreshFailure)

        await client.setFailure(nil)
        await model.refresh(in: workspace)
        XCTAssertNil(model.refreshFailure)
    }

    @MainActor
    func testWithNoWorkspaceNothingIsAskedAndNothingIsShown() async throws {
        let client = FakeArchonClient(
            runsResponse: .fixture(runs: [.fixture(id: "a", status: "running")]))
        let model = ArchonModel(
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
        let model = ArchonModel(
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
        let model = ArchonModel(
            client: FakeArchonClient(), defaults: try isolatedDefaults("archon-rail-poll"))
        let poll = Task {
            await model.poll(in: WorkspacePath("/tmp/project"), every: .milliseconds(1))
        }
        try? await Task.sleep(for: .milliseconds(10))
        poll.cancel()
        await poll.value
    }

    // MARK: - Launching

    @MainActor
    func testSendLaunchesWhatTheSettingsHoldAndClearsTheField() async throws {
        let client = FakeArchonClient()
        let model = ArchonModel(
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
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-rejections"))

        model.config = ArchonLaunchConfig(workflow: "ship", worktree: .automatic)
        model.draft = "do it"
        await model.launch(in: nil)
        XCTAssertEqual(model.launchFailure, ArchonModel.noWorkspace)

        model.config = ArchonLaunchConfig(workflow: "  ", worktree: .automatic)
        await model.launch(in: workspace)
        XCTAssertEqual(model.launchFailure, "Choose a workflow before launching.")

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
        let model = ArchonModel(
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
        let model = ArchonModel(
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
        let model = ArchonModel(
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
        let first = ArchonModel(client: FakeArchonClient(), defaults: defaults)

        first.config = ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40"))

        let second = ArchonModel(client: FakeArchonClient(), defaults: defaults)
        XCTAssertEqual(
            second.config, ArchonLaunchConfig(workflow: "ship", worktree: .branch("issue-40")),
            "a popover dismissed by clicking away fires nothing to save on, so every change saves")
    }

    @MainActor
    func testLoadingWorkflowsSeedsAnUnsetChoice() async throws {
        let client = FakeArchonClient(
            workflowList: .init(
                workflows: [.init(name: "ship", description: "Ship it", provider: nil, model: nil)],
                errors: []))
        let model = ArchonModel(
            client: client, defaults: try isolatedDefaults("archon-rail-settings"))

        await model.loadWorkflows(in: workspace)

        XCTAssertEqual(model.workflows.map(\.name), ["ship"])
        XCTAssertEqual(model.config.workflow, "ship")
    }

    @MainActor
    func testLoadingWorkflowsWithNoWorkspaceSaysSoRatherThanShowingNothing() async throws {
        let model = ArchonModel(
            client: FakeArchonClient(),
            defaults: try isolatedDefaults("archon-rail-settings-empty"))

        await model.loadWorkflows(in: nil)

        XCTAssertEqual(model.launchFailure, ArchonModel.noWorkspace)
    }

    // MARK: - Answering the queue

    @MainActor
    private func queuedModel(
        _ name: String, items: [ArchonAttentionItem]? = nil, client: FakeArchonClient? = nil
    ) async throws -> (ArchonModel, FakeArchonClient) {
        let client = client ?? FakeArchonClient()
        await client.setQueue(try items ?? [.select()])
        let model = ArchonModel(client: client, defaults: try isolatedDefaults(name))
        await model.refresh(in: workspace)
        return (model, client)
    }

    private let rerun = ArchonChoice(id: "rerun", label: "Review again")

    /// Choosing an answer points the composer at it and sends nothing: Archon records the text
    /// with the answer, and the SDLC stages make it the ruling the next round works from.
    @MainActor
    func testChoosingAnAnswerArmsTheComposerAndSendsNothing() async throws {
        let (model, client) = try await queuedModel("archon-queue-arm")

        model.choose(rerun, on: model.queue[0])

        let calls = await client.answerCalls()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(
            model.reply,
            ArchonAnswer(
                runID: "run-1", occurrence: "occ-1", choice: rerun, workflowName: "archon-review"))
    }

    /// **The launch draft survives an answer.** One field, two strings behind it.
    @MainActor
    func testAnsweringNeverTouchesTheLaunchDraft() async throws {
        let (model, _) = try await queuedModel("archon-queue-draft")
        model.draft = "half a launch"

        model.choose(rerun, on: model.queue[0])
        model.replyText = "the reason"
        model.disarm()

        XCTAssertEqual(model.draft, "half a launch")
        XCTAssertNil(model.reply)
    }

    /// The typed reason and the occurrence it was read at reach Archon, and a sent answer gives
    /// the composer back. An empty reason is allowed: it is optional to Archon.
    @MainActor
    func testSendingCarriesTheTextAndTheOccurrence() async throws {
        let (model, client) = try await queuedModel("archon-queue-send")

        model.choose(rerun, on: model.queue[0])
        model.replyText = "review PR 5173"
        await model.sendReply(in: workspace)
        model.choose(rerun, on: model.queue[0])
        await model.sendReply(in: workspace)

        let calls = await client.answerCalls()
        XCTAssertEqual(calls.map(\.text), ["review PR 5173", ""])
        XCTAssertEqual(calls.map(\.answer.occurrence), ["occ-1", "occ-1"])
        XCTAssertNil(model.reply)
        XCTAssertNil(model.actionFailure)
    }

    /// A `message` wait's answer is its text, so an empty one is an Enter pressed by accident
    /// and is not sent. Archon itself would record it.
    @MainActor
    func testAMessageWaitIsNotAnsweredEmpty() async throws {
        let message = try ArchonAttentionItem.captured()[1]
        let (model, client) = try await queuedModel("archon-queue-message", items: [message])

        model.choose(message.choices[0], on: model.queue[0])
        model.replyText = "  "
        await model.sendReply(in: workspace)

        let calls = await client.answerCalls()
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(model.actionFailure, "Type the answer first.")
        XCTAssertNotNil(model.reply, "still armed, so the answer can be typed")
    }

    /// A refusal in the payload and a call that throws both reach the action line, and the
    /// composer stays armed so the answer is not lost.
    @MainActor
    func testARefusedOrFailedAnswerIsReportedAndKept() async throws {
        let (model, client) = try await queuedModel("archon-queue-refused")

        await client.setAnswer(.fixture(ok: false, error: "already answered"))
        model.choose(rerun, on: model.queue[0])
        model.replyText = "why"
        await model.sendReply(in: workspace)
        XCTAssertEqual(model.actionFailure, "Archon refused: already answered")
        XCTAssertNotNil(model.reply)

        await client.setAnswerFailure(.notInstalled())
        await model.sendReply(in: workspace)
        XCTAssertTrue(
            model.actionFailure?.contains("No such file or directory") == true,
            "got \(String(describing: model.actionFailure))")
        XCTAssertNotNil(model.reply)
    }

    /// A second Enter while the first answer is in flight is the double answer Archon refuses.
    /// `busyRuns` is inserted before the first call suspends, so the second finds it busy.
    @MainActor
    func testADoublePressSendsOneAnswer() async throws {
        let client = FakeArchonClient()
        await client.setDelay(.milliseconds(50))
        let (model, _) = try await queuedModel("archon-queue-double", client: client)

        model.choose(rerun, on: model.queue[0])
        let workspace = self.workspace
        let first = Task { await model.sendReply(in: workspace) }
        let second = Task { await model.sendReply(in: workspace) }
        await first.value
        await second.value

        let calls = await client.answerCalls()
        XCTAssertEqual(calls.count, 1, "the second press found the run already busy")
    }

    /// An item answered anywhere else takes the composer back with it, and says so: otherwise
    /// the field reverts under the operator's hands and the next Enter launches a workflow.
    @MainActor
    func testAnItemAnsweredElsewhereDisarmsTheComposer() async throws {
        let (model, client) = try await queuedModel("archon-queue-elsewhere")
        model.choose(rerun, on: model.queue[0])

        await client.setQueue([try .select(occurrence: "occ-2")])
        await model.refresh(in: workspace)

        XCTAssertNil(model.reply, "the run moved to a new question; the old answer is void")
        XCTAssertEqual(
            model.actionFailure, "That question was answered elsewhere. Nothing was sent.")
    }

    /// helm answering the item itself is the one case the composer is *expected* to lose, so it
    /// says nothing.
    @MainActor
    func testOurOwnAnswerLeavesNoSentence() async throws {
        let (model, client) = try await queuedModel("archon-queue-own")
        model.choose(rerun, on: model.queue[0])
        await client.setQueue([])

        await model.sendReply(in: workspace)

        XCTAssertNil(model.reply)
        XCTAssertNil(model.actionFailure)
        XCTAssertEqual(model.queue, [])
    }

    /// An item with no occurrence (a usage limit, an unreadable pause) has nothing to answer.
    @MainActor
    func testAnItemWithNothingToAnswerNeverArms() async throws {
        let json = """
            {"kind":"unreadable","runId":"x","workflow":"w","pausedAt":null,
             "context":{"workingPath":null,"branch":null},"reason":"malformed_gate","detail":"?"}
            """
        let item = try JSONDecoder.archon().decode(ArchonAttentionItem.self, from: Data(json.utf8))
        let (model, _) = try await queuedModel("archon-queue-unreadable", items: [item])

        model.choose(rerun, on: model.queue[0])

        XCTAssertNil(model.reply)
    }

    /// The answer's failure line must not be cleared by the launch's: they mean different
    /// things.
    @MainActor
    func testAnAnswerWithNoWorkspaceSaysSoOnItsOwnLine() async throws {
        let (model, _) = try await queuedModel("archon-queue-no-workspace")
        model.choose(rerun, on: model.queue[0])

        await model.sendReply(in: nil)

        XCTAssertEqual(model.actionFailure, ArchonModel.noWorkspace)
        XCTAssertNil(model.launchFailure)
    }
}

/// Records what the rail asked to open, so the click can be asserted without spawning `gh`.
private actor OpenedRuns {
    private(set) var ids: [String] = []

    func record(_ id: String) { ids.append(id) }
}
