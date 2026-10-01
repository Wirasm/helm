import Combine
import Foundation

/// A replacement for native Chrome popups that are absent from streamed page frames.
@MainActor
final class BrowserFormPicker: ObservableObject {
    struct Option: Decodable, Equatable {
        let index: Int
        let label: String
        let value: String
        let disabled: Bool
    }

    enum Control: Decodable, Equatable {
        case select(options: [Option], selectedIndex: Int)
        case date(value: String, min: String, max: String)

        private enum Keys: String, CodingKey { case kind, options, selectedIndex, value, min, max }
        private enum Kind: String, Decodable { case select, date }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .select:
                self = .select(
                    options: try c.decode([Option].self, forKey: .options),
                    selectedIndex: try c.decode(Int.self, forKey: .selectedIndex))
            case .date:
                self = .date(
                    value: try c.decode(String.self, forKey: .value),
                    min: try c.decode(String.self, forKey: .min),
                    max: try c.decode(String.self, forKey: .max))
            }
        }
    }

    struct Pick: Identifiable {
        let id = UUID()
        let control: Control
        fileprivate let element: Element
    }

    @Published private(set) var current: Pick?
    @Published private(set) var failure: String?
    @Published private(set) var highlighted = -1

    fileprivate struct Element {
        let connection: CDPConnection
        let session: String
        let object: String
    }

    /// A plain left press resolves its hit target; keyboard opening resolves the focused leaf.
    /// Capturing the control keeps the answer tied to this element, not a later click.
    func open(
        at point: CGPoint?, connection: CDPConnection, session: String, isCurrent: () -> Bool
    ) async throws -> Bool {
        var captured: Element?
        do {
            guard
                let resolved = try await resolve(
                    at: point, connection: connection, session: session)
            else { return false }
            let object = resolved.control
            defer {
                connection.send(
                    "Runtime.releaseObject", ObjectID(objectId: resolved.hit), session: session)
            }
            let held = Element(connection: connection, session: session, object: object)
            captured = held
            guard isCurrent() else { release(held); return true }
            if point != nil {
                let activation = try await connection.call(
                    "Runtime.callFunctionOn",
                    Function(
                        objectId: resolved.hit, functionDeclaration: BrowserFormScript.activate,
                        arguments: [.object(object)]),
                    session: session, returning: ValueReply<Bool>.self)
                guard activation.result.value == true else { release(held); return true }
            }
            guard isCurrent() else { release(held); return true }
            let reply = try await connection.call(
                "Runtime.callFunctionOn",
                Function(objectId: object, functionDeclaration: BrowserFormScript.read),
                session: session, returning: ValueReply<Control>.self)
            guard isCurrent(), let control = reply.result.value else {
                release(held)
                return true
            }
            if point == nil, case .date = control { release(held); return false }
            dismiss()
            current = Pick(control: control, element: held)
            if case let .select(_, selected) = control { highlighted = selected }
            return true
        } catch {
            if let captured {
                release(captured)
                throw error
            }
            return false
        }
    }

    private func resolve(
        at point: CGPoint?, connection: CDPConnection, session: String
    )
        async throws -> (control: String, hit: String)?
    {
        let object: String?
        if let point {
            let node = try await connection.call(
                "DOM.getNodeForLocation", Location(x: Int(point.x), y: Int(point.y)),
                session: session, returning: Node.self)
            let resolved = try await connection.call(
                "DOM.resolveNode", Resolve(backendNodeId: node.backendNodeId),
                session: session, returning: Resolved.self)
            object = resolved.object.objectId
        } else {
            object = try await BrowserFocusedElement.resolve(
                connection: connection, session: session)
        }
        guard let object else { return nil }
        do {
            let control = try await connection.call(
                "Runtime.callFunctionOn",
                Function(
                    objectId: object, functionDeclaration: BrowserFormScript.control,
                    returnByValue: false),
                session: session, returning: ObjectReply.self)
            if let captured = control.result.objectId { return (captured, object) }
        } catch {
            connection.send("Runtime.releaseObject", ObjectID(objectId: object), session: session)
            throw error
        }
        connection.send("Runtime.releaseObject", ObjectID(objectId: object), session: session)
        return nil
    }

    func dismiss() {
        if let current { release(current.element) }
        current = nil
        failure = nil
        highlighted = -1
    }

    private func release(_ element: Element) {
        element.connection.send(
            "Runtime.releaseObject", ObjectID(objectId: element.object), session: element.session)
    }

    func choose(index: Int) async {
        guard case let .select(options, _) = current?.control,
            let option = options.first(where: { $0.index == index })
        else { return }
        await commit(.init(index: index, value: option.value, label: option.label))
    }
    func choose(date: String) async { await commit(.init(index: nil, value: date, label: nil)) }

    private func commit(_ answer: Answer) async {
        guard let pick = current else { return }
        let held = pick.element
        do {
            let result = try await held.connection.call(
                "Runtime.callFunctionOn",
                Function(
                    objectId: held.object, functionDeclaration: BrowserFormScript.commit,
                    arguments: [.answer(answer)]),
                session: held.session, returning: ValueReply<String>.self)
            guard current?.id == pick.id else { return }
            if result.result.value == "ok" {
                dismiss()
            } else {
                failure = result.result.value ?? "The page could not change this field."
            }
        } catch {
            guard current?.id == pick.id else { return }
            failure = "The page could not change this field: \(error)"
        }
    }

    /// The surface can keep the keyboard while a select is open. Keyboard and pointer choices
    /// use the same commit; a date calendar handles its own AppKit keys.
    func key(_ event: BrowserPaneModel.KeyEvent) async {
        guard event.type != "keyUp" else { return }
        if event.key == "Escape" { dismiss(); return }
        guard case let .select(options, _) = current?.control else { return }
        switch event.key {
        case "ArrowDown", "ArrowUp":
            let enabled = options.filter { !$0.disabled }.map(\.index)
            guard !enabled.isEmpty else { return }
            let at = enabled.firstIndex(of: highlighted) ?? -1
            let next = max(0, min(enabled.count - 1, at + (event.key == "ArrowDown" ? 1 : -1)))
            highlighted = enabled[next]
        case "Enter", " ": await choose(index: highlighted)
        default: break
        }
    }
}

private struct Location: Encodable { let x: Int; let y: Int }
private struct Node: Decodable { let backendNodeId: Int }
private struct Resolve: Encodable { let backendNodeId: Int }
private struct ObjectID: Encodable { let objectId: String }
private struct RemoteObject: Decodable { let objectId: String? }
private struct Resolved: Decodable { let object: RemoteObject }
private struct ObjectReply: Decodable { let result: RemoteObject }
private struct Answer: Encodable { let index: Int?; let value: String?; let label: String? }
private enum Argument: Encodable {
    case answer(Answer)
    case object(String)

    private enum Keys: String, CodingKey { case value, objectId }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .answer(value): try container.encode(value, forKey: .value)
        case let .object(id): try container.encode(id, forKey: .objectId)
        }
    }
}
private struct Function: Encodable {
    let objectId: String
    let functionDeclaration: String
    var arguments: [Argument]? = nil
    var returnByValue = true
}
private struct ValueReply<Value: Decodable>: Decodable {
    struct Remote: Decodable { let value: Value? }
    let result: Remote
}
