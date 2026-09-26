import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The client against a benchd stand-in on a real unix socket (`FakeBenchd`): what goes out, what
/// comes back, and what happens when the daemon goes away. No cargo, no real daemon.
@MainActor
final class BenchClientTests: XCTestCase {
    private let path = "/tmp/helm-bench-client"

    /// A verb goes out as benchd's request line, and its answer comes back typed.
    func testARequestIsTheWireLineAndTheReportComesBack() throws {
        let pane = UUID()
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal(pane)]), seq: 1))
        defer { server.stop() }
        server.answer = { request in
            [
                "id": request["id"] ?? "", "status": "ok",
                "data": ["seq": 7, "changed": true, "pane_created": pane.uuidString.lowercased()],
            ]
        }
        let client = BenchClient(socketPath: server.path)

        let answer = try client.request(
            BenchRequest(id: "r1", verb: .paneSplit(direction: .right), by: .operatorGesture),
            answering: LayoutReport.self)

        XCTAssertEqual(answer.status, .ok)
        XCTAssertEqual(answer.data?.paneCreated, pane)
        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(sent["verb"] as? String, "pane/split")
        XCTAssertEqual((sent["by"] as? [String: Any])?["kind"] as? String, "operator")
        XCTAssertEqual((sent["args"] as? [String: Any])?["direction"] as? String, "right")
    }

    /// The follower delivers the whole document, then each frame's document, in order; a frame
    /// no newer than what was delivered is not delivered again.
    func testTheFollowerDeliversTheDocumentThenFrames() throws {
        let first = BenchFixture.document(
            path, BenchFixture.bench([BenchFixture.terminal()]), seq: 3)
        let server = try FakeBenchd(document: first)
        defer { server.stop() }
        let client = BenchClient(socketPath: server.path)
        var seen: [UInt64] = []
        client.onDocument = { seen.append($0.seq) }
        client.start()
        defer { client.stop() }

        XCTAssertTrue(Eventually.holds { seen == [3] }, "the first line is the document: \(seen)")
        XCTAssertEqual(client.state, .connected)

        let second = BenchFixture.document(
            path, BenchFixture.bench([BenchFixture.terminal()]), seq: 4)
        server.push(second)
        server.push(first)
        XCTAssertTrue(Eventually.holds { seen == [3, 4] }, "\(seen)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(seen, [3, 4], "an older frame is not drawn over a newer one")
    }

    /// The whole document the follower connects with waits on the main queue, and a verb can
    /// draw a newer one before it runs (`document(atLeast:)`). Drawing the older one then would
    /// put the bench back where it was until the next frame.
    func testTheDocumentOnConnectingIsNotDrawnOverANewerOne() throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        let client = BenchClient(socketPath: server.path)
        var seen: [UInt64] = []
        client.onDocument = { seen.append($0.seq) }
        client.start()
        defer { client.stop() }

        // Nothing here pumps the main queue, so the follower's own deliveries wait there.
        XCTAssertNotNil(client.document(atLeast: 1, within: 5))
        server.push(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal()]), seq: 2))
        XCTAssertNotNil(client.document(atLeast: 2, within: 5))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(seen, [1, 2], "the document connected with was drawn over a newer one")
    }

    /// benchd dropping the follower — a restart, or a follower it found too slow — costs a
    /// reconnect and a fresh document, and the state says so in between.
    func testTheFollowerReconnectsAfterTheServerDropsIt() throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        let client = BenchClient(socketPath: server.path)
        var seen: [UInt64] = []
        client.onDocument = { seen.append($0.seq) }
        client.start()
        defer { client.stop() }
        XCTAssertTrue(Eventually.holds { seen == [1] })

        server.setDocument(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal()]), seq: 9))
        server.dropFollowers()

        XCTAssertTrue(
            Eventually.holds(within: 5) { seen == [1, 9] },
            "reconnected with the whole document: \(seen)")
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(server.followerCount, 1)
    }

    /// No daemon at all: the state names the socket's failure, and a verb throws rather than
    /// hanging.
    func testNoDaemonIsDisconnectedAndAVerbFails() throws {
        let client = BenchClient(socketPath: "/tmp/hb-nobody-\(UUID().uuidString.prefix(6)).sock")
        client.start()
        defer { client.stop() }

        XCTAssertTrue(
            Eventually.holds {
                if case .disconnected = client.state { true } else { false }
            })
        XCTAssertThrowsError(
            try client.request(
                BenchRequest(id: "r", verb: .paneSplit(direction: .down), by: .operatorGesture),
                answering: LayoutReport.self))
    }

    /// A refusal reaches the caller with benchd's own reason, and nothing changes locally.
    func testARefusalIsSaidWithItsReason() throws {
        let at = BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1)
        let server = try FakeBenchd(document: at)
        defer { server.stop() }
        server.answer = { request in
            ["id": request["id"] ?? "", "status": "refused", "reason": "no pane 1234 on the bench"]
        }
        let client = BenchClient(socketPath: server.path)
        let model = WorkbenchModel(
            terminals: TerminalManager(), agents: .blind, client: client)
        defer { client.stop() }
        XCTAssertTrue(Eventually.holds { model.bench != nil })
        let before = model.bench

        XCTAssertNil(model.send(.paneClose(UUID()), by: .operatorGesture))

        XCTAssertEqual(
            model.verbFailure?.contains("no pane 1234 on the bench"), true,
            "\(model.verbFailure ?? "nil")")
        XCTAssertEqual(model.bench, before)
    }
}
