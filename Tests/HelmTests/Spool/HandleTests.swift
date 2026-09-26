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
/// So the point of this file is the rule, not the type: `Handle.init(from:)` *calls*
/// `validating:` rather than restating it, and `testEveryRouteRefusesTheSameMalformedHandle` is
/// what would notice if it stopped. (`MailboxOwner`, the third route, left with helm's mailroom.)
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
    /// the address scheme slug harder than the old rule did — `slug` in `hooks/helm-mail.mjs` and
    /// in `pi/extensions/helm-mail/index.ts` lowercases and collapses `[^a-z0-9]+` to `-`. Since
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
    /// to the disk; the doc comment on `slug` in `pi/extensions/helm-mail/index.ts` records that
    /// as having already lost someone their mail. The refusal is what closes it — and the second
    /// half of this test is
    /// the part that matters, because a rule that lowercased instead would also make the first
    /// half pass while quietly handing `Alice`'s mail to a different real agent.
    func testValidatingRefusesUppercaseRatherThanFoldingItOntoAnotherAgent() throws {
        XCTAssertNil(Handle(validating: "Alice"), "Alice cannot name a directory the writers make")
        XCTAssertEqual(
            Handle(validating: "alice")?.value, "alice", "and the lowercase one is still fine")
        XCTAssertNotEqual(
            Handle(validating: "Alice")?.value, "alice",
            "refused, never normalised — silently answering with a different agent's address is "
                + "the failure a derived address would be")
    }

    /// **The control that stops the rule overshooting.** Every candidate must survive: refusing
    /// one would make helm unable to address an agent benchd named.
    ///
    /// **These are real outputs of benchd's `derive_handle`, obtained by running it** (a
    /// throwaway `#[test]` printing them, 2026-09-26), not transcribed from reading it: the
    /// last corpus here was first transcribed and got `tail` wrong. Re-run it rather than
    /// re-read it if this list needs another entry.
    func testEveryHandleBenchdCanEmitIsStillAccepted() throws {
        let corpus = [
            "helm-4831",  // /Users/op/Projects/helm, session …-dd8f-4831
            "agentic-coding-cour-c9db",  // the place is cut to 19 bytes
            "agent-1234",  // a cwd of "/" has no basename
            "agent-s-2",  // cwd "/x/---", session "---": nothing survives slug, numbered fallback
            "helm-7c8d9e0fa1b2",  // the 4-, 6- and 8-byte tails held: the 12-byte one
            "a-very-long-project-7c8d9e0fa1b2",  // the longest shape: 19 + 1 + 12, exactly 32
            "0-678",  // a basename that is only digits
        ]
        for candidate in corpus {
            XCTAssertEqual(
                Handle(validating: candidate)?.value, candidate,
                "\(candidate.debugDescription) is a handle benchd can mint; refusing it would "
                    + "make helm unable to address the agent it names")
        }
    }

    /// **benchd's `validate_handle`, clause for clause.** benchd is the one writer since #358,
    /// and its rule lives in this repo (`bench_wire::validate_handle`), so helm refuses exactly
    /// what benchd would: at most 32 bytes, a letter or digit first, dashes anywhere after. The
    /// looser rule this replaced was chosen when two writers outside the repo had to be trusted.
    func testTheRuleIsBenchdsValidateHandle() throws {
        for accepted in ["helm-", "helm--678", String(repeating: "a", count: 32)] {
            XCTAssertNotNil(
                Handle(validating: accepted), "benchd accepts \(accepted.debugDescription)")
        }
        for refused in ["-helm", String(repeating: "a", count: 33)] {
            XCTAssertNil(Handle(validating: refused), "benchd refuses \(refused.debugDescription)")
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

    /// The throw path. A handle on the wire — `SpoolResult.handle`, or benchd's `mail/who`
    /// reply — that fails here was hand-edited or came from somewhere else, and is worth a decode
    /// error rather than a field that silently addresses nobody.
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

    /// **The test the copied rule never had.** Before #233 the trim-and-reject lived twice, with
    /// a comment between the copies asking them to match. Now every route calls one rule, and
    /// this is what notices if a second spelling appears: the same malformed input, refused
    /// through the caller-named route and the `Handle` decode route alike.
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
    /// it is the one that reads another process's answer.
    func testEveryRouteRefusesTheSameUnaddressableHandle() throws {
        for candidate in ["Alice", "my agent", "owner_1234", "helm_4831", "héllo", "UPPER"] {
            XCTAssertNil(
                Handle(validating: candidate),
                "the caller-named route must refuse \(candidate.debugDescription)")

            XCTAssertThrowsError(
                try JSONDecoder().decode(Handle.self, from: Data("\"\(candidate)\"".utf8)),
                "the Handle decode route must refuse \(candidate.debugDescription)")
        }
    }

    /// The agreement in the other direction: what one route accepts, the others accept, with the
    /// same trimming applied. A rule that only ever refuses is satisfied by refusing everything.
    func testEveryRouteAcceptsTheSameWellFormedHandleAndTrimsItIdentically() throws {
        XCTAssertEqual(Handle(validating: "  helm-4831 ")?.value, "helm-4831")
        XCTAssertEqual(
            try JSONDecoder().decode(Handle.self, from: Data(#""  helm-4831 ""#.utf8)).value,
            "helm-4831")
    }
}
