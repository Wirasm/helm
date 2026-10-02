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
        let frames: BrowserFrameResolver
        let target: BrowserFrameResolver.Object
    }

    private var resolving: BrowserFrameResolver?

    func invalidated(by event: CDPConnection.Event) -> Bool {
        resolving?.invalidated(by: event) == true
    }

    /// A plain left press resolves its hit target; keyboard opening resolves the focused leaf.
    /// Capturing the control keeps the answer tied to this element, not a later click.
    func open(
        at point: CGPoint?, connection: CDPConnection, session: String, isCurrent: () -> Bool
    ) async throws -> Bool {
        dismiss()
        let frames = BrowserFrameResolver(connection: connection, session: session)
        resolving = frames
        defer {
            if current?.element.frames !== frames {
                frames.close()
                if resolving === frames { resolving = nil }
            }
        }
        var captured: Element?
        do {
            guard let resolved = try await resolve(at: point, frames: frames) else { return false }
            defer { frames.release(resolved.hit) }
            let held = Element(frames: frames, target: resolved.control)
            captured = held
            guard
                let control = try await read(
                    held, hit: resolved.hit, pointer: point != nil, isCurrent: isCurrent)
            else { release(held); return true }
            if point == nil, case .date = control { release(held); return false }
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

    private func read(
        _ held: Element, hit: BrowserFrameResolver.Object, pointer: Bool, isCurrent: () -> Bool
    ) async throws -> Control? {
        guard isCurrent() else { return nil }
        try await held.frames.retainDocumentPath(of: held.target)
        guard isCurrent() else { return nil }
        let connection = held.frames.connection
        let object = held.target.id
        let session = held.target.session
        if pointer {
            let activation = try await connection.call(
                "Runtime.callFunctionOn",
                Function(
                    objectId: hit.id, functionDeclaration: BrowserFormScript.activate,
                    arguments: [.object(object)]),
                session: session, returning: ValueReply<Bool>.self)
            guard activation.result.value == true else { return nil }
        }
        guard isCurrent() else { return nil }
        let reply = try await connection.call(
            "Runtime.callFunctionOn",
            Function(objectId: object, functionDeclaration: BrowserFormScript.read),
            session: session, returning: ValueReply<Control>.self)
        return isCurrent() ? reply.result.value : nil
    }

    private func resolve(
        at point: CGPoint?, frames: BrowserFrameResolver
    ) async throws
        -> (control: BrowserFrameResolver.Object, hit: BrowserFrameResolver.Object)?
    {
        guard let hit = try await frames.resolve(at: point) else { return nil }
        do {
            let control = try await frames.connection.call(
                "Runtime.callFunctionOn",
                Function(
                    objectId: hit.id, functionDeclaration: BrowserFormScript.control,
                    returnByValue: false),
                session: hit.session, returning: ObjectReply.self)
            if let captured = control.result.objectId {
                return (.init(session: hit.session, id: captured), hit)
            }
        } catch {
            frames.release(hit)
            throw error
        }
        frames.release(hit)
        return nil
    }

    func dismiss() {
        if let current { release(current.element) }
        current = nil
        resolving?.close()
        resolving = nil
        failure = nil
        highlighted = -1
    }

    private func release(_ element: Element) {
        element.frames.release(element.target)
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
            let result = try await held.frames.connection.call(
                "Runtime.callFunctionOn",
                Function(
                    objectId: held.target.id, functionDeclaration: BrowserFormScript.commit,
                    arguments: [.answer(answer)]),
                session: held.target.session, returning: ValueReply<String>.self)
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

private struct RemoteObject: Decodable { let objectId: String? }
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
