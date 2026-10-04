import Foundation

/// One block of a reply's markdown, for Pocket to draw: Apple's parser (`AttributedString` with
/// full syntax) read by its presentation intents. Its text keeps the inline runs (bold, italic,
/// code, links) for the drawing to style.
package struct MarkdownBlock: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        /// A list item `depth` lists deep (1 the outermost), marked "•" or its number ("2."). A
        /// later paragraph of the same item has blanks as wide as the marker, to sit under the text.
        case item(depth: Int, marker: String)
        /// A fenced or indented code block, without its last newline.
        case code
        case quote
        /// Each row's cells, the header row first when the table has one.
        case table(rows: [[AttributedString]], header: Bool)
        case rule
    }

    package var kind: Kind
    package var text: AttributedString

    package init(_ kind: Kind, _ text: AttributedString = AttributedString()) {
        self.kind = kind
        self.text = text
    }
}

package enum ChatMarkdown {
    /// `markdown` as blocks, in order. A soft line break stays a line break, as the agent wrote
    /// it; text the parser refuses is one plain paragraph.
    package static func blocks(_ markdown: String) -> [MarkdownBlock] {
        guard
            let parsed = try? AttributedString(
                markdown: markdown, options: .init(interpretedSyntax: .full))
        else { return [MarkdownBlock(.paragraph, AttributedString(markdown))] }
        var reader = Reader()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                piece = AttributedString("\n")
            }
            reader.add(piece, run.presentationIntent?.components ?? [])
        }
        return reader.finish()
    }

    /// Gathers runs into blocks: a run joins the block whose innermost intent it shares, and a
    /// table's cells gather by row and column until a run outside it.
    private struct Reader {
        var blocks: [MarkdownBlock] = []
        var open: (identity: Int, block: MarkdownBlock)?
        /// Each list item already marked, by identity, and its marker: a later paragraph of it,
        /// even after a nested list, is not marked again.
        var marked: [Int: String] = [:]
        var table: (identity: Int, header: Bool, rows: [Int: [Int: AttributedString]])?

        mutating func add(
            _ piece: AttributedString, _ intents: [PresentationIntent.IntentType]
        ) {
            if let cell = Self.cell(intents) {
                closeBlock()
                if table?.identity != cell.table { closeTable() }
                if table == nil { table = (cell.table, false, [:]) }
                if cell.row == 0 { table?.header = true }
                table?.rows[cell.row, default: [:]][cell.column, default: AttributedString()] +=
                    piece
                return
            }
            closeTable()
            let identity = intents.first?.identity ?? -1
            if open?.identity == identity {
                open?.block.text += piece
                return
            }
            closeBlock()
            var kind = Self.kind(intents)
            if case let .item(depth, marker) = kind,
                let identity = intents.first(where: {
                    if case .listItem = $0.kind { true } else { false }
                })?.identity
            {
                if let first = marked[identity] {
                    kind = .item(depth: depth, marker: String(repeating: " ", count: first.count))
                } else {
                    marked[identity] = marker
                }
            }
            open = (identity, MarkdownBlock(kind, piece))
        }

        mutating func finish() -> [MarkdownBlock] {
            closeBlock()
            closeTable()
            return blocks
        }

        private mutating func closeBlock() {
            guard var block = open?.block else { return }
            open = nil
            if block.kind == .code, block.text.characters.last == "\n" {
                block.text.characters.removeLast()
            }
            blocks.append(block)
        }

        private mutating func closeTable() {
            guard let table else { return }
            self.table = nil
            let rows = table.rows.keys.sorted().map { row in
                let cells = table.rows[row] ?? [:]
                let width = (cells.keys.max() ?? -1) + 1
                return (0..<width).map { cells[$0] ?? AttributedString() }
            }
            blocks.append(MarkdownBlock(.table(rows: rows, header: table.header)))
        }

        /// A table cell's table, row (0 the header) and column.
        private static func cell(
            _ intents: [PresentationIntent.IntentType]
        )
            -> (table: Int, row: Int, column: Int)?
        {
            guard case let .tableCell(column)? = intents.first?.kind, intents.count > 2,
                case .table = intents[2].kind
            else { return nil }
            let row: Int
            switch intents[1].kind {
            case .tableHeaderRow: row = 0
            case let .tableRow(index): row = index
            default: return nil
            }
            return (intents[2].identity, row, column)
        }

        /// What the innermost intent makes of a block, read through what holds it.
        private static func kind(_ intents: [PresentationIntent.IntentType]) -> MarkdownBlock.Kind {
            switch intents.first?.kind {
            case let .header(level)?: return .heading(level: level)
            case .codeBlock?: return .code
            case .thematicBreak?: return .rule
            default: break
            }
            let lists = intents.filter {
                switch $0.kind {
                case .orderedList, .unorderedList: true
                default: false
                }
            }
            if let at = intents.firstIndex(where: {
                if case .listItem = $0.kind { true } else { false }
            }), case let .listItem(ordinal) = intents[at].kind {
                let ordered =
                    intents.indices.contains(at + 1) && intents[at + 1].kind == .orderedList
                return .item(depth: lists.count, marker: ordered ? "\(ordinal)." : "•")
            }
            if intents.contains(where: { $0.kind == .blockQuote }) { return .quote }
            return .paragraph
        }
    }
}
