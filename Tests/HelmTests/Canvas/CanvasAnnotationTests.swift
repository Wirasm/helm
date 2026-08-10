import XCTest

@testable import Helm

/// The bridge's payload is written by a page helm did not author, so every field is
/// type-checked and bounded here. A malformed body is nil — never a crash, never a
/// half-written note.
final class CanvasAnnotationTests: XCTestCase {
    /// A plain text selection exactly as the page posts one — **including `kind`**, which every
    /// bridge message has carried since #109 and which the gate refuses a body without. Filled
    /// in here rather than in twenty fixtures so these tests stay about the ANCHOR, which is
    /// their subject; `CanvasModelTests.testTheGateAsksTheKindAndRefusesOneItDoesNotKnow` is
    /// where the kind itself is the subject.
    private func decode(
        _ body: Any, comment: String = "this ordering is wrong"
    ) -> CanvasAnnotation? {
        guard var payload = body as? [String: Any] else {
            return CanvasAnnotation.decode(body, comment: comment)
        }
        payload["kind"] = payload["kind"] ?? CanvasPageSelection.Kind.selection.rawValue
        return CanvasAnnotation.decode(payload, comment: comment)
    }

    // MARK: - The anchor

    func testAnAuthoredIDBecomesTheAnchor() {
        let annotation = decode(["id": "phase-2", "text": "Phase 2 — migrate the store"])

        XCTAssertEqual(
            annotation?.mark,
            .selection(.element(id: "phase-2", text: "Phase 2 — migrate the store")),
            "the agent authored the page, so it knows its own ids — #phase-2 is directly "
                + "editable rather than merely descriptive")
        XCTAssertEqual(annotation?.comment, "this ordering is wrong")
    }

    func testAMermaidNodeAnchorsToItsFenceIdentifier() {
        // What the bridge actually posts for a mermaid node: the walk-up finds the
        // node's <g>, whose id is mostly renderer bookkeeping. The anchor keeps only
        // the part that appears in the ```mermaid fence, so the agent can grep it (#113).
        let annotation = decode(
            ["id": "mermaid-0-flowchart-phase2-1", "text": "Phase 2: Ship"])

        XCTAssertEqual(annotation?.mark, .selection(.element(id: "phase2", text: "Phase 2: Ship")))
    }

    func testANonMermaidIDIsLeftExactlyAsAuthored() {
        // The reduction must be invisible to every canvas that is not a diagram.
        let annotation = decode(["id": "mermaid-flavoured-notes", "text": "a passage"])

        XCTAssertEqual(
            annotation?.mark,
            .selection(.element(id: "mermaid-flavoured-notes", text: "a passage")),
            "an id that merely starts with the word is still the agent's own")
    }

    func testNoIDDegradesToAQuote() {
        let annotation = decode(["text": "the store move has to come first"])

        XCTAssertEqual(
            annotation?.mark, .selection(.quote("the store move has to come first")),
            "markdown goes through marked client-side and headings get no id unless the "
                + "page adds one — this is the documented degradation, not a bug")
    }

    func testAnIDOfNullDegradesToAQuoteRatherThanFailing() {
        // The script posts `id: null` when it found no ancestor with one.
        let annotation = decode(["id": NSNull(), "text": "a passage"])

        XCTAssertEqual(annotation?.mark, .selection(.quote("a passage")))
    }

    // MARK: - Hostile and malformed bodies

    func testAnIDWithCharactersAnIDCannotHaveIsRefused() {
        for hostile in ["a\"b", "id with spaces", "</script>", "a'); drop--", "\u{0}"] {
            XCTAssertEqual(
                decode(["id": hostile, "text": "some text"])?.mark, .selection(.quote("some text")),
                "\(hostile) is not an id, so it degrades rather than being trusted")
        }
    }

    func testAnOversizedIDIsRefused() {
        let long = String(repeating: "a", count: CanvasAnnotation.maximumIDLength + 1)

        XCTAssertEqual(
            decode(["id": long, "text": "some text"])?.mark, .selection(.quote("some text")))
    }

    /// Refused rather than truncated: half a quotation anchors to the wrong place just as
    /// confidently as a whole one.
    func testOversizedTextIsRefusedOutright() {
        let long = String(repeating: "x", count: CanvasAnnotation.maximumTextLength + 1)

        XCTAssertNil(decode(["text": long]))
    }

    func testANonDictionaryBodyIsNil() {
        XCTAssertNil(decode("just a string"))
        XCTAssertNil(decode(42))
        XCTAssertNil(decode([1, 2, 3]))
    }

    func testAMissingOrNonStringTextIsNil() {
        XCTAssertNil(decode(["id": "phase-2"]))
        XCTAssertNil(decode(["id": "phase-2", "text": 17]))
        XCTAssertNil(decode(["text": "   \n  "]), "whitespace is not a selection")
    }

    func testAnEmptyCommentIsRefused() {
        XCTAssertNil(decode(["text": "a passage"], comment: ""))
        XCTAssertNil(decode(["text": "a passage"], comment: "   \n "))
    }

    func testControlCharactersAreStrippedFromTheQuote() {
        let annotation = decode(["text": "clean\u{7}text\nkept"])

        XCTAssertEqual(
            annotation?.mark, .selection(.quote("cleantext\nkept")),
            "newlines and tabs survive; a bell does not")
    }

    /// A JS number arrives as `NSNumber`, not `Int` — the reason every read here
    /// type-checks instead of force-casting.
    func testABridgedNumberWhereAStringBelongsIsNil() {
        XCTAssertNil(decode(["id": "ok", "text": NSNumber(value: 3)]))
    }

    // MARK: - What is deliberately absent

    /// #39 asks for no screenshots in the *payload*, and the guarantee is structural: there
    /// is no field here that could carry one, so a page sending image data has nowhere to
    /// put it. Nothing wider is meant by that — the rendered canvas is screenshotted
    /// elsewhere, and that is how an agent validates what it wrote.
    ///
    /// The expected value is asserted field by field rather than against a hand-built
    /// `CanvasAnnotation` (#326): that construction is gone, and this suite is the one place that
    /// must not reach for `CanvasAnnotationFixture` — its subject IS `decode`, and a gate checked
    /// against a helper that goes through the gate asserts nothing. Nothing is weakened by the
    /// change, because `Equatable` here is synthesized over exactly these two fields, so the whole
    /// value and the pair are the same assertion.
    func testNothingFromTheBodyIsCarriedBeyondTheAnchorAndComment() throws {
        let annotation = try XCTUnwrap(
            decode([
                "id": "phase-2", "text": "Phase 2", "screenshot": "data:image/png;base64,AAAA",
                "rect": ["x": 1, "y": 2],
            ]))

        XCTAssertEqual(annotation.mark, .selection(.element(id: "phase-2", text: "Phase 2")))
        XCTAssertEqual(annotation.comment, "this ordering is wrong")
    }
}
