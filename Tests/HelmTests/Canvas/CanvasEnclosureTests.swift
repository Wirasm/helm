import XCTest

@testable import Helm

/// What a freehand loop actually SELECTS — #208.
///
/// `targetsInside` kept any element whose **centre** fell inside the stroke. `<article
/// id="content">` wraps the whole page, so its centre is the page's centre, and a loop around
/// any node near the middle of a document also captured the entire document — returned first,
/// in document order, with a 400-character quote of mermaid's injected CSS behind it.
///
/// Every test here runs the real script through `CanvasScriptRuntime` and reads what it posts
/// to the bridge. That matters more than usual for this defect: the rule that was wrong had a
/// `.contains("r.left + r.width / 2")` assertion pinning it character for character, and the
/// assertion passed for as long as the bug existed. This suite is on #197's harness rather than
/// one of its own, so there is one DOM stub in the repo and one set of decisions about where it
/// may differ from a browser.
///
/// **The geometry is the fixture's, and the proportions are the measured page's.** The stub
/// cannot express the three-level nesting of the real artifact — node inside `<svg>` inside
/// `<article>` — because it has no `<svg>`, so these tests exercise one ancestor rather than
/// two. That is not a weaker case: coverage judges every candidate on its own box, so a second
/// ancestor is the same rule applied again. What is preserved is the ratio that makes the
/// defect, and it is close: on the real page the loop was 1.4% of `#content`'s area, and here it
/// is 1.1%.
final class CanvasEnclosureTests: XCTestCase {

    /// `#content` is `box(0, 0, 760, 1800)`, so the centre of the page is here. Nothing in the
    /// stub's fixture sits at this point — #197 placed its elements away from it deliberately —
    /// so every test that needs the trap builds it with `layOut`.
    private static let pageCentre = (x: 380.0, y: 900.0)

    // MARK: #208 — the ancestor

    func testALoopAroundANodeAtThePageCentroidDoesNotAlsoReturnTheWholeDocument() throws {
        // The reported defect, at both stroke sizes #114 measured it at.
        for clearance in [6.0, 30.0] {
            let page = try CanvasScriptRuntime()
            let node = atPageCentre(page, id: "detail")

            circle(page, node, clear: clearance)

            XCTAssertEqual(
                try ids(of: page), ["detail"],
                "a \(Int(clearance))pt loop around one node must anchor to that node alone")
        }
    }

    func testTheWholeDocumentIsNotQuotedBackAtTheAgent() throws {
        // The other half of what the operator got. `#content`'s textContent is every word in
        // the artifact, and that string travelled as an anchor's `text` — which is what
        // `CanvasNotes` writes into the sidecar and what the agent then reads.
        let page = try CanvasScriptRuntime()
        let node = atPageCentre(page, id: "detail")

        circle(page, node, clear: 10)

        XCTAssertEqual(try texts(of: page), ["How it works"])
    }

    func testALargeElementTheLoopReallyDoesEncircleComesBackWithoutTheDocumentAroundIt() throws {
        // Coverage is not a ban on big elements — it is the distinction the centre test could
        // not draw. This element is 164 times the area of the ones the fixture ships and covers
        // the page's centre, and it is still returned; what drops out is the article around it,
        // which this loop is NOT around.
        let page = try CanvasScriptRuntime()
        XCTAssertTrue(page.layOut(id: "intro", x: 100, y: 700, width: 560, height: 400))

        circle(page, (x: 100, y: 700, width: 560, height: 400), clear: 10)

        XCTAssertEqual(try ids(of: page), ["intro"])
    }

    func testTheDecisionIsUnchangedByHowFarThePageIsScrolled() throws {
        // The stroke is in PAGE coordinates and `getBoundingClientRect` is viewport-relative, so
        // the conversion between them is load-bearing and easy to drop while moving this code.
        // The elements are where they always were on the page; only the window has moved.
        let page = try CanvasScriptRuntime()
        let node = atPageCentre(page, id: "detail")
        page.scroll(x: 0, y: 900)

        circle(page, node, clear: 10)

        XCTAssertEqual(try ids(of: page), ["detail"])
    }

    func testHelmsOwnInkIsExcludedEvenThoughTheLoopCoversAllOfIt() throws {
        // #197 already proves the guard holds for a loop away from the centroid. What is new
        // under a coverage rule is the size of the hazard: the ink is drawn exactly where the
        // loop is, so it is the BEST-covered element on the page — 1.00, where the operator's
        // node is at most that. It has to stay excluded on the strength of `data-helm-mark`
        // alone, and nothing else.
        let page = try CanvasScriptRuntime()
        let node = atPageCentre(page, id: "detail")
        page.setTool(.freehand)

        page.mouse("mousedown", node.x - 10, node.y - 10)
        page.mouse("mousemove", node.x + node.width + 10, node.y - 10)
        // Mid-gesture, because the paper is created on the first mousemove and torn down by the
        // next mousedown — this is the only window in which helm's chrome exists to lay out.
        XCTAssertTrue(
            page.layOut(
                id: "helm-mark-head", x: node.x, y: node.y, width: node.width,
                height: node.height),
            "the arrowhead def has to exist by now, or this test proves nothing")
        XCTAssertTrue(page.giveText(id: "helm-mark-head", text: "helm's own ink"))
        page.mouse("mousemove", node.x + node.width + 10, node.y + node.height + 10)
        page.mouse("mousemove", node.x - 10, node.y + node.height + 10)
        page.mouse("mouseup", node.x - 10, node.y - 4)

        XCTAssertEqual(try ids(of: page), ["detail"])
    }

