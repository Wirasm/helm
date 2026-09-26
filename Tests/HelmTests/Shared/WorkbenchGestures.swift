import Foundation
import HelmWire

@testable import Helm

/// The bench's gestures, spelled as what they do ("split right", "open this file"), and each one a
/// verb sent through `send` with the actor it stands for: the operator's gestures, and the
/// offering ones an agent's. What comes back is whatever benchd — in a test, the toy
/// (`ToyBench`) — made of it.
@MainActor
extension WorkbenchModel {
    @discardableResult
    func newTerminal() -> TerminalSession? {
        session(send(.paneOpen(surface: .terminal(agent: nil)), by: .operatorGesture))
    }

    @discardableResult
    func spawnTerminal() -> TerminalSession? {
        session(send(.paneOpen(surface: .terminal(agent: nil)), by: .agent()))
    }

    @discardableResult
    func splitRight() -> TerminalSession? {
        session(send(.paneSplit(direction: .right), by: .operatorGesture))
    }

    @discardableResult
    func splitDown() -> TerminalSession? {
        session(send(.paneSplit(direction: .down), by: .operatorGesture))
    }

    @discardableResult
    func offerSplitRight() -> TerminalSession? {
        session(send(.paneSplit(direction: .right), by: .agent()))
    }

    @discardableResult
    func offerSplitDown() -> TerminalSession? {
        session(send(.paneSplit(direction: .down), by: .agent()))
    }

    @discardableResult
    func open(_ source: CanvasSource) -> Pane.ID? {
        send(.paneOpen(surface: .canvas(path: source.fileURL.path)), by: .operatorGesture)
    }

    @discardableResult
    func offer(_ source: CanvasSource) -> Pane.ID? {
        send(.paneOpen(surface: .canvas(path: source.fileURL.path)), by: .agent())
    }

    @discardableResult
    func offerBrowser() -> Pane.ID? {
        send(.paneOpen(surface: .browser), by: .agent())
    }

    func close(_ pane: Pane.ID) {
        send(.paneClose(pane), by: .operatorGesture)
    }

    func select(_ pane: Pane.ID) {
        send(.paneShow(pane), by: .operatorGesture)
    }

    /// Whether the pane is on screen afterwards, which is what the spool reports.
    @discardableResult
    func offerSelect(_ pane: Pane.ID) -> Bool {
        send(.paneShow(pane), by: .agent())
        return bench?.visiblePaneIDs.contains(pane) ?? false
    }

    /// What the pane was called before, or nil when the bench has no such pane.
    @discardableResult
    func name(_ pane: Pane.ID, to name: PaneName) -> PaneName? {
        guard let previous = bench?.pane(pane)?.name else { return nil }
        send(.paneName(pane, name), by: .agent())
        return previous
    }

    func focus(_ slot: Slot.ID) {
        send(.focusSlot(slot), by: .operatorGesture)
    }

    func resizeColumn(_ column: Column.ID, to fraction: Double, against neighbour: Column.ID) {
        send(
            .layoutResize(.columns(member: column, against: neighbour), fraction: fraction),
            by: .operatorGesture)
    }

    func resizeSlot(_ slot: Slot.ID, to fraction: Double, against neighbour: Slot.ID) {
        send(
            .layoutResize(.slots(member: slot, against: neighbour), fraction: fraction),
            by: .operatorGesture)
    }

    func moveFocus(_ direction: BenchDirection) {
        send(.focusStep(direction: direction), by: .operatorGesture)
    }

    private func session(_ pane: Pane.ID?) -> TerminalSession? {
        pane.flatMap { id in bench?.pane(id) }.flatMap(session(for:))
    }
}
