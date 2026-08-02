import SwiftUI

/// Single source of typographic truth for the room log's markdown rendering.
/// Pure values — no views — so every font/spacing decision is testable from
/// `swift test`. (The canvas renders markdown in a webview with its own
/// CSS scale — see CanvasHTML.)
///
/// Chat posts are dense but comfortably readable. Inline code gets a subtle
/// fill via the AttributedString run background (SwiftUI `Text` can't pad or
/// round a run, so the fill is the whole treatment).
struct MarkdownTheme: Equatable {
    // MARK: Body

    let bodySize: CGFloat
    /// Extra spacing between wrapped lines inside a block.
    let lineSpacing: CGFloat
    /// Vertical spacing between two ordinary blocks (paragraph spacing).
    let blockSpacing: CGFloat

    // MARK: Headings

    /// Point size per heading level; levels beyond the array reuse the last.
    let headingSizes: [CGFloat]
    let headingWeights: [Font.Weight]
    /// Space above a heading (replaces `blockSpacing`, doesn't add to it).
    let headingSpaceAbove: CGFloat

    // MARK: Code

    let inlineCodeSize: CGFloat
    let codeBlockSize: CGFloat
    /// Inset inside the code block's fill.
    let codeBlockInset: CGFloat
    let codeBlockCornerRadius: CGFloat

    // MARK: Lists

    /// Fixed marker column so wrapped item text hangs cleanly after it.
    let listMarkerWidth: CGFloat
    /// Spacing between consecutive list items (tighter than paragraphs).
    let listItemSpacing: CGFloat

    // MARK: Profile

    /// Room-log posts: dense, but a real reading size.
    static let chat = MarkdownTheme(
        bodySize: 14,
        lineSpacing: 4,
        blockSpacing: 8,
        headingSizes: [18, 16, 14],
        headingWeights: [.semibold, .semibold, .semibold],
        headingSpaceAbove: 10,
        inlineCodeSize: 13,
        codeBlockSize: 12.5,
        codeBlockInset: 10,
        codeBlockCornerRadius: 6,
        listMarkerWidth: 18,
        listItemSpacing: 4
    )

    // MARK: Derived fonts

    var bodyFont: Font { .system(size: bodySize) }
    var inlineCodeFont: Font { .system(size: inlineCodeSize, design: .monospaced) }
    var codeBlockFont: Font { .system(size: codeBlockSize, design: .monospaced) }

    func headingFont(level: Int) -> Font {
        let index = min(max(level, 1), headingSizes.count) - 1
        return .system(size: headingSizes[index], weight: headingWeights[index])
    }

    /// The font a whole block renders in (inline code inside it is styled
    /// separately via `inlineCodeFont`).
    func font(for block: PostMarkdown.Block) -> Font {
        switch block {
        case let .heading(level, _): headingFont(level: level)
        case .code: codeBlockFont
        case .paragraph, .listItem: bodyFont
        }
    }

    /// Vertical space above `block` given the block that precedes it — the
    /// paragraph-spacing rules in one pure, testable place. The first block
    /// of a run gets no space above (the surface owns its own padding).
    func spacing(above block: PostMarkdown.Block, after previous: PostMarkdown.Block?) -> CGFloat {
        guard previous != nil else { return 0 }
        switch block {
        case .heading: return headingSpaceAbove
        case .listItem:
            if case .listItem = previous { return listItemSpacing }
            return blockSpacing
        case .paragraph, .code: return blockSpacing
        }
    }
}
