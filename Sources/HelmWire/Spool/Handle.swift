import Foundation

/// A mailbox address on the bench: `helm-a1b2`, `operator`.
///
/// benchd mints every handle (`bench_wire::hook::derive_handle`) and helm only ever reads one
/// back — from benchd's `mail/who` answer, or from a spool result it wrote itself. So there is
/// no way to build one from a cwd and a session id here: a derived handle is silently wrong
/// whenever benchd widened it to dodge a holder (#233, #262).
///
/// Encodes as a bare string, exactly like `WorkspacePath`, and that shape must not change:
/// `helm-spool.swift` prints the whole result blob and the agent that invoked it reads `handle`
/// (`SpoolWireConformanceTests.testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady`).
package struct Handle: Codable, Equatable, Hashable, Sendable {
    package let value: String

    /// Trimmed, not empty, and only `[a-z0-9-]`: the alphabet benchd's `validate_handle`
    /// allows. A handle outside it names no mailbox directory, so it is refused rather than
    /// carried to a send that could only fail.
    package init?(validating candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(Self.addressableCharacters.contains) else {
            return nil
        }
        self.value = trimmed
    }

    private static let addressableCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    /// A value that fails `validating:` means the file was hand-edited or came from somewhere
    /// else: a decode error rather than a silently unaddressable field.
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let handle = Handle(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(raw)\" is not a handle")
        }
        self = handle
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
