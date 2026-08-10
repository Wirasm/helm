import Foundation

// MARK: - RequestID

/// A spool request's own name, everywhere that name becomes a path.
///
/// **The invariant this replaces was a comment and a regex applied at one edge (#260).** An id is
/// a filename component — `results/<id>.json`, `prompts/<id>.txt` — and `SpoolPolicy`'s own note
/// said so: *"`..` and `/` are the whole reason: an ungated id writes wherever the caller likes."*
/// The value it governed was a bare `String` in seven declarations with open initializers, so
/// every site that needed the guarantee had to remember to ask for it, and four of six did not.
/// That is the defect `SpoolWork`'s header says its shape exists to prevent — *"so that 'has this
/// been checked?' is answered by the compiler at every call site instead of by reading upwards"* —
/// and `id` was the field in those structs still answered by reading upwards.
///
/// **The cost was reachable in two launches, with no crash involved.** A request with a hostile id
/// is claimed by rename; `SpoolPolicy.accept` refuses it and `SpoolModel.refuse` writes nothing,
/// because there is nowhere to write it; the file stays in `claimed/`. On the next launch
/// `SpoolDirectory.abandoned()` reads that id straight back out of the claimed JSON — which
/// `SpoolRequest`'s decode never pattern-checks — and `answerAbandoned` hands it to a path
/// builder. `appendingPathComponent` does not collapse `..`, measured:
/// `results/../../../../tmp/pwned.json` is a real write to `/tmp/pwned.json`.
/// `SpoolModelTests.testAClaimedRequestWithATraversalIdWritesNothingOutsideTheSpool` is that
/// route, and it failed on `development` before this type existed.
///
/// **So the fix is not a third place to remember — it is making the unchecked value
/// unrepresentable at the path builder.** `SpoolDirectory`'s three builders (`write`,
/// `result(id:)`, `stagePrompt`) take this type, and `abandoned()` returns it, so there is no
/// longer a `String` overload to reach them by.
///
/// **The request types keep their bare `String`, deliberately, and that is not the same
/// omission.** `SpoolRequest`'s rule is that a request is *decoded permissively in shape and
/// judged strictly afterwards*: a malformed id in a request file has to become a `refused` result
/// naming the reason, not a decode failure `SpoolModel` can only describe as unreadable JSON under
/// the wrong id. This is `CloseRequest.terminal`'s carve-out and `TerminalID`'s relationship to
/// it, one field over — `SpoolPolicy.accept` is the single site that turns the raw string into a
/// `RequestID`, exactly where it already applied the regex. The type changed; where the validation
/// happens did not.
///
/// **`SpoolResult.id` does become this type, and that asymmetry is the point.** A result is
/// *written* by helm rather than read from a caller, so there is no refusal to produce and nothing
/// to be permissive about — the only way to hold one is to have been through `validating:`. That
/// is what closes `write`'s path builder, which was the live defect.
package struct RequestID: Codable, Equatable, Hashable, Sendable {
    package let value: String

    /// An id is a filename component, so it is gated as one: an alphanumeric first character,
    /// then up to 63 more from a set with no `/` and no way to spell `..`.
    ///
    /// **It lives here rather than on `SpoolPolicy` because it is this type's own invariant**, and
    /// there is still exactly one spelling of it — `SpoolPolicy.accept` and `SpoolModel.refuse`
    /// both reach the rule by *constructing* a `RequestID` now, rather than by each applying a
    /// shared pattern by hand. The refusal message quotes it so a caller is told the rule rather
    /// than only that it broke one.
    package static let pattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

    /// The only unrestricted route in, and the reason the type is worth having. `nil` on anything
    /// that is not a filename — which is the judgement `SpoolPolicy.accept` already made, now made
    /// in the one place that can also be reached from everywhere else that needs it.
    ///
    /// **Not trimmed, unlike `Handle.init(validating:)`.** A surrounding space is not a typo helm
    /// should silently forgive here: the caller waits on `results/<id>.json` spelled exactly as it
    /// wrote it, so accepting `" r"` as `"r"` would answer a file nobody is watching. The pattern
    /// refuses it and the refusal says why.
    package init?(validating candidate: String) {
        guard candidate.range(of: Self.pattern, options: .regularExpression) != nil else {
            return nil
        }
        self.value = candidate
    }

    /// `SpoolResult.id` is only ever written by helm from a `RequestID` that came through
    /// `validating:`, so a value that fails it here means the file was hand-edited or came from
    /// somewhere else entirely — worth a decode error rather than a silently unusable field. The
    /// rule `TerminalID` and `Handle` both already had, from the identical premise.
    ///
    /// **Nothing production reads is made unreadable by the throw, which is what earns it.** The
    /// one decode site is `SpoolDirectory.result(id:)`, which is `try?` — and its only caller is
    /// `abandoned()`, where an unreadable result already means "not answered yet" and helm replies
    /// with an `abandoned` result naming the reason. So a corrupted result becomes a documented
    /// answer rather than a crash or a hang, and the waiting script — which parses the printed
    /// blob itself and never imports this module — cannot be stuck by it.
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let id = RequestID(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(raw)\" is not a request id")
        }
        self = id
    }

    /// A single-value container, so the wire shape is a bare string — byte-identical to the
    /// `String` this type replaces. That matters more here than for its siblings: every one of the
    /// six spool scripts writes an `id` into a request by hand and reads `results/<id>.json` back,
    /// none of them can import this module, and `SpoolWireConformanceTests` is what holds the two
    /// halves together.
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
