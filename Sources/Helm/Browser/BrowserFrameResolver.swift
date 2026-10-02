import Foundation

/// Attach only along one picker gesture's OOPIF path. Objects never lose their owning session.
@MainActor
final class BrowserFrameResolver {
    enum Invalidation: Error { case frameChanged }

    struct Object {
        let session: String
        let id: String
    }

    let connection: CDPConnection
    private let root: String
    private var children: [String: String] = [:]
    private var framePath: Set<String> = []
    private enum Capture { case resolving(Set<String>), resolved }
    private var capture = Capture.resolving([])
    private var closed = false

    init(connection: CDPConnection, session: String) {
        self.connection = connection
        root = session
    }

    func close() {
        closed = true
        for session in children.keys {
            connection.send("Target.detachFromTarget", Detach(sessionId: session))
        }
        children.removeAll()
        framePath.removeAll()
        capture = .resolved
    }

    func invalidated(by event: CDPConnection.Event) -> Bool {
        switch event.method {
        case "Page.frameNavigated":
            return changed(event.params(Navigation.self)?.frame.id, session: event.sessionId)
        case "Page.frameDetached":
            return changed(event.params(FrameDetached.self)?.frameId, session: event.sessionId)
        case "Target.detachedFromTarget":
            guard let detached = event.params(Detach.self) else { return false }
            return children[detached.sessionId] != nil
        case "Target.targetDestroyed":
            guard let gone = event.params(TargetGone.self) else { return false }
            return children.values.contains(gone.targetId)
        default: return false
        }
    }

    private func owns(_ session: String?) -> Bool {
        session == root || session.map { children[$0] != nil } == true
    }

    private func changed(_ frame: String?, session: String?) -> Bool {
        guard let frame, owns(session) else { return false }
        if framePath.contains(frame) { return true }
        if case .resolving(var changes) = capture {
            changes.insert(frame)
            capture = .resolving(changes)
        }
        return false
    }

    private var changedDuringCapture: Bool {
        if case let .resolving(changes) = capture { return !changes.isEmpty }
        return false
    }

    private func retain(_ frame: String) throws -> Bool {
        if case let .resolving(changes) = capture, changes.contains(frame) {
            throw Invalidation.frameChanged
        }
        return framePath.insert(frame).inserted
    }

    /// Several same-origin documents share a session. Retain only this object's document path.
    private func retainDocumentPath(of object: Object) async throws {
        var held = try await connection.call(
            "Runtime.callFunctionOn",
            DocumentRoot(
                objectId: object.id,
                functionDeclaration:
                    "function() { return (this.nodeType === 9 ? this : this.ownerDocument).documentElement; }"
            ),
            session: object.session, returning: ObjectReply.self
        ).result.objectId
        guard held != nil else {
            throw CDPConnection.Failure(message: "The picker document no longer has a frame.")
        }
        while let id = held {
            defer { release(Object(session: object.session, id: id)) }
            guard !closed else { return }
            let description = try await connection.call(
                "DOM.describeNode", ObjectID(objectId: id), session: object.session,
                returning: Description.self)
            guard let frame = description.node.frameId else {
                throw CDPConnection.Failure(message: "The picker document no longer has a frame.")
            }
            guard try retain(frame) else { return }
            held = try await connection.call(
                "Runtime.callFunctionOn",
                DocumentRoot(
                    objectId: id,
                    functionDeclaration:
                        "function() { return this.ownerDocument.defaultView?.frameElement?.ownerDocument.documentElement; }"
                ),
                session: object.session, returning: ObjectReply.self
            ).result.objectId
        }
    }

    func resolve(at point: CGPoint?) async throws -> Object? {
        do {
            let object = try await resolvePath(at: point)
            if object == nil, changedDuringCapture { throw Invalidation.frameChanged }
            return object
        } catch {
            // A lost context cannot complete ownership. Its pending generation must not fall through.
            if changedDuringCapture { throw Invalidation.frameChanged }
            throw error
        }
    }

