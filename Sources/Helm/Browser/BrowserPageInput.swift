import Foundation

/// The ordered input stream. A control hit test or clipboard write may await CDP; later keys
/// and mouse releases must wait too, and must not migrate to a different tab while they wait.
@MainActor
final class BrowserPageInput {
    enum Event {
        case mouse(BrowserPaneModel.MouseEvent)
        case key(BrowserPaneModel.KeyEvent)
        case text(String)
        case composition(BrowserComposition)
        case paste(BrowserPaste)
    }

    struct Destination {
        let connection: CDPConnection
        let session: String
    }

    let forms = BrowserFormPicker()
    var isCurrent: (Destination) -> Bool = { _ in false }
    var failed: (String) -> Void = { _ in }
    private var pending: [(Event, Destination)] = []
    private var draining = false
    private var revision = 0
    private var swallowedPress = false

    func send(_ event: Event, to destination: Destination) {
        pending.append((event, destination))
        guard !draining else { return }
        draining = true
        let generation = revision
        Task {
            while revision == generation, !pending.isEmpty {
                let (event, destination) = pending.removeFirst()
                guard isCurrent(destination) else { continue }
                await deliver(event, to: destination, revision: generation)
            }
            if revision == generation { draining = false }
        }
    }

    func reset() {
        pending.removeAll()
        revision += 1
        // A dialog can suspend an old CDP call until its page is answered. New tabs must
        // drain independently; the old generation can neither take nor stop their input.
        draining = false
        swallowedPress = false
        forms.dismiss()
    }

    private func current(_ dest: Destination, revision: Int) -> Bool {
        self.revision == revision && isCurrent(dest)
    }

    private func deliver(_ event: Event, to dest: Destination, revision: Int) async {
        if case let .mouse(mouse) = event, mouse.type == "mouseReleased", swallowedPress {
            swallowedPress = false
            return
        }
        if forms.current != nil {
            if case let .key(key) = event { await forms.key(key) }
            if case let .mouse(mouse) = event, mouse.type == "mousePressed" {
                forms.dismiss()
                swallowedPress = true
            }
            return
        }
        switch event {
        case let .mouse(mouse):
            if mouse.type == "mousePressed", mouse.button == "left", mouse.modifiers == 0,
                await open(at: CGPoint(x: mouse.x, y: mouse.y), to: dest, revision: revision)
            {
                if current(dest, revision: revision) { swallowedPress = true }
                return
            }
            guard current(dest, revision: revision) else { return }
            dest.connection.send("Input.dispatchMouseEvent", mouse, session: dest.session)
        case let .key(key):
            if key.type != "keyUp", [" ", "ArrowDown"].contains(key.key),
                await open(at: nil, to: dest, revision: revision)
            {
                return
            }
            guard current(dest, revision: revision) else { return }
            dest.connection.send("Input.dispatchKeyEvent", key, session: dest.session)
        case let .text(text):
            dest.connection.send("Input.insertText", Text(text: text), session: dest.session)
        case let .composition(composition):
            dest.connection.send("Input.imeSetComposition", composition, session: dest.session)
        case let .paste(payload):
            await paste(payload, to: dest, revision: revision)
        }
    }

    private func open(at point: CGPoint?, to dest: Destination, revision: Int) async -> Bool {
        do {
            return try await forms.open(
                at: point, connection: dest.connection, session: dest.session,
                isCurrent: { self.current(dest, revision: revision) })
        } catch {
            if current(dest, revision: revision) {
                failed("The page could not open this picker: \(error)")
            }
            return true
        }
    }

    private func paste(_ payload: BrowserPaste, to dest: Destination, revision: Int) async {
        do {
            var outcome = try await dest.connection.call(
                "Runtime.evaluate", PasteEvaluation(expression: try payload.expression()),
                session: dest.session, returning: PasteReply.self)
            guard current(dest, revision: revision) else { return }
            if outcome.result.value == "fallback" {
                guard
                    let object = try await BrowserFocusedElement.resolve(
                        connection: dest.connection, session: dest.session)
                else { failed("The page has no focused paste target."); return }
                defer {
                    BrowserFocusedElement.release(
                        object, connection: dest.connection, session: dest.session)
                }
                guard current(dest, revision: revision) else { return }
                outcome = try await dest.connection.call(
                    "Runtime.callFunctionOn",
                    PasteFunction(
                        objectId: object, functionDeclaration: try payload.fallbackFunction()),
                    session: dest.session, returning: PasteReply.self)
                guard current(dest, revision: revision) else { return }
            }
            if let error = outcome.exceptionDetails {
                failed("The page could not paste: \(error.text)")
                return
            }
            switch outcome.result.value {
            case "native":
                var key = BrowserPaneModel.KeyEvent(
                    type: "rawKeyDown", modifiers: BrowserModifiers.meta.rawValue, key: "v",
                    code: "KeyV", windowsVirtualKeyCode: 86, commands: ["paste"])
                try await dest.connection.call("Input.dispatchKeyEvent", key, session: dest.session)
                key = .init(
                    type: "keyUp", modifiers: BrowserModifiers.meta.rawValue, key: "v",
                    code: "KeyV", windowsVirtualKeyCode: 86)
                dest.connection.send("Input.dispatchKeyEvent", key, session: dest.session)
            case "text":
                if let text = payload.text {
                    dest.connection.send(
                        "Input.insertText", Text(text: text), session: dest.session)
                }
            case "handled": break
            default: failed("The page did not acknowledge the paste.")
            }
        } catch {
            if current(dest, revision: revision) { failed("The page could not paste: \(error)") }
        }
    }
}

private struct Text: Encodable { let text: String }
private struct PasteEvaluation: Encodable {
    let expression: String
    var returnByValue = true
    var awaitPromise = true
    var userGesture = true
}
private struct PasteFunction: Encodable {
    let objectId: String
    let functionDeclaration: String
    var returnByValue = true
}
private struct PasteReply: Decodable {
    struct Remote: Decodable { let value: String? }
    struct Exception: Decodable { let text: String }
    let result: Remote
    let exceptionDetails: Exception?
}
