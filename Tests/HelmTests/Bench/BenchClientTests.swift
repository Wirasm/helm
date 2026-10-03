import BenchKit
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
        let client = BenchClient(endpoint: .unix(path: server.path))

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

    /// A benchd on another machine (M5c): the same verb and the same follower over TCP, with
    /// nothing but the endpoint changed.
    func testAVerbAndTheFollowerWorkOverTCP() throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 5),
            tcp: true)
        defer { server.stop() }
        guard case .tcp = server.endpoint else { return XCTFail("\(server.endpoint)") }
        let client = BenchClient(endpoint: server.endpoint)
        var seen: [UInt64] = []
        client.onDocument = { seen.append($0.seq) }
        client.start()
        defer { client.stop() }
        XCTAssertTrue(Eventually.holds { seen == [5] }, "\(seen)")

        let answer = try client.request(
            BenchRequest(id: "r1", verb: .paneSplit(direction: .right), by: .operatorGesture),
            answering: LayoutReport.self)
        XCTAssertEqual(answer.status, .ok)
        XCTAssertEqual(server.verbs.first?["verb"] as? String, "pane/split")
    }

    /// A benchd reached over TCP names a `bench` on its own machine; helm runs its own. This one
    /// says no version, so it predates `status.version`: another build than any `bench` here.
    func testAClientOverTCPNeverRunsTheBenchBenchdNames() throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1),
            tcp: true)
        defer { server.stop() }
        server.answer = { request in
            ["id": request["id"] ?? "", "status": "ok", "data": ["bench": "/forge/only/bench"]]
        }
        let attach = AttachBench(client: BenchClient(endpoint: server.endpoint))
        switch attach.current {
        case let .success(bench): XCTFail("attached with \(bench) to a benchd of no version")
        case let .failure(.notFound(missing)):
            XCTAssertTrue(missing.asked.contains("over TCP"), missing.asked)
        case let .failure(.otherBuild(other)):
            XCTAssertNotEqual(other.bench, "/forge/only/bench")
            XCTAssertEqual(other.benchd, "unknown")
        case let .failure(.noAnswer(slow)): XCTFail(slow.description)
        }
        _ = attach.current
        XCTAssertLessThanOrEqual(
            server.verbs.count, 1, "the verdict is kept for the connection, not asked per drawing")
    }

    /// The follower delivers the whole document, then each frame's document, in order; a frame
    /// no newer than what was delivered is not delivered again.
    func testTheFollowerDeliversTheDocumentThenFrames() throws {
        let first = BenchFixture.document(
            path, BenchFixture.bench([BenchFixture.terminal()]), seq: 3)
        let server = try FakeBenchd(document: first)
        defer { server.stop() }
        let client = BenchClient(endpoint: .unix(path: server.path))
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
        let client = BenchClient(endpoint: .unix(path: server.path))
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
        let client = BenchClient(endpoint: .unix(path: server.path))
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

    /// Which `bench` to attach with is asked once per connection: a drawing on the same
    /// connection reuses the answer, and the first drawing after a reconnect, which runs inside
    /// the document delivery, asks again, since a restarted benchd may be another build.
    func testTheAttachBenchIsAskedAgainAfterAReconnect() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bench = dir.appendingPathComponent("bench").path
        try "#!/bin/sh\nexit 0\n".write(toFile: bench, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bench)

        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        server.answer = { request in
            ["id": request["id"] ?? "", "status": "ok", "data": ["bench": bench]]
        }
        let client = BenchClient(endpoint: .unix(path: server.path))
        let attach = AttachBench(client: client)
        var asked: [Int] = []
        let statuses = { server.verbs.filter { $0["verb"] as? String == "status" }.count }
        // As WorkbenchModel draws: asked from inside the document delivery.
        client.onDocument = { _ in
            _ = attach.current
            asked.append(statuses())
        }
        client.start()
        defer { client.stop() }
        XCTAssertTrue(Eventually.holds { asked == [1] }, "\(asked)")
        XCTAssertEqual(try attach.current.get(), bench)
        XCTAssertEqual(statuses(), 1, "the same connection reuses the answer")

        server.setDocument(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal()]), seq: 9))
        server.dropFollowers()
        XCTAssertTrue(
            Eventually.holds(within: 5) { asked.count == 2 }, "reconnected: \(asked)")
        XCTAssertEqual(asked, [1, 2], "the drawing after a reconnect asked benchd again")
    }

    /// A request benchd read and never answered may have been carried out, so it fails as
    /// unanswered; one that never reached benchd fails as anything else. A caller that would
    /// retry has to tell the two apart (#625: Pocket never sends a message twice).
    func testARequestBenchdTookButNeverAnsweredFailsAsUnanswered() throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        server.answer = { _ in [:] }
        let request = BenchRequest(
            id: "r", verb: .paneSplit(direction: .down), by: .operatorGesture)
        XCTAssertThrowsError(
            try BenchClient.request(
                request, at: .unix(path: server.path), answering: LayoutReport.self)
        ) { error in
            XCTAssertTrue(error is BenchUnanswered, "\(error)")
        }
        XCTAssertThrowsError(
            try BenchClient.request(
                request, at: .unix(path: "/tmp/hb-nobody-\(UUID().uuidString.prefix(6)).sock"),
                answering: LayoutReport.self)
        ) { error in
            XCTAssertFalse(error is BenchUnanswered, "nothing was sent: \(error)")
        }
    }

    /// `reconnect` drops the follower's connection and connects again at once, as a phone
    /// coming back from sleep wants rather than waiting on a socket the network change killed.
    func testReconnectConnectsTheFollowerAgainAtOnce() throws {
        let server = try FakeBenchd(
            document: BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        defer { server.stop() }
        let client = BenchClient(endpoint: .unix(path: server.path))
        client.start()
        defer { client.stop() }
        XCTAssertTrue(Eventually.holds { client.connections == 1 })
        client.reconnect()
        XCTAssertTrue(
            Eventually.holds(within: 2) { client.connections == 2 }, "\(client.connections)")
        XCTAssertEqual(client.state, .connected)
    }

    /// No daemon at all: the state names the socket's failure, and a verb throws rather than
    /// hanging.
    func testNoDaemonIsDisconnectedAndAVerbFails() throws {
        let client = BenchClient(
            endpoint: .unix(path: "/tmp/hb-nobody-\(UUID().uuidString.prefix(6)).sock"))
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
        let client = BenchClient(endpoint: .unix(path: server.path))
        let model = WorkbenchModel(
            terminals: TerminalManager(), client: client)
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
