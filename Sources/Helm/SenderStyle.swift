import AppKit
import SwiftUI

/// Visual identity rules for a kild's log: who is speaking, at a glance.
///
/// The human is the special case; every agent handle gets a stable accent derived
/// deterministically from the handle, so a sender keeps its colour across refreshes,
/// kilds, and launches.
enum SenderStyle {
    /// A message the engine could not attribute to a credential is recorded as `human`.
    ///
    /// That is **not** a fallback to treat with suspicion — it is the correct answer for
    /// the operator's own shell, which legitimately sends without attaching. The engine
    /// deliberately does not refuse unattributed sends for exactly this reason: refusing
    /// them would break the human's primary interface to their own engine.
    ///
    /// The caveat worth knowing: an *agent* that sends without presenting its credential
    /// also lands here, and then reads as the operator. That was a real bug in the CLI, now
    /// fixed engine-side — but it is why this name means "unattributed", not "definitely a
    /// person".
    static func isHuman(_ name: String) -> Bool {
        name.caseInsensitiveCompare("human") == .orderedSame
    }

    /// Small palette of system dynamic colors — they adapt to light/dark and stay
    /// legible as text in both. Deliberately absent because reserved elsewhere:
    /// orange (collisions and derived values), red (the waiting badge and errors),
    /// green (engine health), and the app accent (the human's own messages).
    ///
    /// Orange was previously reserved for open decisions. That concept moved to PRP, and
    /// the colour was reassigned rather than freed — it now marks a value helm derived
    /// rather than one the engine reported, which is the distinction most worth seeing.
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