    private func resolvePath(at point: CGPoint?) async throws -> Object? {
        var session = root
        var point = point
        while !closed {
            guard let object = try await object(at: point, session: session) else { return nil }
            var returned = false
            defer { if !returned { release(object) } }
            let description = try await connection.call(
                "DOM.describeNode", ObjectID(objectId: object.id), session: session,
                returning: Description.self)
            guard description.node.nodeName == "IFRAME",
                description.node.contentDocument == nil, let frame = description.node.frameId
            else {
                try await retainDocumentPath(of: object)
                capture = .resolved
                returned = true
                return object
            }
            _ = try retain(frame)
            try await retainDocumentPath(of: object)
            let child = try await attach(frame)
            guard !closed else { return nil }
            if let parentPoint = point {
                point = try await translate(parentPoint, owner: object, child: child)
                guard point != nil else { return nil }
            }
            session = child
        }
        return nil
    }

    private func object(at point: CGPoint?, session: String) async throws -> Object? {
        let id: String?
        if let point {
            // Hit tests take document coordinates; incoming points and box quads use viewport CSS pixels.
            let viewport = try await layout(session)
            let hit = try await connection.call(
                "DOM.getNodeForLocation",
                Location(
                    x: Int((point.x + viewport.pageX).rounded()),
                    y: Int((point.y + viewport.pageY).rounded())),
                session: session, returning: Hit.self)
            let resolved = try await connection.call(
                "DOM.resolveNode", Resolve(backendNodeId: hit.backendNodeId), session: session,
                returning: Resolved.self)
            id = resolved.object.objectId
        } else {
            id = try await BrowserFocusedElement.resolve(connection: connection, session: session)
        }
        return id.map { Object(session: session, id: $0) }
    }

    private func attach(_ frame: String) async throws -> String {
        let attached = try await connection.call(
            "Target.attachToTarget", Attach(targetId: frame), returning: Attached.self)
        guard !closed else {
            connection.send("Target.detachFromTarget", Detach(sessionId: attached.sessionId))
            return attached.sessionId
        }
        children[attached.sessionId] = frame
        try await connection.call("Page.enable", session: attached.sessionId)
        return attached.sessionId
    }

    private func translate(_ point: CGPoint, owner: Object, child: String) async throws -> CGPoint?
    {
        let box = try await connection.call(
            "DOM.getBoxModel", ObjectID(objectId: owner.id), session: owner.session,
            returning: Box.self)
        let viewport = try await layout(child)
        return BrowserFrameQuad(box.model.content)?.local(
            point, size: CGSize(width: viewport.clientWidth, height: viewport.clientHeight))
    }

    private func layout(_ session: String) async throws -> Viewport {
        try await connection.call("Page.getLayoutMetrics", session: session, returning: Layout.self)
            .cssLayoutViewport
    }

    func release(_ object: Object) {
        BrowserFocusedElement.release(object.id, connection: connection, session: object.session)
    }
}

private struct Attach: Encodable { let targetId: String; var flatten = true }
private struct Attached: Decodable { let sessionId: String }
private struct Detach: Codable { let sessionId: String }
private struct TargetGone: Decodable { let targetId: String }
private struct Navigation: Decodable {
    struct Frame: Decodable { let id: String }
    let frame: Frame
}
private struct FrameDetached: Decodable { let frameId: String }
private struct ObjectID: Encodable { let objectId: String }
private struct DocumentRoot: Encodable {
    let objectId: String
    let functionDeclaration: String
}
private struct ObjectReply: Decodable { let result: Resolved.Remote }
private struct Resolve: Encodable { let backendNodeId: Int }
private struct Hit: Decodable { let backendNodeId: Int }
private struct Location: Encodable {
    let x: Int
    let y: Int
    var includeUserAgentShadowDOM = true
}
private struct Resolved: Decodable {
    struct Remote: Decodable { let objectId: String? }
    let object: Remote
}
private struct Description: Decodable {
    struct Document: Decodable {}
    struct Node: Decodable {
        let nodeName: String
        let frameId: String?
        let contentDocument: Document?
    }
    let node: Node
}
private struct Box: Decodable {
    struct Model: Decodable { let content: [Double] }
    let model: Model
}
private struct Layout: Decodable { let cssLayoutViewport: Viewport }
private struct Viewport: Decodable {
    let pageX: Double
    let pageY: Double
    let clientWidth: Double
    let clientHeight: Double
}
