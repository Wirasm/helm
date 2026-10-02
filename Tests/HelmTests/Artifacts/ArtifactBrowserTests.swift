import BenchKit
import HelmWire
import XCTest

@testable import Helm

/// The artifact browser popover, without a window. Which stores exist and what is in them are
/// benchd's answers (M5c) and the daemon gate's to test; the selection rule is
/// `ArtifactListingTests`'.
final class ArtifactBrowserTests: XCTestCase {
    /// #50's actual defect, as an assertion: a browser that has only been *constructed*
    /// already knows its stores and its files.
    ///
    /// This is not pedantry about initialisers. A popover sizes its window once, from its
    /// content as it stands at presentation, and `.onAppear` runs after that pass — so a
    /// browser that discovered its stores there was sized from its own "no stores found"
    /// placeholder and never grew, and the 26 artifacts it then found rendered into an 8pt
    /// sliver. Nothing about that is visible from a listing assertion; the only thing that
    /// distinguishes the broken build from the fixed one, without a window, is *when* the
    /// listing exists. So that is what is pinned here.
    @MainActor
    func testANewlyConstructedBrowserAlreadyHasItsListing() throws {
        let prp = try FakePrp()
        defer { prp.remove() }
        let server = try FakeBenchd(
            document: DocumentAt(seq: 1, document: .init(workspaces: [], active: nil)))
        defer { server.stop() }
        server.answer = server.answeringPrp(prp) { raw in
            ["id": raw["id"] ?? "", "status": "refused", "reason": "not a prp verb"]
        }
        let store = try prp.store("proj", path: "/Users/x/proj", name: "Proj")
        let file = store.appendingPathComponent("issues/issue-50.md")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "content".write(to: file, atomically: true, encoding: .utf8)

        let browser = ArtifactBrowser(
            workspaceRoot: "/Users/x/proj",
            prp: PrpStores(client: BenchClient(endpoint: server.endpoint)),
            onOpen: { _ in },
            onDismiss: {}
        )

        XCTAssertEqual(browser.listing.selectedKey, "proj")
        XCTAssertEqual(browser.listing.files.map(\.relative), ["issues/issue-50.md"])
    }
}
