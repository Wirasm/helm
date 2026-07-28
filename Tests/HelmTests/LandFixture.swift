import Foundation

@testable import Helm

/// `LandReport` values for tests, shaped like the engine's actual `/land` response.
///
/// The previous version of this type was invented from an API sketch and shared no field
/// names with the wire, so every land call failed to decode against the real engine — and
/// the tests passed anyway, because they stubbed JSON matching the Swift type rather than a
/// captured payload. That is the precise trap `KildWireTests` warns about, so the fixture
/// lives here and the decode test uses a verbatim capture.
enum LandFixture {

    /// A landable branch: commits to carry, merges cleanly, nothing conflicting.
    static func landable(
        base: String = "development",
        branch: String? = "kild/sidebar",
        commits: Int = 3,
        files: [String] = ["A.swift", "B.swift"],
        collides: [String] = []
    ) -> LandReport {
        LandReport(
            base: base, branch: branch,
            commits: (0..<commits).map { commit(index: $0) },
            files: files, collides: collides, wouldMerge: true, merged: false,
            sha: nil, error: nil, dryRun: true)
    }

    /// A branch the engine will not land, with its reason.
    static func blocked(
        reason: String = "would not merge cleanly",
        collides: [String] = ["Shared.swift"],
        commits: Int = 2
    ) -> LandReport {
        LandReport(
            base: "development", branch: "kild/sidebar",
            commits: (0..<commits).map { commit(index: $0) },
            files: ["Shared.swift"], collides: collides, wouldMerge: false, merged: false,
            sha: nil, error: reason, dryRun: true)
    }

    /// Nothing to land — the shape the engine returns for a kild that ran on the base
    /// branch itself. Captured verbatim from a live engine.
    static func nothingToLand() -> LandReport {
        LandReport(
            base: "development", branch: "development", commits: [], files: [], collides: [],
            wouldMerge: false, merged: false, sha: nil,
            error: "the kild ran on development itself — there is no branch to land",
            dryRun: true)
    }

    static func commit(index: Int) -> ReviewCommit {
        ReviewCommit(
            sha: "sha\(index)", subject: "commit \(index)", author: "rasmus",
            ts: 1_785_180_000_000, filesChanged: 2, additions: 40, deletions: 8)
    }
}
