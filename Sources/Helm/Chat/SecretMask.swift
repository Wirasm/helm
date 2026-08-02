import Foundation

/// Best-effort credential masking for prose on its way to the screen.
///
/// **Why a reading view needs this when a terminal does not.** Transcripts are
/// written unredacted — measured across this repo's store: zero `REDACTED`
/// markers, and a live `Bearer` token plus two `TOKEN=` assignments sitting in
/// one 13 MB file. Scrollback ages out; a rendered, selectable, scrollable page
/// does not. The chat face is strictly worse than the terminal here unless it
/// masks, which is why the spike had a mask at all.
///
/// **Plain string operations, no regex.** The mask was deleted from the clean
/// overlay because it was built on `NSRegularExpression` and the no-regex rule
/// took it out with the regex — but "no regex" and "no masking" were collapsed
/// into one rule and they are not the same rule. `hasPrefix` and a `=` split do
/// this job.
///
/// **It is best-effort and says so.** A secret with no shape — a bare hex blob,
/// a password in prose — still gets through. The count is returned rather than
/// swallowed so the view can admit how much it caught instead of implying it
/// caught everything.
enum SecretMask {
    static let placeholder = "●●● masked ●●●"

    /// Token prefixes that are self-identifying: seeing one *is* seeing a
    /// credential, whatever surrounds it.
    private static let secretPrefixes = [
        "sk-",  // OpenAI / Anthropic style
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_",  // GitHub
        "github_pat_",
        "xoxb-", "xoxp-", "xoxa-", "xoxs-", "xoxr-",  // Slack
        "AKIA", "ASIA",  // AWS access key ids
        "AIza",  // Google API
        "glpat-",  // GitLab
        "npm_", "pypi-",
    ]

    /// Assignment keys whose *value* is the secret. Compared case-insensitively
    /// against the key half of `KEY=value`.
    private static let secretKeySuffixes = [
        "token", "secret", "password", "passwd", "api_key", "apikey",
        "access_key", "secret_key", "private_key", "credential", "auth",
    ]

    /// The text with anything shaped like a credential replaced, and how many
    /// replacements were made.
    static func mask(_ text: String) -> (text: String, count: Int) {
        var output = ""
        output.reserveCapacity(text.count)
        var count = 0
        // `Bearer <token>` — the secret is the *next* word, so the scan has to
        // remember that the previous word armed it.
        var previousWasBearer = false

        for piece in split(text) {
            switch piece {
            case .separator(let separator):
                output += separator
            case .word(let word):
                let (masked, didMask) = maskWord(word, armed: previousWasBearer)
                if didMask { count += 1 }
                output += masked
                previousWasBearer = word == "Bearer" || word == "bearer"
            }
        }
        return (output, count)
    }

    /// True when `text` carries anything this mask would replace. Cheaper to read
    /// than `mask(_:).count > 0` at a call site that only wants the question.
    static func containsSecret(_ text: String) -> Bool { mask(text).count > 0 }

    // MARK: - One word

    private static func maskWord(_ word: String, armed: Bool) -> (String, Bool) {
        guard !word.isEmpty else { return (word, false) }

        // `Bearer <token>`: whatever follows the scheme is the credential.
        if armed, word.count >= 8 { return (placeholder, true) }

        // A PEM header is the start of a key block. Masking the marker line is
        // honest about what was found; the body below it is base64 with no shape
        // of its own and is left alone rather than guessed at.
        if word.hasPrefix("-----BEGIN"), Literal.contains("PRIVATE", in: word) {
            return (placeholder, true)
        }

        // KEY=value, where the key names a credential. Split on the FIRST `=` so
        // a base64 value's own padding does not confuse the halves.
        if let equals = word.firstIndex(of: "=") {
            let key = String(word[word.startIndex..<equals]).lowercased()
            let value = String(word[word.index(after: equals)...])
            if !value.isEmpty, secretKeySuffixes.contains(where: { key.hasSuffix($0) }) {
                return (String(word[word.startIndex..<equals]) + "=" + placeholder, true)
            }
        }

        // A self-identifying token. The length floor keeps the word `sk-` in
        // prose, or a bare `AKIA` being talked about, from reading as a hit.
        if word.count >= 12, secretPrefixes.contains(where: { word.hasPrefix($0) }) {
            return (placeholder, true)
        }

        return (word, false)
    }

    // MARK: - Splitting

    /// A word, or the run of whitespace between two words.
    ///
    /// Masking has to put the text back together byte-for-byte apart from the
    /// replacements — this is markdown on its way to a renderer, so a lost
    /// newline is a lost paragraph and a lost indent is a broken code block.
    private enum Piece {
        case word(String)
        case separator(String)
    }

    private static func split(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var current = ""
        var currentIsSeparator: Bool?

        for character in text {
            let isSeparator = character.isWhitespace || character.isNewline
            if currentIsSeparator == nil { currentIsSeparator = isSeparator }
            if isSeparator != currentIsSeparator {
                pieces.append(currentIsSeparator == true ? .separator(current) : .word(current))
                current = ""
                currentIsSeparator = isSeparator
            }
            current.append(character)
        }
        if !current.isEmpty {
            pieces.append(currentIsSeparator == true ? .separator(current) : .word(current))
        }
        return pieces
    }
}
