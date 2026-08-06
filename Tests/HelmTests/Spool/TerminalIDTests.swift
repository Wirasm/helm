import Foundation
import HelmWire
import XCTest

/// `TerminalID`'s own contract, isolated from the spool machinery that carries it.
///
/// `SpoolWireConformanceTests` proves the *shape* `TerminalID` puts on the wire is a bare
/// string a script can still read. This file proves the *type* itself: what `validating:`
/// accepts and refuses, and — the gap the code reviewer named on #229's PR, previously
/// exercised only indirectly through `SpoolDirectory.result(id:)`'s `try?`, which fails soft
/// and would hide a regression here — that a malformed value on the wire is a decode error
/// rather than a silently `nil` field.
final class TerminalIDTests: XCTestCase {
    func testDecodingAWellFormedUuidStringSucceeds() throws {
        let uuid = UUID()
        let data = Data(#""\#(uuid.uuidString)""#.utf8)
        let decoded = try JSONDecoder().decode(TerminalID.self, from: data)
        XCTAssertEqual(decoded.uuid, uuid)
    }

    /// The throw path itself. `AcceptedCloseRequest.terminal` and `SpoolResult.terminalId` are
    /// only ever written from a real `TerminalID`, so a value that fails to parse back here
    /// means the file was hand-edited or came from somewhere else entirely — worth a decode
    /// error a caller has to notice, not a `nil` it can quietly ignore.
    func testDecodingAMalformedUuidStringThrowsRatherThanDecodingToNil() {
        let data = Data(#""not-a-uuid""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalID.self, from: data)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected a DecodingError.dataCorrupted, got \(error)")
            }
        }
    }

    func testDecodingAKeyedObjectThrowsRatherThanReadingAField() {
        // The shape `SpoolResult.terminalId` must never take — see
        // `SpoolWireConformanceTests.testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady`
        // for the same property proved from the encode side, through a real script.
        let data = Data(#"{"uuid":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalID.self, from: data))
    }

    func testEncodingIsABareStringNotAnObject() throws {
        let uuid = UUID()
        let data = try JSONEncoder().encode(TerminalID(uuid))
        // A bare string is a valid top-level JSON value but not an array or object, so
        // `JSONSerialization` needs `.fragmentsAllowed` to read it at all — the same leniency
        // `JSONDecoder` grants by default. Failing to parse here would itself be evidence the
        // wire shape is not a bare string.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String)
        XCTAssertEqual(json, uuid.uuidString)
    }

    func testValidatingTrimsWhitespaceAndAcceptsAWellFormedUuid() {
        let uuid = UUID()
        XCTAssertEqual(TerminalID(validating: "  \(uuid.uuidString)  ")?.uuid, uuid)
    }

    func testValidatingRefusesAnythingThatIsNotAUuid() {
        for candidate in ["", "   ", "not-a-uuid", "1E5B7B1C-0000-4000-8000"] {
            XCTAssertNil(
                TerminalID(validating: candidate), "\"\(candidate)\" must not parse as a uuid")
        }
    }
}
