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
        // The prompt's own options are the last run numbered 1, 2, 3…: a numbered list above it
        // (the plan Claude asks to proceed with) is the agent's text, and its digits answer
        // nothing.
        guard let start = options.lastIndex(where: { $0.1.keys == "1" }) else { return nil }
        let run = options[start...]
        guard run.count >= 2, run.map(\.1.keys) == (1...run.count).map(String.init),
            let first = run.first
        else { return nil }
        let question = bottom[..<first.0].last { $0.hasSuffix("?") }
        let words = bottom[first.0...].joined(separator: " ").lowercased()
            .split { !$0.isLetter }
        return PromptChoices(
            question: question, choices: run.map(\.1),
            canEscape: words.contains("esc"))
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

    /// Entries a chat opens with, and each older page brings: the latest first, the rest as he
    /// scrolls up to them. A chat holds what he has scrolled through, not the whole transcript.
    package static let page = 30

    /// A page whose transcript holds no more entries than the newest read means the file was
    /// rewritten under the cursor: what was read is dropped, and the next ask starts over.
    package mutating func merge(_ page: BenchSessionLog) {
        if let newest, page.total <= newest {
            entries = []
        } else if page.entries.isEmpty {
            return
        }
        var byIndex = Dictionary(entries.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        for entry in page.entries { byIndex[entry.index] = entry }
        entries = byIndex.values.sorted { $0.index < $1.index }
    }
}

/// A chat row's last message: his or the agent's, never a tool line or another session's message,
/// cut to its first line.
package struct ChatPreview: Equatable, Sendable {
    package var text: String
    /// His own prompt, rather than the agent's reply.
    package var mine: Bool
    /// Its place in the transcript, which says whether he has read it.
    package var index: Int
    package var atMs: UInt64

    package init?(_ log: BenchSessionLog) {
        guard
            let last = log.entries.last(where: {
                ($0.kind == .user && $0.from == nil) || $0.kind == .agent
            })
        else { return nil }
        text = String(
            last.text.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        mine = last.kind == .user
        index = last.index
        atMs = last.atMs
    }

    /// The agent replied past the last entry he had on screen (`readThrough`), or he never opened
    /// the chat. Indices, not clocks: the transcript's and the phone's need not agree.
    package func isUnread(readThrough: Int?) -> Bool {
        !mine && index > (readThrough ?? -1)
    }
}
