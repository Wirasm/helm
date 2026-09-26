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

    /// The sessions list is a narrow column on the left, like a sidebar (#384); anything else —
    /// a browser, a canvas — wants room, on the right.
    static func builtIn(for name: String) -> DrawerStyle {
        name == "sessions"
            ? DrawerStyle(edge: .left, size: 0.28) : DrawerStyle(edge: .right, size: 0.5)
    }
}
