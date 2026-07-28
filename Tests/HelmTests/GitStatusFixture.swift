import Foundation

@testable import Helm

/// Construct a `GitStatus` for tests.
///
/// `GitStatus` has no defaults in production on purpose: every field is present whenever the
/// engine sends the block at all, and a type that could be half-built would let a test pass
/// against a shape the wire never produces. The convenience lives here, in the test target,
/// where a default is a fixture rather than an assumption about the engine.
enum GitFixture {

    /// A successful measurement. Defaults describe a clean tree with nothing to land, so
    /// each test states only the fields it is actually about.
    static func measured(
        ahead: Int = 0,
        behind: Int = 0,
        dirty: Bool = false,
        uncommittedFiles: Int = 0,
        changedFiles: [String] = [],
        conflictsWithBase: Bool? = false,
        path: String = "/repo",
        branch: String? = "kild/x",
        base: String = "development"
    ) -> GitStatus {
        GitStatus(
            path: path, branch: branch, base: base, ahead: ahead, behind: behind,
            dirty: dirty, uncommittedFiles: uncommittedFiles, changedFiles: changedFiles,
            conflictsWithBase: conflictsWithBase, error: nil)
    }

    /// A **failed** probe, exactly as the engine returns one.
    ///
    /// The values are the engine's safe defaults — `ahead: 0`, `dirty: false`,
    /// `changedFiles: []` — which is the whole hazard: they are indistinguishable from a
    /// clean, up-to-date repository unless a reader checks `error`. Tests that assert helm
    /// does not trust this shape are the point of having it.
    static func failed(_ reason: String = "fatal: not a git repository") -> GitStatus {
        GitStatus(
            path: "/repo", branch: nil, base: "development", ahead: 0, behind: 0,
            dirty: false, uncommittedFiles: 0, changedFiles: [],
            conflictsWithBase: nil, error: reason)
    }
}
