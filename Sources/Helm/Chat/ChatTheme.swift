import AppKit
import SwiftUI

// `ChatPalette` used to live here: five values — paper, ink, quiet, rule, accent — chosen
// for this face and reachable from nowhere else. It is gone, and the five values are not:
// they are `Palette.helm`'s `surface`, `textPrimary`, `textMuted`, `border` and `accent`,
// unchanged to the digit, spent by the whole app now instead of by one face.
//
// The fold went in this direction on purpose. These were the only colours in helm anyone
// had ever *picked* — the terminal took the operator's, the chrome took the system's — so
// promoting them cost nothing and choosing new ones would have regressed the one surface
// that already read well. What the chat face lost is the claim of being separate; what it
// kept is every pixel. Its distinction was never hue anyway, it is the three reading
// profiles below.

/// The chat face's three reading profiles.
///
/// **Declared here rather than beside `.chat`, and they stay here by choice.** The note
/// this replaces said `Canvas/` belonged to another workstream; that workstream was the
/// workbench, and it is finished. Folding them in was reconsidered and refused: these are
/// the *chat face's* reading profiles, used by nothing else, so moving them into `Canvas/`
/// would put chat-specific values in another slice for no gain. `MarkdownTheme`'s
/// memberwise initializer is internal, so an extension in this slice is a complete answer
/// and the profiles live with the only surface that uses them.
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
