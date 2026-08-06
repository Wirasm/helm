import Foundation
import HelmWire
import XCTest

/// `Handle`'s own contract, isolated from the spool machinery that carries it — the file its
/// sibling `TerminalIDTests` has had since `9863944` and this type never got.
///
/// **The gap this closes is that `Handle(validating:)` had no test at all.** It appeared in six
/// places across the suite and every one used it as a fixture builder — `Handle(validating: "…")!`
/// on the way to constructing something else — so nothing asserted what it accepts or refuses.
/// The rule *was* pinned, but only on the disk route, in `MailboxDirectoryTests`; the copy in
/// `validating:` was pinned by nothing, and their agreement by nothing at all. That is what let
/// the two spellings disagree once already (`9863944`'s own message).
///
/// So the point of this file is the rule, not the type: `MailboxOwner.init(from:)` and
/// `Handle.init(from:)` both *call* `validating:` now rather than restating it, and
/// `testEveryRouteRefusesTheSameMalformedHandle` is what would notice if one stopped.
final class HandleTests: XCTestCase {

    // MARK: - validating:

    func testValidatingAcceptsAPlausibleHandleAndTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(Handle(validating: "helm-4831")?.value, "helm-4831")
        XCTAssertEqual(Handle(validating: "  helm-4831\n")?.value, "helm-4831")
    }

    func testValidatingRefusesAnEmptyOrWhitespaceOnlyHandle() {
        for candidate in ["", " ", "   ", "\t", "\n", " \t\n "] {
            XCTAssertNil(
                Handle(validating: candidate),
                "\(candidate.debugDescription) addresses nobody and must not become a Handle")
        }
    }

    /// **A control, and it must pass: `validating:` is not a typo catcher and does not claim to
    /// be.** Every candidate here names a directory that does not exist, and every one is
    /// accepted, because both writers of the address scheme slug harder than this rule does
    /// (`hooks/helm-mail.mjs:66`, `pi/extensions/helm-mail/index.ts:178` — lowercase, collapse
    /// `[^a-z0-9]+`). Tightening to match is a behaviour change that would also start rejecting
    /// already-written files, since every route shares this rule now; it is deferred to its own
    /// issue with the `helm-mail-cc` case in scope. This test exists so that deferral is
    /// *recorded* rather than assumed, and so whoever picks it up sees exactly which inputs
    /// change meaning.
    func testValidatingDoesNotEnforceTheWritersCharacterRuleAndSaysSo() throws {
        for candidate in ["Alice", "my agent", "owner_1234"] {
            XCTAssertNotNil(
                Handle(validating: candidate),
                "\(candidate.debugDescription) is refused now — that is a deliberate behaviour "
                    + "change, so update this test and Handle(validating:)'s header together")
        }
    }

    // MARK: - the wire

    func testEncodingIsABareStringNotAnObject() throws {
        let data = try JSONEncoder().encode(try XCTUnwrap(Handle(validating: "helm-4831")))
        // A bare string is a valid top-level JSON value but not an array or object, so
        // `JSONSerialization` needs `.fragmentsAllowed` to read it at all. Failing to parse here
        // would itself be evidence the wire shape is not a bare string.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String)
        XCTAssertEqual(json, "helm-4831")
    }

    func testDecodingABareStringRoundTripsAndTrims() throws {
        func decode(_ json: String) throws -> String {
            try JSONDecoder().decode(Handle.self, from: Data(json.utf8)).value
        }
        XCTAssertEqual(try decode(#""helm-4831""#), "helm-4831")
        XCTAssertEqual(try decode(#""  helm-4831 ""#), "helm-4831")
    }

    /// The throw path. `SpoolResult.handle` and `BenchSnapshot.OwnerRecord.handle` are only ever
    /// written by helm from a validated `Handle`, so a value that fails here means the file was
    /// hand-edited or came from somewhere else — worth a decode error rather than a field that
    /// silently addresses nobody. Both call sites take it as a soft `nil` behind `try?`; see
    /// `Handle.init(from:)`'s header for why that is safe at each.
    func testDecodingAnEmptyOrWhitespaceOnlyHandleThrowsRatherThanAddressingNobody() {
        for raw in [#""""#, #""   ""#, #""\t""#] {
            XCTAssertThrowsError(try JSONDecoder().decode(Handle.self, from: Data(raw.utf8))) {
                error in
                guard case DecodingError.dataCorrupted = error else {
                    return XCTFail("expected DecodingError.dataCorrupted for \(raw), got \(error)")
                }
            }
        }
    }

    func testDecodingAKeyedObjectThrowsRatherThanReadingAField() {
        // The shape `handle` must never take on the wire — proved from the encode side, through
        // a real script, by `SpoolWireConformanceTests
        // .testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady`.
        XCTAssertThrowsError(
            try JSONDecoder().decode(Handle.self, from: Data(#"{"value":"helm-4831"}"#.utf8)))
    }

    // MARK: - the routes agree

    /// **The test the copied rule never had.** Before #233 the trim-and-reject lived twice —
    /// once in `validating:`, once hand-written inside `MailboxOwner.init(from:)` — with a
    /// comment between them asking them to match. Nothing failed if they stopped. Now all three
    /// routes call one rule, and this is what notices if a fourth spelling appears: the same
    /// malformed input, refused through the caller-named route, the `owner.json` route and the
    /// `Handle` decode route alike.
    /// The candidates are spelled as they appear *inside* a JSON string — `\t`, not a literal
    /// tab — because interpolating a raw control character produces malformed JSON, and then
    /// every decode below would throw for parsing reasons and prove nothing about the rule.
    func testEveryRouteRefusesTheSameMalformedHandle() throws {
        for escaped in ["", "   ", #"\t"#, #"\n"#, #" \t\n "#] {
            let unescaped = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data("\"\(escaped)\"".utf8), options: [.fragmentsAllowed]) as? String,
                "\(escaped.debugDescription) must itself be a valid JSON string body")

            XCTAssertNil(
                Handle(validating: unescaped),
                "the caller-named route must refuse \(unescaped.debugDescription)")

            let owner = Data(
                #"{"handle":"\#(escaped)","runtime":"claude","pid":4242,"cwd":"/tmp"}"#.utf8)
            XCTAssertThrowsError(
                try JSONDecoder().decode(MailboxOwner.self, from: owner),
                "the owner.json route must refuse \(unescaped.debugDescription)")

            XCTAssertThrowsError(
                try JSONDecoder().decode(Handle.self, from: Data("\"\(escaped)\"".utf8)),
                "the Handle decode route must refuse \(unescaped.debugDescription)")
        }
    }

    /// The agreement in the other direction: what one route accepts, the others accept, with the
    /// same trimming applied. A rule that only ever refuses is satisfied by refusing everything.
    func testEveryRouteAcceptsTheSameWellFormedHandleAndTrimsItIdentically() throws {
        let owner = try JSONDecoder().decode(
            MailboxOwner.self,
            from: Data(
                #"{"handle":"  helm-4831 ","runtime":"claude","pid":4242,"cwd":"/tmp"}"#.utf8))

        XCTAssertEqual(owner.handle, "helm-4831")
        XCTAssertEqual(Handle(readingFrom: owner).value, "helm-4831")
        XCTAssertEqual(Handle(validating: "  helm-4831 ")?.value, "helm-4831")
        XCTAssertEqual(
            try JSONDecoder().decode(Handle.self, from: Data(#""  helm-4831 ""#.utf8)).value,
            "helm-4831")
    }
}
