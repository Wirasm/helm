import PocketKit
import SwiftUI
import UIKit

/// Pocket's colours, from the mockup (`proposals/phone.html`): one dark console, state by glyph
/// and colour. Spend these; a view never names a colour of its own.
enum Palette {
    static let background = Color(rgb: 0x15181B)
    static let sheet = Color(rgb: 0x1B1F23)
    static let line = Color(rgb: 0x25292E)
    static let text = Color(rgb: 0xD9DCE0)
    static let dim = Color(rgb: 0x6B7178)
    static let faint = Color(rgb: 0x3E444A)
    static let asking = Color(rgb: 0xE8A33D)
    static let finished = Color(rgb: 0x5FC0AC)

    static func of(_ attention: Attention) -> Color {
        switch attention {
        case .asking: asking
        case .finished: finished
        case .working: faint
        case .seen, .ended: dim
        }
    }
}

/// The one typeface: monospaced, as a terminal.
enum Mono {
    static let body = Font.system(size: bodySize, design: .monospaced)
    static let small = Font.system(size: smallSize, design: .monospaced)
    /// `body` and `small` for a `UITextView` (`SelectableText`), which takes no SwiftUI font.
    static let bodyUI = UIFont.monospacedSystemFont(ofSize: bodySize, weight: .regular)
    static let smallUI = UIFont.monospacedSystemFont(ofSize: smallSize, weight: .regular)
    private static let bodySize: CGFloat = 13
    private static let smallSize: CGFloat = 11.5
    static let group = Font.system(size: 11, design: .monospaced)
    static let screen = Font.system(size: 10, design: .monospaced)
    /// A message's time, under it.
    static let stamp = Font.system(size: 9.5, design: .monospaced)
    static let title = Font.system(size: 13, weight: .semibold, design: .monospaced)
    /// The composer's send arrow, in its circle.
    static let send = Font.system(size: 16, weight: .bold, design: .monospaced)
}

extension Color {
    fileprivate init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}
