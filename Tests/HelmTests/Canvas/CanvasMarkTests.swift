import XCTest

@testable import Helm

/// What a posted mark decodes to, and — the half that is easy to leave to chance — what
/// happens on the diagram families where there is nothing to anchor to.
final class CanvasMarkTests: XCTestCase {
    private func decode(
        _ body: [String: Any], comment: String = "this is wrong"
    ) -> CanvasAnnotation? {
        CanvasAnnotation.decode(posted: body, comment: comment)
    }

    // MARK: - The mark

    func testAMermaidNodeReducesToTheIdentifierInTheSource() {
        let annotation = decode([
            "kind": "selection", "id": "mermaid-0-flowchart-phase2-1", "text": "Phase 2: Ship",
        ])

        XCTAssertEqual(annotation?.mark, .selection(.element(id: "phase2", text: "Phase 2: Ship")))
    }

    func testAMarkWithNoCommentIsRefused() {
        XCTAssertNil(
            decode(["kind": "selection", "id": "phase-2", "text": "Phase 2"], comment: "   "))
    }

    /// The geometry kinds left with their tools (#385). A page still posting one is drift between
    /// two files that ship together, and it is refused like any other unknown kind rather than
    /// read as a selection over whatever text it carried.
    func testTheRemovedGeometryKindsAreRefused() {
        for kind in ["enclosure", "relation", "point"] {
            XCTAssertNil(decode(["kind": kind, "id": "phase-2", "text": "Phase 2"]), kind)
        }
    }

    func testASelectionSaysSoAndDecodesAsOne() {
        // Was `testNoMarkIsStillASelection`, and the rename is the change: a selection used to
        // be the payload with NO discriminator on it at all, which is what made "which shape is
        // this?" an inference and #216 the bill for getting it wrong. It declares itself (#109).
        let annotation = decode(["kind": "selection", "id": "phase-2", "text": "Phase 2"])

        XCTAssertEqual(annotation?.mark, .selection(.element(id: "phase-2", text: "Phase 2")))
    }

    /// **This inverts what it used to assert, and the inversion is the ticket.**
    ///
    /// It was `testAMarkHelmDoesNotKnowDegradesToSelectionRatherThanLosingTheComment`: an
    /// unknown `mark` fell through to a text selection, reasoning that *"the page is
    /// agent-authored and a mark helm has not learned yet is not a reason to throw away a
    /// comment the operator already typed"*. **The page posting here is not agent-authored.**
    /// The bridge lives in a named content world (#164), so the only thing that can post to it
    /// is `canvas-annotation.js` — shipped in the same binary as this decoder. An unknown kind
    /// is therefore never a newer page; it is drift between two files that ship together, and
    /// "it was probably a selection" turns a lasso into a highlight over whatever text the
    /// payload happened to carry, then writes a note saying the wrong thing about it.
    ///
    /// Nothing is lost silently either way: the gate refuses the message before a comment field
    /// ever opens, and the refusal names the kind in the log.
    func testAKindHelmDoesNotKnowIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(decode(["kind": "lasso", "id": "phase-2", "text": "Phase 2"]))
        XCTAssertNil(
            decode(["id": "phase-2", "text": "Phase 2"]),
            "and a body with no kind at all is refused too — that shape IS the inference")
    }

    // MARK: - The families where there is nothing to anchor to

    func testAMindmapNodeDegradesToAQuoteRatherThanKeepingRendererBookkeeping() {
        // `mermaid-0-node_1` carries no author identifier. Keeping it hands the agent an
        // anchor that survives a re-render and matches nothing in the source — the exact
        // anchor #113 abolished. This is the behaviour that used to fall through.
        let annotation = decode([
            "kind": "selection", "id": "mermaid-0-node_1", "text": "branchA",
        ])

        XCTAssertEqual(annotation?.mark, .selection(.quote("branchA")))
    }

    func testAnEdgeAndAMarkerDefDegradeToo() {
        for id in ["mermaid-0-L_phase1_phase2_0", "mermaid-0_flowchart-v2-pointEnd"] {
            let annotation = decode(["kind": "selection", "id": id, "text": "x"])
            XCTAssertEqual(
                annotation?.mark, .selection(.quote("x")),
                "\(id) is renderer bookkeeping, not an anchor")
        }
    }

    func testAnAgentAuthoredIDIsStillKept() {
        // The whole reason `isRenderGenerated` exists: "cannot reduce" has two causes and
        // only one of them means "throw it away".
        let annotation = decode(["kind": "selection", "id": "phase-2", "text": "Phase 2"])

        XCTAssertEqual(annotation?.mark, .selection(.element(id: "phase-2", text: "Phase 2")))
    }

    func testASequenceActorIsIndistinguishableFromAnAuthoredID() {
        // A stated ceiling rather than a hidden one: sequenceDiagram emits `actor0` with no
        // `mermaid-` prefix, so helm cannot tell it from an id an agent wrote. It does not
        // guess — it keeps it, and #112's spec says so.
        let annotation = decode(["kind": "selection", "id": "actor0", "text": "alice"])

        XCTAssertEqual(annotation?.mark, .selection(.element(id: "actor0", text: "alice")))
    }
}
