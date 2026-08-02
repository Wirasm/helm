import Foundation

/// Encoding a message into ghostty's `text:` binding action.
///
/// **The route, and why it is this one** (#29's client half measured all three):
/// `ghostty_surface_write_buffer` paints the emulator screen and the pty never
/// sees it; the public `sendText` sanitises control bytes, turning ESC into a
/// space and dropping CR, so it cannot submit a line. `performBindingAction`
/// with a `text:` action delivers bytes byte-exact, and it is **public** on
/// `AppTerminalView` (`AppTerminalView+PublicInput.swift`) — so this needs no
/// vendor patch. `docs/direction.md` used to say otherwise and was corrected.
///
/// **The escaping rule, read off ghostty's own source** at the pinned commit
/// (`Ghostty.ref` → `35e1a01`, `src/config/string.zig`): the action's value is
/// copied byte-for-byte except that `\` opens a Zig string-literal escape. `"`,
/// `:`, spaces and multi-byte UTF-8 are all ordinary bytes — only the backslash
/// is special. `src/apprt/embedded.zig` passes the string straight to
/// `Binding.Action.parse`, which splits on the first colon and takes the rest
/// verbatim, so nothing tokenises or unquotes it on the way.
///
/// **Which is why escaping is not optional.** `Surface.zig`'s `.text` handler
/// logs an invalid escape and `return true` — the message is dropped and the
/// call still reports success. Doubling every backslash makes an invalid escape
/// structurally impossible, so that silent path can never be reached.
enum PtyText {
    /// The action string for sending `message` and submitting it.
    ///
    /// The newline is part of the same action on purpose. #29 measured a race
    /// when prose and its return went as two calls — an 88-character message
    /// lost its CR, and a CR sent a moment later submitted it. One action is one
    /// write, so there is no gap for the two to reorder in.
    static func submitAction(for message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "text:" + escape(trimmed) + #"\r"#
    }

    /// Ghostty's escaping for a literal run of text: double the backslashes and
    /// leave everything else alone.
    ///
    /// Newlines inside the message are escaped to `\n` rather than passed as raw
    /// bytes. A raw newline mid-message would submit whatever came before it and
    /// leave the rest at a fresh prompt — the message arriving as two prompts,
    /// silently. `\n` keeps it one write; what the agent's own line editor does
    /// with an embedded newline is then its business and is visible either way.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count + 8)
        for character in text {
            switch character {
            case "\\": escaped += #"\\"#
            case "\n": escaped += #"\n"#
            case "\r": escaped += #"\r"#
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
