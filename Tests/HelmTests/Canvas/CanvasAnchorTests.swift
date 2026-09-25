import XCTest

@testable import Helm

/// What a text mark reports about **what it marked** — #215.
///
/// `resolve` walked up for an id and then read `textContent` off whatever the walk stopped on,
/// so on a markdown canvas — where `marked` gives paragraphs no id and helm wraps the page in
/// `<article id="content">` — every block came back as the whole document under an id that
/// occurs nowhere in the `.md` file, rendered in exactly the form that means "grep for this".
/// The geometry tools that shared `resolve` left in #385; the text mark keeps the rule through
/// `nameFor`.
///
/// **The fixture is why it survived.** Every element `canvas-dom-stub.js` shipped carried an id,
/// and when the marked element has its own id the walk stops on its first iteration. The defect
/// only exists for an id-less element. `canvas-dom-stub.js` now has three.
///
/// Everything here drives the shipped `canvas-annotation.js` through `CanvasScriptRuntime` and
/// reads what it posted, and the seam test pushes that straight into the real
/// `CanvasAnnotation.decode` and `CanvasNotes.entry` — the two things that turn a payload into
/// the sentence an agent actually reads.
final class CanvasAnchorTests: XCTestCase {

    /// The fixture's id-less block, and a point inside it.
    private static let first = (text: "First unnamed block", at: (x: 100.0, y: 1240.0))
    /// The unnamed word inside `<h2 id="phase-2">Phase two</h2>`.
    private static let word = (text: "two", at: (x: 150.0, y: 1170.0))

    /// Select `text` inside the block holding `block`, and release the mouse there.
    private func mark(
        _ text: String, inBlockWithText block: String, at point: (x: Double, y: Double),
        on page: CanvasScriptRuntime
    ) {
        page.setTool(.text)
        page.select(inBlockWithText: block, text: text)
        page.mouse("mouseup", point.x, point.y)
    }

    // MARK: The text is the operator's highlight

    func testASelectionReportsTheHighlightAndNotTheBlockAroundIt() throws {
        let page = try CanvasScriptRuntime()
        mark("unnamed", inBlockWithText: Self.first.text, at: Self.first.at, on: page)

        let message = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(message["text"] as? String, "unnamed", "the highlight, not the element")
    }

    // MARK: helm's own wrapper is not a name

    /// The acceptance criterion in as many words: a markdown canvas does not report `#content`.
    /// `content` is in `CanvasHTML.documentPage` and in no operator's `.md` file, so an anchor
    /// naming it is a grep that finds nothing — and it renders identically to a real one.
    func testAnUnnamedBlockIsNotAnchoredToHelmsOwnWrapper() throws {
        let page = try CanvasScriptRuntime()
        mark("unnamed", inBlockWithText: Self.first.text, at: Self.first.at, on: page)

        XCTAssertNil(try XCTUnwrap(page.lastPosted)["id"] as? String)
    }

    /// **The other direction, and the reason this is not just "report less".** An ancestor's id
    /// still names what is inside it: a marked word inside `<h2 id="phase-2">` anchors to the
    /// heading, and that walk is the whole of #113 — a mark on a mermaid node lands on the
    /// `<text>`/`<p>` inside the `<g>` that carries the id, so reading only the marked element's
    /// own id would anchor no diagram at all.
    func testAnAncestorsIDStillNamesTheWordInsideIt() throws {
        let page = try CanvasScriptRuntime()
        mark(Self.word.text, inBlockWithText: Self.word.text, at: Self.word.at, on: page)

        let message = try XCTUnwrap(page.lastPosted)
        XCTAssertEqual(message["id"] as? String, "phase-2", "the walk must survive")
        XCTAssertEqual(message["text"] as? String, Self.word.text, "but report what was marked")
    }

