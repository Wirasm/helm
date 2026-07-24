import AppKit
import SwiftUI

/// Visual identity rules for the room log: who is speaking, at a glance.
///
/// The human is the special case (accent-tinted, trailing-aligned, chat-style);
/// every agent sender gets a stable accent color derived deterministically from
/// its name, so a sender keeps its color across refreshes, rooms, and launches.
enum SenderStyle {
    /// The engine attributes operator posts to this name (see `EngineClient.post`:
    /// omitting `from`/`sessionId` makes the post the human's).
    static func isHuman(_ name: String) -> Bool {
        name.caseInsensitiveCompare("human") == .orderedSame
    }

    /// Small palette of system dynamic colors — they adapt to light/dark and stay
    /// legible as text in both. Deliberately absent because reserved elsewhere:
    /// orange (open decisions), red (errors), green (engine health), and the
    /// app accent (the human's own posts).
    private static let palette: [Color] = [.blue, .purple, .indigo, .teal, .pink, .brown]

    /// Stable accent for an agent name: FNV-1a over the lowercased UTF-8 bytes,
    /// mapped into the palette. Swift's `Hasher` is seeded per launch and would
    /// shuffle colors on every start — hence the hand-rolled hash.
    static func accent(for name: String) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

/// Clipboard helper shared by the room-detail header and the sidebar context menu.
enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
