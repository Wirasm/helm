import XCTest

@testable import Helm

/// The composer's write path.
///
/// The rules come from ghostty's own source at the commit this build pins
/// (`Ghostty.ref` → `35e1a01`): `src/config/string.zig` copies bytes verbatim
/// except that `\` opens a Zig string-literal escape, and `src/Surface.zig`'s
/// `.text` handler **logs an invalid escape and returns success** — the message
/// is dropped and the call still reports true. So the escaping is not cosmetic:
/// it is what makes that silent path unreachable.
final class PtyTextTests: XCTestCase {
    // MARK: - Escaping

    func testOrdinaryTextIsUnchanged() {
        XCTAssertEqual(PtyText.escape("fix the failing test"), "fix the failing test")
    }

    /// The only special byte. Doubling it means no other byte can ever begin an
    /// escape sequence, so `config/string.zig` cannot fail to parse.
    func testBackslashIsDoubled() {
        XCTAssertEqual(PtyText.escape(#"C:\Users\rasmus"#), #"C:\\Users\\rasmus"#)
        XCTAssertEqual(PtyText.escape(#"\n"#), #"\\n"#, "a literal backslash-n stays literal")
    }

    /// Quotes, colons and spaces are ordinary bytes: the action value is not
    /// quoted and `Binding.Action.parse` splits on the first colon only, taking
    /// the rest verbatim.
    func testQuotesColonsAndSpacesPassThrough() {
        let message = #"run "make test": it fails at 3:00"#
        XCTAssertEqual(PtyText.escape(message), message)
    }

    func testUnicodePassesThroughAsItsOwnBytes() {
        XCTAssertEqual(PtyText.escape("ship it 🚀 — nästa"), "ship it 🚀 — nästa")
    }

    /// A raw newline mid-message would submit everything before it and leave the
    /// rest at a fresh prompt — one message silently arriving as two.
    func testNewlinesAreEscapedRatherThanSentRaw() {
        XCTAssertEqual(PtyText.escape("one\ntwo"), #"one\ntwo"#)
        XCTAssertFalse(PtyText.escape("one\ntwo").contains("\n"))
    }

    // MARK: - The action

    /// One action, not two. #29 measured a race when prose and its return went
    /// separately: an 88-character message lost its CR, and a CR sent a moment
    /// later submitted it. One action is one write.
    func testSubmitActionCarriesTheTextAndItsReturn() {
        XCTAssertEqual(PtyText.submitAction(for: "hello"), #"text:hello\r"#)
    }

    func testSubmitActionTrimsSurroundingWhitespace() {
        XCTAssertEqual(PtyText.submitAction(for: "  hello  \n"), #"text:hello\r"#)
    }

    func testEmptyMessageProducesNoAction() {
        XCTAssertNil(PtyText.submitAction(for: ""))
        XCTAssertNil(PtyText.submitAction(for: "   \n  "))
    }

    /// The whole point, end to end: nothing an operator can type produces an
    /// action containing an escape sequence ghostty would reject.
    func testNoTypedMessageCanProduceAnInvalidEscape() {
        let hostile = [
            #"\"#, #"\x"#, #"\u"#, #"\u{"#, #"trailing backslash \"#,
            #"\\\"#, "\u{1B}[31m", #"{"json": "value"}"#,
        ]
        for message in hostile {
            guard let action = PtyText.submitAction(for: message) else { continue }
            XCTAssertTrue(action.hasPrefix("text:"))
            XCTAssertTrue(
                everyBackslashOpensAValidEscape(in: String(action.dropFirst("text:".count))),
                "\(message) produced an action ghostty would drop silently: \(action)")
        }
    }

    /// Mirrors `config/string.zig`: walk the value and check that every `\` opens
    /// an escape this build ever emits.
    private func everyBackslashOpensAValidEscape(in value: String) -> Bool {
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\" else {
                index += 1
                continue
            }
            guard index + 1 < characters.count else { return false }
            switch characters[index + 1] {
            case "\\", "n", "r": index += 2
            default: return false
            }
        }
        return true
    }
}
