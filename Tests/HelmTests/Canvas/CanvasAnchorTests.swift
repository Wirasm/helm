import XCTest

@testable import Helm

/// What a mark reports about **what it marked** — #215.
///
/// `resolve` walked up for an id and then read `textContent` off whatever the walk stopped on,
/// so the variable holding the marked element was assigned and never read: `node || labelled`
/// could not fall back, because after the walk `node` is either the id-bearing ancestor or
/// `document.body` and both are truthy. On a markdown canvas — where `marked` gives paragraphs
/// no id and helm wraps the page in `<article id="content">` — every block came back as the
/// whole document under an id that occurs nowhere in the `.md` file, rendered in exactly the
/// form that means "grep for this".
///
/// **The fixture is why it survived.** Every element `canvas-dom-stub.js` shipped carried an id,
/// and when the marked element has its own id the walk stops on its first iteration, so the
/// element it stops on *is* the element that was marked and the right text comes back by
/// accident. The defect only exists for an id-less element. `canvas-dom-stub.js` now has three.
///
/// Everything here drives the shipped `canvas-annotation.js` through `CanvasScriptRuntime` and
/// reads what it posted, and the seam test at the end pushes that straight into the real
/// `CanvasAnnotation.decode` and `CanvasNotes.entry` — the two things that turn a payload into
/// the sentence an agent actually reads.
final class CanvasAnchorTests: XCTestCase {

    /// The fixture's id-less blocks, and a point inside each.
    private static let first = (text: "First unnamed block", at: (x: 100.0, y: 1240.0))
    private static let second = (text: "Second unnamed block", at: (x: 100.0, y: 1310.0))
    /// A loop that covers both of them and nothing else.
    private static let roundBoth = (x: 10.0, y: 1210.0, width: 720.0, height: 120.0)
    /// The unnamed word inside `<h2 id="phase-2">Phase two</h2>`.
    private static let word = (text: "two", at: (x: 150.0, y: 1170.0))

    // MARK: The text is the marked element's own

