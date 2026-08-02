import Foundation
import GhosttyTerminal

// Helm's ghostty config story, in one place.
//
// Effective config precedence (later wins — ghostty's "last value" rule):
//   1. Helm's own defaults — ALWAYS the base, config or no config: mono with a
//      taller cell for breathing room and modest padding (see
//      `TerminalSession.defaultConfiguration`).
//   2. The user's own Ghostty config, layered on top, so helm terminals feel
//      like their Ghostty (font, keybinds) — but only for the keys they
//      actually set. macOS Ghostty load order is mirrored:
//      $XDG_CONFIG_HOME/ghostty/config first, then
//      ~/Library/Application Support/com.mitchellh.ghostty/config (which
//      therefore wins where both set a key).
//   3. Helm's session overrides — the things helm must win:
//      `term = xterm-256color` (the embedded xcframework ships no terminfo, so
//      ghostty's default TERM breaks TUIs — docs/SPIKE.md), `scrollback-limit`
//      (a job requirement for agent transcripts, not a preference), and the
//      font size the human chose with ⌘+/⌘- if they ever have.
//   4. Helm's theme — LAST, and therefore the final word on colour. This is a
//      separate channel (`TerminalTheme`) rather than more config lines because
//      ghostty re-renders it per appearance; helm derives it from the app
//      palette in `TerminalSession.terminalColors`.
//
// Tier 1 used to be an EITHER/OR with tier 2 — any user config at all, even a
// single keybind line, discarded every one of helm's defaults. Layering them is
// what makes "I have a Ghostty config" cost only the keys it mentions.
//
// A user config that ghostty rejects (unknown key, missing theme, …) is
// dropped WHOLE with a logged warning; helm's defaults still stand, since they
// are the base rather than the fallback.
//
// WHO OWNS WHICH KEY — the decision, not a description of it.
//
// Helm owns COLOUR, and nothing else it did not already own:
//   background, foreground, cursor-color, cursor-text, selection-background,
//   selection-foreground, and minimum-contrast in the light appearance.
// Everything else is the operator's, exactly as before — font family, size and
// thickening, keybinds, cursor style, padding, and the SIXTEEN ANSI PALETTE
// ENTRIES.
//
// The line falls there because a colour is only worth owning where it is helm's
// own surface. Background, foreground, cursor and selection are the frame the
// grid is drawn in — the part that has to agree with the strip above it, and the
// part that made helm look like three applications stacked. The ANSI sixteen are
// not that: they are what the operator's programs colour their *content* with,
// they are the most personal thing in a terminal config, and helm has no opinion
// about them. `ls` staying the green it has always been costs the palette
// nothing.
//
// This reverses tier 4's old behaviour, which was to go empty the moment a user
// config existed — deliberately, so their colours were never stomped. That is
// the behaviour being changed, and only that one: tier 2 still wins every key
// listed above as the operator's, which is what "font and keybinds survive"
// means and what `GhosttyConfigTests` pins.

/// Points the embedded libghostty at a resources directory providing the
/// shell-integration scripts (OSC 133 prompt marks → ⌘↑/⌘↓ jump-to-prompt,
/// command-finished events, OSC 7 pwd) — the xcframework itself is headers +
/// static lib only. Helm BUNDLES the script tree, vendored from the ghostty
/// source at the exact commit the embed was built from (docs/VENDORED.md), so
/// integration works with nothing installed; an installed Ghostty.app's copy
/// is only the fallback (it additionally provides named themes, which the
/// bundle deliberately does not carry).
@MainActor
enum GhosttyResources {
    private static var installAttempted = false

    /// The vendored `ghostty/` resources dir inside helm's own bundle —
    /// first choice. Qualifies only if the shell-integration payload made it
    /// into the build (both manifests must carry it; see docs/VENDORED.md).
    static func bundledPath() -> String? {
        // SPM builds (swift run/test) resolve resources via Bundle.module;
        // the XcodeGen .app carries them in the main bundle.
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        guard let resources = bundle.resourceURL else { return nil }
        let path = resources.appendingPathComponent("ghostty", isDirectory: true).path
        guard FileManager.default.fileExists(atPath: path + "/shell-integration") else {
            return nil
        }
        return path
    }

    /// Fallback candidates: an installed Ghostty.app's resources, in order.
    /// A directory qualifies only if it actually contains the
    /// shell-integration payload.
    static func candidatePaths(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String] {
        [
            "/Applications/Ghostty.app/Contents/Resources/ghostty",
            home.appendingPathComponent("Applications/Ghostty.app/Contents/Resources/ghostty").path,
        ]
    }

    /// Sets GHOSTTY_RESOURCES_DIR (respecting an existing value) before the
    /// first ghostty controller is created: bundled copy first, Ghostty.app
    /// borrow as fallback. Safe to call repeatedly; only the first call does
    /// work. Version skew on the fallback path is accepted — the
    /// shell-integration protocol (OSC 133/7) is stable across releases.
    static func installIfAvailable() {
        guard !installAttempted else { return }
        installAttempted = true
        guard getenv("GHOSTTY_RESOURCES_DIR") == nil else { return }
        if let bundled = bundledPath() {
            setenv("GHOSTTY_RESOURCES_DIR", bundled, 1)
            return
        }
        for path in candidatePaths()
        where FileManager.default.fileExists(atPath: path + "/shell-integration") {
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

    /// The `font-size` the user's config declares, if any — the size helm's
    /// first ⌘+ steps up FROM, so zooming starts at what they are actually
    /// looking at rather than at helm's baseline. Last value wins, mirroring
    /// ghostty; comments and other keys are ignored.
    static func declaredFontSize(in contents: String) -> Float? {
        contents
            .components(separatedBy: .newlines)
            .compactMap { line -> Float? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else {
                    return nil
                }
                guard trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "font-size" else {
                    return nil
                }
                return Float(
                    trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            }
            .last
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
