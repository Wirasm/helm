import AppKit
import SwiftUI

/// The chat face's palette. Five values, one accent, spent in exactly two
/// places: the beats on the ticker, and the tick that opens an answer's rule.
///
/// Its own colours rather than the system's because this face is *paper* — the
/// one surface in helm meant to be read at length rather than watched.
enum ChatPalette {
    static let paper = dynamic(light: 0xFB_FA_F8, dark: 0x1C_1E_21)
    static let ink = dynamic(light: 0x1B_1D_1F, dark: 0xE6_E3_DE)
    /// Prose from earlier in the turn: the same voice, half a step back.
    static let quiet = dynamic(light: 0x5C_60_66, dark: 0x93_99_A0)
    static let rule = dynamic(light: 0xE2_DF_DA, dark: 0x30_34_39)
    static let accent = dynamic(light: 0x3F_8F_80, dark: 0x5F_C0_AC)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex =
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: Double((hex >> 16) & 0xFF) / 255,
                    green: Double((hex >> 8) & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255,
                    alpha: 1)
            })
    }
}

/// The chat face's three reading profiles.
///
/// **Declared here rather than beside `.chat`** because `Canvas/` belongs to
/// another workstream right now. `MarkdownTheme`'s memberwise initializer is
/// internal, so an extension in this slice is a complete answer and the profiles
/// live with the only surface that uses them. Fold them in beside `.chat` if the
/// two ever want to be read together.
extension MarkdownTheme {
    /// The turn's last word — the thing the operator opened this face for.
    /// Bigger than chat and much airier: read once, carefully, not scanned.
    static let chatAnswer = MarkdownTheme(
        bodySize: 15.5,
        lineSpacing: 6.5,
        blockSpacing: 15,
        headingSizes: [19, 17, 15.5],
        headingWeights: [.semibold, .semibold, .semibold],
        headingSpaceAbove: 22,
        inlineCodeSize: 13.5,
        codeBlockSize: 12.5,
        codeBlockInset: 12,
        codeBlockCornerRadius: 7,
        listMarkerWidth: 22,
        listItemSpacing: 6
    )

    /// Prose the agent wrote on the way to that answer. Same family, one step
    /// back — small enough to skim past, large enough to read when you want to.
    static let chatAside = MarkdownTheme(
        bodySize: 13.5,
        lineSpacing: 5,
        blockSpacing: 10,
        headingSizes: [16, 14.5, 13.5],
        headingWeights: [.semibold, .semibold, .semibold],
        headingSpaceAbove: 14,
        inlineCodeSize: 12.2,
        codeBlockSize: 11.5,
        codeBlockInset: 10,
        codeBlockCornerRadius: 6,
        listMarkerWidth: 19,
        listItemSpacing: 4
    )

    /// The operator's own turn. Same size as an aside — this is what you said,
    /// not what you are here to read — but it carries its own rail instead of a
    /// type change, so a long prompt never competes with the answer under it.
    static let chatOperator = MarkdownTheme(
        bodySize: 13.5,
        lineSpacing: 5,
        blockSpacing: 9,
        headingSizes: [15.5, 14, 13.5],
        headingWeights: [.semibold, .semibold, .semibold],
        headingSpaceAbove: 12,
        inlineCodeSize: 12.2,
        codeBlockSize: 11.5,
        codeBlockInset: 10,
        codeBlockCornerRadius: 6,
        listMarkerWidth: 19,
        listItemSpacing: 4
    )
}
