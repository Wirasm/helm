import Foundation

// MARK: - TerminalID

/// A terminal pane's identity, everywhere the spool carries one.
///
/// **The round trip this replaces.** `TerminalSession.id` is a real `UUID` in the app; crossing
/// the spool it became `.uuidString` in `SpoolResult.terminalId`, a bare `String` in
/// `CloseRequest.terminal`, and `UUID(uuidString:)` again in `AcceptedCloseRequest` — a parse a
/// caller could forget to check, answered with a silent `nil` rather than a compile error.
/// `TerminalID` wraps `UUID`, does that parsing exactly once, here, so a malformed id is
/// unrepresentable in the *accepted* shape rather than a `nil` three calls downstream.
///
/// **`CloseRequest.terminal` itself stays a bare `String`, deliberately.** `SpoolRequest`'s own
/// header explains why a request is "decoded permissively in shape and judged strictly
/// afterwards": a malformed uuid in a request file must become a `refused` result naming the
/// reason ("… is not a pane id"), not a decode failure `SpoolModel` can only describe as
/// unreadable JSON under the wrong id. `SpoolPolicy.accept` is what turns a request's raw string
/// into a `TerminalID` — exactly the site that used to turn one into a `UUID`. The type changed;
/// where the validation happens did not.
///
/// Encodes as a bare string through a single-value container, exactly like `WorkspacePath`, and
/// that shape must not change. **No script parses `terminalId` itself**, so the obligation is not
/// the `json["terminalId"] as? String` this comment used to claim (#240): every spool script
/// prints the whole result blob verbatim on stdout and then reads only what it needs to choose an
/// exit code and a one-line summary — `status`, `reason`, and at most its own kind's report
/// object. The agent that invoked the script reads this field out of that printed JSON.
/// **Which scripts those are is `AGENTS.md`'s list, and deliberately not restated here**: this
/// comment said "all three" with three line numbers beside it, and stayed at three through
/// `helm-command`, `helm-select` and `helm-name`. `SpoolWireConformanceTests`
/// `.testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady` and
/// `.testHelmClosePrintsTerminalIdAsABareStringOnceClosed` are what hold it, against the real
/// scripts as subprocesses. (`BenchSnapshot.OwnerRecord.handle` is a `Handle` since #233, not the
/// unrelated bare `String` this note used to describe — a sibling newtype with the same wire
/// obligation, still not this type's business.)
package struct TerminalID: Codable, Equatable, Hashable, Sendable {
    package let uuid: UUID

    /// The app already has a real `UUID` — `TerminalSession.id` — so wrapping it costs nothing
    /// and loses no information, unlike `Handle`'s newtype, which exists precisely because there
    /// is no safe *unrestricted* constructor for an address.
    package init(_ uuid: UUID) {
        self.uuid = uuid
    }

    /// A caller-supplied string: a request file's `terminal` field, or a script's command-line
    /// argument. `nil` on anything that is not a uuid — the same judgement `UUID(uuidString:)`
    /// made, just made in exactly one place instead of at every call site that used to repeat
    /// `UUID(uuidString: …)` by hand.
    package init?(validating candidate: String) {
        guard
            let uuid = UUID(
                uuidString: candidate.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        self.uuid = uuid
    }

    /// `SpoolResult.terminalId` is only ever written by `SpoolModel` from a real `TerminalID`,
    /// so a value that fails to parse back here means the file was hand-edited or came from
    /// somewhere else entirely — worth a decode error rather than a silently `nil` field.
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(raw)\" is not a uuid")
        }
        self.uuid = uuid
    }

    /// A single-value container, so the wire shape is a bare string — byte-identical to the
    /// `String` this type replaces, and read outside this process by an agent rather than by a
    /// `json["terminalId"]` in any script. See the type's header for what actually holds that
    /// shape.
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString)
    }

    /// The same spelling every refusal message, `HELM_PANE` and `TerminalSession.id` already
    /// use.
    package var uuidString: String { uuid.uuidString }
}
