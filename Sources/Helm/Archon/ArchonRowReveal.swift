import Foundation

/// Which finished run in the rail is showing its dismiss control, and whether that control is
/// there at all.
///
/// **A value rather than three lines in a view closure, because the reveal is not decoration —
/// it is what makes the × exist.** Measured for #180: SwiftUI drops a fully transparent view
/// from hit testing, so a × at `opacity(0)` does not merely look absent, it *is* absent. A grid
/// of synthetic clicks over the finished row registered 21 hits on the × while revealed and
/// **zero** while hidden. So `isRevealed` is the same fact as "can be clicked", and getting it
/// wrong does not produce a cosmetic flicker — it produces a control that cannot be used.
///
/// That is also why the row that owns this has to declare an explicit hit region: the reveal is
/// only correct if hovering *the ×'s own rectangle* keeps it revealed, and a container's
/// inherited region does not cover it. `ArchonRailHoverRegionTests` holds that.
struct ArchonRowReveal: Equatable {
    /// The run whose × is showing, or none.
    private(set) var revealed: String?

    /// **The exit is guarded, and that guard is the whole subtlety.** Moving between two
    /// adjacent rows delivers the entering row's `true` before the leaving row's `false`, so an
    /// unguarded `revealed = nil` on exit would clear the reveal the row below had just claimed
    /// and the × would blink out as the pointer slid down the list. Only the row that currently
    /// owns the reveal may give it up.
    mutating func update(inside: Bool, for id: String) {
        if inside {
            revealed = id
        } else if revealed == id {
            revealed = nil
        }
    }

    func isRevealed(_ id: String) -> Bool { revealed == id }

    /// Opacity for the dismiss control. Read the type's note before making the hidden value
    /// non-zero: `0` and `0.01` differ in whether the control can be clicked, not only in how
    /// it looks.
    func dismissOpacity(for id: String) -> Double { isRevealed(id) ? 1 : 0 }
}
