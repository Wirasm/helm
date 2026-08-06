import XCTest

@testable import Helm

/// `WorkbenchModel` decides whether a pushed artifact lands on this bench by comparing
/// `workspacePath` **by value** — so the guarantee a newtype has to carry is that every
/// route in normalizes the same way `Workspace.path` already does.
///
/// **Not `StandardizedPath`'s discipline, on purpose, past the shared `Codable` shape.**
/// `StandardizedPath` runs through `URL.standardizedFileURL`, which collapses `.`/`..` and
/// does not expand `~`. A `WorkspacePath` built the same way would silently re-normalize
/// every persisted `Workspace`, `BenchSnapshot` and `WorkspaceContext` path on the next
/// launch — `~/Projects/foo` staying a literal `~` directory, and a path built by any code
/// that legitimately carries a `.` or `..` segment jumping to a different string. This suite
/// pins the actual, narrower contract: `Workspace.normalized`'s tilde-expand-plus-trailing-
/// slash-trim, delegated to rather than reimplemented, with symlinks and dot segments left
/// alone exactly as `Workspace.path` already leaves them.
final class WorkspacePathTests: XCTestCase {

    func testItMatchesWorkspacesOwnNormalizer() {
        for path in ["/tmp/plan", "/tmp/plan/", "~/code", "~/code/", "/", "/tmp//plan"] {
            XCTAssertEqual(
                WorkspacePath(path).value, Workspace.normalized(path),
                "WorkspacePath must delegate to Workspace.normalized rather than carry a "
                    + "second, drifting spelling of \"normalized\"")
        }
    }

    func testTildeExpands() {
        XCTAssertEqual(
            WorkspacePath("~/code").value,
            FileManager.default.homeDirectoryForCurrentUser.path + "/code")
    }

    func testTrailingSlashesAreTrimmed() {
        XCTAssertEqual(WorkspacePath("/tmp/plan/").value, "/tmp/plan")
        XCTAssertEqual(WorkspacePath("/tmp/plan///").value, "/tmp/plan")
        XCTAssertEqual(WorkspacePath("/").value, "/", "the root must not be trimmed to empty")
    }

    /// The distinguishing case from `StandardizedPath`'s `.standardizedFileURL`, and the one
    /// a regression back to it would get wrong silently: `Workspace.normalized` does not
    /// touch dot segments at all, so neither does this.
    func testDotSegmentsAreNotCollapsed() {
        XCTAssertEqual(WorkspacePath("/tmp/./plan").value, "/tmp/./plan")
        XCTAssertEqual(WorkspacePath("/tmp/sub/../plan").value, "/tmp/sub/../plan")
    }

    func testTwoSpellingsOfOneFolderAreEqual() {
        XCTAssertEqual(WorkspacePath("/a/b/"), WorkspacePath("/a/b"))
    }

    /// **The negative control, against real directories on a real filesystem.** Both
    /// directions of the hazard are silent: normalizing too little and every push/spawn/
    /// snapshot gate returns early forever; normalizing too much and two different
    /// workspaces compare equal, so a push from one lands on the other's bench. A symlink is
    /// the sharpest version of "too much" — resolving it is exactly what `Workspace.path`
    /// has never done, so it is what a regression to `StandardizedPath`-style normalization
    /// would get wrong first. Built against `NSTemporaryDirectory()` rather than asserted in
    /// the abstract, so this is a real `symlink(2)` and a real distinct directory, not a
    /// description of one.
    func testASymlinkAndItsRealTargetAreGenuinelyDifferentWorkspaces() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-workspace-path-negative-control-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real-project")
        let link = root.appendingPathComponent("link-to-real-project")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertNotEqual(
            WorkspacePath(real.path), WorkspacePath(link.path),
            "symlinks are deliberately unresolved — a push from the workspace opened at the "
                + "symlink must never land on the bench of the workspace opened at its target, "
                + "or vice versa")

        // And the ordinary case the whole type exists for: two genuinely unrelated
        // directories must never compare equal either.
        let other = root.appendingPathComponent("unrelated-project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNotEqual(WorkspacePath(real.path), WorkspacePath(other.path))
    }

    func testAURLAndItsPathStringNormalizeTheSame() {
        XCTAssertEqual(
            WorkspacePath(URL(fileURLWithPath: "/tmp/plan/")), WorkspacePath("/tmp/plan"))
    }

    func testDecodingNormalizesToo() throws {
        // A hand-edited defaults blob, or a `BenchSnapshot` an agent wrote by hand, is a
        // route in like any other.
        let raw = Data(#""/tmp/plan/""#.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePath.self, from: raw)

        XCTAssertEqual(decoded.value, "/tmp/plan")
    }

    /// The acceptance criterion #223 names: the wire shape must stay a bare string, not gain
    /// a wrapper object, so `BenchSnapshot` and `WorkspaceContext` stay byte-identical.
    func testItRoundTripsAsAPlainString() throws {
        let encoded = try JSONEncoder().encode(WorkspacePath("/tmp/plan"))

        XCTAssertEqual(
            String(decoding: encoded, as: UTF8.self), #""\/tmp\/plan""#,
            "a workspace path is read by agents outside the process, so it stays a plain "
                + "string rather than gaining a wrapper object")
        XCTAssertEqual(
            try JSONDecoder().decode(WorkspacePath.self, from: encoded), WorkspacePath("/tmp/plan"))
    }
}
