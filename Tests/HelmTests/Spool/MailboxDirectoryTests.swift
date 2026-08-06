import HelmWire
import XCTest

@testable import Helm

/// The identity join: pid → registry row → session → mailbox, one rule for both runtimes, and a
/// handle that is read rather than computed.
final class MailboxDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-mailbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func mailbox(_ handle: String, runtime: String, pid: Int, sessionId: String) throws {
        let dir = root.appendingPathComponent(handle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"handle":"\(handle)","runtime":"\(runtime)","pid":\(pid),
         "sessionId":"\(sessionId)","cwd":"/tmp","claimedAt":1785831967319}
        """
        .write(to: dir.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)
    }

    private func retiredMailbox(_ handle: String, pid: Int, sessionId: String) throws {
        let dir = root.appendingPathComponent(handle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"handle":"\(handle)","runtime":"claude","pid":\(pid),
         "sessionId":"\(sessionId)","cwd":"/tmp","claimedAt":1785831967319,
         "retiredAt":1786040000000}
        """
        .write(to: dir.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)
    }

    /// The Claude session registry as a fixture: `pid → sessionId`, exactly what
    /// `AgentRegistry.sessionLookup(in:)` produces from `~/.claude/sessions/<pid>.json`. A
    /// closure, so every rule below is testable without a registry on disk or a live process.
    private func registry(_ rows: [pid_t: String]) -> (pid_t) -> String? {
        { rows[$0] }
    }

    /// No registry at all — the pi case, and the state of the world before an agent's own row
    /// has been published.
    private let noRegistry: (pid_t) -> String? = { _ in nil }

    private func book(_ sessionFor: @escaping (pid_t) -> String?) -> AddressBook {
        AddressBook(owners: MailboxDirectory.owners(in: root), sessionFor: sessionFor)
    }

    // MARK: - #247: the pid is how the session is found, and nothing more

    /// **The defect, staged.** `owner.json` records a pid at `SessionStart` and is never
    /// rewritten, so `helm-4831`'s row still names 14832 long after that process died — and
    /// macOS handed 14832 to a different agent entirely. Joining on the pid answers a spool
    /// spawn with `helm-4831`'s handle, which nobody is reading.
    ///
    /// The registry is what tells them apart: pid 14832 runs session `…-2dd3` *now*.
    func testARecycledPidResolvesToTheAgentThatHasItNowRatherThanTheOneThatRecordedIt() throws {
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")
        try mailbox("helm-2dd3", runtime: "claude", pid: 90210, sessionId: "…-2dd3")

        let found = book(registry([14832: "…-2dd3"])).owner(forPid: 14832)

        XCTAssertEqual(
            found?.handle, "helm-2dd3",
            "the pid was recycled — the mailbox belongs to the session running there now")
        XCTAssertNotEqual(
            found?.handle, "helm-4831",
            "a recorded pid is neither identity nor liveness (#236) — this is the wrong answer "
                + "a spool spawn used to get, and the wrong session snapshot.json used to report")
    }

    /// The other half of the same rule, and the case #236 made *more* common by keeping these
    /// rows alive: the agent is fine, its recorded pid is not. helm restarted, the session was
    /// resumed into a new process, and `owner.json` still names the old one — so the pane's
    /// foreground pid is one no owner records, and a pid join finds nothing at all.
    func testALiveAgentWhoseRecordedPidIsStaleIsStillFoundThroughItsSession() throws {
        try mailbox("helm-4831", runtime: "claude", pid: 13104, sessionId: "…-4831")

        let found = book(registry([74011: "…-4831"])).owner(forPid: 74011)

        XCTAssertEqual(
            found?.handle, "helm-4831",
            "the session moved to a new process and the address book did not — the registry is "
                + "the only thing that knows, and it is 2026-08-06's incident by its own numbers")
    }

    /// A known session with no mailbox is **absence**, not a licence to fall back to the pid.
    ///
    /// The pane is running Claude session `…-new`; nobody has claimed a mailbox for it. Any
    /// owner whose recorded pid happens to equal this one is stale or recycled by definition, so
    /// matching it would be the defect wearing a rescue's clothes. A caller that polls sees the
    /// mailbox the moment the agent's `SessionStart` hook writes it.
    func testAKnownSessionWithNoMailboxIsAbsenceRatherThanTheStaleRowAtThatPid() throws {
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")

        XCTAssertNil(
            book(registry([14832: "…-new"])).owner(forPid: 14832),
            "there is no mailbox for the session in that process; the row at that pid is stale")
    }

    // MARK: - The controls: what must keep working, and what must still fail

    /// **A control, and the one that fails if the fix overshoots.** pi publishes no pid→session
    /// registry anywhere on disk (it keys sessions by cwd-slug), so for a pi owner the recorded
    /// pid is the whole answer available — see #245. A rule that asked the registry for
    /// *everyone* would resolve pi to nothing and take the whole runtime off the mail system.
    ///
    /// Passes on both sides of #247 by design: before, because everything joined on the pid;
    /// after, because this is the branch that survives.
    func testAPiOwnerIsStillResolvedOnItsPidWithNoRegistryInvolved() throws {
        try mailbox("sild-2dd3", runtime: "pi", pid: 22001, sessionId: "…-2dd3")

        XCTAssertEqual(
            book(noRegistry).owner(forPid: 22001)?.handle, "sild-2dd3",
            "pi has no registry to ask — the pid is the only answer there is")
    }

    /// And the registry cannot take pi off the air. A stale `~/.claude/sessions` row sitting on
    /// a pid pi now holds must not cost pi its mailbox — a pi owner's `sessionId` is pi's own
    /// and could never match a Claude session id, so the pid branch has to still be reached.
    func testAPiOwnerStillResolvesWhenTheRegistryHasAStaleRowForThatPid() throws {
        try mailbox("sild-2dd3", runtime: "pi", pid: 22001, sessionId: "…-2dd3")

        XCTAssertEqual(
            book(registry([22001: "a-claude-session-that-left"])).owner(forPid: 22001)?.handle,
            "sild-2dd3",
            "a Claude row on pi's pid is not evidence about pi")
    }

    /// A Claude owner still resolves the ordinary way — the registry names its session and the
    /// address book carries it. The control against a fix that only knows how to say no.
    func testAClaudeOwnerWhoseRecordedPidIsCurrentStillResolves() throws {
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")

        XCTAssertEqual(
            book(registry([14832: "…-4831"])).owner(forPid: 14832)?.handle, "helm-4831")
    }

    // MARK: - #236: retired rows

    /// #236: a retired mailbox keeps its `owner.json` forever, so helm has to stop joining to it.
    ///
    /// Before #236 this was true for free — a gone owner's file was deleted, so no row existed to
    /// match. Now the row survives with its last-known pid, and macOS reuses pids. The day one is
    /// handed to an unrelated live terminal, the join would answer with a dead agent's handle and
    /// say nothing about it.
    func testARetiredMailboxIsNeverJoinedEvenWhenItsPidComesBack() throws {
        try retiredMailbox("helm-4831", pid: 14832, sessionId: "…-4831")
        try mailbox("sild-2dd3", runtime: "pi", pid: 22001, sessionId: "…-2dd3")

        let owners = MailboxDirectory.owners(in: root)
        XCTAssertEqual(owners.map(\.handle), ["sild-2dd3"], "a retired owner was still addressable")

        // The hazard, staged twice: pid 14832 is alive again and belongs to someone else — and
        // the registry still remembers the retired session running there, which is the one route
        // that could bring a retired row back after #247.
        let book = AddressBook(owners: owners, sessionFor: registry([14832: "…-4831"]))
        XCTAssertNil(
            book.owner(foregroundPid: 14832, shellPid: 1, ancestors: { _ in [] }),
            "a reused pid matched a RETIRED mailbox — #236's join hazard")
    }

    /// The control: retirement must cost only the retired row. A fix that returned nothing at all
    /// would satisfy the assertion above and break every live lookup.
    func testAnOwnerWithNoRetiredAtIsStillAddressable() throws {
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")
        let owners = MailboxDirectory.owners(in: root)
        XCTAssertEqual(owners.count, 1, "a live owner was dropped alongside the retired ones")
        XCTAssertNil(owners.first?.retiredAt)
        XCTAssertEqual(
            AddressBook(owners: owners, sessionFor: registry([14832: "…-4831"]))
                .owner(foregroundPid: 14832, shellPid: 1, ancestors: { _ in [] })?.handle,
            "helm-4831")
    }

    // MARK: - Both runtimes, and the wrapper case

    func testOneAddressBookAnswersForBothRuntimes() throws {
        // The Claude session registry publishes no row for pi at all. `owner.json` does, with
        // the same fields — so a pi agent is addressable by the same call, down the branch that
        // does not need a registry.
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")
        try mailbox("sild-2dd3", runtime: "pi", pid: 22001, sessionId: "…-2dd3")
        let book = self.book(registry([14832: "…-4831"]))

        // `ancestors` is never called on a direct hit, so a closure that would fail the test if
        // it ran is the honest stand-in for "not needed here" (#221: `HelmWire` has no default
        // to lean on, since `AgentLocator` is `Helm`-only).
        let unreachable: (pid_t) -> [pid_t] = { _ in
            XCTFail("no wrapper here")
            return []
        }

        let claude = book.owner(foregroundPid: 14832, shellPid: 1, ancestors: unreachable)
        XCTAssertEqual(claude?.handle, "helm-4831")
        XCTAssertEqual(claude?.runtime, "claude")

        let pi = book.owner(foregroundPid: 22001, shellPid: 1, ancestors: unreachable)
        XCTAssertEqual(pi?.handle, "sild-2dd3")
        XCTAssertEqual(pi?.sessionId, "…-2dd3")
    }

    func testAnAgentBehindAWrapperIsFoundThroughItsAncestry() throws {
        // The agent is usually the pty's own foreground process. Not always — a shell
        // function, `env`, or a wrapper can sit in between, and then it is a descendant of the
        // pane's login shell while something else holds the foreground.
        //
        // This branch stays on the pid deliberately: `ancestors` walks the LIVE process tree,
        // so a stale recorded pid yields an empty chain and a recycled one has to actually be
        // running under this pane's own shell. Passes either side of #247, and is meant to.
        try mailbox("work-aaaa", runtime: "claude", pid: 500, sessionId: "…-aaaa")
        let found = book(noRegistry).owner(
            foregroundPid: 999, shellPid: 100,
            ancestors: { $0 == 500 ? [400, 100] : [] })
        XCTAssertEqual(found?.handle, "work-aaaa")
    }

    func testAnUnrelatedMailboxIsNeverAttributedToThisTerminal() throws {
        try mailbox("someone-else", runtime: "claude", pid: 777, sessionId: "…-else")
        XCTAssertNil(
            book(noRegistry).owner(foregroundPid: 999, shellPid: 100, ancestors: { _ in [] }),
            "a mailbox that is not below this pane belongs to somebody else's agent")
    }

    // MARK: - Reading the directory

    func testAnUnreadableMailboxCostsItsOwnRowAndNothingElse() throws {
        try mailbox("good-1111", runtime: "claude", pid: 11, sessionId: "…-1111")
        let bad = root.appendingPathComponent("bad-2222")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "not json".write(
            to: bad.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MailboxDirectory.owners(in: root).map(\.handle), ["good-1111"])
    }

    /// **The one field `Handle` exists to protect enters Swift from JavaScript.** `owner.json`
    /// has exactly two writers — `hooks/helm-mail.mjs` and `pi/extensions/helm-mail/index.ts`
    /// — and neither is Swift, so this decode is the only place Swift gets to say no to a
    /// malformed one. An empty or whitespace-only handle addresses nobody, and `owners(in:)`'s
    /// own header already promises "a malformed file costs its own row and nothing else" for
    /// unreadable JSON; an empty handle is malformed by that same rule, not a different one.
    /// Uses raw JSON (not the `mailbox(_:...)` helper) so the directory name and the `handle`
    /// field can differ — an empty *handle* is the thing under test, not an empty directory.
    func testAnOwnerWithAnEmptyOrWhitespaceHandleCostsItsOwnRowAndNothingElse() throws {
        try mailbox("good-3333", runtime: "claude", pid: 33, sessionId: "…-3333")

        let empty = root.appendingPathComponent("empty-handle")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try #"{"handle":"","runtime":"claude","pid":34,"sessionId":"…-empty","cwd":"/tmp"}"#
            .write(
                to: empty.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        let whitespace = root.appendingPathComponent("whitespace-handle")
        try FileManager.default.createDirectory(at: whitespace, withIntermediateDirectories: true)
        try #"{"handle":"   ","runtime":"claude","pid":35,"sessionId":"…-ws","cwd":"/tmp"}"#
            .write(
                to: whitespace.appendingPathComponent("owner.json"), atomically: true,
                encoding: .utf8)

        XCTAssertEqual(MailboxDirectory.owners(in: root).map(\.handle), ["good-3333"])
    }

    func testAMissingMailRootIsAbsenceRatherThanAnError() {
        XCTAssertEqual(
            MailboxDirectory.owners(in: root.appendingPathComponent("nope")).count, 0)
    }

    func testTheMailRootFollowsTheSameOverrideTheHooksHonour() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        XCTAssertEqual(
            MailboxDirectory.resolve(environment: [:], home: home).path,
            "/Users/nobody/.helm/mail")
        XCTAssertEqual(
            MailboxDirectory.resolve(environment: ["HELM_MAIL_DIR": "/tmp/mail"], home: home).path,
            "/tmp/mail")
    }
}