    /// All four kinds, because all four resolve through the same code path and the ticket is
    /// therefore a change to the whole annotation surface rather than to one tool.
    func testEveryMarkKindReportsTheTextOfTheThingItMarked() throws {
        let tap = try CanvasScriptRuntime()
        tap.setTool(.point)
        tap.tap(at: Self.first.at)
        XCTAssertEqual(try XCTUnwrap(tap.lastPosted)["text"] as? String, Self.first.text)

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: Self.first.at, to: Self.second.at)
        let ends = try XCTUnwrap(arrow.lastPosted)
        XCTAssertEqual(
            (ends["from"] as? [String: Any])?["text"] as? String, Self.first.text,
            "an arrow's tail names where it started, not the article around it")
        XCTAssertEqual((ends["to"] as? [String: Any])?["text"] as? String, Self.second.text)

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: Self.roundBoth)
        XCTAssertEqual(try texts(of: loop), [Self.first.text, Self.second.text])
    }

    /// A selection's text was always the operator's own highlight, so this is the half of the
    /// defect it did *not* have. It had the other half: its own copy of the id walk, which this
    /// change deletes in favour of the shared one — so `#content` reached the operator through a
    /// code path `resolve` never touched.
    func testASelectionKeepsTheHighlightItAlwaysReportedAndLosesTheWrapper() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.select)
        page.select(inBlockWithText: Self.first.text, text: "unnamed")

        page.mouse("mouseup", Self.first.at.x, Self.first.at.y)

        let message = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(message["text"] as? String, "unnamed", "the highlight, not the element")
        XCTAssertNil(message["id"] as? String, "and no id helm invented for it")
    }

    // MARK: helm's own wrapper is not a name

    /// The acceptance criterion in as many words: a markdown canvas does not report `#content`.
    /// `content` is in `CanvasHTML.documentPage` and in no operator's `.md` file, so an anchor
    /// naming it is a grep that finds nothing — and it renders identically to a real one.
    func testAnUnnamedBlockIsNotAnchoredToHelmsOwnWrapper() throws {
        let tap = try CanvasScriptRuntime()
        tap.setTool(.point)
        tap.tap(at: Self.first.at)
        XCTAssertNil(try XCTUnwrap(tap.lastPosted)["id"] as? String)

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: Self.first.at, to: Self.second.at)
        let ends = try XCTUnwrap(arrow.lastPosted)
        XCTAssertNil((ends["from"] as? [String: Any])?["id"] as? String)
        XCTAssertNil((ends["to"] as? [String: Any])?["id"] as? String)

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: Self.roundBoth)
        XCTAssertEqual(try ids(of: loop), [], "neither block can be named, and neither pretends")
    }

    /// **The other direction, and the reason this is not just "report less".** An ancestor's id
    /// still names what is inside it: a marked word inside `<h2 id="phase-2">` anchors to the
    /// heading, and that walk is the whole of #113 — a hit on a mermaid node lands on the
    /// `<text>`/`<p>` inside the `<g>` that carries the id, so a resolver reading only the
    /// marked element's own id would anchor no diagram at all.
    ///
    /// The `id` assertion passes before and after: it is here to fail if the fix overshoots
    /// into dropping the walk. The `text` assertion is the one that was wrong — it read
    /// "Phase two", the heading's whole contents, for a mark on the word.
    func testAnAncestorsIDStillNamesTheWordInsideIt() throws {
        let tap = try CanvasScriptRuntime()
        tap.setTool(.point)
        tap.tap(at: Self.word.at)

        let message = try XCTUnwrap(tap.lastPosted)
        XCTAssertEqual(message["id"] as? String, "phase-2", "the walk must survive")
        XCTAssertEqual(message["text"] as? String, Self.word.text, "but report what was marked")

        let selection = try CanvasScriptRuntime()
        selection.setTool(.select)
        selection.select(inBlockWithText: Self.word.text, text: Self.word.text)
        selection.mouse("mouseup", Self.word.at.x, Self.word.at.y)
        XCTAssertEqual(
            try XCTUnwrap(selection.lastPosted)["id"] as? String, "phase-2",
            "the selection branch shares the walk now, so it must share this too")
    }

    /// Circling the whole document is a real gesture, and the answer to it is a quote of the
    /// whole document — not helm's wrapper id dressed as an anchor. The article is still
    /// *selected*; what it no longer is, is *named*.
    func testCirclingTheWholeDocumentQuotesItRatherThanNamingHelmsWrapper() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)

        page.loop(around: (x: -10, y: -10, width: 780, height: 1820))

        let article = try XCTUnwrap(targets(of: page).first, "the article is the first candidate")
        XCTAssertNil(article["id"] as? String, "`#content` is helm's, and it is in no artifact")
        XCTAssertEqual(
            (article["text"] as? String)?.hasPrefix("The Plan"), true,
            "and what comes back instead is what the operator circled")
    }

    // MARK: Multiplicity, which the text fix resolves on its own

    /// `Mark.enclosure` exists to carry several things and could not. The dedupe key at
    /// `canvas-annotation.js` is `(id, text)`, and every id-less sibling produced the identical
    /// pair — `("content", <the whole document>)` — so circling three paragraphs yielded one
    /// target. Per-element text separates them with **no change to the key**.
    func testCirclingSeveralUnnamedBlocksYieldsOneTargetEach() throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.freehand)

        page.loop(around: Self.roundBoth)

        XCTAssertEqual(try texts(of: page), [Self.first.text, Self.second.text])
    }

    // MARK: The seam — what the agent actually reads

    /// The payload run through the real decoder and the real note writer. This is the criterion
    /// that matters: an unanchorable block must **never** be rendered as `` `#…` ``, and that
    /// is a fact about `CanvasNotes`' output, not about a JSON field.
    func testAnUnanchorableBlockReachesTheAgentAsAQuoteAndNeverAsAnID() throws {
        let tap = try CanvasScriptRuntime()
        tap.setTool(.point)
        tap.tap(at: Self.first.at)
        XCTAssertEqual(try mark(tap), .point(.quote(Self.first.text)))

        let arrow = try CanvasScriptRuntime()
        arrow.setTool(.arrow)
        arrow.drag(from: Self.first.at, to: Self.second.at)
        XCTAssertEqual(
            try mark(arrow),
            .relation(from: .quote(Self.first.text), to: .quote(Self.second.text)))

        let loop = try CanvasScriptRuntime()
        loop.setTool(.freehand)
        loop.loop(around: Self.roundBoth)
        XCTAssertEqual(
            try mark(loop),
            .enclosure(covering: [.quote(Self.first.text), .quote(Self.second.text)]))

        let selection = try CanvasScriptRuntime()
        selection.setTool(.select)
        selection.select(inBlockWithText: Self.first.text, text: "unnamed")
        selection.mouse("mouseup", Self.first.at.x, Self.first.at.y)
        XCTAssertEqual(try mark(selection), .selection(.quote("unnamed")))

        for page in [tap, arrow, loop, selection] {
            let annotation = try XCTUnwrap(
                CanvasAnnotation.decode(try XCTUnwrap(page.lastPosted), comment: "a comment"))
            let entry = CanvasNotes.entry(annotation, at: Date())
            XCTAssertFalse(
                entry.contains("`#"), "a block helm cannot name must not be printed as one")
            XCTAssertFalse(entry.contains("content"), "least of all as helm's own wrapper")
        }
    }

    // MARK: The gate that keeps the two halves in step

    /// The script spells `content` out rather than interpolating it, exactly as it spells out
    /// the handler name and the tool global — JavaScript cannot compile against a Swift
    /// constant. So this reads both halves: the page `CanvasHTML.documentPage` generates, and
    /// the script's own test for it. Rename the wrapper and this fails, rather than marking
    /// quietly going back to reporting `#content`.
    func testTheScriptAndTheGeneratedPageStillAgreeOnHelmsWrapper() throws {
        let page = CanvasHTML.documentPage(markdown: "# Hi\n\nA paragraph.", theme: .light)
        let script = CanvasHTML.annotationScript()

        let openBody = try XCTUnwrap(page.range(of: "<body>"))
        let wrapper = try XCTUnwrap(
            page.range(of: "<article id=\"content\">"),
            "the script recognises helm's wrapper by this exact id")
        XCTAssertTrue(
            page[openBody.upperBound..<wrapper.lowerBound].allSatisfy(\.isWhitespace),
            "and by it being a direct child of <body>, which is the other half of the test")
        XCTAssertTrue(
            script.contains("node.id === \"content\""),
            "the script must still know which id is helm's own")
        XCTAssertTrue(
            script.contains("node.parentNode === document.body"),
            "an authored `id=\"content\"` deeper in a .html artifact is still a real anchor")
    }

    // MARK: -

    private func targets(of page: CanvasScriptRuntime) throws -> [[String: Any]] {
        let posted = try XCTUnwrap(page.lastPosted, "the gesture posted nothing to the bridge")
        XCTAssertEqual(posted["mark"] as? String, "enclosure")
        return try XCTUnwrap(posted["targets"] as? [Any]).compactMap { $0 as? [String: Any] }
    }

    private func ids(of page: CanvasScriptRuntime) throws -> [String] {
        try targets(of: page).compactMap { $0["id"] as? String }
    }

    private func texts(of page: CanvasScriptRuntime) throws -> [String] {
        try targets(of: page).compactMap { $0["text"] as? String }
    }

    private func mark(_ page: CanvasScriptRuntime) throws -> CanvasAnnotation.Mark {
        try XCTUnwrap(
            CanvasAnnotation.decode(try XCTUnwrap(page.lastPosted), comment: "a comment"),
            "the page posted a payload the real decoder refuses"
        ).mark
    }
}
