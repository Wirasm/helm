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
/// path inside Swift: there is no `init(_ String)`, so the three ways to end up holding a
/// `Handle` are —
///
/// - `readingFrom:`, which pulls one out of a `MailboxOwner`. Every production call site
///   (`SpoolModel.act(on: AcceptedSpawnRequest)`, on a `ready` result) reaches this with a
///   `MailboxOwner` that came from `MailboxDirectory.owners(in:)` decoding an `owner.json` off
///   disk. Non-failable because **both routes into a `MailboxOwner` refuse a handle this type
///   would refuse** (#233): `MailboxOwner.init(from:)` calls `validating:` and throws on `nil`,
///   and the `package`-visible memberwise initializer — the fixture constructor test code uses
///   across the module boundary — takes an already-validated `Handle` rather than a raw `String`.
/// - `validating:`, for the one legitimate case where a caller *names* a recipient rather than
///   reading one that already claimed a mailbox — a real case (`helm-mail-cc` sends by handle),
///   even though that particular caller is JavaScript and out of this type's reach today.
/// - `init(from:)`, reading one back off disk, which routes through `validating:` as well.
///
/// Deriving one by concatenation now means going through `validating:`, which is greppable —
/// modest, honest, and it is what makes the argument in `MailboxOwner`'s header enforceable
/// rather than hortatory.
///
/// **One rule, expressed once, and that is the whole point.** #231 fixed a disagreement between
/// these routes by *copying* `validating:`'s trim-and-reject into `MailboxOwner.init(from:)`
/// (see `9863944`), which left two hand-maintained spellings of one rule and a comment asking
/// them to match. That is the shape #233 exists to remove, one size smaller, so they are a call
/// now rather than a copy: tightening `validating:` tightens every route at once.
///
/// **That cuts both ways, and it is the cost to weigh before adding a rule.** A stricter
/// `validating:` also starts *rejecting already-written files*, so anything added there has to
/// be something nothing helm ever wrote could fail. Trimming and non-emptiness qualify: both
/// `owner.json` writers run every component of a handle through a `slug` that lowercases,
/// collapses `[^a-z0-9]+` and falls back to `"agent"` (`hooks/helm-mail.mjs:66`,
/// `pi/extensions/helm-mail/index.ts:178`), so neither can emit one. A character rule would not
/// obviously qualify — see `validating:`'s own note for why it is deferred rather than added.
///
/// **`MailboxOwner.handle` itself stays a bare `String`, deliberately.** `Handle(readingFrom:)`
/// only means something if there is a raw field to read *from* — wrapping it at the decode site
/// too would make the two indistinguishable and the blessed path pointless. Decoding
/// `owner.json` already *is* the reading act this type exists to require, and — since #229's
/// review — the act that validates.
///
/// Encodes as a bare string through a single-value container, exactly like `WorkspacePath`, and
/// that shape must not change. **No script parses `handle` itself**, so the obligation is not
/// the `json["handle"] as? String` this comment used to claim: `helm-spool.swift` prints the
/// whole result blob on stdout (`tools/helm-spool.swift:186`) and the agent that invoked it
/// reads the field. `SpoolWireConformanceTests
/// .testHelmSpoolPrintsHandleAndTerminalIdAsBareStringsOnceReady` is what holds it, against the
/// real script as a subprocess.
package struct Handle: Codable, Equatable, Hashable, Sendable {
    package let value: String

    /// The blessed path: a handle read out of an owner record. Non-failable because **neither**
    /// route into a `MailboxOwner` can carry a handle `validating:` would refuse — decoding calls
    /// it, and the memberwise initializer takes a `Handle` that already came through it. See this
    /// type's header for the rule and for what tightening it would cost.
    package init(readingFrom owner: MailboxOwner) {
        self.value = owner.handle
    }

    /// A caller naming a recipient by hand rather than reading one off an owner record, and —
    /// since #233 — the single expression of "is this plausibly an address" that the other two
    /// routes call rather than restate.
    ///
    /// **It enforces exactly two things: trimmed, and not empty.** It is deliberately *not* a
    /// typo catcher, and the claim that it was is what this comment used to overreach on.
    /// `"Alice"`, `"my agent"` and `"owner_1234"` all pass here and all name a directory that
    /// does not exist, because both writers of the scheme slug harder than this does — and
    /// `Alice` vs `alice` is not hypothetical: the macOS default filesystem is case-insensitive,
    /// so those are two agents to a sender and one directory to the disk, which
    /// `pi/extensions/helm-mail/index.ts:178` documents as having already cost someone their
    /// mail. Applying that character rule here is a **behaviour** change, not a doc fix: every
    /// route now shares this rule, so it would also start rejecting already-written files. It
    /// wants its own issue, with the `helm-mail-cc` case in scope. Until then this promises only
    /// what it checks.
    package init?(validating candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    /// `SpoolResult.handle` and `BenchSnapshot.OwnerRecord.handle` are only ever written by helm
    /// from a `Handle` that came through `validating:`, so a value that fails it here means the
    /// file was hand-edited or came from somewhere else entirely — worth a decode error rather
    /// than a silently unaddressable field. **This is the rule its sibling already had**:
    /// `TerminalID.init(from:)` throws on a non-uuid from the identical premise, and this route
    /// reached the opposite conclusion from the same sentence until #233.
    ///
    /// **Nothing production reads is made unreadable by the throw, which is what earned it.**
    /// Both decode sites are `try?` — `SpoolDirectory.result(id:)` and
    /// `BenchSnapshotDirectory.read()` — so a rejection is a soft `nil`, never a crash and never
    /// a hang. `read()` has no caller in `Sources/` at all; `result(id:)` has exactly one,
    /// `abandoned()`, where an unreadable result already means "not answered yet" and helm
    /// replies with an `abandoned` result naming the reason. So a corrupted result becomes a
    /// documented answer instead of a handle addressing nobody, and the waiting script — which
    /// parses the printed blob itself and never imports this module — cannot be hung by it.
    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let handle = Handle(validating: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(raw)\" is not a handle")
        }
        self = handle
    }

    /// A single-value container, so the wire shape is a bare string — byte-identical to the
    /// `String` this type replaces, and read outside this process by an agent rather than by a
    /// `json["handle"]` in any script. See the type's header for what actually holds that shape.
    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
