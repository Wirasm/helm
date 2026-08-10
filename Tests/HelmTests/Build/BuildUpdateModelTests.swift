import XCTest

@testable import Helm

/// What the model does with a stamp, on top of what `BuildUpdate.decide` does with a value.
///
/// The pure rule is tested in `BuildUpdateTests`; these are the three things only the model
/// can answer, because each one needs the filesystem or the environment.
@MainActor
final class BuildUpdateModelTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("build-update-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    private func writeStamp(sha: String, product: String) throws -> BuildStampDirectory {
        let directory = BuildStampDirectory(root: scratch.appendingPathComponent("stamps"))
        try FileManager.default.createDirectory(
            at: directory.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BuildStamp(sha: sha, builtAt: Date(), product: product))
            .write(to: directory.latest)
        return directory
    }

    private func makeBundle(named name: String) throws -> URL {
        let bundle = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    func testOffersABuildWhoseProductIsOnDisk() async throws {
        let product = try makeBundle(named: "New.app")
        let directory = try writeStamp(sha: "def5678", product: product.path)
        let model = BuildUpdateModel(
            directory: directory,
            runningSHA: "abc1234",
            isIsolated: false,
            installTarget: try makeBundle(named: "Installed.app"))

        await model.refresh()

        XCTAssertEqual(model.update.waiting?.sha, "def5678")
    }

    /// **A badge must never be a button that does nothing.** `make clean` after a build leaves
    /// a stamp pointing at a product that is gone; offering it would put a control in the bar
    /// whose only possible outcome is a line in the system log. The filesystem check belongs
    /// here rather than in `BuildUpdate.decide`, which is pure on purpose.
    func testDoesNotOfferABuildWhoseProductHasBeenDeleted() async throws {
        let directory = try writeStamp(
            sha: "def5678", product: scratch.appendingPathComponent("Gone.app").path)
        let model = BuildUpdateModel(
            directory: directory,
            runningSHA: "abc1234",
            isIsolated: false,
            installTarget: try makeBundle(named: "Installed.app"))

        await model.refresh()

        XCTAssertEqual(model.update, .upToDate)
    }

    /// A worktree instance under `HELM_DEFAULTS_SUITE` does not get to offer to replace the
    /// operator's installed application — the policy the stamp directory deliberately does not
    /// encode as a path.
    func testIsolatedInstanceNeverPolls() async throws {
        let product = try makeBundle(named: "New.app")
        let directory = try writeStamp(sha: "def5678", product: product.path)
        let model = BuildUpdateModel(
            directory: directory,
            runningSHA: "abc1234",
            isIsolated: true,
            installTarget: try makeBundle(named: "Installed.app"))

        // `poll` is the isolation gate — it returns immediately rather than looping, so this
        // await is the assertion that it never reaches `refresh`.
        await model.poll(every: .milliseconds(1))

        XCTAssertEqual(model.update, .upToDate)
    }

    /// Nothing is installed over itself: that would delete the bundle and copy it back, which
    /// is a great deal of risk for no change at all.
    func testRefusesToInstallABuildOverItself() async throws {
        let bundle = try makeBundle(named: "Helm.app")
        let directory = try writeStamp(sha: "def5678", product: bundle.path)
        let model = BuildUpdateModel(
            directory: directory,
            runningSHA: "abc1234",
            isIsolated: false,
            installTarget: bundle)

        await model.refresh()
        XCTAssertEqual(model.update.waiting?.sha, "def5678", "precondition: the badge is showing")

        // Returns without starting a helper and without terminating; the bundle is untouched.
        model.relaunch()

        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }
}
