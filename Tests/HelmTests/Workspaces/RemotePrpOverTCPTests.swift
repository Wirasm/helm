import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The artifact browser and ⇧⌘O against a real benchd reached only over TCP (M5c, #459): benchd's
/// stores are listed, the workspace's is picked, and a typed `~` is benchd's home.
///
/// Skipped unless the harness `RemoteNoteOverTCPTests` describes sets it up, and run after it, so
/// the workspace's store holds the note that test made.
@MainActor
final class RemotePrpOverTCPTests: XCTestCase {
    private var prp: PrpStores!
    private var client: BenchClient!
    private var remoteHome: String!
    private var workspace: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["HELM_REMOTE_BENCH_URL"], let home = env["HELM_REMOTE_HOME"],
            let workspace = env["HELM_REMOTE_WORKSPACE"]
        else { throw XCTSkip("needs a benchd over TCP (see RemoteNoteOverTCPTests)") }
        client = BenchClient(
            endpoint: try BenchRoot.endpoint(environment: ["BENCH_URL": url]).get())
        prp = PrpStores(client: client)
        remoteHome = home
        self.workspace = workspace
    }

    override func tearDown() {
        client?.stop()
    }

    func testTheBrowserListsBenchdsStoreForTheWorkspace() throws {
        let listing = ArtifactListing.load(prp, workspace: workspace, remembered: "")
        XCTAssertNil(listing.failure)
        let store = try XCTUnwrap(listing.selectedStore, "the workspace's store is picked")
        XCTAssertEqual(store.path, workspace)
        XCTAssertTrue(store.dir.hasPrefix(remoteHome + "/.prp/"), store.dir)
        XCTAssertTrue(
            listing.files.contains { $0.relative.hasPrefix("notes/") },
            "the note is listed: \(listing.files.map(\.relative))")
    }

    func testATypedTildeIsBenchdsHomeAndTheWorkspaceIsAKnownRoot() throws {
        XCTAssertEqual(try prp.resolve("~", as: .directory).get(), remoteHome)
        let relative = String(workspace.dropFirst(remoteHome.count))
        XCTAssertEqual(try prp.resolve("~" + relative, as: .directory).get(), workspace)
        XCTAssertTrue(try WorkspacePicker.knownRoots(prp).get().contains(workspace))
    }
}
