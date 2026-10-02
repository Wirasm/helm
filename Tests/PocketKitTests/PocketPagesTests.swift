import Foundation
import HelmWire
import XCTest

@testable import PocketKit

/// Pocket's pages: the plan and review pages in the workspaces' prp stores, and a reply written
/// into a page's live file for the agent that opened it.
final class PocketPagesTests: XCTestCase {
    private func file(_ relative: String, _ ms: UInt64) -> BenchPrpArtifact {
        BenchPrpArtifact(path: "/s/\(relative)", relative: relative, modifiedMs: ms)
    }

    /// The `.html` pages of every store once, newest first; markdown is not a page here.
    func testPagesAreTheStoresHTMLNewestFirstOnce() {
        let helm = [file("plans/a.plan.html", 30), file("plans/a.plan.md", 31)]
        let prp = [file("reviews/pr-1-review.html", 40), file("plans/a.plan.html", 30)]
        let pages = PocketPages.pages(files: [helm, prp])
        XCTAssertEqual(pages.map(\.path), ["/s/reviews/pr-1-review.html", "/s/plans/a.plan.html"])
        XCTAssertEqual(pages.map(\.title), ["reviews/pr-1-review", "plans/a.plan"])
    }

    /// A reply is added to the live file's `replies`, every other key kept, written as a page
    /// writes its live file (sorted, pretty, a trailing newline).
    func testAReplyIsAddedToTheLiveFileKeepingWhatIsThere() throws {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try XCTUnwrap(PocketReply.adding("keep it", at: at, to: nil))
        XCTAssertEqual(
            first,
            """
            {
              "replies" : [
                {
                  "at" : "2026-09-21T14:13:20Z",
                  "from" : "pocket",
                  "text" : "keep it"
                }
              ]
            }

            """)
        let existing = Data(#"{"answers": {"q1": "yes"}, "replies": [{"text": "one"}]}"#.utf8)
        let second = try XCTUnwrap(PocketReply.adding("two", at: at, to: existing))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])
        XCTAssertEqual((object["answers"] as? [String: String])?["q1"], "yes")
        XCTAssertEqual(
            (object["replies"] as? [[String: Any]])?.map { $0["text"] as? String }, ["one", "two"])
    }

    /// A live file that is not a JSON object is the page's own business: Pocket does not write
    /// over it.
    func testALiveFileThatIsNotAnObjectIsLeftAlone() {
        XCTAssertNil(PocketReply.adding("x", at: Date(), to: Data("[1, 2]".utf8)))
        XCTAssertNil(PocketReply.adding("x", at: Date(), to: Data("not json".utf8)))
    }
}
