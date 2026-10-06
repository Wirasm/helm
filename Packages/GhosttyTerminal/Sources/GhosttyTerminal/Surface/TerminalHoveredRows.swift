/// Viewport rows as text, and the index of the one under the mouse (helm).
public struct TerminalHoveredRows: Sendable, Equatable {
    public let rows: [String]
    public let hovered: Int

    public init(rows: [String], hovered: Int) {
        self.rows = rows
        self.hovered = hovered
    }
}
