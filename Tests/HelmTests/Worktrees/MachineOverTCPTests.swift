import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The Worktrees drawer, the Archon drawer and a tab's branch against a real benchd reached only
/// over TCP, whose disk this process cannot read (M5c, #459): every repository, git command and
/// Archon run is benchd's machine's.
///
/// **Skipped unless a harness sets it up**, because the Swift gate needs no benchd: a benchd with
/// `BENCH_LISTEN` and a `HOME` of its own holding `Projects/app` — cloned from a bare origin, on
/// `main`, with a worktree `.worktrees/feature` one commit ahead holding one untracked file and a
/// worktree `.worktrees/merged-one` at main's tip — and a stub `archon` in its `~/.bun/bin` that
/// prints Archon's run list; and this test run where that `HOME` is unreadable, under
/// `sandbox-exec` denying it, with an empty `BENCH_DIR`. `HELM_REMOTE_BENCH_URL` and
/// `HELM_REMOTE_REPO` (the `app` path) name the two. `HELM_REMOTE_HOST=local` runs it with git
/// and archon run on this machine instead, the behaviour before M5c, which the red run uses.
@MainActor
final class MachineOverTCPTests: XCTestCase {
    private var host: (any BenchHost)!
    private var benchd: BenchdHost!
    private var app: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_REMOTE_BENCH_URL"], let repo = env["HELM_REMOTE_REPO"] else {
            throw XCTSkip("needs a benchd over TCP (see the header)")
        }
        benchd = BenchdHost(
            endpoint: try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get())
        app = repo
        host =
            env["HELM_REMOTE_HOST"] == "local"
            ? LocalBenchHost(environment: env, homeDirectory: env["HOME"] ?? NSHomeDirectory())
            : benchd
        XCTAssertFalse(
            FileManager.default.isReadableFile(atPath: repo + "/a.txt"),
            "precondition: this process cannot read benchd's disk")
    }

    /// The drawer lists benchd's repository, and a delete keeps every rule: the loss is named,
    /// new work asks again, an unmerged branch stays and a merged one goes.
    func testTheWorktreesDrawerListsAndDeletesOnBenchdsMachine() async throws {
        let feature = app + "/.worktrees/feature"
        let merged = app + "/.worktrees/merged-one"
        let host = self.host!
        let found = try await benchd.repositories(workspaces: [app])
        XCTAssertEqual(found.first, BenchGitRepository(commonDir: app + "/.git", isWorkspace: true))

        let common = app + "/.git"
        let model = WorktreesModel(
            worktreeClient: WorktreeCLI(host: host),
            discover: { _ in [BenchGitRepository(commonDir: common, isWorkspace: true)] })
        await model.refresh(workspaces: [app])
        XCTAssertEqual(model.refreshFailures, [:])
        let rows = model.repos.flatMap(\.worktrees)
        XCTAssertEqual(Set(rows.map(\.id)), [app, feature, merged], "benchd's worktrees")
        let featureRow = try XCTUnwrap(rows.first { $0.id == feature })
        XCTAssertTrue(featureRow.exists)

        await model.requestDelete(of: featureRow)
        guard case let .delete(_, loss) = model.confirmation else {
            return XCTFail("no confirmation: \(String(describing: model.confirmation))")
        }
        XCTAssertEqual(loss.uncommittedFiles, 1)
        XCTAssertEqual(loss.unmergedCommits, 1)

        // New work while the dialog is open: a commit, made on benchd's machine.
        let committed = try await host.run(
            .git(args: [
                "-C", feature, "-c", "user.name=t", "-c", "user.email=t@example.com",
                "commit", "-q", "--allow-empty", "-m", "more",
            ]), timeout: .seconds(20))
        XCTAssertEqual(committed.status, 0)
        await model.confirm()
        guard case let .delete(_, again) = model.confirmation else {
            return XCTFail("new work must be asked about again")
        }
        XCTAssertEqual(again.unmergedCommits, 2)
        let stillThere = try await benchd.existing([feature])
        XCTAssertEqual(stillThere, [feature], "nothing removed before the second yes")

        await model.confirm()
        XCTAssertNil(model.actionFailures[feature])
        let afterFeature = try await benchd.existing([feature])
        XCTAssertEqual(afterFeature, [], "removed on benchd's machine")
        let kept = try await benchd.run(
            .git(args: ["-C", app, "branch", "--list", "feature"]), timeout: .seconds(20))
        XCTAssertEqual(
            String(decoding: kept.stdout, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines), "feature", "an unmerged branch is never deleted")

        let mergedRow = try XCTUnwrap(model.repos.flatMap(\.worktrees).first { $0.id == merged })
        await model.requestDelete(of: mergedRow)
        guard case let .delete(_, nothing) = model.confirmation else {
            return XCTFail("no confirmation for the merged worktree")
        }
        XCTAssertTrue(nothing.losesNothing)
        await model.confirm()
        let gone = try await benchd.run(
            .git(args: ["-C", app, "branch", "--list", "merged-one"]), timeout: .seconds(20))
        XCTAssertEqual(gone.stdout, Data(), "a merged branch goes with its worktree")
    }

    /// The Archon drawer's runs come from the `archon` on benchd's machine, and the tab's branch
    /// from benchd's git.
    func testTheArchonDrawerAndTheBranchLabelAreBenchdsMachines() async throws {
        let runs = try await ArchonCLI(host: host).runs(in: WorkspacePath(app))
        XCTAssertFalse(runs.runs.isEmpty, "the stub's run list, read on benchd's machine")
        let branch = await WorkspaceModel.currentBranch(in: WorkspacePath(app), host: host)
        XCTAssertEqual(branch, "main")
    }
}
