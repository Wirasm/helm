import BenchKit
import HelmWire
import XCTest

@testable import Helm

/// The artifact browser popover, without a window. Which stores exist and what is in them are
/// benchd's answers (M5c) and the daemon gate's to test; the selection rule is
/// `ArtifactListingTests`'.
final class ArtifactBrowserTests: XCTestCase {
    /// SwiftUI builds the browser again on every redraw of the tab strip while the popover is
    /// open, on the main thread. It used to ask benchd for its listing right there, and a walk
    /// of Archon's store took seconds, so helm stopped answering for that long once per
    /// redraw. Building the browser asks benchd nothing; it asks when it appears, off the main
    /// thread.
    @MainActor
    func testBuildingABrowserAsksBenchdNothing() throws {
        let prp = try FakePrp()
        defer { prp.remove() }
        let server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: .init(workspaces: [], active: nil)))
        defer { server.stop() }
        server.answer = server.answeringPrp(prp) { raw in
            ["id": raw["id"] ?? "", "status": "refused", "reason": "not a prp verb"]
        }
        try prp.store("proj", path: "/Users/x/proj", name: "Proj")

        _ = ArtifactBrowser(
            workspaceRoot: "/Users/x/proj",
            prp: PrpStores(client: BenchClient(endpoint: server.endpoint)),
            onOpen: { _ in },
            onDismiss: {}
        )

        let asked = server.requests.compactMap { $0["verb"] as? String }
        XCTAssertEqual(asked.filter { $0.hasPrefix("prp/") }, [])
    }
}
