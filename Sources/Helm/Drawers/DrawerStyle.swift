/// Where a drawer sits over the bench and how much of the window it takes (#356).
///
/// helm's presentation, so it lives in helm's file (`[drawer.<name>]` in `keymap.toml`) rather
/// than in benchd's document: the document says which drawer is open and what it holds, and
/// nothing about how it is drawn.
struct DrawerStyle: Equatable {
    enum Edge: String {
        case left, right
    }

    var edge: Edge
    /// A fraction of the window's width.
    var size: Double

    static let sizes = 0.1...0.9

    /// The sessions list is a narrow column on the left, like a sidebar (#384); anything else —
    /// a browser, a canvas — wants room, on the right.
    static func builtIn(for name: String) -> DrawerStyle {
        name == "sessions"
            ? DrawerStyle(edge: .left, size: 0.28) : DrawerStyle(edge: .right, size: 0.5)
    }
}
