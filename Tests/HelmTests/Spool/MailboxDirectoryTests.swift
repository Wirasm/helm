import HelmWire
import XCTest

@testable import Helm

/// The identity join: one lookup on pid, both runtimes, and a handle that is read rather than
/// computed.
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

        // The hazard, staged: pid 14832 is alive again and belongs to someone else entirely.
        let reused = MailboxDirectory.owner(
            in: owners, foregroundPid: 14832, shellPid: 1, ancestors: { _ in [] })
        XCTAssertNil(reused, "a reused pid matched a RETIRED mailbox — #236's join hazard")
    }

    /// The control: retirement must cost only the retired row. A fix that returned nothing at all
    /// would satisfy the assertion above and break every live lookup.
    func testAnOwnerWithNoRetiredAtIsStillAddressable() throws {
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")
        let owners = MailboxDirectory.owners(in: root)
        XCTAssertEqual(owners.count, 1, "a live owner was dropped alongside the retired ones")
        XCTAssertNil(owners.first?.retiredAt)
        XCTAssertEqual(
            MailboxDirectory.owner(
                in: owners, foregroundPid: 14832, shellPid: 1, ancestors: { _ in [] })?.handle,
            "helm-4831")
    }

    func testOneJoinOnPidAnswersForBothRuntimes() throws {
        // The Claude session registry publishes no row for pi at all. `owner.json` does, with
        // the same fields — so this replaces "a source of truth plus a degradation path".
        try mailbox("helm-4831", runtime: "claude", pid: 14832, sessionId: "…-4831")
        try mailbox("sild-2dd3", runtime: "pi", pid: 22001, sessionId: "…-2dd3")
        let owners = MailboxDirectory.owners(in: root)

        // `ancestors` is never called on a direct pid hit, so a closure that would fail the
        // test if it ran is the honest stand-in for "not needed here" (#221: `HelmWire` has no
        // default to lean on, since `AgentLocator` is `Helm`-only).
        let unreachable: (pid_t) -> [pid_t] = { _ in
            XCTFail("no wrapper here")
            return []
        }

        let claude = MailboxDirectory.owner(
            in: owners, foregroundPid: 14832, shellPid: 1, ancestors: unreachable)
        XCTAssertEqual(claude?.handle, "helm-4831")
        XCTAssertEqual(claude?.runtime, "claude")

        let pi = MailboxDirectory.owner(
            in: owners, foregroundPid: 22001, shellPid: 1, ancestors: unreachable)
        XCTAssertEqual(pi?.handle, "sild-2dd3")
        XCTAssertEqual(pi?.sessionId, "…-2dd3")
    }

    func testAnAgentBehindAWrapperIsFoundThroughItsAncestry() throws {
        // The agent is usually the pty's own foreground process. Not always — a shell
        // function, `env`, or a wrapper can sit in between, and then it is a descendant of the
        // pane's login shell while something else holds the foreground.
        try mailbox("work-aaaa", runtime: "claude", pid: 500, sessionId: "…-aaaa")
        let owners = MailboxDirectory.owners(in: root)
        let found = MailboxDirectory.owner(
            in: owners, foregroundPid: 999, shellPid: 100,
            ancestors: { $0 == 500 ? [400, 100] : [] })
        XCTAssertEqual(found?.handle, "work-aaaa")
    }

    func testAnUnrelatedMailboxIsNeverAttributedToThisTerminal() throws {
        try mailbox("someone-else", runtime: "claude", pid: 777, sessionId: "…-else")
        let owners = MailboxDirectory.owners(in: root)
        XCTAssertNil(
            MailboxDirectory.owner(
                in: owners, foregroundPid: 999, shellPid: 100, ancestors: { _ in [] }),
            "a mailbox that is not below this pane belongs to somebody else's agent")
    }

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
