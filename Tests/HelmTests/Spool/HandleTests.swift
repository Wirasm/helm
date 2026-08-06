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

    /// **The record of #239, and it used to say the opposite.** These same three candidates were
    /// asserted *accepted* here — the test was the deliberate record of the gap, kept so whoever
    /// closed it would see exactly which inputs change meaning. They are the inputs that changed.
    ///
    /// Every one names a directory that does not exist and never will, because both writers of
    /// the address scheme slug harder than the old rule did (`hooks/helm-mail.mjs:66`,
    /// `pi/extensions/helm-mail/index.ts:178` — lowercase, collapse `[^a-z0-9]+` to `-`). Since
    /// #239 `validating:` enforces that alphabet, and every route shares the rule, so this is a
    /// behaviour change on all three of them. `Handle`'s header carries the decision and the two
    /// options it turned down.
    func testValidatingEnforcesTheWritersCharacterRuleSoAHandleCanNameADirectory() throws {
        for candidate in ["Alice", "my agent", "owner_1234"] {
            XCTAssertNil(
                Handle(validating: candidate),
                "\(candidate.debugDescription) cannot name a mailbox directory — both owner.json "
                    + "writers would have slugged it — so it must not become a Handle")
        }
    }

    /// **The case collision, which is the one with a reported cost.** The macOS default
    /// filesystem folds case, so `Alice` and `alice` are two agents to a sender and one directory
    /// to the disk; `pi/extensions/helm-mail/index.ts:178` documents that as having already lost
    /// someone their mail. The refusal is what closes it — and the second half of this test is
    /// the part that matters, because a rule that lowercased instead would also make the first
    /// half pass while quietly handing `Alice`'s mail to a different real agent.
    func testValidatingRefusesUppercaseRatherThanFoldingItOntoAnotherAgent() throws {
        XCTAssertNil(Handle(validating: "Alice"), "Alice cannot name a directory the writers make")
        XCTAssertEqual(
            Handle(validating: "alice")?.value, "alice", "and the lowercase one is still fine")
        XCTAssertNotEqual(
            Handle(validating: "Alice")?.value, "alice",
            "refused, never normalised — silently answering with a different agent's address is "
                + "the failure MailboxDirectory's header forbids for derivation")
    }

    /// **The control that stops the rule overshooting.** Every candidate must survive: refusing
    /// one would make helm unable to read a mailbox it created.
    ///
    /// **These are real outputs, obtained by running the real code.** `slug`, `tail` and
    /// `deriveHandle` were extracted from `hooks/helm-mail.mjs` by brace-matching the file text
    /// and executed — not transcribed from reading them. The first draft of this test did
    /// transcribe them, got `tail` wrong (it strips edge dashes; the draft assumed it did not),
    /// and pinned `helm--678` here as a reachable handle. It is not reachable — the real answer
    /// is `helm-678` — and `Handle`'s header now says so. Re-derive rather than re-read if this
    /// list ever needs another entry.
    func testEveryHandleTheWritersCanEmitIsStillAccepted() throws {
        let corpus = [
            "helm-4831",  // the ordinary shape: <cwd basename>-<tail of session id>
            "agentic-coding-course-c9db",  // a multi-word basename, slugged
            "agent",  // slug's own fallback when a component reduces to nothing
            "helm-678",  // deriveHandle("/x/helm", "12345-678") — the case the draft got wrong
            "agent-gent",  // deriveHandle("/x/---", "---") — both components hit the fallback
            "a-b",  // deriveHandle("/x/a", "-b-") — tail strips the dashes off its slice
            "helm-f9e4639d-1111-2222-3333-444455556666",  // the full-session-id fallback
            "0",  // a basename that is only digits
        ]
        for candidate in corpus {
            XCTAssertEqual(
                Handle(validating: candidate)?.value, candidate,
                "\(candidate.debugDescription) is a handle deriveHandle can produce; refusing it "
                    + "would make helm unable to read a mailbox it created")
        }
    }

    /// **The margin, recorded so it reads as a choice rather than an oversight.** The writers can
    /// only emit `[a-z0-9]+(-[a-z0-9]+)*` — no edge dash, no `--`, measured over 200,000 fuzzed
    /// derivations of the real `deriveHandle`, none outside it. This rule is looser than that on
    /// purpose: it refuses characters and says nothing about where dashes fall, so it depends on
    /// one property of the far side instead of three. `Handle`'s header has the argument, and
    /// the reason it matters — nothing runs the real writers against this rule, so the boundary
    /// is unwatched and the cheaper dependency is the safer one.
    ///
    /// If a later change *does* constrain dash placement, this test is what should be deleted to
    /// say so — deliberately, with the header updated in the same commit.
    func testTheRuleIsLooserThanWhatTheWritersEmitAndThatIsDeliberate() throws {
        for candidate in ["helm--678", "-helm", "helm-"] {
            XCTAssertNotNil(
                Handle(validating: candidate),
                "\(candidate.debugDescription) is accepted on purpose: no writer emits it, but "
                    + "refusing it would couple this rule to how deriveHandle composes tail(), "
                    + "not just to the characters slug() emits")
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

    /// **The same agreement for #239's half of the rule.** Kept separate from the
    /// whitespace test above rather than folded into its candidate list, because the two refusals
    /// have different reasons and a single list would stop saying which: those candidates address
    /// nobody because they are *blank*, these because they are outside the alphabet the writers
    /// emit. If decode ever stopped calling `validating:`, the third assertion here is what
    /// notices — and that is the route whose stricter behaviour is the actual cost of #239, since
    /// it is the one that reads files off disk.
    func testEveryRouteRefusesTheSameUnaddressableHandle() throws {
        for candidate in ["Alice", "my agent", "owner_1234", "helm_4831", "héllo", "UPPER"] {
            XCTAssertNil(
                Handle(validating: candidate),
                "the caller-named route must refuse \(candidate.debugDescription)")

            let owner = Data(
                #"{"handle":"\#(candidate)","runtime":"claude","pid":4242,"cwd":"/tmp"}"#.utf8)
            XCTAssertThrowsError(
                try JSONDecoder().decode(MailboxOwner.self, from: owner),
                "the owner.json route must refuse \(candidate.debugDescription)")

            XCTAssertThrowsError(
                try JSONDecoder().decode(Handle.self, from: Data("\"\(candidate)\"".utf8)),
                "the Handle decode route must refuse \(candidate.debugDescription)")
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
