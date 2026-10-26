import XCTest

@testable import Helm

/// The attention queue as Archon 0.12 prints it: `Fixtures/workflow-attention.json` holds one
/// item of each answerable shape, captured from a probe workflow (a select, a message, an
/// approval and a multi-select wait, then a legacy `approval:` gate).
final class ArchonAttentionTests: XCTestCase {
    func testDecodesEveryItemShapeArchonPrints() throws {
        let items = try ArchonAttentionItem.captured()
        XCTAssertEqual(items.count, 5)

        guard case let .question(node, occurrence, message, form, options) = items[0].ask else {
            return XCTFail("expected a question, got \(items[0].ask)")
        }
        XCTAssertEqual(node, "pick")
        XCTAssertEqual(occurrence, "253f0983-399f-48f9-bff7-7b9d69fd0337")
        XCTAssertTrue(message.hasPrefix("**probe: pick one**"))
        XCTAssertEqual(form, "select")
        XCTAssertEqual(options.map(\.id), ["rerun", "finish"])
        XCTAssertNotNil(items[0].pausedAt, "ISO dates with milliseconds")
        XCTAssertNotNil(items[0].context.workingPath)

        guard case .gate(node: "gate", _, message: "Legacy gate: approve?") = items[4].ask else {
            return XCTFail("expected the legacy gate, got \(items[4].ask)")
        }
        XCTAssertNil(items[4].pausedAt, "a gate records no pause time")
    }

    /// What each shape offers the drawer. The approval form's options carry no labels, so the id
    /// is the label; a message wait's one answer is its text.
    func testEachShapeOffersTheAnswersArchonAccepts() throws {
        let items = try ArchonAttentionItem.captured()
        XCTAssertEqual(
            items[0].choices,
            [
                ArchonChoice(id: "rerun", label: "Run it again"),
                ArchonChoice(id: "finish", label: "Finish this run"),
            ])
        XCTAssertEqual(
            items[1].choices, [ArchonChoice(id: "approve", label: "answer", needsText: true)])
        XCTAssertEqual(items[2].choices.map(\.id), ["approve", "reject"])
        XCTAssertEqual(items[2].choices.map(\.label), ["approve", "reject"])
        XCTAssertEqual(
            items[3].choices, [], "respond carries one choice; a multi-select wants several")
        XCTAssertTrue(
            items[3].message.contains("archon workflow answer"), "and it says where to go")
        XCTAssertEqual(items[4].choices.map(\.id), ["approve", "reject"])
    }

    /// A kind this helm does not know costs that item its controls, never the queue its decode.
    func testAnUnknownKindIsKeptWithoutControls() throws {
        let json = """
            {"ok":true,"items":[{"kind":"something_new","runId":"r","workflow":"w",
             "pausedAt":null,"context":{"workingPath":null,"branch":null}},
             {"kind":"usage_limit","runId":"u","workflow":"w","pausedAt":null,
              "context":{"workingPath":null,"branch":null},"node":"plan",
              "resetAt":"2026-10-26T12:00:00.000Z"},
             {"kind":"unreadable","runId":"x","workflow":"w","pausedAt":null,
              "context":{"workingPath":null,"branch":null},"reason":"malformed_gate",
              "detail":"paused with no approval gate"}]}
            """
        let items = try JSONDecoder.archon().decode(
            ArchonAttentionResponse.self, from: Data(json.utf8)
        ).items

        XCTAssertEqual(items.map(\.runId), ["r", "u", "x"])
        XCTAssertEqual(items[0].ask, .unknown(kind: "something_new"))
        XCTAssertTrue(items.allSatisfy { $0.choices.isEmpty && $0.occurrence == nil })
        XCTAssertTrue(items[1].message.contains("usage limit"))
        XCTAssertTrue(items[2].isUnreadable)
    }
}
