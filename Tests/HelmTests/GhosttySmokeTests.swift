import XCTest
@testable import Helm

/// Non-GUI smoke for the libghostty embed: ghostty_init, config render + load
/// (with helm's overrides), and ghostty app creation all happen inside
/// `TerminalController.init` — no window, no surface, no pty. Surface spawning
/// needs a window and stays a human/visual check (docs/SPIKE.md exit criteria).
final class GhosttySmokeTests: XCTestCase {
    @MainActor
    func testGhosttyInitAndConfigLoad() {
        let controller = TerminalSession.makeController()
        XCTAssertNil(
            controller.lastConfigurationIssue,
            "ghostty rejected helm's config: \(controller.lastConfigurationIssue ?? "")"
        )
        XCTAssertTrue(
            controller.renderedConfig.contains("term = xterm-256color"),
            "TERM override missing — TUIs will break without ghostty's terminfo"
        )
    }
}
