import Foundation
import HelmWire

/// A waiting prompt's choices, read off the bottom of its screen (`screen/get`), for buttons that
/// answer it with the keys a hand at the terminal would press: a numbered option's digit, and Esc
/// when the prompt says Esc cancels. Claude's permission prompt, codex's approval and hook review
/// number their options; a menu moved with the arrows offers none here, and the keys row answers it.
package struct PromptChoices: Equatable, Sendable {
    package struct Choice: Equatable, Sendable {
        package var label: String
        /// What `screen/send keys` types: the option's digit.
        package var keys: String
    }

    /// The line ending in `?` above the options, when there is one.
    package var question: String?
    package var choices: [Choice]
    package var canEscape: Bool

    /// Only the bottom of a screen holds a live prompt: an answered one scrolls away, and numbered
    /// lines higher up are the agent's own text.
    static let tail = 16

    /// The prompt at the bottom of `lines`, or nil when no numbered options are there.
    package static func read(_ lines: [String]) -> PromptChoices? {
        let bottom = Array(
            lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .suffix(tail))
        let options = bottom.enumerated().compactMap { offset, line in
            option(line).map { (offset, $0) }
        }
        guard let first = options.first, options.count >= 2 else { return nil }
        let question = bottom[..<first.0].last { $0.hasSuffix("?") }
        let after = bottom[first.0...].joined(separator: " ").lowercased()
        return PromptChoices(
            question: question, choices: options.map(\.1),
            canEscape: after.contains("esc"))
    }

    /// `❯ 1. Yes` or `2. No`: a digit, a dot, the label; a cursor mark in front is allowed.
    private static func option(_ line: String) -> Choice? {
        var rest = Substring(line)
        if let mark = rest.first, "❯›>→".contains(mark) {
            rest = rest.dropFirst().drop { $0 == " " }
        }
        guard let digit = rest.first, digit.isNumber, digit != "0",
            rest.dropFirst().hasPrefix(". ")
        else { return nil }
        let label = rest.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : Choice(label: label, keys: String(digit))
    }
}

/// One chat's conversation: every transcript entry Pocket has read, in order and once each,
/// however the pages (`sessions/log`) arrived.
package struct ChatLog: Equatable, Sendable {
    package private(set) var entries: [BenchLogEntry] = []

    package init() {}

    /// The cursor to follow new entries with (`after`): the newest index read.
    package var newest: Int? { entries.last?.index }
    /// The cursor to page back with (`before`).
    package var oldest: Int? { entries.first?.index }
    /// Whether the transcript holds entries before the oldest read.
    package var hasOlder: Bool { (oldest ?? 0) > 0 }

    package mutating func merge(_ page: BenchSessionLog) {
        var byIndex = Dictionary(entries.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in page.entries { byIndex[entry.index] = entry }
        entries = byIndex.values.sorted { $0.index < $1.index }
    }
}

/// A chat row's last message: his or the agent's, never a tool line, cut to its first line.
package struct ChatPreview: Equatable, Sendable {
    package var text: String
    /// His own prompt, rather than the agent's reply.
    package var mine: Bool
    /// When it was written, from the transcript's timestamp.
    package var atMs: UInt64?

    package init?(_ log: BenchSessionLog) {
        guard let last = log.entries.last(where: { $0.kind == .user || $0.kind == .agent })
        else { return nil }
        text = String(
            last.text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        mine = last.kind == .user
        atMs = Self.epochMs(last.at)
    }

    /// The agent replied after he last opened the chat (or he never has).
    package func isUnread(openedAtMs: UInt64?) -> Bool {
        guard !mine, let atMs else { return false }
        return openedAtMs.map { atMs > $0 } ?? true
    }

    private static func epochMs(_ text: String) -> UInt64? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        else { return nil }
        return UInt64(max(0, date.timeIntervalSince1970 * 1000))
    }
}
