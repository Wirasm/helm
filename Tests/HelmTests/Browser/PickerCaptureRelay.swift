import Darwin
import Foundation

/// Scripted CDP phases for a held document-root lookup, not a browser implementation.
final class PickerCaptureRelay: @unchecked Sendable {
    enum Hit { case localControl, processFrameOwner }
    struct Commit: Equatable { let object: String; let session: String?; let index: Int? }

    private let condition = NSCondition()
    private let hit: Hit
    private var socket: Int32?
    private var stopped = false
    private var finished = false
    private var held: Call?
    private var didHold = false
    private var inserted: [String] = []
    private var chosen: [Commit] = []

    init(hit: Hit) { self.hit = hit }

    var waiting: Bool { condition.withLock { held != nil } }
    var texts: [String] { condition.withLock { inserted } }
    var commits: [Commit] { condition.withLock { chosen } }

    func serve(_ fd: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        var noPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        condition.withLock { socket = fd }
        defer {
            condition.withLock {
                close(fd)
                socket = nil
                finished = true
                condition.broadcast()
            }
        }
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, !condition.withLock({ stopped }) {
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[..<count])
            while let end = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<end])
                buffer = Data(buffer[buffer.index(after: end)...])
                do {
                    let call = try JSONDecoder().decode(Call.self, from: line)
                    try condition.withLock { try answer(call, on: fd) }
                } catch { return }
            }
        }
    }

    @discardableResult
    func stop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        stopped = true
        if let socket { shutdown(socket, SHUT_RDWR) }
        let deadline = Date().addingTimeInterval(2)
        while !finished, socket != nil {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    /// The event and held reply share one write order, making the interleaving deterministic.
    func resume(method: String, frame: String, failing: Bool) throws {
        try condition.withLock {
            guard let socket, let held else { throw Failure.phase }
            if method == "Page.frameNavigated" {
                try send(
                    socket,
                    Event(
                        method: method,
                        params: Navigation(frame: .init(id: frame, parentId: "main"))))
            } else {
                try send(socket, Event(method: method, params: Detachment(frameId: frame)))
            }
            self.held = nil
            if failing {
                try send(
                    socket,
                    Failed(
                        id: held.id,
                        error: .init(code: -32000, message: "Execution context was destroyed")))
            } else {
                try send(
                    socket,
                    Reply(
                        id: held.id,
                        result: Remote(result: .init(objectId: document(for: held.params.objectId)))
                    ))
            }
        }
    }

    private func answer(_ call: Call, on fd: Int32) throws {
        switch call.method {
        case "Runtime.callFunctionOn": try function(call, on: fd)
        case "DOM.getNodeForLocation":
            try send(fd, Reply(id: call.id, result: Backend(backendNodeId: 1)))
        case "DOM.resolveNode":
            try send(
                fd,
                Reply(
                    id: call.id,
                    result: Resolved(
                        object: .init(objectId: hit == .localControl ? "hit" : "owner"))))
        case "DOM.describeNode":
            try send(
                fd, Reply(id: call.id, result: Description(node: describe(call.params.objectId))))
        case "Page.getLayoutMetrics":
            try send(fd, Reply(id: call.id, result: Layout(cssLayoutViewport: .init())))
        case "Input.insertText":
            inserted.append(call.params.text ?? "")
            try send(fd, Reply(id: call.id, result: Empty()))
        default: try send(fd, Reply(id: call.id, result: Empty()))
        }
    }

    private func function(_ call: Call, on fd: Int32) throws {
        // Document-root calls omit returnByValue; classification explicitly requests false.
        if call.params.returnByValue == nil {
            if !didHold { didHold = true; held = call; return }
            try send(
                fd,
                Reply(
                    id: call.id,
                    result: Remote(result: .init(objectId: document(for: call.params.objectId)))))
        } else if call.params.returnByValue == false {
            try send(fd, Reply(id: call.id, result: Remote(result: .init(objectId: "control"))))
        } else if let answer = call.params.arguments?.first?.value {
            chosen.append(
                .init(
                    object: call.params.objectId ?? "", session: call.sessionId, index: answer.index
                ))
            try send(fd, Reply(id: call.id, result: Value(result: .init(value: "ok"))))
        } else if call.params.objectId == "control" {
            try send(fd, Reply(id: call.id, result: Value(result: .init(value: Select()))))
        } else {
            try send(fd, Reply(id: call.id, result: Value(result: .init(value: true))))
        }
    }

    private func document(for object: String?) -> String? {
        switch object {
        case "hit", "control": "owned-document"
        case "owned-document": "ancestor-document"
        case "ancestor-document", "owner": "main-document"
        default: nil
        }
    }

    private func describe(_ object: String?) -> Node {
        switch object {
        case "owner": .init(nodeName: "IFRAME", frameId: "child")
        case "owned-document": .init(nodeName: "HTML", frameId: "owned")
        case "ancestor-document": .init(nodeName: "HTML", frameId: "ancestor")
        case "main-document": .init(nodeName: "HTML", frameId: "main")
        default: .init(nodeName: "SELECT", frameId: nil)
        }
    }

    private func send(_ fd: Int32, _ message: some Encodable) throws {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress! + sent, bytes.count - sent, 0)
                guard count > 0 else { throw Failure.socket }
                sent += count
            }
        }
    }

    private enum Failure: Error { case phase, socket }
    private struct Call: Decodable {
        let id: Int; let method: String; let sessionId: String?; let params: Params
    }
    private struct Params: Decodable {
        let objectId: String?
        let returnByValue: Bool?
        let text: String?
        let arguments: [Argument]?
    }
    private struct Argument: Decodable { let value: Answer? }
    private struct Answer: Decodable { let index: Int? }
    private struct Reply<Result: Encodable>: Encodable { let id: Int; let result: Result }
    private struct Failed: Encodable {
        struct Error: Encodable { let code: Int; let message: String }
        let id: Int
        let error: Error
    }
    private struct Event<Params: Encodable>: Encodable {
        let method: String
        let params: Params
        var sessionId = "root"
    }
    private struct Navigation: Encodable {
        struct Frame: Encodable { let id: String; let parentId: String }
        let frame: Frame
    }
    private struct Detachment: Encodable { let frameId: String }
    private struct Empty: Encodable {}
    private struct Backend: Encodable { let backendNodeId: Int }
    private struct Object: Encodable { let objectId: String? }
    private struct Remote: Encodable { let result: Object }
    private struct Resolved: Encodable { let object: Object }
    private struct Description: Encodable { let node: Node }
    private struct Node: Encodable { let nodeName: String; let frameId: String? }
    private struct Layout: Encodable { let cssLayoutViewport: Viewport }
    private struct Viewport: Encodable {
        var pageX = 0; var pageY = 0; var clientWidth = 800; var clientHeight = 500
    }
    private struct Value<T: Encodable>: Encodable {
        struct Result: Encodable { let value: T }
        let result: Result
    }
    private struct Select: Encodable {
        struct Option: Encodable {
            let index: Int; let label: String; let value: String; var disabled = false
        }
        var kind = "select"
        var selectedIndex = 0
        var options = [
            Option(index: 0, label: "First", value: "first"),
            Option(index: 1, label: "Second", value: "second"),
        ]
    }
}
