import Foundation

/// Resolve keyboard focus through same-origin documents and open/closed shadow roots.
/// The caller owns the returned CDP object. No child target is attached here.
@MainActor
enum BrowserFocusedElement {
    static func resolve(connection: CDPConnection, session: String) async throws -> String? {
        let reply = try await connection.call(
            "Runtime.evaluate",
            Evaluate(expression: "document.activeElement", returnByValue: false),
            session: session, returning: ObjectReply.self)
        var held = reply.result.objectId
        do {
            while let object = held {
                let description = try await connection.call(
                    "DOM.describeNode", ObjectID(objectId: object), session: session,
                    returning: Description.self)
                guard
                    let root = description.node.contentDocument
                        ?? description.node.shadowRoots?.first
                else { return object }
                let resolved = try await connection.call(
                    "DOM.resolveNode", Resolve(backendNodeId: root.backendNodeId),
                    session: session, returning: Resolved.self)
                guard let rootObject = resolved.object.objectId else { return object }
                defer { release(rootObject, connection: connection, session: session) }
                let inner = try await connection.call(
                    "Runtime.callFunctionOn",
                    Focus(objectId: rootObject), session: session, returning: ObjectReply.self)
                guard let focused = inner.result.objectId else { return object }
                release(object, connection: connection, session: session)
                held = focused
            }
            return nil
        } catch {
            if let held { release(held, connection: connection, session: session) }
            throw error
        }
    }

    static func release(_ object: String, connection: CDPConnection, session: String) {
        connection.send("Runtime.releaseObject", ObjectID(objectId: object), session: session)
    }
}

private struct ObjectID: Encodable { let objectId: String }
private struct Resolve: Encodable { let backendNodeId: Int }
private struct RemoteObject: Decodable { let objectId: String? }
private struct ObjectReply: Decodable { let result: RemoteObject }
private struct Resolved: Decodable { let object: RemoteObject }
private struct Description: Decodable {
    struct Root: Decodable { let backendNodeId: Int }
    struct Node: Decodable { let contentDocument: Root?; let shadowRoots: [Root]? }
    let node: Node
}
private struct Focus: Encodable {
    let objectId: String
    var functionDeclaration = "function() { return this.activeElement; }"
}
