import XCTest

@testable import Helm

/// Marking with geometry (#112): what a circle, an arrow and a tap decode to, and — the half
/// that is easy to leave to chance — what happens on the diagram families where there is
/// nothing to anchor to.
final class CanvasMarkTests: XCTestCase {
    private func decode(
        _ body: [String: Any], comment: String = "this is wrong"
    ) -> CanvasAnnotation? {
        CanvasAnnotation.decode(body, comment: comment)
    }

    private func target(_ id: String?, _ text: String) -> [String: Any] {
        var t: [String: Any] = ["text": text]
        if let id { t["id"] = id }
        return t
    }

    // MARK: - The gestures

    func testCirclingOneElementYieldsAnEnclosureNamingIt() {
        let annotation = decode([
            "kind": "enclosure",
            "targets": [target("mermaid-0-flowchart-phase2-1", "Phase 2: Ship")],
        ])

        XCTAssertEqual(
            annotation?.mark,
            .enclosure(covering: [.element(id: "phase2", text: "Phase 2: Ship")]))
    }

    func testCirclingSeveralKeepsAllOfThem() {
        // Multiplicity is data, not an error — collapsing to "the nearest" would be helm
        // deciding what the operator meant.
        let annotation = decode([
            "kind": "enclosure",
            "targets": [
                target("mermaid-0-flowchart-phase1-0", "One"),
                target("mermaid-0-flowchart-phase2-1", "Two"),
            ],
        ])

        XCTAssertEqual(
            annotation?.mark,
            .enclosure(covering: [
                .element(id: "phase1", text: "One"), .element(id: "phase2", text: "Two"),
            ]))
    }

    func testAnArrowYieldsARelationBetweenBothEnds() {
        let annotation = decode([
            "kind": "relation",
            "from": target("mermaid-0-flowchart-phase1-0", "One"),
            "to": target("mermaid-0-flowchart-phase3-3", "Three"),
        ])

        XCTAssertEqual(
            annotation?.mark,
            .relation(
                from: .element(id: "phase1", text: "One"),
                to: .element(id: "phase3", text: "Three")))
    }

    func testAnArrowIntoEmptySpaceIsRepresentableRatherThanRefused() {
        // "add a node here" is a real instruction. tldraw's model-facing arrow has nullable
        // fromId/toId for exactly this.
        let annotation = decode([
            "kind": "relation", "from": target("phase-1", "One"),
        ])

        XCTAssertEqual(
            annotation?.mark, .relation(from: .element(id: "phase-1", text: "One"), to: nil))
    }

    func testATapYieldsAPoint() {
        let annotation = decode(["kind": "point", "id": "phase-2", "text": "Phase 2"])

        XCTAssertEqual(annotation?.mark, .point(.element(id: "phase-2", text: "Phase 2")))
    }

    // MARK: - What is refused

    func testACircleAroundNothingIsRefused() {
        XCTAssertNil(decode(["kind": "enclosure", "targets": []]))
        XCTAssertNil(decode(["kind": "enclosure"]))
    }

    func testAnArrowWithNeitherEndIsRefused() {
        XCTAssertNil(
            decode(["kind": "relation"]),
            "one end empty is 'add a node here'; both ends empty is nothing at all")
    }

    func testAnEnclosureCoveringTheWholeDocumentIsRefused() {
        let many = (0..<(CanvasAnnotation.maximumEnclosureCount + 1)).map {
            target("node-\($0)", "n\($0)")
        }

        XCTAssertNil(decode(["kind": "enclosure", "targets": many]))
    }

    func testAMarkWithNoCommentIsRefusedLikeAnySelection() {
        XCTAssertNil(
            decode(["kind": "point", "id": "phase-2", "text": "Phase 2"], comment: "   "))
    }

    // MARK: - Today's behaviour, unchanged

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
            "kind": "point", "id": "mermaid-0-node_1", "text": "branchA",
        ])

        XCTAssertEqual(annotation?.mark, .point(.quote("branchA")))
    }

    func testAnEdgeAndAMarkerDefDegradeToo() {
        for id in ["mermaid-0-L_phase1_phase2_0", "mermaid-0_flowchart-v2-pointEnd"] {
            let annotation = decode(["kind": "point", "id": id, "text": "x"])
            XCTAssertEqual(
                annotation?.mark, .point(.quote("x")),
                "\(id) is renderer bookkeeping, not an anchor")
        }
    }

    func testAnAgentAuthoredIDIsStillKept() {
        // The whole reason `isRenderGenerated` exists: "cannot reduce" has two causes and
        // only one of them means "throw it away".
        let annotation = decode(["kind": "point", "id": "phase-2", "text": "Phase 2"])

        XCTAssertEqual(annotation?.mark, .point(.element(id: "phase-2", text: "Phase 2")))
    }

    func testASequenceActorIsIndistinguishableFromAnAuthoredID() {
        // A stated ceiling rather than a hidden one: sequenceDiagram emits `actor0` with no
        // `mermaid-` prefix, so helm cannot tell it from an id an agent wrote. It does not
        // guess — it keeps it, and #112's spec says so.
        let annotation = decode(["kind": "point", "id": "actor0", "text": "alice"])

        XCTAssertEqual(annotation?.mark, .point(.element(id: "actor0", text: "alice")))
    }
}
