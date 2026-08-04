import Foundation

/// The one thing sending a message needs of a live terminal: a way to run a ghostty
/// binding action against its surface.
///
/// It exists so the send path can be *driven* by a test rather than only inspected.
/// `submitAction` used to return one string and the tests asserted that string, which
/// looked right and was wrong — nothing asserted what the pty actually received, so
/// #119 shipped. A recorder conforming to this sees the writes themselves, in order,
/// with the gap between them.
@MainActor
protocol PtyWriting: AnyObject {
    @discardableResult
    func performBindingAction(_ action: String) -> Bool
}

/// Encoding a message into ghostty's `text:` binding action, and delivering it.
///
/// **The route, and why it is this one** (#29's client half measured all three):
/// `ghostty_surface_write_buffer` paints the emulator screen and the pty never
/// sees it; the public `sendText` sanitises control bytes, turning ESC into a
/// space, and wraps everything in bracketed-paste markers. `performBindingAction`
/// with a `text:` action delivers bytes byte-exact — `Surface.zig`'s `.text` handler
/// is a plain `writeReq` with no fences round it — and it is **public** on
/// `AppTerminalView` (`AppTerminalView+PublicInput.swift`), so this needs no vendor
/// patch. `docs/direction.md` used to say otherwise and was corrected.
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
    /// The action that puts `message` in the agent's line editor. It does **not**
    /// submit it — see `returnAction`.
    ///
    /// `nil` when there is nothing to send, so an empty draft writes nothing at all
    /// rather than a bare Return into somebody's session.
    static func messageAction(for message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "text:" + escape(trimmed)
    }

    /// The action that submits it: a carriage return, on its own, in its own write.
    static let returnAction = #"text:\r"#

    /// How long the Return waits behind the message.
    ///
    /// **This is the whole of #119, and it is measured rather than guessed.** An agent's
    /// TUI classifies a *chunk* of stdin, not a byte stream: anything past a size
    /// threshold is treated as pasted text and inserted verbatim — which is exactly what
    /// you want a paste to do, and exactly wrong for the Return riding on the end of it.
    /// Measured against Claude Code 2.1.221 over a pty, message + `\r`:
    ///
    /// | shape                                   | result                          |
    /// | --------------------------------------- | ------------------------------- |
    /// | 19 chars, one write                     | submits                         |
    /// | 138 chars, one write                    | newline inserted, **no submit** |
    /// | 138 chars, two writes, no gap           | newline inserted, **no submit** |
    /// | 138 chars, bracketed paste + `\r`, no gap | CR swallowed, **no submit**   |
    /// | 138 chars, two writes, 5 ms gap         | submits                         |
    /// | 138 chars, two writes, 20/100 ms gap    | submits                         |
    ///
    /// So two writes are necessary and not sufficient: back-to-back they land in one
    /// `read()` on the far side and are one chunk again. What the Return needs is to
    /// arrive in a read of its own, and the smallest gap that bought that was under
    /// 5 ms. 50 ms is a ten-fold margin on the measurement and still under a frame at
    /// 20 Hz, so nobody sees it.
    ///
    /// **This does not reinstate #29's race.** That was prose and its Return going as two
    /// calls where the CR could be *lost*; ordering here is guaranteed by both writes
    /// running on the main actor, and the gap is what makes the second one legible as a
    /// key press instead of more pasted text.
    static let submitGap: Duration = .milliseconds(50)

    /// Send `message` to `pty` and submit it: two writes, separated.
    ///
    /// Returns false when the message did not land — an empty draft, or a surface that
    /// refused it. **A refused message is never followed by a Return**, because a bare
    /// Return would submit whatever the operator had left in the agent's own box.
    /// Refusals are logged rather than only returned: a silent one is how #119 read from
    /// the outside, helm having cleared the composer and believed it had sent.
    @MainActor
    @discardableResult
    static func submit(
        _ message: String, to pty: PtyWriting, gap: Duration = submitGap
    ) async -> Bool {
        guard let action = messageAction(for: message) else { return false }
        if !pty.performBindingAction(action) {
            NSLog("helm: the agent never got the message — ghostty refused the text action")
            return false
        }
        try? await Task.sleep(for: gap)
        if !pty.performBindingAction(returnAction) {
            NSLog(
                "helm: the message is in the agent's box unsent — ghostty refused the Return")
        }
        return true
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

/// The real pty behind a chat face. A one-line conformance because the vendored view
/// already has the method — the protocol exists for the *other* implementation.
extension FocusClaimingTerminalView: PtyWriting {}
