import HelmWire
import SwiftUI

/// The four arrow keys, once: the key code a keystroke carries, the word the keymap file uses,
/// the menu's key equivalent, the status bar's glyph and the bench direction. Matched on the code
/// because arrows carry function-key code points rather than typable characters.
enum ArrowKey: UInt16, CaseIterable {
    // The order is the menu's: Focus Left, Right, Up, Down.
    case left = 123
    case right = 124
    case up = 126
    case down = 125

    init?(_ trigger: KeyBinding.Trigger) {
        guard case let .keyCode(code) = trigger else { return nil }
        self.init(rawValue: code)
    }

    var trigger: KeyBinding.Trigger { .keyCode(rawValue) }

    /// The keymap file's word, and the menu title's with a capital.
    var name: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        }
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .left: .leftArrow
        case .right: .rightArrow
        case .up: .upArrow
        case .down: .downArrow
        }
    }

    var glyph: String {
        switch self {
        case .left: "←"
        case .right: "→"
        case .up: "↑"
        case .down: "↓"
        }
    }

    var direction: BenchDirection {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}
