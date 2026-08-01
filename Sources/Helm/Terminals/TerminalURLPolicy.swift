import Foundation

/// Which URLs a ⌘-click in the terminal grid may hand to the system.
///
/// Deliberately a strict allowlist: terminal content is untrusted (an agent or
/// any program can print an OSC 8 hyperlink with an arbitrary URI), and
/// `NSWorkspace.open` will happily launch whatever app claims a scheme —
/// `ssh:`, `x-apple.systempreferences:`, worse. Web links, mail, and local
/// files cover the real uses; everything else is dropped silently.
enum TerminalURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "file", "mailto"]

    /// The URL to open, or nil when the click must be ignored. Trims
    /// whitespace/newlines (grid-wrapped links), then requires a parseable
    /// URL with an explicitly allowed scheme — scheme-less strings ("
    /// example.com") are rejected rather than guessed at.
    static func validated(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            allowedSchemes.contains(scheme)
        else { return nil }
        return url
    }
}
