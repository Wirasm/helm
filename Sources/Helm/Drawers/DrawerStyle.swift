import HelmWire

/// Where a drawer sits over the bench and how much of the window it takes (#356).
///
/// The size is helm's presentation, from `[drawer.<name>]` in `keymap.toml`. The edge is the
/// operator's: where he dragged the drawer, kept in benchd's document (#178), and the keymap's
/// edge is only the default for a drawer he has not placed (`placed(by:)`).
struct DrawerStyle: Equatable {
    /// The wire's spelling, so the keymap file and the document name an edge one way.
    typealias Edge = BenchDocument.DrawerEdge

    var edge: Edge
    /// A fraction of the window: of its height for a drawer on the bottom edge, of its width
    /// for one on a side.
    var size: Double

    static let sizes = 0.1...0.9

    /// This style with the edge the operator put drawer `name` against, when the document has
    /// one.
    func placed(_ name: String, by document: BenchDocument?) -> DrawerStyle {
        var style = self
        if let edge = document?.drawerEdges[name] { style.edge = edge }
        return style
    }

    /// benchd's `DrawerName::new` (`daemon/crates/bench-doc/src/drawer.rs`): 1 to 32 of
    /// `[a-z0-9-]`. Spelled again so the keymap file is refused when it loads, with the line,
    /// rather than when the key is pressed; benchd still judges every name it is sent.
    static func isDrawerName(_ raw: String) -> Bool {
        (1...32).contains(raw.utf8.count)
            && raw.utf8.allSatisfy {
                (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D
            }
    }

    static let nameRule = "a drawer name is 1-32 of [a-z0-9-]"

    /// The sessions list is a narrow column on the left, like a sidebar (#384); Archon's runs
    /// are rows of stage dots that want the window's width, along the bottom (#382); anything
    /// else — a browser, a canvas — wants room, on the right.
    static func builtIn(for name: String) -> DrawerStyle {
        switch name {
        case "sessions": DrawerStyle(edge: .left, size: 0.28)
        case "archon": DrawerStyle(edge: .bottom, size: 0.42)
        default: DrawerStyle(edge: .right, size: 0.5)
        }
    }
}