    /// **The other side of the wrapper rule, and the case the first cut got wrong.**
    ///
    /// This script does not only meet the page helm generates. An `.html` artifact is read
    /// straight from disk, never passes through `CanvasHTML.documentPage`, and gets the same
    /// annotation script injected. So an agent writing `<body><div id="content">`, which is
    /// among the commonest wrappers in hand-written HTML, meets the same code. That id **is** in
    /// the agent's file and **is** greppable, so it is a real anchor.
    ///
    /// The fixture is byte-identical to every other test in this file except for helm's marker,
    /// which is the point: nothing about the DOM can tell these apart, so only something helm
    /// wrote can.
    func testAnIDTheAgentWroteIsAnAnchorEvenWhenItIsSpelledLikeHelmsOwn() throws {
        let page = try CanvasScriptRuntime()
        page.asHTMLArtifact()
        mark("unnamed", inBlockWithText: Self.first.text, at: Self.first.at, on: page)

        XCTAssertEqual(
            try XCTUnwrap(page.lastPosted)["id"] as? String, "content",
            "an .html artifact is the agent's own, so its wrapper id is a real anchor")
        XCTAssertEqual(
            try decodedMark(page), .selection(.element(id: "content", text: "unnamed")),
            "which the real decoder must see as an element, not a quote")
    }

    // MARK: The seam — what the agent actually reads

    /// The payload run through the real decoder and the real note writer. This is the criterion
    /// that matters: an unanchorable block must **never** be rendered as `` `#…` ``, and that
    /// is a fact about `CanvasNotes`' output, not about a JSON field.
    func testAnUnanchorableBlockReachesTheAgentAsAQuoteAndNeverAsAnID() throws {
        let page = try CanvasScriptRuntime()
        mark("unnamed", inBlockWithText: Self.first.text, at: Self.first.at, on: page)
        XCTAssertEqual(try decodedMark(page), .selection(.quote("unnamed")))

        let annotation = try XCTUnwrap(
            CanvasAnnotation.decode(posted: try XCTUnwrap(page.lastPosted), comment: "a comment"))
        let entry = CanvasNotes.entry(annotation, at: Date())
        XCTAssertFalse(entry.contains("`#"), "a block helm cannot name must not be printed as one")
        XCTAssertFalse(entry.contains("content"), "least of all as helm's own wrapper")
    }

    // MARK: The gate that keeps the two halves in step

    /// The script spells `data-helm-frame` out rather than interpolating it, exactly as it
    /// spells out the handler name and the tool global — JavaScript cannot compile against a
    /// Swift constant. So this reads both halves: the page `CanvasHTML.documentPage` generates
    /// and the script that reads it. Drop the marker from either side and this fails, rather
    /// than marking quietly going back to reporting `#content`.
    ///
    /// **This is the only assertion that can see `documentPage` dropping the marker**, which is
    /// why it is a substring check at all. Everything else about the marker is covered by
    /// behaviour: the stub's wrapper carries it, so a script that stopped reading it fails
    /// `testAnUnnamedBlockIsNotAnchoredToHelmsOwnWrapper`, and a script that went back to
    /// recognising the frame by its id fails the `.html`-artifact test above.
    /// The stub cannot catch the Swift half, because the stub writes the attribute itself.
    ///
    /// **There is deliberately no assertion forbidding the old guess by name.** Two reviewers
    /// flagged one independently as brittle and they were right: a substring check over the
    /// script's *text* is exactly the kind of assertion #197 exists to replace, and this one
    /// would have failed on a comment that quoted the code it forbids — it nearly did while
    /// this was being written. The behavioural test is the regression pin.
    func testTheScriptAndTheGeneratedPageStillAgreeOnHelmsWrapper() {
        let page = CanvasHTML.documentPage(markdown: "# Hi\n\nA paragraph.", theme: .light)

        XCTAssertTrue(
            page.contains("<article id=\"content\" data-helm-frame>"),
            "helm must mark its own wrapper, or the script cannot tell it from an artifact's")
        XCTAssertTrue(
            CanvasHTML.annotationScript().contains("getAttribute(\"data-helm-frame\")"),
            "and the script must read the marker helm writes")
    }

    // MARK: -

    private func decodedMark(_ page: CanvasScriptRuntime) throws -> CanvasAnnotation.Mark {
        try XCTUnwrap(
            CanvasAnnotation.decode(posted: try XCTUnwrap(page.lastPosted), comment: "a comment"),
            "the page posted a payload the real decoder refuses"
        ).mark
    }
}
