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

    // MARK: - The message action

    /// The message action carries the text and NOTHING else. A carriage return on
    /// the end of it is #119: one chunk of stdin, which the agent's TUI classifies
    /// as a paste and inserts verbatim, newline and all.
    func testTheMessageActionCarriesTheTextWithoutAReturn() {
        XCTAssertEqual(PtyText.messageAction(for: "hello"), "text:hello")
    }

    func testTheMessageActionTrimsSurroundingWhitespace() {
        XCTAssertEqual(PtyText.messageAction(for: "  hello  \n"), "text:hello")
    }

    func testEmptyMessageProducesNoAction() {
        XCTAssertNil(PtyText.messageAction(for: ""))
        XCTAssertNil(PtyText.messageAction(for: "   \n  "))
    }

    /// The whole point, end to end: nothing an operator can type produces an
    /// action containing an escape sequence ghostty would reject.
    func testNoTypedMessageCanProduceAnInvalidEscape() {
        let hostile = [
            #"\"#, #"\x"#, #"\u"#, #"\u{"#, #"trailing backslash \"#,
            #"\\\"#, "\u{1B}[31m", #"{"json": "value"}"#,
        ]
        for message in hostile {
            guard let action = PtyText.messageAction(for: message) else { continue }
            XCTAssertTrue(action.hasPrefix("text:"))
            XCTAssertTrue(
                everyBackslashOpensAValidEscape(in: String(action.dropFirst("text:".count))),
                "\(message) produced an action ghostty would drop silently: \(action)")
        }
    }

    // MARK: - What the pty actually receives

    /// **The gap the old tests left.** They asserted the string `submitAction`
    /// returned, which looked right; nothing asserted what reached the pty. These
    /// drive the send path against a recorder, and every one of them fails against
    /// the single-action version — which is the point of writing them this way.

    @MainActor
    func testSubmittingWritesTheMessageAndThenTheReturn() async {
        let pty = RecordingPty()
        let sent = await PtyText.submit("hello", to: pty, gap: .milliseconds(5))
        XCTAssertTrue(sent)
        XCTAssertEqual(pty.actions, ["text:hello", #"text:\r"#])
    }

    /// The first write must not carry a return in any form — a raw CR byte, or the
    /// `\r` escape ghostty turns into one. Either is the bug.
    @MainActor
    func testTheMessageWriteCarriesNoReturnAtAll() async {
        let pty = RecordingPty()
        await PtyText.submit("a fairly long message, past any paste threshold", to: pty, gap: .zero)
        XCTAssertEqual(pty.actions.count, 2, "the return must be its own write")
        let message = pty.actions.first ?? ""
        XCTAssertFalse(message.contains("\r"), "a raw CR rides in the same chunk")
        XCTAssertFalse(message.contains(#"\r"#), "ghostty would turn this into one")
    }

    /// Two writes are necessary and not sufficient: back-to-back they land in one
    /// `read()` on the agent's side and are one chunk again. Measured — see
    /// `PtyText.submitGap`.
    @MainActor
    func testTheReturnWaitsBehindTheMessage() async {
        let pty = RecordingPty()
        let gap = Duration.milliseconds(30)
        await PtyText.submit("hello", to: pty, gap: gap)
        XCTAssertEqual(pty.actions.count, 2)
        XCTAssertGreaterThanOrEqual(
            pty.interval ?? .zero, gap,
            "the return arrived in the same breath as the message")
    }

    /// A production gap of zero would be the bug with extra steps.
    func testTheShippedGapIsNotZero() {
        XCTAssertGreaterThan(PtyText.submitGap, .zero)
    }

    /// A multi-line draft is still ONE message and one Return — not a write per
    /// line, which would arrive as several prompts.
    @MainActor
    func testAMultiLineDraftIsStillOneMessage() async {
        let pty = RecordingPty()
        await PtyText.submit("first line\nsecond line", to: pty, gap: .zero)
        XCTAssertEqual(pty.actions, [#"text:first line\nsecond line"#, #"text:\r"#])
    }

    /// An empty draft writes nothing — not even a bare Return, which would submit
    /// whatever the operator had left in the agent's own box.
    @MainActor
    func testAnEmptyDraftWritesNothing() async {
        let pty = RecordingPty()
        let sent = await PtyText.submit("   \n ", to: pty, gap: .zero)
        XCTAssertFalse(sent)
        XCTAssertEqual(pty.actions, [])
    }

    /// A surface that refuses the message is not followed by a Return. Sending one
    /// anyway would submit whatever the operator had typed in the terminal itself.
    @MainActor
    func testARefusedMessageIsNotFollowedByAReturn() async {
        let pty = RecordingPty(accepts: false)
        let sent = await PtyText.submit("hello", to: pty, gap: .zero)
        XCTAssertFalse(sent)
        XCTAssertEqual(pty.actions, ["text:hello"])
    }

    /// A pty that keeps what it was told, and when.
    @MainActor
    private final class RecordingPty: PtyWriting {
        /// Whether ghostty accepts the action. `false` is the surface that has gone away.
        private let accepts: Bool
        private(set) var actions: [String] = []
        private var instants: [ContinuousClock.Instant] = []

        init(accepts: Bool = true) { self.accepts = accepts }

        /// How long the second write waited behind the first.
        var interval: Duration? {
            guard instants.count >= 2 else { return nil }
            return instants[0].duration(to: instants[1])
        }

        func performBindingAction(_ action: String) -> Bool {
            actions.append(action)
            instants.append(.now)
            return accepts
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
