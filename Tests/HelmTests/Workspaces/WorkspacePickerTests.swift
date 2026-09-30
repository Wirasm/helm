import Foundation
import HelmWire
import XCTest

@testable import Helm

/// ⇧⌘O and the artifact browser's path field (M5c): a typed path is benchd's to resolve, and the
/// known roots are benchd's stores'. What benchd does with `~` is the daemon gate's; this is the
/// rule helm keeps on top — the kind each field wants, and what it says about the wrong one.
@MainActor
final class WorkspacePickerTests: XCTestCase {
    private var prp: FakePrp!
    private var server: FakeBenchd!
    private var stores: PrpStores!

    override func setUpWithError() throws {
        prp = try FakePrp()
        server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: .init(workspaces: [], active: nil)))
        server.answer = server.answeringPrp(prp) { raw in
            ["id": raw["id"] ?? "", "status": "refused", "reason": "not a prp verb"]
        }
        stores = PrpStores(client: BenchClient(endpoint: server.endpoint))
        try FileManager.default.createDirectory(
            at: prp.home.appendingPathComponent("proj"), withIntermediateDirectories: true)
        try "x".write(
            to: prp.home.appendingPathComponent("proj/plan.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        server.stop()
        prp.remove()
    }

    func testATypedFolderIsBenchdsPath() {
        XCTAssertEqual(
            stores.resolve("  ~/proj/  \n", as: .directory),
            .success(prp.home.appendingPathComponent("proj").path),
            "trimmed, then `~` is benchd's home, not this process's")
        let asked = server.requests.last?["args"] as? [String: String]
        XCTAssertEqual(asked, ["path": "~/proj/"], "the `~` goes to benchd unexpanded")
    }

    func testTheWrongKindIsSaidAndNotOpened() {
        let file = prp.home.appendingPathComponent("proj/plan.md").path
        XCTAssertEqual(
            stores.resolve("~/proj/plan.md", as: .directory),
            .failure(.init(reason: "\(file) is a file, not a folder.")))
        XCTAssertEqual(
            stores.resolve("~/proj", as: .file),
            .failure(
                .init(
                    reason:
                        "\(prp.home.appendingPathComponent("proj").path) is a folder, not a file."))
        )
    }

    func testARefusalCarriesBenchdsReasonAndNothingTypedAsksNothing() {
        guard case let .failure(gone) = stores.resolve("~/gone", as: .directory) else {
            return XCTFail("a path with nothing there is refused")
        }
        XCTAssertTrue(gone.reason.contains("nothing at"), gone.reason)
        let before = server.requests.count
        XCTAssertEqual(
            stores.resolve("   ", as: .directory), .failure(.init(reason: "Type a path first.")))
        XCTAssertEqual(server.requests.count, before)
    }

    func testTheKnownRootsAreTheStoresProjectsOnceEach() throws {
        try prp.store("a", path: "/srv/work/helm")
        try prp.store("b", path: nil)
        try prp.store("c", path: "/srv/work/kild")
        try prp.store("d", path: "/srv/work/helm")

        XCTAssertEqual(
            try WorkspacePicker.knownRoots(stores).get(), ["/srv/work/helm", "/srv/work/kild"])
    }

    func testAnUnreachableBenchdHasNoRootsAndSaysSo() {
        server.stop()
        guard case .failure = WorkspacePicker.knownRoots(stores) else {
            return XCTFail("an unreachable benchd is a failure, not an empty list")
        }
    }
}
