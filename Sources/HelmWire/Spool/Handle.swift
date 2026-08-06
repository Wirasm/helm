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
/// **That cuts both ways, and #239 is where the bill came due.** A stricter `validating:` also
/// starts *rejecting already-written files*, so anything added there has to be something nothing
/// helm ever wrote could fail. Trimming and non-emptiness always qualified. Since #239 a
/// character rule does too, and it is enforced on every route: **`[a-z0-9-]`, and nothing about
/// where the dashes fall.**
///
/// **Why that alphabet, and why the rule is deliberately looser than it could be.** Both
/// `owner.json` writers — `hooks/helm-mail.mjs` and `pi/extensions/helm-mail/index.ts` — run
/// every component of a handle through a `slug` that lowercases, collapses `[^a-z0-9]+` to `-`,
/// strips edge dashes and falls back to `"agent"`; `tail` strips edge dashes off its slice again;
/// and `deriveHandle` joins the components with a single `-`. So the shape they can actually emit
/// is *narrower* than this rule — `[a-z0-9]+(-[a-z0-9]+)*`, no leading or trailing dash and no
/// `--`.
///
/// **Those are function names and not line numbers, deliberately.** The first draft of this
/// paragraph cited `hooks/helm-mail.mjs:66` and `pi/extensions/helm-mail/index.ts:184`, and
/// offered *"compare against their `slug` by eye"* as the standing substitute for the conformance
/// test named below. #236 then merged underneath this branch and moved pi's `slug` thirteen lines
/// down; the citation landed inside `mailRoot()`, which has nothing to do with the alphabet. The
/// substitute rotted inside this PR's own lifetime, from a commit about something else entirely.
/// A function name survives an edit above it. A line number into another runtime is a claim
/// nothing in either gate re-checks.
///
/// **Measured across both writers, by executing them.** `slug`, `tail`, `heldByAnother` and
/// `deriveHandle` were lifted verbatim out of each file by brace-matching the source text and
/// run — never transcribed, which is the mistake recorded three paragraphs down. 225,702
/// derivations of the hooks pair and 238,202 of pi's, over junk cwd basenames and session ids
/// (uppercase, punctuation, combining marks, emoji, empty), including the pinned-handle route,
/// and driven through the whole 4 → 6 → 8 → full widening to the exhaustion fallback 12,500
/// times each by claiming every answer with a live foreign pid. **Nothing either writer emitted
/// fell outside `[a-z0-9-]`, and nothing fell outside the stricter `[a-z0-9]+(-[a-z0-9]+)*`
/// either.** The harness is not vacuous: widening `slug`'s own class to `[^a-zA-Z0-9_]+` makes
/// both writers produce handles it reports. The eight `owner.json` on this machine match as well.
///
/// **Both, because the two writers are not the same function — and that is why one measurement
/// could not have spoken for the pair.** They diverge in exactly the exhaustion fallback: with
/// every candidate held, `deriveHandle(_, "/x/helm", "12345-678")` is `helm-12345-678` from
/// `hooks` and `helm-12345-678-44347` from pi, which appends `process.pid`. A pid is digits, so
/// pi's extra component sits inside this alphabet too and the conclusion is unchanged — but it is
/// a shape `hooks` cannot emit, so a corpus derived from `hooks` alone was missing it
/// (`HandleTests.testEveryHandleTheWritersCanEmitIsStillAccepted` now carries it). `hooks`'
/// `deriveHandle` calls itself *"identical to pi's"*; it is not, and that comment is wrong
/// independently of this type.
///
/// **The rule stops at the alphabet anyway, and the margin is the point.** Constraining dash
/// placement would buy almost nothing — `Alice`, `my agent` and `owner_1234` are what a caller
/// actually types, and the alphabet refuses all three — while widening what this rule depends on
/// from *one* property of the far side (which characters `slug` emits) to *three* functions
/// interacting (`slug`, `tail`, and how `deriveHandle` composes them). **Nothing checks that
/// dependency.** This alphabet and the JavaScript `slug` are two spellings of one rule across a
/// runtime boundary, and unlike the spool's wire format — watched by `SpoolWireConformanceTests`
/// running the real scripts as subprocesses — no *test* runs the real writers and asserts their
/// output satisfies this one. The fuzz above is a measurement taken once, not a gate: it says
/// what the writers emitted on the day it ran and nothing about what they will emit — exactly the
/// standing the line numbers it replaced had. It could not live in the Swift gate either: that
/// gate is Swift-and-xcodegen by policy and this needs node, so it belongs in `hooks/test.sh` and
/// pi's. Until it exists, the looser rule is the one that survives the far side drifting.
///
/// That margin is not hypothetical caution. #239's first draft asserted the opposite — that
/// `deriveHandle("/x/helm", "12345-678")` was `helm--678`, so dash placement *could not* be
/// constrained — written from `tail`'s name and signature without reading its body. It is
/// `helm-678`. The far side is easy to get wrong from here, which is the argument for depending
/// on less of it.
///
/// **What was ruled out, and why.**
///
/// - **Tighten `validating:` only, leaving decode permissive.** Rejected. Since #233 the other
///   two routes *call* `validating:`, so "only" means splitting one rule back into two spellings
///   — exactly the defect #233 removed, and one that had already shipped once between these very
///   routes (`9863944`). It would also make `Handle(readingFrom:)`'s non-failability a lie about
///   the rule: an owner decoded permissively could hand out a handle `validating:` refuses.
/// - **Normalise instead of reject** — slug the candidate here, so `"My Agent"` becomes
///   `my-agent`. Rejected, and it is the attractive one. The line is not "never normalise":
///   trimming stays, and trimming *is* normalisation. The difference is whether it can change
///   **which agent you address**. No writer can emit a handle carrying surrounding whitespace, so
///   trimming only ever recovers the single handle that was meant. Slugging does not — `"Alice"`
///   becomes `alice`, which is very likely a *different real agent*, and the caller is never told
///   it asked for one address and got another. That is `MailboxDirectory`'s "read, never derived"
///   argument one turn worse: a derived handle is silently wrong, and a normalised one is
///   silently wrong while looking right.
///
/// **What it costs, measured rather than assumed.** Eight `owner.json` on this machine when the
/// rule landed; all eight already inside `[a-z0-9-]`, and all eight with a `handle` equal to their
/// own directory name. A file the new rule *does* refuse costs its own row and nothing else —
/// `MailboxDirectory.owners(in:)` is a `compactMap { try? … }`, pinned by
/// `MailboxDirectoryTests.testAnOwnerOutsideTheWritersAlphabetCostsItsOwnRowAndNothingElse`.
/// Downstream that agent is unreportable, not unreachable: helm answers a spawn `unclaimed`
/// rather than `ready` (exit 5, with a reason) instead of crashing or hanging, and the mailbox
/// keeps working, because both writers are JavaScript and never consult this rule. It also
/// self-heals — `owner.json` is a live claim the slugging writer rewrites on the next session
/// start, not an archive.
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
/// whole result blob on stdout — the `print` on its terminal-status branch — and the agent that
/// invoked it reads the field. `SpoolWireConformanceTests
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
    /// **It enforces three things: trimmed, not empty, and every character inside
    /// `[a-z0-9-]`.** It is still not a typo catcher — `helm-4381` for `helm-4831` is a perfectly
    /// well-formed address for nobody — but it no longer accepts handles that could not name a
    /// mailbox directory at all. Until #239 it did: `"Alice"`, `"my agent"` and `"owner_1234"`
    /// all passed, and `~/.helm/mail/Alice/` does not exist and never will, because both writers
    /// of the scheme slug harder than this rule did.
    ///
    /// **`Alice` vs `alice` is the one with a measured cost, and it is why this refuses rather
    /// than lowercases.** The macOS default filesystem is case-insensitive, so those are two
    /// agents to a sender and one directory to the disk, and the doc comment on `slug` in
    /// `pi/extensions/helm-mail/index.ts` records that as having already lost someone their mail.
    /// Folding the case here would hand `Alice`'s mail to `alice` without telling anyone; see the
    /// type's header for the full argument, and for what the alphabet is derived from.
    package init?(validating candidate: String) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(Self.addressableCharacters.contains) else {
            return nil
        }
        self.value = trimmed
    }

    /// The alphabet both `owner.json` writers can emit, spelled out rather than written as a
    /// predicate so the set itself is the thing on the page: `[a-z0-9]` is what survives
    /// `slug`'s `replace(/[^a-z0-9]+/g, "-")`, and `-` is what that replacement substitutes and
    /// what `deriveHandle` joins a handle's components with.
    ///
    /// **Reading it against that regex is not a substitute for a test, and this comment used to
    /// offer it as one.** "Compare against their `slug` by eye" only works if a reader can find
    /// `slug`, and the line numbers that pointed at it went stale from an unrelated merge before
    /// this rule had shipped. What holds the two sides together is still nothing; the type's
    /// header says where that test would have to live and why it is not here.
    private static let addressableCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

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
