import GhosttyTerminal
import XCTest

@testable import Helm

/// What a ⌘-clicked path may have meant, before benchd is asked whether any of it is a store file.
final class TerminalStorePathTests: XCTestCase {
    private let path = "/Users/r/.prp/helm-3ec376fc/reports/plan.md"

    func testTheClickedPathAloneWhenItIsRenderable() {
        let cases: [(String, [String])] = [
            (path, [path]),
            ("~/.prp/helm-3ec376fc/review.html", ["~/.prp/helm-3ec376fc/review.html"]),
            // ghostty's path characters include the full stop that ends a sentence.
            (path + ".", [path]),
            (" \(path)\n", [path]),
            // Not a file helm renders, not rooted, or not a path at all: nothing to ask about.
            ("/Users/r/.prp/k/state.json", []),
            ("reports/plan.md", []),
            ("//host/plan.md", []),
            ("", []),
        ]
        for (clicked, expected) in cases {
            XCTAssertEqual(TerminalStorePath.candidates(clicked, around: nil), expected, clicked)
        }
    }

    func testAPathInsideARowIsNotJoinedWithItsNeighbours() {
        let grid = TerminalHoveredRows(
            rows: ["  /Users/r/.prp/k/a", "see `\(path)` for it", "/x.md"], hovered: 1)

        XCTAssertEqual(TerminalStorePath.candidates(path, around: grid), [path])
    }

    // MARK: - Hard-wrapped by the agent's TUI

    private let wrapped = TerminalHoveredRows(
        rows: [
            "⏺ Wrote the plan to `/Users/r/.prp/helm-3ec376fc/rep",
            "  orts/plan.md` and opened it.",
        ], hovered: 0)

    func testClickingTheFirstHalfJoinsTheRowBelow() {
        XCTAssertEqual(
            TerminalStorePath.candidates("/Users/r/.prp/helm-3ec376fc/rep", around: wrapped),
            [path])
    }

    func testClickingTheSecondHalfJoinsTheRowAbove() {
        // ghostty hands over the bare relative half when it names nothing on helm's disk.
        let below = TerminalHoveredRows(rows: wrapped.rows, hovered: 1)

        XCTAssertEqual(TerminalStorePath.candidates("orts/plan.md", around: below), [path])
    }

    func testAPathAcrossThreeRowsJoinsThroughTheMiddleOne() {
        let grid = TerminalHoveredRows(
            rows: [
                "see /Users/r/.prp/helm-3ec376fc/orch", "estration/2026-10-02-run",
                "/brief.md done",
            ],
            hovered: 0)

        XCTAssertEqual(
            TerminalStorePath.candidates("/Users/r/.prp/helm-3ec376fc/orch", around: grid),
            ["/Users/r/.prp/helm-3ec376fc/orchestration/2026-10-02-run/brief.md"])
    }

    func testEveryRenderableJoinIsOfferedTheClickedPathFirst() {
        // Prose wrapped at a space puts a whole word at each row edge; which join is the path is
        // benchd's to say, so each renderable spelling is a candidate.
        let grid = TerminalHoveredRows(rows: ["\(path)", "x.md"], hovered: 0)

        XCTAssertEqual(TerminalStorePath.candidates(path, around: grid), [path, path + "x.md"])
    }
}
