import BenchKit
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// Who needs the operator (M1, #357), as helm draws it from benchd's `sessions` answer: the items,
/// their counts, the drawer's rows, the tab and workspace marks, and when a notification is due.
@MainActor
final class AttentionTests: XCTestCase {
    private let paneA = UUID()
    private let paneB = UUID()
    private let paneC = UUID()

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// One of each: a wait, a finished turn of his, one of an orchestrator's, one he has seen,
    /// and mail to him.
    private func entries() -> [BenchLiveSessions.Entry] {
        [
            .init(
                session: "s1", handle: "asker", pane: paneA, foregroundPid: 1,
                waiting: .init(waitingFor: "permission prompt", since: at(30), source: "hook")),
            .init(
                session: "s2", handle: "mine", pane: paneB, foregroundPid: 2,
                done: BenchDone(since: at(20), to: "operator", seen: false),
                operatorMail: BenchOperatorMail(unread: 1, since: at(10), subject: "PR ready")),
            .init(
                session: "s3", handle: "theirs", pane: paneC, foregroundPid: 3,
                done: BenchDone(since: at(5), to: "orch", seen: false)),
            .init(
                session: "s4", handle: "looked", pane: UUID(), foregroundPid: 4,
                done: BenchDone(since: at(1), to: "operator", seen: true)),
        ]
    }

    func testEachThingNeedingSomeoneIsAnItemInTheWalksOrder() {
        let items = Attention.items(entries())
        XCTAssertEqual(
            items.map { "\($0.kind.glyph) \($0.who) \($0.words ?? "-") \($0.mine)" },
            [
                "● asker permission prompt true",
                "✓ theirs - false",
                "✓ mine - true",
                "✉ mine PR ready true",
            ], "asking, finished, mail; the oldest first; a seen turn is gone")
        XCTAssertEqual(Attention.counts(items), [.asking: 1, .finished: 1, .message: 1])
        XCTAssertEqual(NeedsYou.rows(items, all: false).map(\.who), ["asker", "mine", "mine"])
        XCTAssertEqual(NeedsYou.rows(items, all: true).count, 4)
        XCTAssertEqual(
            Attention.byPane(items), [paneA: .asking, paneB: .finished],
            "the most urgent of his own per pane; an orchestrator's turn marks nothing")
        XCTAssertTrue(Attention.items([]).isEmpty)
        XCTAssertTrue(Attention.counts([]).isEmpty, "nothing shows when nobody needs him")
    }

    func testAWorkspaceIsMarkedByItsMostUrgentPaneElseItsWork() {
        let busy = BenchLiveSessions.Report(activity: "busy")
        let idle = BenchLiveSessions.Report(activity: "idle")
        let marks = WorkspaceMark.of(
            panes: ["/a": [paneA, paneB], "/b": [paneC], "/c": [UUID()]],
            marks: [paneA: .message, paneB: .asking],
            reports: [paneC: busy])
        XCTAssertEqual(marks, ["/a": .needs(.asking), "/b": .working])
        XCTAssertEqual(
            WorkspaceMark.of(panes: ["/d": [paneA]], marks: [:], reports: [paneA: idle]), [:],
            "an idle agent is nothing by itself: finished is what benchd says, not a guess")
    }

    func testOnlyAWaitThatHasJustBegunIsTold() {
        let before = Attention.items(entries())
        XCTAssertTrue(Attention.newlyAsking(before: before, after: before).isEmpty)
        var later = entries()
        later[2].waiting = .init(waitingFor: "question", since: at(40), source: "hook")
        let new = Attention.newlyAsking(before: before, after: Attention.items(later))
        XCTAssertEqual(new.map(\.who), ["theirs"])
    }

    /// A wait already open when helm starts is not news; one that begins after is told, once.
    func testNoNotificationForWhatWasAlreadyAskingAtLaunch() {
        let foregrounds = SessionForegrounds()
        var told: [String] = []
        foregrounds.onAsking = { told += $0.map(\.who) }
        let first = Attention.items(entries())
        foregrounds.set([:], attention: first)
        XCTAssertEqual(told, [], "the first answer only sets the scene")
        var later = entries()
        later[2].waiting = .init(waitingFor: "question", since: at(40), source: "hook")
        foregrounds.set([:], attention: Attention.items(later))
        foregrounds.set([:], attention: Attention.items(later))
        XCTAssertEqual(told, ["theirs"])
    }

    /// The whole path: benchd's `sessions` answer reaches every surface's items.
    func testARefreshTakesBenchdsAnswer() async throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                "/w", BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        let reply = try JSONSerialization.data(
            withJSONObject: XCTUnwrap(fixture("session-list.json")["attention"]))
        server.answer = { (request: [String: Any]) -> [String: Any] in
            let data = (try? JSONSerialization.jsonObject(with: reply)) ?? [:]
            return ["id": request["id"] ?? "", "status": "ok", "data": data]
        }
        let foregrounds = SessionForegrounds()
        var told: [AttentionItem] = []
        foregrounds.onAsking = { told += $0 }
        await foregrounds.refresh(using: BenchClient(endpoint: server.endpoint))
        XCTAssertEqual(
            foregrounds.attention.map { "\($0.kind.glyph) \($0.who) \($0.mine)" },
            ["✓ reviewer false", "✉ reviewer true"])
        XCTAssertTrue(told.isEmpty, "a finished turn and mail are not told")
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/\(name)")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
