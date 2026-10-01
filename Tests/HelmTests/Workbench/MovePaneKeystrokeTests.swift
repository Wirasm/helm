import HelmWire
import XCTest

@testable import Helm

// MARK: - The keystroke

/// The route from ⌘⌥⇧arrow to `pane/move` (#287). Where the pane lands is benchd's
/// (`bench-doc`'s `move_pane.rs`, which mirrors the value tests this file used to hold); this is
/// helm's half — the key, the menu row, and the verb it sends. No window and no ghostty surface,
/// so nothing here is subject to #253.
@MainActor
final class MovePaneKeystrokeTests: XCTestCase {

    /// The table's half. ⌘⌥arrow is focus, ⌘⌥⇧arrow is the pane — one keystroke apart, which
    /// is the gesture's whole claim to being learnable.
    func testShiftTurnsTheFocusBindingIntoAPaneMove() {
        for (keyCode, direction) in [
            (UInt16(123), BenchDirection.left), (124, .right), (126, .up), (125, .down),
        ] {
            XCTAssertEqual(
                KeyBindings.match(
                    characters: nil, keyCode: keyCode, modifiers: [.command, .option, .shift],
                    focus: .terminal, in: KeyBindings.all)?.action,
                .verb(.moveFocused(direction)),
                "⇧⌥⌘ keyCode \(keyCode)")
            XCTAssertEqual(
                KeyBindings.match(
                    characters: nil, keyCode: keyCode, modifiers: [.command, .option],
                    focus: .terminal, in: KeyBindings.all)?.action,
                .verb(.stepFocus(direction)),
                "…and without shift it is still focus movement, keyCode \(keyCode)")
        }
    }

    /// Every direction a pane can move in is in the menu, once, named for that direction. #152
    /// is the reason this is asserted rather than assumed: four View ▸ Focus rows were silent
    /// no-ops for as long as the payload rode in an untyped `Notification.object`. The home-row
    /// letters (#498) are a second key for the same move and carry no item of their own.
    func testEveryMoveDirectionIsClickableOnceAndNamesItself() {
        let menus = KeyBindings.all.compactMap { row -> (BenchDirection, String)? in
            guard case let .verb(.moveFocused(direction)) = row.action, let menu = row.menu
            else { return nil }
            return (direction, menu)
        }
        XCTAssertEqual(
            Set(menus.map(\.0)), [.left, .right, .up, .down], "one clickable item per direction")
        XCTAssertEqual(menus.count, 4)
        for (direction, menu) in menus {
            XCTAssertEqual(menu, "Move Pane \(direction.rawValue.capitalized)")
        }
    }

    /// The end of it: the gesture, resolved against the bench helm is drawing, goes to benchd as
    /// the operator's `pane/move` of the focused pane.
    func testTheGestureSendsAMoveOfTheFocusedPane() throws {
        let rig = try toyRig("/tmp/helm-move-pane")
        rig.model.send(.paneSplit(direction: .right), by: .operatorGesture)
        let moved = try XCTUnwrap(rig.model.bench?.focusedPane?.id)

        let verb = try XCTUnwrap(
            VerbTemplate.moveFocused(.left).resolve(
                bench: rig.model.bench, workspaces: [], active: nil))
        XCTAssertEqual(verb, .paneMove(moved, .step(.left)))
        rig.model.send(verb, by: .operatorGesture)

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "pane/move", "⇧⌥⌘← never reached benchd")
        XCTAssertEqual((sent["by"] as? [String: Any])?["kind"] as? String, "operator")
    }
}
