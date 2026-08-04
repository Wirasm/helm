import XCTest

@testable import Helm

/// Every id in here was captured from a real WKWebView rendering the vendored
/// mermaid build with `deterministicIds: true` — not hand-written to match the
/// implementation, which would only prove the regex agrees with itself.
final class MermaidAnchorTests: XCTestCase {

    // MARK: - The families that carry the author's identifier

    func testAFlowchartNodeReducesToTheFenceIdentifier() {
        XCTAssertEqual(
            MermaidAnchor.sourceIdentifier(in: "mermaid-0-flowchart-phase2-1"), "phase2",
            "`phase2` is the only part of the id that appears in the ```mermaid fence, so "
                + "it is the only part an agent can grep for")
    }

    func testClassStateAndEntityNodesReduceToo() {
        XCTAssertEqual(MermaidAnchor.sourceIdentifier(in: "mermaid-0-classId-Animal-0"), "Animal")
        XCTAssertEqual(MermaidAnchor.sourceIdentifier(in: "mermaid-0-state-idle-1"), "idle")
        XCTAssertEqual(
            MermaidAnchor.sourceIdentifier(in: "mermaid-0-entity-CUSTOMER-0"), "CUSTOMER")
    }

    func testTheDiagramIndexIsIgnoredSoASecondDiagramOnThePageStillReduces() {
        // The second diagram on a page renders as mermaid-1; the node is the same node.
        XCTAssertEqual(MermaidAnchor.sourceIdentifier(in: "mermaid-1-flowchart-phase2-1"), "phase2")
    }

    func testTheSameNodeReducesIdenticallyAcrossTheEditsThatMoveItsRawID() {
        // Measured: adding a node above phase2 moved the counter 1 -> 3, removing one
        // moved it to 0, and a second diagram moved the prefix. All four are the same
        // node, and must produce the same anchor — this is the whole point of #113.
        let acrossEdits = [
            "mermaid-0-flowchart-phase2-1",  // baseline
            "mermaid-0-flowchart-phase2-3",  // a node added above it
            "mermaid-0-flowchart-phase2-0",  // a node removed above it
            "mermaid-1-flowchart-phase2-1",  // a second diagram added to the page
        ]

        XCTAssertEqual(
            Set(acrossEdits.compactMap(MermaidAnchor.sourceIdentifier(in:))), ["phase2"],
            "the raw id moves on almost any edit; the fence identifier does not")
    }

    // MARK: - Identifiers that contain the separator

    func testAnIdentifierContainingDashesSurvivesWhole() {
        // helm's own docs anchor to `#phase-2`, so this is the shape that matters most.
        XCTAssertEqual(
            MermaidAnchor.sourceIdentifier(in: "mermaid-0-flowchart-phase-2-1"), "phase-2",
            "only the LAST dash separates the counter — an identifier may contain dashes")
    }

    func testAPurelyNumericIdentifierStillReduces() {
        XCTAssertEqual(MermaidAnchor.sourceIdentifier(in: "mermaid-0-flowchart-2-0"), "2")
    }

    func testAnUnderscoredIdentifierSurvives() {
        XCTAssertEqual(
            MermaidAnchor.sourceIdentifier(in: "mermaid-0-state-root_start-0"), "root_start")
    }

    // MARK: - Everything that must be left alone

    func testAnAgentAuthoredIDIsNotTouched() {
        XCTAssertNil(
            MermaidAnchor.sourceIdentifier(in: "phase-2"),
            "an id the agent wrote by hand is already the greppable thing — reducing it "
                + "further would be helm inventing an anchor")
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "overview"))
    }

    func testTheSVGItselfIsNotANode() {
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0"))
    }

    func testEdgesAreNotReduced() {
        // An edge names two endpoints; reducing it to one would be a lie about what the
        // operator marked. #112 is where relations get their own representation.
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0-L_phase1_phase2_0"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0-edge0"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0-id_Animal_Dog_1"))
    }

    func testMarkerDefinitionsAreNotReduced() {
        // These use `_` after the diagram index rather than `-`.
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0_flowchart-v2-pointEnd"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0_class-extensionStart-margin"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0-drop-shadow"))
    }

    func testFamiliesThatEncodeNoIdentifierReturnNil() {
        // Measured: mindmap emits `node_0` and sequenceDiagram emits `actor0` / `root-0`.
        // The author's name for the node is nowhere in the DOM, so there is nothing to
        // recover and helm must not pretend otherwise. This is the documented ceiling
        // on #113, and what #112 inherits.
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0-node_1"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "actor0"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "root-0"))
    }

    func testAMalformedOrHostileIDIsRefusedRatherThanGuessedAt() {
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: ""))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-"))
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-x-flowchart-phase2-1"))
        XCTAssertNil(
            MermaidAnchor.sourceIdentifier(in: "mermaid-0-flowchart-phase2-x"),
            "a non-numeric trailing segment is part of an id helm does not recognise")
        XCTAssertNil(
            MermaidAnchor.sourceIdentifier(in: "mermaid-0-flowchart--1"),
            "an empty identifier is not an anchor")
        XCTAssertNil(MermaidAnchor.sourceIdentifier(in: "mermaid-0-unknownfamily-phase2-1"))
    }
}
