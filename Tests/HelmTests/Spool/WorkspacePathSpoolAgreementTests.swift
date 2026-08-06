import Foundation
import HelmWire
import XCTest

@testable import Helm

/// Two independent call sites normalize a workspace-shaped path — `WorkspacePath.init` and
/// `SpoolPolicy.accept`'s spawn validation — and both call `HelmWire.FilesystemPath.normalized`
/// directly rather than through a shared chain (`Workspace.normalized`'s header has the
/// reasoning for why that indirection was removed). Calling the same function directly from two
/// places is not the same guarantee as calling it through one shared caller: nothing in the
/// type system stops either site from drifting if it is edited in isolation, and `helm-spool`
/// writing a `cwd` that `WorkbenchSpoolSpawner` then compares against a `WorkspacePath` is one
/// of the four agent-facing gates — a silent disagreement there is a spawn that lands in the
/// wrong workspace, or in none.
///
/// **Same shape as `SpoolWireConformanceTests`**: two sides of a boundary that must agree,
/// proven against real inputs rather than assumed from the fact that they currently call the
/// same function.
final class WorkspacePathSpoolAgreementTests: XCTestCase {
    private static let captures = URL(fileURLWithPath: "/tmp/spool/captures")

    private var symlinkRoot: URL!
    private var target: URL!
    private var link: URL!

    override func setUpWithError() throws {
        symlinkRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-path-agreement-\(UUID().uuidString)")
        target = symlinkRoot.appendingPathComponent("real-target")
        link = symlinkRoot.appendingPathComponent("via-symlink")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: symlinkRoot)
        symlinkRoot = nil
        target = nil
        link = nil
    }

    /// What `SpoolPolicy.accept` normalizes a spawn's `cwd` to — the spool side of the
    /// boundary. `isDirectory` always answers yes, so the only thing under test is the
    /// normalization itself, not the directory-existence gate `SpoolPolicy` also runs.
    private func spoolNormalized(_ path: String) throws -> String {
        let request = SpoolRequest.spawn(SpawnRequest(id: "wp-agree", cwd: path, command: "claude"))
        guard
            case .spawn(let accepted) = try SpoolPolicy.accept(
                request, captures: Self.captures, isDirectory: { _ in true }
            ).get()
        else {
            throw SpoolRefusal("expected a spawn")
        }
        return accepted.cwd
    }

    func testWorkspacePathAndTheSpoolAgreeOnEveryCase() throws {
        var cases = [
            "~/foo",  // tilde expands
            "/a/b/",  // one trailing slash, trimmed
            "/a/b//",  // two trailing slashes, both trimmed
            "/a/./b",  // dot segment — must survive, not collapse
            "/a/../b",  // dot-dot segment — must survive, not collapse
            "/",  // the single-slash edge the trim loop's `count > 1` guards
        ]
        cases.append(link.path)
        cases.append(target.path)

        for path in cases {
            let workspace = WorkspacePath(path).value
            let spool = try spoolNormalized(path)
            XCTAssertEqual(
                workspace, spool,
                "WorkspacePath and SpoolPolicy.accept disagree on \"\(path)\": "
                    + "\"\(workspace)\" vs \"\(spool)\"")
        }
    }

    /// The main loop above proves the two sides agree; it does not prove they agree on the
    /// *right* answer — both could drift to collapsing dot segments together and this test
    /// would still be green. `AGENTS.md`: symlinks are deliberately unresolved because the
    /// path the operator chose is the path helm shows and filters on, and the same is true of
    /// `.`/`..` — collapsing them would let a symlinked ancestor make `/a/../b` and `/b` the
    /// same identity when they are not.
    func testDotSegmentsSurviveNormalizationUnchangedOnBothSides() throws {
        XCTAssertEqual(WorkspacePath("/a/./b").value, "/a/./b")
        XCTAssertEqual(try spoolNormalized("/a/./b"), "/a/./b")
        XCTAssertEqual(WorkspacePath("/a/../b").value, "/a/../b")
        XCTAssertEqual(try spoolNormalized("/a/../b"), "/a/../b")
    }

    /// The other half of the same guard, against a **real** filesystem symlink rather than two
    /// strings that merely look different: a spawn's `cwd` must not silently become a
    /// different workspace than the one the caller named, on either side of the boundary.
    func testASymlinkAndItsTargetStayTwoDifferentWorkspacesOnBothSides() throws {
        XCTAssertNotEqual(link.path, target.path, "the fixture itself must be two real paths")
        XCTAssertNotEqual(WorkspacePath(link.path).value, WorkspacePath(target.path).value)
        XCTAssertNotEqual(try spoolNormalized(link.path), try spoolNormalized(target.path))
    }
}
