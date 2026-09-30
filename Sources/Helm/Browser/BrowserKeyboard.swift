import AppKit

/// Which browser pane holds the keyboard, if one does — the question a browser key (#542) asks
/// before it acts, and the one `KeyFocus.current` asks to decide whether it may fire.
///
/// **AppKit's first responder, not the bench's focused pane**, for the reason
/// `TerminalManager.anyTerminalHasFocus` gives: the document says which pane *should* have the
/// keyboard, and the responder is where the operator is actually typing. It answers the same
/// way for a pane on the bench and one in the browser drawer.
///
/// Two responders count: the page (`BrowserSurfaceView`), and the address field while it is
/// being edited — ⌘W or ⌘T typed there is still a browser key. A SwiftUI text field's responder
/// is AppKit's shared field editor, which names no pane, so the pane that is editing says so
/// itself (`editingAddress`); there is one field editor per window, so one such pane at a time.
@MainActor
enum BrowserKeyboard {
    /// The pane whose address field is being edited, set and cleared by its view.
    static weak var editingAddress: BrowserPaneModel?

    static func holder() -> BrowserPaneModel? {
        guard let responder = NSApp?.keyWindow?.firstResponder else { return nil }
        if let surface = responder as? BrowserSurfaceView {
            return surface.model as? BrowserPaneModel
        }
        if let field = responder as? NSTextView, field.isFieldEditor { return editingAddress }
        return nil
    }
}
