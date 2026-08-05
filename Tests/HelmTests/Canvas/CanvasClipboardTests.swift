import XCTest

@testable import Helm

/// What lands on the clipboard when a comment is written, so it can be pasted into an agent
/// helm cannot reach. One comment, never the accumulation — pasting every note is the same as
/// pasting the file, and the header already copies the path for that.
final class CanvasClipboardTests: XCTestCase {
    private let canvas = URL(fileURLWithPath: "/tmp/plans/audit-board.html")

    private func copied(
        _ mark: CanvasAnnotation.Mark, _ comment: String = "is this right?"
    ) -> String {
        CanvasNotes.clipboardEntry(
            CanvasAnnotation(mark: mark, comment: comment), for: canvas)
    }

    func testItCarriesThePathTheAnchorAndTheComment() {
        let text = copied(.selection(.element(id: "p-iss", text: "ISSUES — 17 PROBED")))

        XCTAssertTrue(text.contains("/tmp/plans/audit-board.html"))
        XCTAssertTrue(text.contains("`#p-iss`"))
        XCTAssertTrue(text.contains("is this right?"))
    }

    func testTheAnchorLineIsTheSAMELineTheSidecarWrites() {
        // Not a second format. The heading already carries the gesture and what it covered,
        // because that is how an anchor renders — so a paste and the file cannot disagree.
        let annotation = CanvasAnnotation(
            mark: .enclosure(covering: [.element(id: "phase-2", text: "Phase 2: Ship")]),
            comment: "wrong order")
        let entry = CanvasNotes.entry(annotation, at: Date(timeIntervalSince1970: 0))
        let heading = entry.split(separator: "\n").first.map { $0.dropFirst(3) } ?? ""

        XCTAssertTrue(
            CanvasNotes.clipboardEntry(annotation, for: canvas).contains(String(heading)),
            "the clipboard should quote the sidecar's own heading verbatim")
    }

    func testAnArrowKeepsBothEnds() {
        // The reason the heading is reused rather than a bare id: an arrow names two things,
        // and half of it is a different instruction.
        let text = copied(
            .relation(
                from: .element(id: "phase-1", text: "One"),
                to: .element(id: "phase-3", text: "Three")))

        XCTAssertTrue(text.contains("`#phase-1`"))
        XCTAssertTrue(text.contains("`#phase-3`"))
        XCTAssertTrue(text.contains("→"))
    }

    func testAQuoteIsVisiblyNotAnID() {
        // mindmap, sequence and plain markdown all degrade to a quote. The agent has to be
        // able to tell "grep for this identifier" from "search for this text".
        let quoted = copied(.point(.quote("branchA")))

        XCTAssertTrue(quoted.contains("\"branchA\""))
        XCTAssertFalse(quoted.contains("`#"), "a quote must not look like an id")
    }

    func testItCarriesNoImageAndNoCoordinate() {
        let text = copied(.enclosure(covering: [.element(id: "a", text: "A")]))

        for forbidden in ["data:image", "base64", "rect", "px"] {
            XCTAssertFalse(
                text.contains(forbidden),
                "an anchor made of pixels is not something an agent can edit — found \(forbidden)")
        }
    }

    func testItIsOneCommentRatherThanTheAccumulation() {
        let text = copied(.selection(.quote("just this")), "only me")

        XCTAssertEqual(
            text.components(separatedBy: "canvas:").count - 1, 1,
            "one entry; the whole sidecar is what copying the file is for")
    }
}
