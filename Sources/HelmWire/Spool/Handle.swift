import Foundation

// MARK: - Handle

/// A mailbox address — read off an owner record, or validated when a caller names one by hand.
///
/// **Why this exists: `MailboxOwner`'s own argument, made unbypassable.** A handle looks
/// derivable — `<cwd basename>-<last 4 of the session id>` — and that is the trap: `deriveHandle`
/// (`hooks/helm-mail.mjs`) widens the suffix 4 → 6 → 8 → full when a live process already holds
/// the shorter form, so a *computed* handle is silently wrong whenever the derivation widened,
/// and the caller cannot see that it did. `MailboxOwner`'s own header has the twenty-line
/// version. A newtype cannot forbid derivation — the deriving code is JavaScript
/// (`hooks/helm-mail.mjs`), outside this process entirely — but it can close the *accidental*
/// path inside Swift: there is no `init(_ String)`, so the only ways to end up holding a
/// `Handle` are —
///
/// - `readingFrom:`, which pulls one out of a `MailboxOwner` — a value that, in this codebase,
///   is only ever produced by `MailboxDirectory.owners(in:)` decoding an `owner.json` off disk.
///   This is the blessed path, and the one every production call site uses
///   (`SpoolModel.act(on: AcceptedSpawnRequest)`, on a `ready` result).
/// - `validating:`, for the one legitimate case where a caller *names* a recipient rather than
///   reading one that already claimed a mailbox — a real case (`helm-mail-cc` sends by handle),
///   even though that particular caller is JavaScript and out of this type's reach today.
///
/// Deriving one by concatenation now means going through `validating:`, which is greppable —
/// modest, honest, and it is what makes the argument in `MailboxOwner`'s header enforceable
/// rather than hortatory.
///
/// **`MailboxOwner.handle` itself stays a bare `String`, deliberately.** `Handle(readingFrom:)`
/// only means something if there is a raw field to read *from* — wrapping it at the decode site
/// too would make the two indistinguishable and the blessed path pointless. Decoding
/// `owner.json` already *is* the reading act this type exists to require.
///
/// Encodes as a bare string through a single-value container, exactly like `WorkspacePath` —
/// `SpoolResult.handle` is read by three standalone scripts as `json["handle"] as? String`, and
/// that shape must not change.
package struct Handle: Codable, Equatable, Hashable, Sendable {
    package let value: String

    /// The blessed path: a handle already read out of an owner record.
    package init(readingFrom owner: MailboxOwner) {
        self.value = owner.handle
    }

    /// A caller naming a recipient by hand rather than reading one off an owner record. `nil`
    /// on anything that is not plausibly an address, so a typo is a caller-visible `nil` rather
    /// than a `Handle` that silently addresses nobody.
    package init?(validating candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    /// Decoding is a route in like any other route in this codebase's newtypes, and here it is
    /// the *same* blessed path spelled differently: `SpoolResult.handle` is only ever written
    /// by `SpoolModel` from a `Handle(readingFrom:)`, so decoding it back is reading what was
    /// already read, not deriving anything new. No extra validation here for the same reason
    /// `WorkspacePath`'s decode has none beyond its own normalization: there is nothing to
    /// normalize, and rejecting an already-written value would only turn a helm-authored file
    /// into an unreadable one.
    package init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(String.self)
    }

    /// A single-value container, so the wire shape is a bare string — byte-identical to the
    /// `String` this type replaces. Three standalone scripts (`helm-spool.swift`,
    /// `helm-close.swift`, `helm-capture.swift`) read `SpoolResult.handle` as
    /// `json["handle"] as? String` and cannot `import HelmWire` to do anything smarter — see
    /// `AGENTS.md`'s "Why the spool is a script, and must stay one".
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
