import AppKit
import SwiftUI

/// The palette's SwiftUI face: one `Color` per token, and nothing else.
///
/// Kept out of `Palette.swift` on purpose — the seam between a value a test can read and a
/// `Color` only a view can spend is exactly where the file boundary should be. The terminal
/// theme crosses at the *other* edge, rendering the same tokens as ghostty config lines
/// (`TerminalSession.terminalTheme`); neither side is the palette.
extension Palette.Token {
    /// A dynamic colour: AppKit re-resolves it whenever the drawing appearance changes, so
    /// `AppearanceOverride` re-themes every surface with no helm code and no observation.
    var color: Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = self.value(
                    in: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? .dark : .light)
                return NSColor(
                    srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
            })
    }
}

/// helm's tokens, as the names a view writes.
///
/// **The only colour names a view should spend.** A literal `Color(red:…)` or a system
/// default in a view is the defect this whole slice exists to remove — it is how helm ended
/// up with three palettes. If a surface needs a colour that is not here, the answer is a
/// token, not a one-off.
extension Color {
    static let surface = Palette.helm.surface.color
    static let surfaceRaised = Palette.helm.surfaceRaised.color
    static let textPrimary = Palette.helm.textPrimary.color
    static let textMuted = Palette.helm.textMuted.color
    static let textFaint = Palette.helm.textFaint.color
    static let border = Palette.helm.border.color
    static let accent = Palette.helm.accent.color
    static let selection = Palette.helm.selection.color
    static let archonMagenta = Palette.helm.archonMagenta.color
    static let archonViolet = Palette.helm.archonViolet.color
    static let archonTeal = Palette.helm.archonTeal.color
    static let archonRunning = Palette.helm.archonRunning.color
    static let archonAttention = Palette.helm.archonAttention.color
    static let archonError = Palette.helm.archonError.color
}

extension ShapeStyle where Self == LinearGradient {
    /// Archon's brand, as the one thing a view spends it through.
    ///
    /// 135° and three stops, because that is what the console's `--brand-gradient` is; a
    /// `LinearGradient` rather than two so `.foregroundStyle` paints the title's glyphs and
    /// the same value fills the send button. SwiftUI's unit space runs y-down, so 135° from
    /// the CSS convention is top-leading → bottom-trailing here.
    static var archonBrand: LinearGradient {
        LinearGradient(
            colors: [.archonMagenta, .archonViolet, .archonTeal],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
