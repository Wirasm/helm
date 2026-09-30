import Foundation

/// The page zoom levels a browser pane steps through: Chrome's own, so ⌘+ lands where it would
/// in Chrome (#544).
enum BrowserZoom {
    static let levels: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5,
    ]

    /// The next level from `current`, clamped at both ends. A level between two steps goes to
    /// the nearer one in the direction asked.
    static func step(from current: Double, _ step: FontSizeStep) -> Double {
        switch step {
        case .reset: 1
        case .increase: levels.first { $0 > current + 0.001 } ?? levels[levels.count - 1]
        case .decrease: levels.last { $0 < current - 0.001 } ?? levels[0]
        }
    }
}
