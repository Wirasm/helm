import XCTest

@testable import Helm

/// What lands on the clipboard when a comment is written, so it can be pasted into an agent
/// helm cannot reach. One comment, never the accumulation — pasting every note is the same as
/// pasting the file, and the header already copies the path for that.
final class CanvasClipboardTests: XCTestCase {
    private let canvas = URL(fileURLWithPath: "/tmp/plans/audit-board.html")

    /// **The gesture as the page posts it, decoded** (#326) — see `CanvasAnnotationFixture`.
    /// These took a `CanvasAnnotation.Mark` assembled by hand, so what was being pasted was a
    /// value the decoder had never produced and no page could send.
    private func copied(
        _ body: [String: Any], _ comment: String = "is this right?",
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        CanvasNotes.clipboardEntry(
            try annotation(marking: body, comment: comment, file: file, line: line), for: canvas)
    }

    func testItCarriesThePathTheAnchorAndTheComment() throws {
        let text = try copied([
            "kind": "selection", "id": "p-iss", "text": "ISSUES — 17 PROBED",
        ])

        XCTAssertTrue(text.contains("/tmp/plans/audit-board.html"))
        XCTAssertTrue(text.contains("`#p-iss`"))
        XCTAssertTrue(text.contains("is this right?"))
    }

    func testTheAnchorLineIsTheSAMELineTheSidecarWrites() throws {
        // Not a second format. The heading already carries the gesture and what it covered,
        // because that is how an anchor renders — so a paste and the file cannot disagree.
        let marked = try annotation(
            marking: [
                "kind": "enclosure",
                "targets": [["id": "phase-2", "text": "Phase 2: Ship"] as [String: Any]],
            ],
            comment: "wrong order")
        let entry = CanvasNotes.entry(marked, at: Date(timeIntervalSince1970: 0))
        let heading = entry.split(separator: "\n").first.map { $0.dropFirst(3) } ?? ""

        XCTAssertTrue(
            CanvasNotes.clipboardEntry(marked, for: canvas).contains(String(heading)),
            "the clipboard should quote the sidecar's own heading verbatim")
    }

    func testAnArrowKeepsBothEnds() throws {
        // The reason the heading is reused rather than a bare id: an arrow names two things,
        // and half of it is a different instruction.
        let text = try copied([
            "kind": "relation",
            "from": ["id": "phase-1", "text": "One"] as [String: Any],
            "to": ["id": "phase-3", "text": "Three"] as [String: Any],
        ])

        XCTAssertTrue(text.contains("`#phase-1`"))
        XCTAssertTrue(text.contains("`#phase-3`"))
        XCTAssertTrue(text.contains("→"))
    }

    func testAQuoteIsVisiblyNotAnID() throws {
        // mindmap, sequence and plain markdown all degrade to a quote. The agent has to be
        // able to tell "grep for this identifier" from "search for this text".
        let quoted = try copied(["kind": "point", "text": "branchA"])

        XCTAssertTrue(quoted.contains("\"branchA\""))
        XCTAssertFalse(quoted.contains("`#"), "a quote must not look like an id")
    }

    func testItCarriesNoImageAndNoCoordinate() throws {
        let text = try copied([
            "kind": "enclosure", "targets": [["id": "a", "text": "A"] as [String: Any]],
        ])

        for forbidden in ["data:image", "base64", "rect", "px"] {
            XCTAssertFalse(
                text.contains(forbidden),
                "an anchor made of pixels is not something an agent can edit — found \(forbidden)")
        }
    }

    func testItIsOneCommentRatherThanTheAccumulation() throws {
        let text = try copied(["kind": "selection", "text": "just this"], "only me")

        XCTAssertEqual(
            text.components(separatedBy: "canvas:").count - 1, 1,
            "one entry; the whole sidecar is what copying the file is for")
    }
}
