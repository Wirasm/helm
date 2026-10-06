import PocketKit
import SwiftUI

/// Markdown as Pocket draws it, a reply's or a store document's: runs of text blocks as
/// selectable text, and each table as a grid of its own (`ChatText.segments`).
struct MarkdownView: View {
    let text: String
    var links = StoreLinks()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let segments = ChatText.segments(
                text, font: Mono.bodyUI, color: UIColor(Palette.text), links: links)
            ForEach(segments.indices, id: \.self) { index in
                switch segments[index] {
                case let .text(styled):
                    SelectableText(
                        text: text, styled: styled, font: Mono.bodyUI, color: Palette.text,
                        copy: text)
                case let .table(rows, header):
                    TableView(rows: rows, header: header, copy: text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A table as a grid: its columns aligned, each cell wrapping at a width a phone can read, the
/// header ruled off under it. Wider than the screen, it scrolls sideways inside its own block,
/// and the message never does. Each cell can be selected and copied; "Copy message" copies the
/// whole reply.
struct TableView: View {
    @Environment(\.tableRegions) private var regions
    @State private var id = UUID()
    let rows: [[NSAttributedString]]
    let header: Bool
    let copy: String

    /// A cell wraps here: about thirty characters, so a three- or four-column table shows a
    /// column and more at once.
    private static let cellWidth: CGFloat = 200

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(rows[row].indices, id: \.self) { column in
                            SelectableText(
                                text: rows[row][column].string, styled: rows[row][column],
                                font: Mono.bodyUI, color: Palette.text, copy: copy,
                                maxWidth: Self.cellWidth)
                        }
                    }
                    if header, row == 0 {
                        Palette.dim.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.vertical, 2)
            // Inside a sideways scroll view the chat's own tap never sees a touch, so a tap on
            // the table puts the keyboard away here, as one on any message does.
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                })
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(MessagesView.space))
        } action: {
            regions?.frames[id] = $0
        }
        .onDisappear { regions?.frames[id] = nil }
    }
}

/// Where a chat's tables are among its messages, in the messages' own space
/// (`MessagesView.space`), by table, so the chat's swipe leaves a drag that starts on a table to
/// the table. Read from each table's geometry, never from a gesture on it: a drag gesture inside
/// the table's scroll view held back its scrolling. A reference, so a table moving does not
/// redraw the chat.
@MainActor
final class TableRegions {
    var frames: [UUID: CGRect] = [:]

    func contains(_ point: CGPoint) -> Bool {
        frames.values.contains { $0.contains(point) }
    }
}

extension EnvironmentValues {
    /// The chat's table regions; nil outside a chat, where no swipe switches anything.
    @Entry var tableRegions: TableRegions?
}
