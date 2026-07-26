import Foundation
import GhosttyTerminal

// Helm's ghostty config story, in one place.
//
// Effective config precedence (later wins — ghostty's "last value" rule):
//   1. The user's own Ghostty config, when one exists — loaded verbatim as the
//      base so helm terminals feel like the user's Ghostty (font, colors,
//      keybinds, everything). macOS Ghostty load order is mirrored:
//      $XDG_CONFIG_HOME/ghostty/config first, then
//      ~/Library/Application Support/com.mitchellh.ghostty/config (which
//      therefore wins where both set a key).
//   2. Helm's required overrides — applied AFTER the user config. Today that is
//      only `term = xterm-256color`: the embedded xcframework ships no
//      terminfo, so ghostty's default TERM breaks TUIs (docs/SPIKE.md).
//   3. No user config → helm's own defaults instead (13pt mono with breathing
//      room, large scrollback, light/dark theme following helm's appearance
//      override — see `TerminalSession.makeController`).
//
// A user config that ghostty rejects (unknown key, missing theme, …) is
// dropped WHOLE with a logged warning and helm falls back to its defaults —
// a terminal that opens always beats a faithfully-broken one.

/// Points the embedded libghostty at a Ghostty.app resources directory when
/// one is installed. The xcframework is headers + static lib only; the
/// resources dir is what provides shell-integration scripts (OSC 133 prompt
/// marks → jump-to-prompt, command-finished events) and named themes, so
/// borrowing an installed Ghostty.app's copy lights those up for free.
@MainActor
enum GhosttyResources {
    private static var installAttempted = false

    /// Candidate resources directories, in order. A directory qualifies only
    /// if it actually contains the shell-integration payload.
    static func candidatePaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            home.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty").path,
        ]
    }

    /// Sets GHOSTTY_RESOURCES_DIR (respecting an existing value) before the
    /// first ghostty controller is created. Safe to call repeatedly; only the
    /// first call does work. Version skew between an installed Ghostty.app's
    /// scripts and the pinned embed is accepted — the shell-integration
    /// protocol (OSC 133/7) is stable across releases.
    static func installIfAvailable() {
        guard !installAttempted else { return }
        installAttempted = true
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }
        for path in candidatePaths()
            where FileManager.default.fileExists(atPath: path + "/shell-integration")
        {
            setenv("GHOSTTY_RESOURCES_DIR", path, 1)
            return
        }
    }
}

/// Locates and loads the user's own Ghostty config as helm's base config.
enum GhosttyUserConfig {
    /// The two macOS Ghostty config locations, in load order (both load when
    /// both exist; the later Application Support file wins, like Ghostty).
    static func configPaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        xdgConfigHome: String? = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    ) -> [String] {
        let xdgBase = xdgConfigHome ?? home.appendingPathComponent(".config").path
        return [
            xdgBase + "/ghostty/config",
            home.appendingPathComponent(
                "Library/Application Support/com.mitchellh.ghostty/config"
            ).path,
        ]
    }

    /// Concatenated, sanitized contents of every config file that exists, or
    /// nil when the user has none (→ helm defaults).
    static func load(paths: [String]? = nil) -> String? {
        let contents = (paths ?? configPaths()).compactMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        guard !contents.isEmpty else { return nil }
        return contents.map(sanitize).joined(separator: "\n")
    }

    /// Drops `config-file` include lines: helm re-renders the config into a
    /// temp file (the wrapper's mechanism for layering overrides), where
    /// relative include paths would resolve against the temp dir and turn
    /// into hard config errors. Everything else passes through verbatim.
    static func sanitize(_ contents: String) -> String {
        contents
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let eq = trimmed.firstIndex(of: "=") else { return true }
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                return key != "config-file"
            }
            .joined(separator: "\n")
    }
}