    // MARK: What a concave stroke does, pinned because the comment cannot prove it

    func testAConcaveStrokeSelectsWhatItCoversEvenWhereTheCentreFallsOutsideIt() throws {
        // The one place the coverage rule is NOT a restatement of the centre test.
        //
        // For a convex stroke, covering more than half of a rectangle implies containing its
        // centre, so dropping the centre test changed nothing. A freehand stroke is not
        // guaranteed convex — a hand dipping around an indent draws a concave one — and there
        // the two rules disagree: this horseshoe is notched across the mid-row, so it covers
        // 0.918 of the box while the centre falls in the notch. The centre test rejected that;
        // coverage takes it.
        //
        // Pinned rather than argued because the argument is a comment in a file where three
        // defects have now shipped past assertions that read as though they covered the
        // behaviour. The widening is deliberate: the loop does cover most of the element, which
        // is what the rule says. An ancestor still cannot come back in — `#content` is 190
        // times this stroke's area, and that bound holds whatever shape the stroke is.
        let page = try CanvasScriptRuntime()
        XCTAssertTrue(page.layOut(id: "detail", x: 100, y: 300, width: 100, height: 100))
        page.setTool(.freehand)

        // Around the box, then in from the right edge across the middle and back out.
        let horseshoe = [
            (90.0, 290.0), (210.0, 290.0), (210.0, 345.0), (140.0, 345.0),
            (140.0, 355.0), (210.0, 355.0), (210.0, 410.0), (90.0, 410.0),
        ]
        page.mouse("mousedown", horseshoe[0].0, horseshoe[0].1)
        for point in horseshoe.dropFirst() { page.mouse("mousemove", point.0, point.1) }
        page.mouse("mouseup", horseshoe[0].0, horseshoe[0].1 + 6)

        XCTAssertEqual(try ids(of: page), ["detail"])
    }

    // MARK: The other direction — a fix that merely selects less would pass none of these

    func testACircleRoundEverythingStillReturnsEverything() throws {
        // The container the operator really did circle, and the acceptance criterion in as many
        // words. Unchanged by this fix, and that is the point of asserting it.
        //
        // **What #215 changed here, and what it did not.** The article is still SELECTED — it is
        // still the first target — but it is no longer NAMED: helm injected `id="content"`, so it
        // occurs in no artifact and can be grepped for in none. The count and the leading text
        // are what pin the selection, which is this test's subject; the id list belongs to #215
        // and is asserted here only so the two cannot drift apart unnoticed.
        let page = try CanvasScriptRuntime()

        circle(page, (x: 0, y: 0, width: 760, height: 1800), clear: 10)

        XCTAssertEqual(try enclosure(page).count, 9, "every candidate on the page")
        XCTAssertEqual(
            try texts(of: page).first?.hasPrefix("The Plan"), true,
            "the article the loop is around is still the first thing it returns")
        XCTAssertEqual(
            try ids(of: page), ["title", "intro", "detail", "item-a", "item-b", "phase-2"])
    }

    func testAStrokeThatGrazesANeighbourDoesNotMeanTheNeighbour() throws {
        // The property the replaced rule existed for. It is held harder now: a grazed element
        // is rejected for covering almost none of itself, where the centre test only rejected
        // it when the graze happened to miss its middle.
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)

        // Around `item-a`, running on far enough to clip the left tenth of `item-b`.
        page.loop(around: (x: 10, y: 1390, width: 420, height: 50))

        XCTAssertEqual(try ids(of: page), ["item-a"], "the stroke only grazed the neighbour")
    }

    func testALoopAroundNothingSelectsNothing() throws {
        // Posted empty rather than not posted, so `CanvasAnnotation.decode` refuses it visibly —
        // silence is indistinguishable from the stroke never registering.
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)

        page.loop(around: (x: 100, y: 1600, width: 100, height: 60))

        XCTAssertEqual(try ids(of: page), [])
    }

    // MARK: -

    private typealias Box = (x: Double, y: Double, width: Double, height: Double)

    /// Move one of the fixture's elements onto the centre of `#content`, which is the state that
    /// makes the ancestor's centre and the target's centre the same point.
    private func atPageCentre(_ page: CanvasScriptRuntime, id: String) -> Box {
        let box = (
            x: Self.pageCentre.x - 80, y: Self.pageCentre.y - 30, width: 160.0, height: 60.0
        )
        XCTAssertTrue(page.layOut(id: id, x: box.x, y: box.y, width: box.width, height: box.height))
        return box
    }

    /// Circle `box` with a stroke `clearance` clear of it, the way a hand circling one thing
    /// draws — never touching what it is about.
    private func circle(_ page: CanvasScriptRuntime, _ box: Box, clear clearance: Double) {
        page.setTool(.freehand)
        page.loop(
            around: (
                x: box.x - clearance, y: box.y - clearance,
                width: box.width + clearance * 2, height: box.height + clearance * 2
            ))
    }

    private func enclosure(_ page: CanvasScriptRuntime) throws -> [[String: Any]] {
        let posted = try XCTUnwrap(page.lastPosted, "the gesture posted nothing to the bridge")
        XCTAssertEqual(posted["mark"] as? String, "enclosure")
        let targets = try XCTUnwrap(posted["targets"] as? [Any])
        return targets.compactMap { $0 as? [String: Any] }
    }

    private func ids(of page: CanvasScriptRuntime) throws -> [String] {
        try enclosure(page).compactMap { $0["id"] as? String }
    }

    private func texts(of page: CanvasScriptRuntime) throws -> [String] {
        try enclosure(page).compactMap { $0["text"] as? String }
    }
}
