import PocketKit
import SwiftUI
import UIKit

/// A reply's markdown drawn for a `UITextView` (`SelectableText`): one attributed string, so a
/// selection runs across blocks. Everything is in the one monospaced face, which is what lines a
/// table's columns up.
enum ChatText {
    static func markdown(
        _ text: String, font: UIFont, color: UIColor, links: StoreLinks = StoreLinks()
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (at, block) in ChatMarkdown.blocks(text).enumerated() {
            if at > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(draw(linked(block, with: links), font: font, color: color))
        }
        return out
    }

    private static func linked(_ block: MarkdownBlock, with links: StoreLinks) -> MarkdownBlock {
        var block = block
        block.text = links.linking(block.text)
        if case let .table(rows, header) = block.kind {
            block.kind = .table(rows: rows.map { $0.map(links.linking) }, header: header)
        }
        return block
    }

    private static func draw(
        _ block: MarkdownBlock, font: UIFont, color: UIColor
    )
        -> NSAttributedString
    {
        let space = " ".size(withAttributes: [.font: font]).width
        switch block.kind {
        case .paragraph:
            return paragraph(inline(block.text, font: font, color: color))
        case let .heading(level):
            let size = font.pointSize + (level <= 2 ? 2 : 0)
            let heading = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
            return paragraph(inline(block.text, font: heading, color: color))
        case let .item(depth, marker):
            // The marker hangs: wrapped lines start under the text, not under the marker.
            let indent = CGFloat(depth - 1) * 2 * space
            let line = NSMutableAttributedString(
                string: marker + " ",
                attributes: [.font: font, .foregroundColor: UIColor(Palette.dim)])
            line.append(inline(block.text, font: font, color: color))
            let text = indent + CGFloat(marker.count + 1) * space
            return paragraph(line, first: indent, rest: text)
        case .code:
            return paragraph(
                code(block.text, font: font, color: color))
        case .quote:
            // The bar on every line of it; a wrapped line starts under the text.
            let bar = NSAttributedString(
                string: "│ ", attributes: [.font: font, .foregroundColor: UIColor(Palette.faint)])
            let line = inline(block.text, font: font, color: UIColor(Palette.dim))
            for at in line.string.indices(of: "\n").reversed() {
                line.insert(bar, at: at + 1)
            }
            line.insert(bar, at: 0)
            return paragraph(line, first: 0, rest: 2 * space, next: 0)
        case let .table(rows, header):
            return paragraph(table(rows, header: header, font: font, color: color))
        case .rule:
            return paragraph(
                NSAttributedString(
                    string: String(repeating: "─", count: 12),
                    attributes: [.font: font, .foregroundColor: UIColor(Palette.dim)]))
        }
    }

    private static func code(
        _ text: AttributedString, font: UIFont, color: UIColor
    ) -> NSAttributedString {
        let out = inline(text, font: font, color: color)
        out.addAttribute(
            .backgroundColor, value: UIColor(Palette.sheet),
            range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Columns padded to their widest cell, the header bold and ruled off under it.
    private static func table(
        _ rows: [[AttributedString]], header: Bool, font: UIFont, color: UIColor
    ) -> NSAttributedString {
        let cells = rows.map { $0.map { String($0.characters) } }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            cells.map { $0.indices.contains(column) ? $0[column].count : 0 }.max() ?? 0
        }
        let bold = bolder(font)
        let out = NSMutableAttributedString()
        for index in cells.indices {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            let isHeader = header && index == 0
            for column in 0..<columns {
                let cell =
                    rows[index].indices.contains(column) ? rows[index][column] : AttributedString()
                out.append(inline(cell, font: isHeader ? bold : font, color: color))
                let padding =
                    widths[column] - cell.characters.count + (column < columns - 1 ? 2 : 0)
                out.append(
                    NSAttributedString(
                        string: String(repeating: " ", count: padding),
                        attributes: [.font: font, .foregroundColor: color]))
            }
            if isHeader {
                let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "  ")
                out.append(
                    NSAttributedString(
                        string: "\n" + rule,
                        attributes: [.font: font, .foregroundColor: UIColor(Palette.dim)]))
            }
        }
        return out
    }

    /// `text` in `font` and `color`, with its inline markdown: bold, italic, code in the reply
    /// colour, links kept.
    static func inline(
        _ text: AttributedString, font: UIFont, color: UIColor
    )
        -> NSMutableAttributedString
    {
        let out = NSMutableAttributedString(text)
        out.addAttributes(
            [.font: font, .foregroundColor: color], range: NSRange(location: 0, length: out.length))
        for run in text.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let range = NSRange(run.range, in: text)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty,
                let descriptor = font.fontDescriptor.withSymbolicTraits(
                    font.fontDescriptor.symbolicTraits.union(traits))
            {
                out.addAttribute(
                    .font, value: UIFont(descriptor: descriptor, size: 0), range: range)
            }
            if intent.contains(.code) {
                out.addAttribute(.foregroundColor, value: UIColor(Palette.finished), range: range)
            }
        }
        return out
    }

    private static func bolder(_ font: UIFont) -> UIFont {
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) }
            ?? font
    }

    /// A block's paragraphs, one per line of it: the first line indented `first`, each later one
    /// `next` (`rest` when nil), a wrapped line `rest`, and a little space under the last only.
    private static func paragraph(
        _ text: NSAttributedString, first: CGFloat = 0, rest: CGFloat = 0, next: CGFloat? = nil
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let string = out.string as NSString
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, range, enclosing, _ in
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = range.location == 0 ? first : next ?? rest
            style.headIndent = rest
            style.paragraphSpacing = NSMaxRange(enclosing) >= string.length ? 4 : 0
            out.addAttribute(.paragraphStyle, value: style, range: enclosing)
        }
        return out
    }
}

extension String {
    /// The UTF-16 offsets of `character`, as `NSAttributedString` counts.
    fileprivate func indices(of character: Character) -> [Int] {
        var offsets: [Int] = []
        var offset = 0
        for c in self {
            if c == character { offsets.append(offset) }
            offset += c.utf16.count
        }
        return offsets
    }
}
