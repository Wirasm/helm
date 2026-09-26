import Darwin
import Foundation
import HelmWire
import XCTest

@testable import Helm

/// A benchd stand-in on a real unix socket, speaking benchd's framing: one request line per
/// connection and one answer line back, except `events --follow`, which stays open for frames.
///
/// **It holds no bench logic.** A test says what each verb answers (`answer`) and pushes the
/// frames it wants helm to see (`push`); what helm *sent* is recorded in `requests`, as JSON.
/// That keeps the test about helm's side of the wire and nothing else — benchd's own behaviour
/// is the daemon gate's business, pinned by the same fixtures.
final class FakeBenchd: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var followers: [Int32] = []
    private var recorded: [[String: Any]] = []
    private var stopped = false
    /// What the follower's first line carries.
    private var document: DocumentAt

    /// The answer to every verb that is not `events --follow`. Default: an ok report, changed,
    /// at the next seq — with the frame pushed first, as benchd does, when `frame` gives one.
    var answer: @Sendable ([String: Any]) -> [String: Any]

    init(document: DocumentAt) throws {
        // Short on purpose: a sockaddr_un path caps near 104 bytes, and the temporary directory
        // alone is half of that.
        path = "/tmp/hb-\(UUID().uuidString.prefix(8)).sock"
        self.document = document
        answer = { request in
            ["id": request["id"] ?? "", "status": "ok", "data": ["seq": 0, "changed": false]]
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            throw XCTSkip(
                "cannot bind a unix socket at \(path): \(String(cString: strerror(errno)))")
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    deinit { stop() }

    /// Every request helm sent, oldest first, as decoded JSON.
    var requests: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The layout verbs among them — not the follower's own `events` line.
    var verbs: [[String: Any]] { requests.filter { $0["verb"] as? String != "events" } }

    /// The document the follower's first line would carry now: the last one set or pushed.
    var current: DocumentAt {
        lock.lock()
        defer { lock.unlock() }
        return document
    }

    func setDocument(_ at: DocumentAt) {
        lock.lock()
        document = at
        lock.unlock()
    }

    /// A frame to every follower: the event, and the document when there is one.
    func push(_ at: DocumentAt, kind: String = "bench/changed") {
        let frame = BenchFrame(
            event: .init(seq: at.seq, at: "2026-09-26T00:00:00Z", kind: kind), document: at.document
        )
        var line = try! JSONEncoder().encode(frame)
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        document = at
        for fd in followers { write(fd, line) }
    }

    /// Close every follower connection — benchd restarting, or dropping a slow follower.
    func dropFollowers() {
        lock.lock()
        let targets = followers
        followers = []
        lock.unlock()
        for fd in targets {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    var followerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return followers.count
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        dropFollowers()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            let thread = Thread { [self] in serve(fd) }
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else {
                close(fd)
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let line = buffer.prefix(upTo: buffer.firstIndex(of: 0x0A)!)
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            close(fd)
            return
        }
        lock.lock()
        recorded.append(request)
        lock.unlock()
        if request["verb"] as? String == "events" {
            // **Answered and registered under one lock, as benchd does** ("registered and
            // snapshotted under one lock, so no event falls between the document this answers
            // with and the first frame"). Writing the answer first and registering after left a
            // gap: the client had the document and the test pushed a frame into it, to nobody.
            // A loaded CI runner found it; `push` takes the same lock.
            lock.lock()
            defer { lock.unlock() }
            let data = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(document))
            write(
                fd,
                try! JSONSerialization.data(withJSONObject: [
                    "id": request["id"] ?? "", "status": "ok", "data": data,
                ]) + Data([0x0A]))
            followers.append(fd)
            return
        }
        let reply = answer(request)
        write(fd, try! JSONSerialization.data(withJSONObject: reply) + Data([0x0A]))
        close(fd)
    }

    private func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

extension FakeBenchd {
    /// An ok report for a verb that changed the document to `at` — with `at` pushed to the
    /// followers first, which is the order benchd keeps (the frame is queued before the answer).
    func answerWith(_ at: @escaping @Sendable ([String: Any]) -> DocumentAt?, created: UUID? = nil)
    {
        answer = { [weak self] request in
            guard let next = at(request) else {
                return [
                    "id": request["id"] ?? "", "status": "ok",
                    "data": ["seq": 0, "changed": false],
                ]
            }
            self?.push(next)
            var report: [String: Any] = ["seq": next.seq, "changed": true]
            if let created { report["pane_created"] = created.uuidString.lowercased() }
            return ["id": request["id"] ?? "", "status": "ok", "data": report]
        }
    }
}

/// Small documents for the tests, built the way benchd would write them.
enum BenchFixture {
    static func terminal(_ id: UUID = UUID()) -> BenchDocument.Pane {
        .init(id: id, surface: .terminal(agent: nil))
    }

    static func bench(_ panes: [BenchDocument.Pane], selected: UUID? = nil) -> BenchDocument.Bench {
        let slot = UUID()
        return BenchDocument.Bench(
            columns: [
                .init(
                    id: UUID(),
                    slots: [
                        .init(id: slot, panes: panes, selected: selected ?? panes[0].id, height: 1)
                    ],
                    width: 1)
            ],
            focusedSlot: slot)
    }

    static func document(
        _ path: String, _ bench: BenchDocument.Bench, seq: UInt64,
        others: [BenchDocument.Workspace] = []
    ) -> DocumentAt {
        DocumentAt(
            seq: seq,
            document: BenchDocument(
                workspaces: [.init(path: path, bench: bench)] + others, active: path))
    }
}
