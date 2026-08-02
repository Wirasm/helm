import XCTest

@testable import Helm

/// The mask restored with plain string operations.
///
/// It was deleted along with the regex it was built on — but "no regex" and "no
/// masking" were collapsed into one rule and they are not the same rule.
/// Transcripts are written unredacted (measured: 30 hits in a single 13.5 MB
/// file), and a chat view makes a credential scrollable, selectable and
/// searchable forever where scrollback would age it out.
final class SecretMaskTests: XCTestCase {
    private func mask(_ text: String) -> String { SecretMask.mask(text).text }

    /// A credential-shaped string, assembled at runtime from its prefix.
    ///
    /// **Never written as a literal.** A fixture that looks like a real token
    /// *is* a real token to a secret scanner, and a repo that trains its people
    /// to wave those through is how a live one eventually lands. Concatenating
    /// costs the test nothing — the mask sees the same bytes either way — and
    /// keeps the prefix, which is the actual subject, right there in the case.
    private func token(_ prefix: String, length: Int = 24) -> String {
        prefix + String(repeating: "0", count: max(0, length - prefix.count))
    }

    // MARK: - What it catches

    func testSelfIdentifyingTokensAreMasked() {
        for prefix in [
            "sk-", "ghp_", "gho_", "github_pat_", "xoxb-", "AKIA", "AIza", "glpat-", "npm_",
        ] {
            let secret = token(prefix)
            XCTAssertEqual(
                mask("here it is \(secret) ok"), "here it is \(SecretMask.placeholder) ok",
                "the \(prefix) prefix is a credential wherever it appears")
        }
    }

    func testBearerTokenIsMasked() {
        XCTAssertEqual(
            mask("Authorization: Bearer \(token("t", length: 16))"),
            "Authorization: Bearer \(SecretMask.placeholder)")
    }

    /// The key names the secret, so the *value* is what goes — keeping the key
    /// visible is what makes the masking legible rather than mysterious.
    func testAssignmentValuesAreMaskedAndKeysKept() {
        XCTAssertEqual(
            mask("export GITHUB_TOKEN=\(token("ghp_"))"),
            "export GITHUB_TOKEN=\(SecretMask.placeholder)")
        XCTAssertEqual(mask("API_KEY=abc123"), "API_KEY=\(SecretMask.placeholder)")
        XCTAssertEqual(mask("db_password=hunter2"), "db_password=\(SecretMask.placeholder)")
    }

    func testPemHeaderIsMasked() {
        XCTAssertEqual(
            mask("-----BEGIN-RSA-PRIVATE-KEY----- rest"),
            "\(SecretMask.placeholder) rest")
    }

    func testCountIsReportedSoTheViewCanAdmitIt() {
        let result = SecretMask.mask("\(token("sk-")) and API_KEY=bbbbbb and nothing")
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - What it must not touch

    /// The mask runs over markdown on its way to a renderer, so it has to put the
    /// text back byte-for-byte apart from the replacements. A lost newline is a
    /// lost paragraph; a lost indent is a broken code block.
    func testWhitespaceAndStructureSurviveExactly() {
        let markdown = "# Heading\n\n- one\n- two\n\n```sh\n  indented\n```\n"
        XCTAssertEqual(mask(markdown), markdown)
    }

    func testOrdinaryProseIsUntouched() {
        let prose = "The token bucket refills every second. See docs/auth.md for the secret sauce."
        XCTAssertEqual(mask(prose), prose)
    }

    /// Talking *about* a credential shape is not carrying one. The length floor
    /// is what separates the two.
    func testShortLookalikesAreNotMasked() {
        XCTAssertEqual(mask("the sk- prefix"), "the sk- prefix")
        XCTAssertEqual(mask("AKIA keys start with AKIA"), "AKIA keys start with AKIA")
    }

    /// An assignment whose key names nothing secret keeps its value — masking
    /// every `=` would make ordinary output unreadable.
    func testNonSecretAssignmentsAreKept() {
        XCTAssertEqual(mask("count=42"), "count=42")
        XCTAssertEqual(mask("PATH=/usr/bin"), "PATH=/usr/bin")
    }

    func testEmptyInput() {
        XCTAssertEqual(mask(""), "")
        XCTAssertEqual(SecretMask.mask("").count, 0)
    }
}
