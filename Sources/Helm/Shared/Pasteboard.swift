import AppKit

/// Copy to the system pasteboard.
///
/// Lived in a kild view file until that layer was removed; it was never kild-specific, so
/// it moved here rather than going with it.
enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
