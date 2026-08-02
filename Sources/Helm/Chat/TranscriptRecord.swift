import Foundation

/// What one JSONL line of a Claude Code transcript means to the chat face.
///
/// **No regex, anywhere in this file.** Every decision is a lookup on the
/// record's own typed fields — `type`, `message.content`, the block's `type`,
/// `isMeta` — or a structural test on a tag's shape. Nothing is pattern-matched
/// against prose. `Literal` at the bottom exists so even the closing-tag test is
/// a hand-written byte scan rather than a call that could resolve to a regex
/// overload; grep this file for `Regex`, `NSRegularExpression` or `range(of:`
/// and it comes back empty.
enum TranscriptRecord: Equatable {
    /// The operator typed this. Opens a new turn.
    case operatorPrompt(String)
    /// A `user` record that the operator did not write — a tool result coming
    /// back, or a machine-authored injection. Activity, never prose, and it does
    /// **not** open a turn: it belongs to the turn already running.
    case machineTurn
    /// One `text` block from an assistant record: the only thing drawn as prose.
    case agentProse(String)
    /// `thinking` or `tool_use`. Evidence the agent is alive and nothing more —
    /// this is what the ticker draws, and it is never named or rendered.
    case agentActivity
    /// Bookkeeping with nothing to say: `system`, `attachment`, `mode`,
    /// `ai-title`, `file-history-*`, and the dozen others a transcript carries.
    /// Never invented into prose.
    case ignored

    /// Every meaning one line carries, in file order.
    ///
    /// A list because one assistant record can hold several content blocks and
    /// each is its own beat. Measured across 38 transcripts of this repo (17,166
    /// records): assistant records carry exactly one block type each — 3,028
    /// `tool_use`, 1,821 `thinking`, 1,607 `text`, never mixed — but the format
    /// permits more and the cost of handling it is one loop.
    static func meanings(of record: [String: Any]) -> [TranscriptRecord] {
        switch record["type"] as? String {
        case "user": return [userMeaning(record)]
        case "assistant": return assistantMeanings(record)
        default: return [.ignored]
        }
    }

    // MARK: - user

    /// Who actually wrote this `user` record.
    ///
    /// **Two independent tests, and both are needed.** Measured over 300
    /// transcripts (4,045 user text blocks): `isMeta` is set on 384 records but
    /// misses 1,126 marker-carrying ones — `<task-notification>` alone accounts
    /// for 926 with `isMeta` absent. In the other direction, 301 records carry
    /// `isMeta` with no marker at all ("Another Claude session sent a
    /// message: …", skill preambles). Neither test subsumes the other, so a view
    /// that trusts one of them styles roughly a third of the machine's words as
    /// the operator's.
    private static func userMeaning(_ record: [String: Any]) -> TranscriptRecord {
        if record["isMeta"] as? Bool == true { return .machineTurn }

        let content = (record["message"] as? [String: Any])?["content"]

        // A bare string is always the whole prompt.
        if let text = content as? String {
            return prompt(from: text)
        }
        // An array: `text` blocks are candidate prose. An array of nothing but
        // `tool_result` is the agent's own work coming back — activity that
        // stays inside the turn it belongs to, never a new turn.
        if let blocks = content as? [[String: Any]] {
            let texts = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            guard !texts.isEmpty else { return .machineTurn }
            return prompt(from: texts.joined(separator: "\n\n"))
        }
        return .ignored
    }

    private static func prompt(from text: String) -> TranscriptRecord {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ignored
        }
        return machineMarker(in: text) == nil ? .operatorPrompt(text) : .machineTurn
    }

    // MARK: - assistant

    private static func assistantMeanings(_ record: [String: Any]) -> [TranscriptRecord] {
        guard let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return [.ignored] }

        return blocks.map { block in
            guard block["type"] as? String == "text",
                let text = block["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .agentActivity }
            return .agentProse(text)
        }
    }

    // MARK: - The machinery marker

    /// The tag name of a machine-authored injection, or nil when the operator
    /// wrote it.
    ///
    /// **Structural, not a list.** The measured openers are
    /// `<task-notification>`, `<command-name>`, `<command-message>`,
    /// `<local-command-stdout>`, `<local-command-caveat>`, `<bash-input>`,
    /// `<bash-stdout>` and `<system-reminder>` — but that set has grown twice
    /// already (#29's reader found `<bash-input>`/`<bash-stdout>` outside the
    /// list #20 measured; this build found `<command-message>` outside both), so
    /// a hard-coded list fails *silently* in exactly the direction that matters.
    /// The shape is the rule: a lowercase `[a-z0-9-]` tag at the very start.
    ///
    /// **And the tag must close.** All 1,209 machine records measured close their
    /// own tag; requiring it costs nothing and is what keeps an operator who
    /// opens a message with `<placeholder>` from having their words silently
    /// dropped. Measured false positives on 2,535 human prose records: zero.
    static func machineMarker(in text: String) -> String? {
        let trimmed = text.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.first == "<" else { return nil }

        let body = trimmed.dropFirst()
        guard let close = body.firstIndex(of: ">") else { return nil }
        let tag = body[body.startIndex..<close]

        // A tag, not a comparison and not prose: bounded, opening on a lowercase
        // letter, and nothing but lowercase letters, digits and hyphens after it.
        guard let first = tag.first, first.isLetter, first.isLowercase,
            tag.count <= 40,
            tag.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" })
        else { return nil }

        guard Literal.contains("</\(tag)>", in: text) else { return nil }
        return String(tag)
    }
}

/// A literal substring search, written out by hand.
///
/// `String.contains(_:)` and `range(of:)` would both do this, and neither is a
/// regex — but both have overloads that take a `RegexComponent`, so their
/// presence makes the no-regex rule something you have to check the types to
/// believe rather than something you can grep for. This is eleven lines and
/// leaves nothing to check.
enum Literal {
    static func contains(_ needle: String, in haystack: String) -> Bool {
        let needleBytes = Array(needle.utf8)
        let hayBytes = Array(haystack.utf8)
        guard !needleBytes.isEmpty, hayBytes.count >= needleBytes.count else {
            return needleBytes.isEmpty
        }
        for start in 0...(hayBytes.count - needleBytes.count) {
            var matched = true
            for offset in 0..<needleBytes.count
            where hayBytes[start + offset] != needleBytes[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }
}
