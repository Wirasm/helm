import XCTest

@testable import Helm

/// Builds a `CanvasAnnotation` the only way there is — through `CanvasAnnotation.decode`, from
/// the body `canvas-annotation.js` actually posts (#326).
///
/// **Why this exists at all.** `CanvasAnnotation.init` is `private`, so a fixture cannot assemble
/// a mark beside the gate any more; before that it could, and fifteen across five files did. What
/// they held themselves to was nothing — not a non-empty comment, not `maximumIDLength` or
/// `maximumTextLength`, and not the control-character strip. Going through
/// the decoder makes the next wire change fail **here**, at construction, instead of three
/// assertions downstream on whatever the test was actually about. #293 is what that costs: a
/// selection fixture went stale the moment #288 made `kind` the discriminator, and CI reported
/// *"Enter no longer writes the note"* across three tests while Enter worked perfectly.
///
/// **Shared, where #323 wrote the same helper twice.** That PR had two call sites in two files and
/// a private copy in each; this one has fifteen across five, and five copies of one refusal message
/// is the drift these gates exist to stop — a rule spelled once and maintained by hand in five
/// places is the defect, not the fix. It is `extension XCTestCase` rather than a namespace enum
/// because that is how `IsolatedDefaults` already hands a suite to every test class here.
///
/// **What deliberately does NOT come through here**: anything whose subject *is* the decoder.
/// `CanvasMarkTests` and `CanvasAnnotationTests` drive `CanvasAnnotation.decode(posted:)` directly
/// and must keep doing so — a gate tested through a helper that goes through the gate asserts
/// nothing.
extension XCTestCase {
    /// The page's own message body, decoded. `kind` defaults to `selection`, as it does in
    /// `CanvasAnnotationTests` and `CanvasMarkTests`.
    ///
    /// `file`/`line` default from the caller, so a refusal is reported at the test that asked
    /// rather than here — a whole suite pointing at this line would name the drift's location
    /// instead of its subject.
    func annotation(
        marking body: [String: Any], comment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> CanvasAnnotation {
        var body = body
        body["kind"] = body["kind"] ?? CanvasPageSelection.Kind.selection.rawValue
        return try XCTUnwrap(
            CanvasAnnotation.decode(posted: body, comment: comment),
            "the annotation fixture this test is built on is not a body helm accepts any more — "
                + "`CanvasAnnotation.decode` refused \(body) commented \"\(comment)\". Rebuild it "
                + "to the shape `canvas-annotation.js` posts; do not loosen the decoder.",
            file: file, line: line)
    }

    /// Selected text, with the authored element id where the page found one.
    func annotation(
        selecting text: String, id: String? = nil, comment: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> CanvasAnnotation {
        var body: [String: Any] = ["text": text]
        if let id { body["id"] = id }
        return try annotation(marking: body, comment: comment, file: file, line: line)
    }
}

extension CanvasAnnotation {
    /// A body the page posted, through **both** real gates in the order the app runs them:
    /// `CanvasPageSelection.decode` (the bridge's, which reads `kind` and decodes the mark) and
    /// then `CanvasAnnotation.decode` (the comment's). `nil` when either refuses.
    ///
    /// Test-only, and not a third gate. Since #210 there is no production function that takes a
    /// raw body and a comment together, because the app never holds both at once: the body is
    /// decoded when the page posts it and the comment arrives later. Tests about what a posted
    /// body becomes want exactly that composition, and `CanvasSelection.init` is `fileprivate`,
    /// so this cannot build a selection any other way.
    static func decode(posted body: Any, comment: String) -> CanvasAnnotation? {
        guard case let .success(.selected(selection)) = CanvasPageSelection.decode(body) else {
            return nil
        }
        return decode(selection, comment: comment)
    }
}
