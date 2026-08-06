import HelmWire
import XCTest

@testable import Helm

/// The on-disk half: where the spool is, and the rename that makes a request happen once.
final class SpoolDirectoryTests: XCTestCase {
    private var directory: SpoolDirectory!

    override func setUpWithError() throws {
        directory = SpoolDirectory(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("helm-spool-tests-\(UUID().uuidString)"))
        try directory.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.root)
        directory = nil
    }

    private func writeRequest(_ name: String, _ json: String) throws -> URL {
        let url = directory.root.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Where the spool is

    func testAnIsolatedInstanceGetsItsOwnSpool() {
        // The disaster this closes: a worktree build watching the operator's spool claims a
        // request meant for their helm and opens the terminal in the wrong window. The suite
        // that already isolates defaults isolates this too, automatically rather than by
        // remembering.
        let home = URL(fileURLWithPath: "/Users/nobody")
        XCTAssertEqual(
            SpoolDirectory.resolve(environment: [:], home: home).root.path,
            "/Users/nobody/.helm/spool")
        XCTAssertEqual(
            SpoolDirectory.resolve(
                environment: ["HELM_DEFAULTS_SUITE": "helm-bench"], home: home
            ).root.path,
            "/Users/nobody/.helm/spool-helm-bench")
    }

    func testAnExplicitDirectoryOutranksEverything() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        XCTAssertEqual(
            SpoolDirectory.resolve(
                environment: ["HELM_SPOOL_DIR": "/tmp/elsewhere", "HELM_DEFAULTS_SUITE": "x"],
                home: home
            ).root.path,
            "/tmp/elsewhere")
        // A shell's way of saying "not set" is not a directory named "".
        XCTAssertEqual(
            SpoolDirectory.resolve(environment: ["HELM_SPOOL_DIR": "  "], home: home).root.path,
            "/Users/nobody/.helm/spool")
    }

    func testTheOffSwitchIsOnlyOnWhenItSaysSomething() {
        XCTAssertFalse(SpoolDirectory.isOff([:]))
        XCTAssertFalse(SpoolDirectory.isOff(["HELM_SPOOL_OFF": ""]))
        XCTAssertTrue(SpoolDirectory.isOff(["HELM_SPOOL_OFF": "1"]))
    }

    // MARK: - Exactly once

    func testAClaimIsAtomicSoOnlyOneOfManyClaimantsWins() throws {
        let request = try writeRequest("r.json", "{}")
        // The rename race, run for real rather than argued. Two helms — or two windows of one
        // helm — reach this at the same moment, and `rename(2)` is what decides.
        let winners = Atomic()
        DispatchQueue.concurrentPerform(iterations: 16) { [directory] _ in
            if directory?.claim(request) != nil { winners.increment() }
        }
        XCTAssertEqual(winners.value, 1, "exactly one claimant may take a request")
        XCTAssertTrue(directory.pending().isEmpty, "the request is gone from the spool")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.claimed.path), ["r.json"])
    }

    func testAClaimedRequestIsNeverOfferedAgain() throws {
        _ = directory.claim(try writeRequest("r.json", "{}"))
        // The other half of exactly-once, and the half a restart tests: `claimed/` is a
        // graveyard. Re-reading it after a crash is the double-open #54 forbids.
        XCTAssertTrue(directory.pending().isEmpty)
    }

    func testOnlyTopLevelJsonCountsAsARequest() throws {
        _ = try writeRequest("r.json", "{}")
        _ = try writeRequest("notes.txt", "hello")
        directory.write(SpoolResult(id: "other", status: .started))
        _ = directory.stagePrompt("hi", for: "other")
        XCTAssertEqual(directory.pending().map(\.lastPathComponent), ["r.json"])
    }

    // MARK: - Results

    func testAResultRoundTrips() {
        directory.write(
            SpoolResult(
                id: "r", status: .ready,
                terminalId: TerminalID(validating: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
                pid: 4242, sessionId: "f9e4639d", handle: Handle(validating: "helm-48c4"),
                runtime: "claude"))
        let read = directory.result(id: "r")
        XCTAssertEqual(read?.status, .ready)
        XCTAssertEqual(read?.handle?.value, "helm-48c4")
        XCTAssertEqual(read?.pid, 4242)
    }

    func testAClaimedRequestWithNoResultIsAbandoned() throws {
        // helm stopped between the rename and the answer. Nothing else can see that, because
        // from outside a claimed file looks exactly like one being worked on.
        _ = directory.claim(try writeRequest("r.json", #"{"id":"r","cwd":"/tmp","command":"pi"}"#))
        XCTAssertEqual(directory.abandoned(), ["r"])
        directory.write(SpoolResult(id: "r", status: .started))
        XCTAssertEqual(directory.abandoned(), [], "an answered request was not abandoned")
    }
}

/// A counter safe to increment from several threads. Small enough to be worth having here
/// rather than reaching for a dependency.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
