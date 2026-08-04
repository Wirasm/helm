import AppKit
import Foundation

/// Copy to the system pasteboard.
///
/// Lived in a kild view file until that layer was removed; it was never kild-specific, so
/// it moved here rather than going with it.
enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// **The one answer to tilde-versus-absolute, so helm stops having two.**
    ///
    /// A path is copied from three places — the canvas header, the artifact browser and the
    /// workspace bar — and they had drifted: the browser abbreviated to `~/.prp/…` while the
    /// workspace bar copied the absolute path. #168 asked for one answer across all three.
    ///
    /// **Absolute, because a copied path is going somewhere helm cannot see.** The tilde form
    /// reads better and is what prp's own docs write, but it is only a path in a context that
    /// expands it — a shell does, `open(2)` does not, and neither do most of the tools an
    /// operator pastes into. The point of taking a value out of helm is that it works wherever
    /// it lands, and the shorter form is the one that looks right and then does not.
    ///
    /// A function rather than a call-site expression so the choice is testable and there is
    /// exactly one place to change it if that judgement turns out wrong.
    static func path(of url: URL) -> String { url.standardizedFileURL.path }
}
