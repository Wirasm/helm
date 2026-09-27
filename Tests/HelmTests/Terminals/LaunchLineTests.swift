import XCTest

@testable import Helm

/// Every word of a line helm composes is quoted: the sessions drawer's lines, and the words of
/// `bench attach` a pane runs. (The resume posture tests went with #85's resume line, M5b: a pane's
/// agent is resumed by benchd, with the posture `bench_session::argv` spells.)
final class LaunchLineTests: XCTestCase {
    func testQuotingSurvivesAnEmbeddedSingleQuote() {
        XCTAssertEqual(LaunchLine.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(LaunchLine.quoted("; rm -rf /"), "'; rm -rf /'")
    }
}
