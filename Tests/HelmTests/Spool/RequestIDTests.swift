import Foundation
import HelmWire
import XCTest

/// `RequestID`'s own contract, isolated from the spool machinery that carries it — the shape
/// `TerminalIDTests` and `HandleTests` already hold for their own newtypes.
///
/// `SpoolWireConformanceTests` proves the *shape* this puts on the wire is a bare string the six
/// scripts can still read and write by hand, and that each of them applies the same pattern.
/// `SpoolModelTests.testAClaimedRequestWithATraversalIdWritesNothingOutsideTheSpool` proves the
/// *route* #260 was filed over. This file proves the *type*: what `validating:` takes, what it
/// refuses, and that a malformed value on the wire is a decode error rather than a silently
/// wrong filename.
final class RequestIDTests: XCTestCase {
    // MARK: - What a filename is

    func testValidatingAcceptsTheIdsTheSpoolScriptsActuallyGenerate() {
        // The real default from each script — `<verb>-<millis>-<random>` — plus the dotted shape
        // `SpoolPolicyTests` already pins, and a bare uuid, which is what a caller passing
        // `--id "$(uuidgen)"` produces.
        for candidate in [
            "spool-1786393222051-52341", "capture-1786393222051-4096", "close-1-4096",
            "spawn.2026-08-04_17-02-11", "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "r", "A0",
        ] {
            XCTAssertEqual(
                RequestID(validating: candidate)?.value, candidate,
                "\"\(candidate)\" is a filename and must be accepted verbatim")
        }
    }

    /// **The two that escape are the whole reason this type exists.** `..` and `/` both survive
    /// `appendingPathComponent` — measured, `results/../../../../tmp/pwned.json` standardizes to
    /// `/tmp/pwned.json` — so an id carrying either writes wherever the caller likes.
    func testValidatingRefusesAnythingThatIsNotAFilename() {
        for candidate in [
            "../../etc/passwd", "..", "a/b", "/absolute", "", "   ", ".hidden", "-leading-dash",
            "has space", "trailing\n", String(repeating: "x", count: 65),
        ] {
            XCTAssertNil(
                RequestID(validating: candidate),
                "\"\(candidate)\" must not be usable as a filename component")
        }
    }

    /// **Deliberately not trimmed, unlike `Handle(validating:)`** — the caller waits on
    /// `results/<id>.json` spelled exactly as it wrote it, so silently accepting `" r"` as `"r"`
    /// would answer a file nobody is watching.
    func testValidatingDoesNotTrimTheWayHandleDoes() {
        XCTAssertNil(RequestID(validating: " r"))
        XCTAssertNil(RequestID(validating: "r "))
        XCTAssertNotNil(
            Handle(validating: " helm-4242 "), "the sibling that does trim, for contrast")
    }

    func testTheBoundaryOfTheLengthCapIsSixtyFour() {
        XCTAssertNotNil(RequestID(validating: String(repeating: "x", count: 64)))
        XCTAssertNil(RequestID(validating: String(repeating: "x", count: 65)))
    }

    // MARK: - The wire

    func testEncodingIsABareStringNotAnObject() throws {
        let data = try JSONEncoder().encode(RequestID(validating: "spool-1-2")!)
        // A bare string is a valid top-level JSON value but not an array or object, so
        // `JSONSerialization` needs `.fragmentsAllowed` to read it at all. Failing to parse here
        // would itself be evidence the wire shape is not a bare string — which every one of the
        // six scripts reads and writes by hand.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String)
        XCTAssertEqual(json, "spool-1-2")
    }

    func testDecodingAWellFormedIdSucceeds() throws {
        let decoded = try JSONDecoder().decode(RequestID.self, from: Data(#""close-1-2""#.utf8))
        XCTAssertEqual(decoded.value, "close-1-2")
    }

    /// The throw path. `SpoolResult.id` is only ever written by helm from a `RequestID` that came
    /// through `validating:`, so a value that fails it here means the file was hand-edited or came
    /// from somewhere else entirely — worth a decode error rather than a filename helm would then
    /// build a path from.
    func testDecodingATraversalIdThrowsRatherThanDecodingToIt() {
        let data = Data(#""../../../../tmp/pwned""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RequestID.self, from: data)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected a DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    /// A `SpoolResult` whose id was tampered with on disk fails to decode as a whole, rather than
    /// decoding with a hostile id — which is what makes `SpoolDirectory.result(id:)`'s `try?`
    /// answer `nil` and helm treat the request as unanswered.
    func testAResultCarryingATraversalIdDoesNotDecodeAtAll() {
        let data = Data(#"{"id":"../../pwned","status":"ready","updatedAt":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SpoolResult.self, from: data))
    }

    // MARK: - One spelling of the rule

    /// **The pattern lives on this type and nothing restates it in Swift.** `SpoolPolicy.accept`
    /// and `SpoolModel.refuse` both reach the rule by *constructing* a `RequestID`, so the only
    /// other copies are the six scripts', which cannot import this module and are held by
    /// `SpoolWireConformanceTests.testEverySpoolScriptGatesItsIdWithHelmWiresOwnPattern`.
    func testThePatternAndTheConstructorAgree() {
        for candidate in ["ok-1", "../escape", "", String(repeating: "x", count: 65)] {
            let matchesPattern =
                candidate.range(of: RequestID.pattern, options: .regularExpression) != nil
            XCTAssertEqual(
                matchesPattern, RequestID(validating: candidate) != nil,
                "the published pattern and the constructor disagree about \"\(candidate)\" — the "
                    + "scripts copy the pattern, so a constructor that means something else is a "
                    + "silent divergence")
        }
    }
}
